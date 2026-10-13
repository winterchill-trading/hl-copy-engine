open! Core
open! Async
open Hl_protocol

module Update = struct
  type t =
    | Position of
        { coin : Coin.t
        ; szi : Size.t
        ; mark : Price.t option
        ; fill_time_ms : int option
        }
    | Resync
  [@@deriving sexp_of]
end

module Source = struct
  type t =
    | Websocket
    | Polling
  [@@deriving sexp_of, compare, equal]
end

module Poller = struct
  type t =
    { mutable consumers : Update.t Pipe.Writer.t list
    ; mutable last : Size.t Map.M(Coin).t option
    ; stopped : unit Ivar.t
    }

  let broadcast t update =
    t.consumers <- List.filter t.consumers ~f:(fun w -> not (Pipe.is_closed w));
    List.iter t.consumers ~f:(fun w -> Pipe.write_without_pushback w update)
  ;;

  (* Positions that changed since the previous poll (all of them on the first), closes
     included. *)
  let changes ~previous (state : Clearinghouse_state.t) =
    let now =
      List.filter_map state.positions ~f:(fun p ->
        if Size.is_zero p.szi then None else Some (p.coin, p))
      |> Map.of_alist_reduce (module Coin) ~f:(fun a _ -> a)
    in
    let previous = Option.value previous ~default:(Map.empty (module Coin)) in
    let opened_or_moved =
      Map.fold now ~init:[] ~f:(fun ~key:coin ~data:(p : Clearinghouse_state.Position.t) acc ->
        match Map.find previous coin with
        | Some szi when Size.equal szi p.szi -> acc
        | _ ->
          let mark =
            if Size.is_zero p.szi
            then None
            else
              (* A mark estimate only (the IOC limit is rounded to the tick later), so
                 the float rounding is harmless. *)
              Some
                ((Price.of_float [@alert "-lossy"])
                   (Usd.to_float p.position_value /. Float.abs (Size.to_float p.szi)))
          in
          Update.Position { coin; szi = p.szi; mark; fill_time_ms = None } :: acc)
    in
    let closed =
      Map.fold previous ~init:[] ~f:(fun ~key:coin ~data:_ acc ->
        if Map.mem now coin
        then acc
        else
          Update.Position { coin; szi = Size.zero; mark = None; fill_time_ms = None }
          :: acc)
    in
    List.rev opened_or_moved @ List.rev closed, Map.map now ~f:(fun p -> p.szi)
  ;;
end

type t =
  { config : Hl_client.Config.t
  ; max_ws_users : int
  ; poll_interval : Time_ns.Span.t
  ; time_source : Time_source.t
  ; rate_limit : Rate_limit.t
  ; mutable feed : Hl_client.User_feed.t option
  ; pollers : Poller.t Hashtbl.M(Address).t
  ; ws_leaders : unit Hashtbl.M(Address).t
  ; mutable closed : bool
  }

let create
  ?(max_ws_users = Hl_client.User_feed.default_max_users)
  ?(poll_interval = Time_ns.Span.of_int_sec 5)
  ?(time_source = Time_source.wall_clock ())
  ~rate_limit
  config
  =
  { config
  ; max_ws_users
  ; poll_interval
  ; time_source
  ; rate_limit
  ; feed = None
  ; pollers = Hashtbl.create (module Address)
  ; ws_leaders = Hashtbl.create (module Address)
  ; closed = false
  }
;;

let feed t =
  match t.feed with
  | Some feed -> return (Ok feed)
  | None ->
    let%map feed = Hl_client.User_feed.create ~max_users:t.max_ws_users t.config in
    Or_error.iter feed ~f:(fun feed -> t.feed <- Some feed);
    feed
;;

(* Remembers the price and time of the leader's latest fill per coin, so each position
   update carries the price the leader just traded at. *)
let of_user_feed reader =
  let last = Hashtbl.create (module Coin) in
  Pipe.filter_map' reader ~f:(fun (update : Hl_client.User_feed.Update.t) ->
    return
      (match update with
       | Fills { fills; _ } ->
         List.iter fills ~f:(fun (f : User_fill.t) ->
           Hashtbl.set last ~key:f.coin ~data:(f.px, f.time));
         None
       | Position { coin; szi; time; _ } ->
         let mark, fill_time_ms =
           match Hashtbl.find last coin with
           | Some (px, fill_time) -> Some px, Some fill_time
           | None -> None, Some time
         in
         Some (Update.Position { coin; szi; mark; fill_time_ms })
       | Resync _ -> Some Update.Resync))
;;

let poll_loop t ~leader (poller : Poller.t) =
  let rec loop () =
    if Ivar.is_full poller.stopped || t.closed
    then return ()
    else (
      let%bind () =
        Rate_limit.take
          ~time_source:(Time_source.read_only t.time_source)
          t.rate_limit
          ~weight:Rate_limit.Weight.clearinghouse_state
      in
      let%bind state = Hl_client.Info.clearinghouse_state ~user:leader t.config in
      (match state with
       | Ok state ->
         let updates, now = Poller.changes ~previous:poller.last state in
         poller.last <- Some now;
         List.iter updates ~f:(Poller.broadcast poller)
       | Error err ->
         Log.Global.info_s [%message "leader poll failed" (leader : Address.t) (err : Error.t)]);
      let%bind () =
        Deferred.any
          [ Time_source.after t.time_source t.poll_interval; Ivar.read poller.stopped ]
      in
      loop ())
  in
  don't_wait_for (loop ())
;;

let subscribe_polling t ~leader =
  let poller =
    match Hashtbl.find t.pollers leader with
    | Some poller -> poller
    | None ->
      let poller = { Poller.consumers = []; last = None; stopped = Ivar.create () } in
      Hashtbl.set t.pollers ~key:leader ~data:poller;
      poll_loop t ~leader poller;
      poller
  in
  let reader, writer = Pipe.create () in
  (* A late consumer starts from the positions already known. *)
  Option.iter poller.last ~f:(fun last ->
    Map.iteri last ~f:(fun ~key:coin ~data:szi ->
      Pipe.write_without_pushback
        writer
        (Update.Position { coin; szi; mark = None; fill_time_ms = None })));
  poller.consumers <- writer :: poller.consumers;
  upon (Pipe.closed reader) (fun () ->
    poller.consumers <- List.filter poller.consumers ~f:(fun w -> not (phys_equal w writer));
    if List.is_empty poller.consumers
    then (
      Ivar.fill_if_empty poller.stopped ();
      Hashtbl.remove t.pollers leader));
  reader
;;

let subscribe t ~leader =
  if t.closed
  then return (Or_error.error_string "leader hub closed")
  else if Hashtbl.mem t.pollers leader
  then return (Ok (subscribe_polling t ~leader))
  else if Hashtbl.mem t.ws_leaders leader || Hashtbl.length t.ws_leaders < t.max_ws_users
  then (
    match%bind feed t with
    | Error _ as e -> return e
    | Ok feed ->
      (match%map Hl_client.User_feed.subscribe feed ~address:leader with
       | Error _ as e -> e
       | Ok reader ->
         Hashtbl.set t.ws_leaders ~key:leader ~data:();
         let updates = of_user_feed reader in
         upon (Pipe.closed updates) (fun () ->
           Pipe.close_read reader;
           if Hl_client.User_feed.consumers feed ~address:leader = 0
           then Hashtbl.remove t.ws_leaders leader);
         Ok updates))
  else return (Ok (subscribe_polling t ~leader))
;;

let source t ~leader =
  if Hashtbl.mem t.ws_leaders leader
  then Some Source.Websocket
  else if Hashtbl.mem t.pollers leader
  then Some Polling
  else None
;;

let leaders t =
  let ws =
    Hashtbl.keys t.ws_leaders
    |> List.map ~f:(fun leader ->
      ( leader
      , Source.Websocket
      , Option.value_map t.feed ~default:0 ~f:(fun feed ->
          Hl_client.User_feed.consumers feed ~address:leader) ))
  in
  let polled =
    Hashtbl.to_alist t.pollers
    |> List.map ~f:(fun (leader, (p : Poller.t)) ->
      leader, Source.Polling, List.count p.consumers ~f:(fun w -> not (Pipe.is_closed w)))
  in
  List.sort (ws @ polled) ~compare:(fun (a, _, _) (b, _, _) -> Address.compare a b)
;;

let close t =
  t.closed <- true;
  Hashtbl.iter t.pollers ~f:(fun p ->
    Ivar.fill_if_empty p.stopped ();
    List.iter p.consumers ~f:Pipe.close);
  Hashtbl.clear t.pollers;
  match t.feed with
  | None -> return ()
  | Some feed -> Hl_client.User_feed.close feed
;;
