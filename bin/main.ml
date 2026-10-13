open! Core
open! Async
open Hl_copy_engine
module Signing = Hl_client.Signing

let api_param =
  let%map_open.Command base_url =
    flag
      "-base-url"
      (optional_with_default "http://localhost:3000" string)
      ~doc:"URL hl-sim or testnet API root (default http://localhost:3000)"
  and ws_url =
    flag "-ws-url" (optional string) ~doc:"URL websocket (default from -base-url)"
  in
  let config =
    Hl_client.Config.create
      ?ws_url:(Option.map ws_url ~f:Uri.of_string)
      ~base_url:(Uri.of_string base_url)
      ()
  in
  match Safety.check_config config with
  | Ok () -> config
  | Error err ->
    (* With [open! Async] a plain eprintf is lost before exit; see GOTCHAS. *)
    Core.eprintf "%s\n" (Error.to_string_hum err);
    Stdlib.exit 2
;;

let key_of_env var =
  match Signing.Private_key.of_env ~var () with
  | Ok key -> key
  | Error _ ->
    Core.eprintf "%s is not set to a 64-digit hex private key\n" var;
    Stdlib.exit 2
;;

let log_level_param =
  let%map_open.Command level =
    flag
      "-log-level"
      (optional_with_default "info" string)
      ~doc:"LEVEL debug, info or error (default info)"
  in
  Log.Global.set_output [ Log.Output.stderr () ];
  Log.Global.set_level (Log.Level.of_string level)
;;

let run_command =
  Command.async
    ~summary:"Run the copy-trading engine over a directory of follow files"
    ~readme:(fun () ->
      "Follow files are Hl_copy_core.Follower_config sexps (*.sexp). Orders are signed \
       by the agent key in the environment variable named by -agent-key-env (development \
       only, one agent for every follow), or sent unsigned with -unsigned (hl-sim \
       without -strict-signatures). Mainnet URLs are refused.")
    (let%map_open.Command api = api_param
     and () = log_level_param
     and configs_dir =
       flag "-configs-dir" (required string) ~doc:"DIR directory of follow files"
     and journal_dir =
       flag "-journal-dir" (optional string) ~doc:"DIR per-follow journals (default none)"
     and port =
       flag
         "-port"
         (optional_with_default 9930 int)
         ~doc:"PORT /metrics, /status and /healthz (default 9930)"
     and resync_s =
       flag
         "-resync-s"
         (optional_with_default 30 int)
         ~doc:"S resync both accounts every S seconds (default 30)"
     and scan_ms =
       flag
         "-scan-ms"
         (optional_with_default 1000 int)
         ~doc:"MS rescan the follow files every MS milliseconds (default 1000)"
     and max_ws_leaders =
       flag
         "-max-ws-leaders"
         (optional_with_default Hl_client.User_feed.default_max_users int)
         ~doc:"N leaders followed over the websocket; more are polled (default 10)"
     and leader_poll_s =
       flag
         "-leader-poll-s"
         (optional_with_default 5 int)
         ~doc:"S poll interval of leaders past -max-ws-leaders (default 5)"
     and agent_key_env =
       flag
         "-agent-key-env"
         (optional string)
         ~doc:"VAR environment variable holding the agent key"
     and unsigned =
       flag "-unsigned" no_arg ~doc:" send unsigned orders (hl-sim only, X-Address)"
     in
     fun () ->
       let signer : Follower.Signer.t =
         match agent_key_env, unsigned with
         | Some var, false -> Agent (key_of_env var)
         | None, true -> Unsigned
         | _ ->
           Core.eprintf "pass exactly one of -agent-key-env and -unsigned\n";
           Stdlib.exit 2
       in
       let config =
         Engine.Config.create
           ?journal_root:journal_dir
           ~scan_interval:(Time_ns.Span.of_int_ms scan_ms)
           ~resync_interval:(Time_ns.Span.of_int_sec resync_s)
           ~max_ws_users:max_ws_leaders
           ~leader_poll_interval:(Time_ns.Span.of_int_sec leader_poll_s)
           ~api
           ~configs_dir
           ~signer_for:(fun _ -> return (Ok signer))
           ()
       in
       match%bind Engine.start ~port config with
       | Error err ->
         Core.eprintf "%s\n" (Error.to_string_hum err);
         Stdlib.exit 1
       | Ok engine ->
         Log.Global.info_s
           [%message
             "engine started"
               ~port:(Engine.port engine : int option)
               ~followers:(List.length (Engine.followers engine) : int)];
         (* Command.async does not run at_shutdown handlers on SIGTERM by itself; the
            journals must be flushed. *)
         Shutdown.at_shutdown (fun () -> Engine.stop engine);
         Signal.handle Signal.terminating ~f:(fun _ -> shutdown 0);
         Deferred.never ())
;;

let approve_agent_command =
  Command.async_or_error
    ~summary:"Approve an agent for an account (hl-sim and testnet only)"
    ~readme:(fun () ->
      "Signs approveAgent with the account key from -user-key-env, for the address of \
       the key in -agent-key-env. In production the user's wallet signs this in the \
       browser; this command is for local runs. Keys are never printed.")
    (let%map_open.Command api = api_param
     and () = log_level_param
     and user_key_env =
       flag "-user-key-env" (required string) ~doc:"VAR environment variable, account key"
     and agent_key_env =
       flag "-agent-key-env" (required string) ~doc:"VAR environment variable, agent key"
     and name =
       flag
         "-name"
         (optional_with_default "copy" string)
         ~doc:"NAME agent name (default copy)"
     in
     fun () ->
       let user = key_of_env user_key_env in
       let agent = key_of_env agent_key_env in
       let owner = Hl_client.Client.trading ~is_mainnet:false ~key:user api in
       let%map.Deferred.Or_error response =
         Hl_client.Client.approve_agent
           owner
           ~agent_address:(Signing.Private_key.address agent)
           ~agent_name:name
       in
       print_s
         [%message
           ""
             ~account:(Signing.Private_key.address user : Hl_protocol.Address.t)
             ~agent:(Signing.Private_key.address agent : Hl_protocol.Address.t)
             (response : Hl_protocol.Exchange_response.t)])
;;

let replay_command =
  Command.async_or_error
    ~summary:"Replay a follow's journal and check every output matches"
    (let%map_open.Command dir =
       anon ("DIR" %: string)
       (* <journal-dir>/<follower>-<leader> *)
     and show_state = flag "-state" no_arg ~doc:" print the final state" in
     fun () ->
       let%bind entries = Journal.load dir in
       Deferred.return
         (let%bind.Or_error verified = Journal.verify entries in
          print_s
            [%message
              ""
                ~entries:(List.length entries : int)
                ~inputs:(verified.inputs : int)
                ~outputs:(verified.outputs : int)
                ~orders:(verified.orders : int)
                ~identical:(Option.is_none verified.mismatch : bool)];
          if show_state then print_s [%sexp (verified.final : Follower_core.t option)];
          match verified.mismatch with
          | None -> Ok ()
          | Some (index, recorded, replayed) ->
            Or_error.error_s
              [%message
                "replay differs"
                  (index : int)
                  (recorded : Follower_core.Output.t)
                  (replayed : Follower_core.Output.t)]))
;;

let () =
  Command.group
    ~summary:"Copy-trading engine for Hyperliquid (hl-sim and testnet)"
    [ "run", run_command
    ; "approve-agent", approve_agent_command
    ; "replay", replay_command
    ]
  |> Command_unix.run
;;
