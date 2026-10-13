open! Core
open! Async
open Hl_copy_core

module Config = struct
  type t =
    { api : Hl_client.Config.t
    ; configs_dir : string
    ; journal_root : string option
    ; scan_interval : Time_ns.Span.t
    ; resync_interval : Time_ns.Span.t
    ; max_ws_users : int
    ; leader_poll_interval : Time_ns.Span.t
    ; signer_for : Follower_config.t -> Follower.Signer.t Or_error.t Deferred.t
    ; agent_of : (Follower_config.t -> Address.t option Or_error.t) option
    ; builder : Hl_protocol.Builder_fee.t option
    }

  let create
    ?journal_root
    ?(scan_interval = Time_ns.Span.of_int_sec 1)
    ?(resync_interval = Time_ns.Span.of_int_sec 30)
    ?(max_ws_users = Hl_client.User_feed.default_max_users)
    ?(leader_poll_interval = Time_ns.Span.of_int_sec 5)
    ?agent_of
    ?builder
    ~api
    ~configs_dir
    ~signer_for
    ()
    =
    { api
    ; configs_dir
    ; journal_root
    ; scan_interval
    ; resync_interval
    ; max_ws_users
    ; leader_poll_interval
    ; signer_for
    ; agent_of
    ; builder
    }
  ;;
end

(* Why a file is not running: kept across scans so a failed start is retried only when the
   file or the account's agent changes, or after [retry_after] (each start reads [meta],
   weight 20). *)
type failure =
  { contents : string
  ; follow : Follower_config.t option
  ; error : Error.t
  ; agent : Address.t option Or_error.t option
  ; at : Time_ns.t
  }

type running =
  { contents : string
  ; follower : Follower.t
  }

type t =
  { config : Config.t
  ; hub : Leader_hub.t
  ; rate_limit : Rate_limit.t
  ; running : running String.Table.t (** by file name *)
  ; failures : failure String.Table.t
  ; mutable dir_error : Error.t option
  ; mutable http : (Socket.Address.Inet.t, int) Cohttp_async.Server.t option
  ; scanning : unit Sequencer.t
  ; stopped : unit Ivar.t
  }

let followers t =
  Hashtbl.data t.running
  |> List.map ~f:(fun r -> r.follower)
  |> List.sort ~compare:(fun a b ->
    [%compare: Address.t * Address.t]
      ((Follower.follow a).follower, (Follower.follow a).leader)
      ((Follower.follow b).follower, (Follower.follow b).leader))
;;

let find t ~follower ~leader =
  List.find (followers t) ~f:(fun f ->
    let follow = Follower.follow f in
    Address.equal follow.follower follower && Address.equal follow.leader leader)
;;

let errors t =
  Option.to_list (Option.map t.dir_error ~f:(fun e -> t.config.configs_dir, e))
  @ (Hashtbl.to_alist t.failures
     |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b)
     |> List.map ~f:(fun (name, (f : failure)) -> name, f.error))
;;

let same_pair (a : Follower_config.t) (b : Follower_config.t) =
  Address.equal a.follower b.follower && Address.equal a.leader b.leader
;;

let start_follower t follow =
  let open Deferred.Or_error.Let_syntax in
  let%bind signer = t.config.signer_for follow in
  Follower.start
    ~hub:t.hub
    ~rate_limit:t.rate_limit
    ~api:t.config.api
    (Follower.Config.create
       ?journal_root:t.config.journal_root
       ~resync_interval:t.config.resync_interval
       ?builder:t.config.builder
       ~signer
       follow)
;;

let read_dir dir =
  match%bind Monitor.try_with_or_error (fun () -> Sys.readdir dir) with
  | Error _ as e -> return e
  | Ok names ->
    let names =
      Array.to_list names
      |> List.filter ~f:(fun n ->
        String.is_suffix n ~suffix:".sexp" && not (String.is_prefix n ~prefix:"."))
      |> List.sort ~compare:String.compare
    in
    let%map files =
      Deferred.List.filter_map ~how:`Sequential names ~f:(fun name ->
        match%map
          Monitor.try_with_or_error (fun () -> Reader.file_contents (dir ^/ name))
        with
        | Ok contents -> Some (name, contents)
        | Error _ -> None (* removed between readdir and read *))
    in
    Ok files
;;

let retry_after = Time_ns.Span.of_int_sec 30

let current_agent t follow =
  Option.map t.config.agent_of ~f:(fun agent_of -> agent_of follow)
;;

let same_agent a b =
  match a, b with
  | None, None -> true
  | Some (Ok a), Some (Ok b) -> Option.equal Address.equal a b
  | Some (Error _), Some (Error _) -> true
  | _ -> false
;;

let fail t name ~contents ?follow error =
  let agent = Option.bind follow ~f:(current_agent t) in
  Hashtbl.set
    t.failures
    ~key:name
    ~data:{ contents; follow; error; agent; at = Time_ns.now () }
;;

(* Restart a follower whose account's agent was rotated; pause one whose agent was revoked
   (the key file is gone). *)
let check_agent t name (r : running) =
  match current_agent t (Follower.follow r.follower) with
  | None | Some (Error _) -> return ()
  | Some (Ok None) ->
    (match (Follower.state r.follower).status with
     | Running -> Follower.pause r.follower ~reason:"agent revoked"
     | Paused _ | Stopped -> return ())
  | Some (Ok (Some agent)) ->
    if Option.equal Address.equal (Follower.agent_address r.follower) (Some agent)
    then return ()
    else (
      Log.Global.info_s
        [%message
          "agent changed, restarting the follower"
            ~follower:((Follower.follow r.follower).follower : Address.t)];
      let follow = Follower.follow r.follower in
      (* The stopped follower stays listed until its replacement is up, so [/status] never
         loses the follow in between. *)
      let%bind () = Follower.stop r.follower in
      match%map start_follower t follow with
      | Ok follower -> Hashtbl.set t.running ~key:name ~data:{ r with follower }
      | Error err ->
        Hashtbl.remove t.running name;
        fail t name ~contents:r.contents ~follow err)
;;

let apply_file t (name, contents) =
  match Hashtbl.find t.running name with
  | Some r when String.equal r.contents contents -> check_agent t name r
  | existing ->
    (match Follower_config.of_file_contents contents with
     | Error err ->
       fail t name ~contents err;
       return ()
     | Ok follow ->
       let retry =
         match Hashtbl.find t.failures name with
         | Some f when Option.is_none existing && String.equal f.contents contents ->
           Time_ns.Span.( >= ) (Time_ns.diff (Time_ns.now ()) f.at) retry_after
           || not (same_agent f.agent (current_agent t follow))
         | _ -> true
       in
       let duplicate =
         Hashtbl.existsi t.running ~f:(fun ~key ~data ->
           (not (String.equal key name))
           && same_pair (Follower.follow data.follower) follow)
       in
       if not retry
       then return ()
       else if duplicate
       then (
         fail
           t
           name
           ~contents
           ~follow
           (Error.of_string "another file already follows this pair");
         return ())
       else (
         match existing with
         | Some r when same_pair (Follower.follow r.follower) follow ->
           (match%map Follower.reconfigure r.follower follow with
            | Ok () -> Hashtbl.set t.running ~key:name ~data:{ r with contents }
            | Error err -> fail t name ~contents ~follow err)
         | _ ->
           let%bind () =
             match existing with
             | None -> return ()
             | Some r ->
               Hashtbl.remove t.running name;
               Follower.stop r.follower
           in
           (match%map start_follower t follow with
            | Ok follower ->
              Hashtbl.remove t.failures name;
              Hashtbl.set t.running ~key:name ~data:{ contents; follower }
            | Error err ->
              Log.Global.info_s [%message "follow not started" name (err : Error.t)];
              fail t name ~contents ~follow err)))
;;

let scan_once t =
  match%bind read_dir t.config.configs_dir with
  | Error err ->
    t.dir_error <- Some err;
    return ()
  | Ok files ->
    t.dir_error <- None;
    let present = String.Set.of_list (List.map files ~f:fst) in
    (* Removed files first, so a follow renamed to another file restarts cleanly. *)
    let%bind () =
      Deferred.List.iter ~how:`Sequential (Hashtbl.keys t.running) ~f:(fun name ->
        if Set.mem present name
        then return ()
        else (
          match Hashtbl.find_and_remove t.running name with
          | None -> return ()
          | Some r -> Follower.stop r.follower))
    in
    Hashtbl.filter_keys_inplace t.failures ~f:(Set.mem present);
    Deferred.List.iter ~how:`Sequential files ~f:(apply_file t)
;;

let scan t =
  if Ivar.is_full t.stopped
  then return ()
  else Throttle.enqueue t.scanning (fun () -> scan_once t)
;;

let metrics_text t =
  Metrics.prometheus
    (List.map (followers t) ~f:(fun f ->
       let follow = Follower.follow f in
       ( ~follower:(Address.to_string follow.follower)
       , ~leader:(Address.to_string follow.leader)
       , Follower.metrics f )))
  ^ sprintf
      "# HELP hl_copy_followers Followers running.\n\
       # TYPE hl_copy_followers gauge\n\
       hl_copy_followers %d\n\
       # HELP hl_copy_config_errors Follow files not applied in the last scan.\n\
       # TYPE hl_copy_config_errors gauge\n\
       hl_copy_config_errors %d\n\
       # HELP hl_copy_rest_weight_total REST weight spent.\n\
       # TYPE hl_copy_rest_weight_total counter\n\
       hl_copy_rest_weight_total %d\n"
      (Hashtbl.length t.running)
      (List.length (errors t))
      (Rate_limit.taken t.rate_limit)
;;

let status_json t =
  `Assoc
    [ ( "followers"
      , `List
          (List.map (followers t) ~f:Follower.status_json
           @ (Hashtbl.to_alist t.failures
              |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b)
              |> List.filter_map ~f:(fun (_, (f : failure)) ->
                Option.map f.follow ~f:(fun (follow : Follower_config.t) ->
                  `Assoc
                    [ "follower", `String (Address.to_string follow.follower)
                    ; "leader", `String (Address.to_string follow.leader)
                    ; "state", `String "error"
                    ; "pnl", `Float 0.
                    ; "positions", `List []
                    ; "last_error", `String (Error.to_string_hum f.error)
                    ])))) )
    ; ( "leaders"
      , `List
          (List.map (Leader_hub.leaders t.hub) ~f:(fun (leader, source, consumers) ->
             `Assoc
               [ "leader", `String (Address.to_string leader)
               ; ( "source"
                 , `String
                     (match source with
                      | Websocket -> "websocket"
                      | Polling -> "polling") )
               ; "followers", `Int consumers
               ])) )
    ; ( "errors"
      , `List
          (List.map (errors t) ~f:(fun (file, err) ->
             `Assoc [ "file", `String file; "error", `String (Error.to_string_hum err) ]))
      )
    ; "rest_weight", `Int (Rate_limit.taken t.rate_limit)
    ]
;;

let respond t (request : Cohttp.Request.t) =
  let path = Uri.path (Cohttp.Request.uri request) in
  let text ?(status = `OK) ~content_type body =
    Cohttp_async.Server.respond_string
      ~status
      ~headers:(Cohttp.Header.of_list [ "content-type", content_type ])
      body
  in
  match path with
  | "/metrics" -> text ~content_type:"text/plain; version=0.0.4" (metrics_text t)
  | "/status" ->
    text ~content_type:"application/json" (Yojson.Safe.to_string (status_json t))
  | "/healthz" -> text ~content_type:"text/plain" "ok\n"
  | _ -> text ~status:`Not_found ~content_type:"text/plain" "not found\n"
;;

let rec scan_loop t =
  let%bind () =
    Deferred.any_unit [ Clock_ns.after t.config.scan_interval; Ivar.read t.stopped ]
  in
  if Ivar.is_full t.stopped
  then return ()
  else (
    let%bind () = scan t in
    scan_loop t)
;;

let start ?port (config : Config.t) =
  match Safety.check_config config.api with
  | Error _ as e -> return e
  | Ok () ->
    let rate_limit = Rate_limit.hyperliquid () in
    let t =
      { config
      ; hub =
          Leader_hub.create
            ~max_ws_users:config.max_ws_users
            ~poll_interval:config.leader_poll_interval
            ~rate_limit
            config.api
      ; rate_limit
      ; running = String.Table.create ()
      ; failures = String.Table.create ()
      ; dir_error = None
      ; http = None
      ; scanning = Sequencer.create ~continue_on_error:true ()
      ; stopped = Ivar.create ()
      }
    in
    let%bind () =
      match port with
      | None -> return ()
      | Some port ->
        let%map http =
          Cohttp_async.Server.create
            ~on_handler_error:`Ignore
            (Tcp.Where_to_listen.of_port port)
            (fun ~body:_ _ request -> respond t request)
        in
        t.http <- Some http
    in
    let%map () = scan t in
    don't_wait_for (scan_loop t);
    Ok t
;;

let port t = Option.map t.http ~f:Cohttp_async.Server.listening_on

let stop t =
  if Ivar.is_full t.stopped
  then return ()
  else (
    let%bind () = Throttle.prior_jobs_done t.scanning in
    Ivar.fill_if_empty t.stopped ();
    let%bind () =
      Deferred.List.iter ~how:`Parallel (Hashtbl.data t.running) ~f:(fun r ->
        Follower.stop r.follower)
    in
    Hashtbl.clear t.running;
    let%bind () = Leader_hub.close t.hub in
    match t.http with
    | None -> return ()
    | Some http -> Cohttp_async.Server.close http)
;;
