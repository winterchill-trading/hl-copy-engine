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
    }

  let create
    ?journal_root
    ?(scan_interval = Time_ns.Span.of_int_sec 1)
    ?(resync_interval = Time_ns.Span.of_int_sec 30)
    ?(max_ws_users = Hl_client.User_feed.default_max_users)
    ?(leader_poll_interval = Time_ns.Span.of_int_sec 5)
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
    }
  ;;
end

type running =
  { contents : string
  ; follower : Follower.t
  }

type t =
  { config : Config.t
  ; hub : Leader_hub.t
  ; rate_limit : Rate_limit.t
  ; running : running String.Table.t (** by file name *)
  ; mutable errors : (string * Error.t) list
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

let errors t = t.errors

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

let scan_once t =
  match%bind read_dir t.config.configs_dir with
  | Error err ->
    t.errors <- [ t.config.configs_dir, err ];
    return ()
  | Ok files ->
    let errors = ref [] in
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
    let%map () =
      Deferred.List.iter ~how:`Sequential files ~f:(fun (name, contents) ->
        match Hashtbl.find t.running name with
        | Some r when String.equal r.contents contents -> return ()
        | existing ->
          (match Follower_config.of_file_contents contents with
           | Error err ->
             errors := (name, err) :: !errors;
             return ()
           | Ok follow ->
             let duplicate =
               Hashtbl.existsi t.running ~f:(fun ~key ~data ->
                 (not (String.equal key name))
                 && same_pair (Follower.follow data.follower) follow)
             in
             if duplicate
             then (
               errors
               := (name, Error.of_string "another file already follows this pair")
                  :: !errors;
               return ())
             else (
               match existing with
               | Some r when same_pair (Follower.follow r.follower) follow ->
                 (match%map Follower.reconfigure r.follower follow with
                  | Ok () -> Hashtbl.set t.running ~key:name ~data:{ r with contents }
                  | Error err -> errors := (name, err) :: !errors)
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
                    Hashtbl.set t.running ~key:name ~data:{ contents; follower }
                  | Error err -> errors := (name, err) :: !errors))))
    in
    t.errors <- List.rev !errors;
    List.iter t.errors ~f:(fun (file, error) ->
      Log.Global.info_s [%message "follow file not applied" file (error : Error.t)])
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
      (List.length t.errors)
      (Rate_limit.taken t.rate_limit)
;;

let status_json t =
  `Assoc
    [ "followers", `List (List.map (followers t) ~f:Follower.status_json)
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
          (List.map t.errors ~f:(fun (file, err) ->
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
      ; errors = []
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
