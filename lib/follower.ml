open! Core
open! Async
open Hl_protocol
open Hl_copy_core
module Symbol = Market_data.Symbol

module Signer = struct
  type t =
    | Agent of Hl_client.Signing.Private_key.t
    | Hook of Hl_client.Exchange.sign
    | Unsigned
end

module Config = struct
  type t =
    { follow : Follower_config.t
    ; signer : Signer.t
    ; resync_interval : Time_ns.Span.t
    ; journal_root : string option
    ; builder : Builder_fee.t option
    ; algo_tick : Time_ns.Span.t
    }

  let create
    ?(resync_interval = Time_ns.Span.of_int_sec 30)
    ?journal_root
    ?builder
    ?(algo_tick = Time_ns.Span.of_int_ms 500)
    ~signer
    follow
    =
    { follow; signer; resync_interval; journal_root; builder; algo_tick }
  ;;
end

(* How orders reach the exchange, whatever signs them. *)
module Exec = struct
  type t =
    { place :
        builder:Builder_fee.t option
        -> Order_request.t list
        -> Exchange_response.t Or_error.t Deferred.t
    ; cancel : Cancel_by_cloid.t list -> Exchange_response.t Or_error.t Deferred.t
    }

  let create (signer : Signer.t) (config : Hl_client.Config.t) ~account =
    match signer with
    | Agent agent_key ->
      let client =
        Hl_client.Client.trading_with_agent
          ~is_mainnet:false
          ~agent_key
          ~account_address:account
          config
      in
      { place =
          (fun ~builder orders -> Hl_client.Client.place_orders ?builder client orders)
      ; cancel = (fun cancels -> Hl_client.Client.cancel_by_cloid client cancels)
      }
    | Hook sign ->
      let config = { config with address = Some account } in
      { place =
          (fun ~builder orders ->
            Hl_client.Exchange.place_orders config ~sign ?builder orders)
      ; cancel = (fun cancels -> Hl_client.Exchange.cancel_by_cloid config ~sign cancels)
      }
    | Unsigned ->
      let config = { config with address = Some account } in
      { place =
          (fun ~builder orders -> Hl_client.Exchange.place_orders config ?builder orders)
      ; cancel = (fun cancels -> Hl_client.Exchange.cancel_by_cloid config cancels)
      }
  ;;
end

(* What the follower's account has approved for the configured builder, from
   [maxBuilderFee]. Orders carry the builder field only while [Approved]. *)
module Builder_state = struct
  type t =
    | Unchecked
    | Approved of { max_tenths_bp : int }
    | Not_approved of { max_tenths_bp : int }
    | Rejected of string (** the exchange refused an order over the builder fee *)
    | Check_failed of string (** no answer yet; orders go out without the builder *)
  [@@deriving equal]

  let approved = function
    | Approved _ -> true
    | Unchecked | Not_approved _ | Rejected _ | Check_failed _ -> false
  ;;

  let max_tenths_bp = function
    | Approved { max_tenths_bp } | Not_approved { max_tenths_bp } -> Some max_tenths_bp
    | Unchecked | Rejected _ | Check_failed _ -> None
  ;;

  let note (builder : Builder_fee.t) = function
    | Approved _ -> None
    | Unchecked -> Some "builder fee approval not checked yet"
    | Not_approved { max_tenths_bp } ->
      Some
        (sprintf
           "builder fee not approved: %d tenths of a bp approved, %d needed"
           max_tenths_bp
           builder.fee_tenths_bp)
    | Rejected message -> Some ("builder fee rejected: " ^ message)
    | Check_failed message -> Some ("builder fee check failed: " ^ message)
  ;;
end

(* Books and traded volume of the symbols that parents worked by an algorithm other than
   [Immediate] need, from the venue's public websocket (one feed per symbol, opened on
   first use). *)
module Market = struct
  type t =
    { books : Market_data.L2_book.t Hashtbl.M(Symbol).t
    ; traded : Size.t Hashtbl.M(Symbol).t
    ; feeds : Market_data.Feed.t Hashtbl.M(Symbol).t
    ; opening : unit Hashtbl.M(Symbol).t
    }

  let create () =
    { books = Hashtbl.create (module Symbol)
    ; traded = Hashtbl.create (module Symbol)
    ; feeds = Hashtbl.create (module Symbol)
    ; opening = Hashtbl.create (module Symbol)
    }
  ;;
end

(* How many finished parents [/status] lists. *)
let recent_reports = 20

type t =
  { config : Config.t
  ; api : Hl_client.Config.t
  ; time_source : Time_source.t
  ; rate_limit : Rate_limit.t
  ; exec : Exec.t
  ; assets : Asset.t Map.M(Symbol).t
  ; sequencer : unit Sequencer.t
  ; metrics : Metrics.t
  ; journal : Journal.Writer.t option
  ; mutable core : Follower_core.t
  ; mutable pnl : Pnl.t
  ; mutable start_equity : Usd.t option
  ; mutable day : Date.t
  ; mutable leader_updates : Leader_hub.Update.t Pipe.Reader.t option
  ; mutable source : Leader_hub.Source.t option
  ; mutable last_resync : Time_ns.t option
  ; mutable drop_leader_updates : bool
  ; mutable last_error : string option
  ; mutable builder_state : Builder_state.t
  ; mutable builder_checked_at : Time_ns.t option
  ; market : Market.t
  ; mutable own_fills : [ `Off | `Opening | `On of Hl_client.User_feed.t ]
  ; reports : (Time_ns.t * Execution_algos.Cost_report.t) Queue.t
  ; mutable totals : Execution_algos.Cost_report.Totals.t
  ; stopped : unit Ivar.t
  }

let follow t = t.core.follow
let state t = t.core
let metrics t = t.metrics
let now t = Time_source.now t.time_source
let utc_date time = Time_ns.to_date time ~zone:Time_float.Zone.utc

let log_notice t (notice : Follower_core.Notice.t) =
  match notice with
  | Dropped_while_paused _ -> ()
  | Rejected r -> Metrics.reject t.metrics r
  | Margin_capped { leverage; shortfall } ->
    Log.Global.info_s
      [%message
        "insufficient margin: capping leverage"
          ~follower:(t.core.follow.follower : Address.t)
          (leverage : float)
          (shortfall : Usd.t)]
  | Paused reason ->
    Log.Global.info_s
      [%message "follow paused" ~follower:(t.core.follow.follower : Address.t) reason]
  | Resumed ->
    Log.Global.info_s
      [%message "follow resumed" ~follower:(t.core.follow.follower : Address.t)]
  | Stopped ->
    Log.Global.info_s
      [%message "follow stopped" ~follower:(t.core.follow.follower : Address.t)]
;;

let update_pnl_metrics t =
  let marks = t.core.mirror.marks in
  match Pnl.summary t.pnl ~marks with
  | [] -> ()
  | summaries ->
    List.iter summaries ~f:(fun (s : Pnl.Summary.t) ->
      if Address.equal s.leader t.core.follow.leader
      then (
        t.metrics.realized_pnl <- Usd.to_float s.realized;
        t.metrics.unrealized_pnl <- Usd.to_float s.unrealized))
;;

(* [maxBuilderFee] weighs 20 against 6 for the rest of a resync, so an approved account is
   checked again only every 5 minutes; a revoked approval shows up sooner as a rejected
   order ([Rejected]), and an account that has not approved is checked on every resync so
   its approval takes effect at once. *)
let builder_recheck_interval = Time_ns.Span.of_int_sec 300

(* Reads the follower's approved cap for the configured builder. A failed check keeps the
   last answer, so a flaky info request does not drop the fee from approved accounts. *)
let check_builder t =
  let due () =
    match t.builder_state, t.builder_checked_at with
    | Approved _, Some at ->
      Time_ns.Span.( >= ) (Time_ns.diff (now t) at) builder_recheck_interval
    | _ -> true
  in
  match t.config.builder with
  | Some _ when not (due ()) -> return ()
  | None -> return ()
  | Some (builder : Builder_fee.t) ->
    let%bind () =
      Rate_limit.take
        ~time_source:(Time_source.read_only t.time_source)
        t.rate_limit
        ~weight:Rate_limit.Weight.max_builder_fee
    in
    let follower = t.core.follow.follower in
    let%map result =
      Hl_client.Info.max_builder_fee t.api ~user:follower ~builder:builder.builder
    in
    t.builder_checked_at <- Some (now t);
    let before = t.builder_state in
    t.builder_state
    <- (match result, before with
        | Ok max_tenths_bp, _ when max_tenths_bp >= builder.fee_tenths_bp ->
          Approved { max_tenths_bp }
        | Ok max_tenths_bp, _ -> Not_approved { max_tenths_bp }
        | Error _, (Approved _ | Not_approved _) -> before
        | Error err, (Unchecked | Rejected _ | Check_failed _) ->
          Check_failed (Error.to_string_hum err));
    if not (Builder_state.equal before t.builder_state)
    then
      Log.Global.info_s
        [%message
          "builder fee approval"
            ~follower:(follower : Address.t)
            ~builder:(builder.builder : Address.t)
            ~approved:(Builder_state.approved t.builder_state : bool)
            ~note:(Builder_state.note builder t.builder_state : string option)]
;;

let enqueue t f =
  if Ivar.is_full t.stopped then return () else Throttle.enqueue t.sequencer f
;;

let record_report t ~time (r : Execution_algos.Cost_report.t) =
  Queue.enqueue t.reports (time, r);
  while Queue.length t.reports > recent_reports do
    ignore (Queue.dequeue_exn t.reports : Time_ns.t * Execution_algos.Cost_report.t)
  done;
  t.totals <- Execution_algos.Cost_report.Totals.add t.totals r;
  Metrics.parent t.metrics r
;;

let fill_of_user_fill (f : User_fill.t) =
  { Fill.time_ns = f.time * 1_000_000
  ; symbol = f.coin
  ; side = f.side
  ; size = f.sz
  ; price = f.px
  ; fee = f.fee
  ; closed_pnl = f.closed_pnl
  ; cloid = f.cloid
  }
;;

(* Applies one input: journal it, step the core, journal the output, then send the plan.
   Order results are applied the same way, inside the same sequencer job. *)
let rec apply t ?lag_from input =
  let time = now t in
  (match input with
   | Follower_core.Input.Order_rejected { message; _ } -> t.last_error <- Some message
   | Mirror (Follower_fill _) -> t.last_error <- None
   | _ -> ());
  Option.iter t.journal ~f:(fun j -> Journal.Writer.input j ~time input);
  let core, (output : Follower_core.Output.t) = Follower_core.apply t.core input in
  t.core <- core;
  Option.iter t.journal ~f:(fun j -> Journal.Writer.output j ~time output);
  List.iter output.notices ~f:(log_notice t);
  List.iter output.reports ~f:(record_report t ~time);
  t.metrics.paused <- not (Follower_core.is_running core);
  watch_market t;
  if not (List.is_empty output.post_only) then watch_own_fills t;
  execute t ?lag_from output

and execute t ?lag_from (output : Follower_core.Output.t) =
  let plan = output.plan in
  let cancels =
    List.filter_map plan.actions ~f:(function
      | Plan.Action.Cancel { symbol; cloid } ->
        Option.map (Map.find t.assets symbol) ~f:(fun asset ->
          { Cancel_by_cloid.asset; cloid })
      | Place _ -> None)
  in
  let%bind () =
    if List.is_empty cancels
    then return ()
    else (
      let%bind () =
        Rate_limit.take
          ~time_source:(Time_source.read_only t.time_source)
          t.rate_limit
          ~weight:(Rate_limit.Weight.exchange ~batch:(List.length cancels))
      in
      let%bind (_ : Exchange_response.t Or_error.t) = t.exec.cancel cancels in
      (* Whatever the answer (an IOC is normally gone already), the orders are done. *)
      Deferred.List.iter ~how:`Sequential cancels ~f:(fun c ->
        apply t (Mirror (Order_closed c.cloid))))
  in
  let places = Plan.places plan in
  let places, unknown =
    List.partition_map places ~f:(fun (o : Plan.Order.t) ->
      match Map.find t.assets o.symbol with
      | Some asset -> First (o, asset)
      | None -> Second o)
  in
  let%bind () =
    Deferred.List.iter ~how:`Sequential unknown ~f:(fun o ->
      apply t (Order_rejected { cloid = o.cloid; message = "unknown asset" }))
  in
  if List.is_empty places
  then return ()
  else send t ?lag_from ~post_only:output.post_only places

and send t ?lag_from ~post_only places =
  let marks = t.core.mirror.marks in
  let requests =
    List.map places ~f:(fun ((o : Plan.Order.t), asset) ->
      { Order_request.asset
      ; is_buy = Side.is_buy o.side
      ; limit_px = o.limit_px
      ; sz = o.size
      ; reduce_only = o.reduce_only
      ; order_type =
          (if List.mem post_only o.cloid ~equal:Cloid.equal
           then Order_type.alo
           else Order_type.ioc)
      ; cloid = Some o.cloid
      })
  in
  let%bind () =
    Rate_limit.take
      ~time_source:(Time_source.read_only t.time_source)
      t.rate_limit
      ~weight:(Rate_limit.Weight.exchange ~batch:(List.length requests))
  in
  let builder =
    match t.config.builder with
    | Some _ as builder when Builder_state.approved t.builder_state -> builder
    | Some _ ->
      t.metrics.builder_fee_skipped
      <- t.metrics.builder_fee_skipped + List.length requests;
      None
    | None -> None
  in
  if Option.is_some builder
  then t.metrics.builder_fee_orders <- t.metrics.builder_fee_orders + List.length requests;
  let sent = now t in
  t.metrics.orders <- t.metrics.orders + List.length requests;
  Option.iter lag_from ~f:(fun from ->
    Metrics.Summary.add t.metrics.lag_ms (Time_ns.Span.to_ms (Time_ns.diff sent from)));
  let%bind response = t.exec.place ~builder requests in
  let orders = List.map places ~f:fst in
  let reject_all message =
    Deferred.List.iter ~how:`Sequential orders ~f:(fun o ->
      apply t (Order_rejected { cloid = o.cloid; message }))
  in
  match response with
  | Error err ->
    (* The request may have reached the exchange: close the orders, then resync so the
       positions come from the venue, not from what we think happened. *)
    let%bind () = reject_all ("request failed: " ^ Error.to_string_hum err) in
    resync t
  | Ok (Err message) ->
    (* The approval was revoked or lowered since the last check: stop sending the field
       until the next resync checks again. *)
    if Option.is_some builder
       && String.is_substring (String.lowercase message) ~substring:"builder"
    then t.builder_state <- Rejected message;
    reject_all message
  | Ok (Ok (Cancel _ | Default)) -> reject_all "unexpected response"
  | Ok (Ok (Order statuses)) ->
    let pairs =
      match List.zip orders statuses with
      | Ok pairs -> pairs
      | Unequal_lengths ->
        List.mapi orders ~f:(fun i o ->
          o, Option.value (List.nth statuses i) ~default:Order_status.Waiting_for_fill)
    in
    Deferred.List.iter ~how:`Sequential pairs ~f:(fun ((o : Plan.Order.t), status) ->
      match status with
      | Filled { total_sz; avg_px; _ } ->
        let fill =
          { Fill.time_ns = Time_ns.to_int_ns_since_epoch (now t)
          ; symbol = o.symbol
          ; side = o.side
          ; size = total_sz
          ; price = avg_px
          ; fee = Usd.zero
          ; closed_pnl = Usd.zero
          ; cloid = Some o.cloid
          }
        in
        t.metrics.fills <- t.metrics.fills + 1;
        Option.iter (Map.find marks o.symbol) ~f:(fun mark ->
          let mark = Price.to_float mark in
          if Float.(mark > 0.)
          then (
            let bps = (Price.to_float avg_px -. mark) /. mark *. 10_000. in
            Metrics.Summary.add
              t.metrics.slippage_bps
              (if Side.is_buy o.side then bps else -.bps)));
        t.pnl <- Pnl.on_fill t.pnl ~leader:t.core.follow.leader fill;
        let%bind () = apply t (Mirror (Follower_fill fill)) in
        let%map () = apply t (Mirror (Order_closed o.cloid)) in
        update_pnl_metrics t
      | Error message -> apply t (Order_rejected { cloid = o.cloid; message })
      | Resting _ ->
        (* A post-only child rests: its fills come from the account's fill feed. An IOC
           never rests; leave it pending until the next resync replaces the pending list
           from the venue. *)
        return ()
      | Waiting_for_fill | Waiting_for_trigger -> apply t (Mirror (Order_closed o.cloid)))

(* Opens a public market feed for every symbol a parent waits on (see [Market]). *)
and watch_market t =
  List.iter (Follower_core.market_symbols t.core) ~f:(fun symbol ->
    if not
         (Hashtbl.mem t.market.feeds symbol
          || Hashtbl.mem t.market.opening symbol
          || Ivar.is_full t.stopped)
    then (
      Hashtbl.set t.market.opening ~key:symbol ~data:();
      don't_wait_for
        (match%map
           Monitor.try_with (fun () ->
             Hl_client.Live_feed.create
               t.api
               ~symbols:[ Symbol.to_string symbol ]
               ~streams:[ L2; Trades ])
         with
         | Error exn ->
           Hashtbl.remove t.market.opening symbol;
           Log.Global.info_s
             [%message
               "market feed failed"
                 ~follower:(t.core.follow.follower : Address.t)
                 (symbol : Symbol.t)
                 (exn : Exn.t)]
         | Ok feed ->
           Hashtbl.remove t.market.opening symbol;
           Hashtbl.set t.market.feeds ~key:symbol ~data:feed;
           let module F = (val feed) in
           Pipe.close_read F.bbo;
           Pipe.close_read F.funding;
           don't_wait_for
             (Pipe.iter_without_pushback F.l2 ~f:(fun u ->
                Hashtbl.update t.market.books symbol ~f:(fun b ->
                  Market_data.L2_book.apply
                    (Option.value b ~default:Market_data.L2_book.empty)
                    u)));
           don't_wait_for
             (Pipe.iter_without_pushback F.trades ~f:(fun (tr : Market_data.Trade.t) ->
                Hashtbl.update t.market.traded symbol ~f:(fun x ->
                  Size.(Option.value x ~default:zero + tr.size)))))))

(* Fills of resting (post-only) children come from the account's own [userFills]; IOC
   fills come with the order answer and are ignored here. The first snapshot is history
   (already applied, or replayed from the journal); snapshots after a reconnect carry the
   fills missed meanwhile. *)
and watch_own_fills t =
  match t.own_fills with
  | `On _ | `Opening -> ()
  | `Off ->
    t.own_fills <- `Opening;
    let follower = t.core.follow.follower in
    let failed err =
      t.own_fills <- `Off;
      Log.Global.info_s
        [%message "own fill feed failed" ~follower:(follower : Address.t) (err : Error.t)]
    in
    don't_wait_for
      (match%bind Hl_client.User_feed.create t.api with
       | Error err -> return (failed err)
       | Ok feed ->
         (match%map Hl_client.User_feed.subscribe feed ~address:follower with
          | Error err ->
            failed err;
            don't_wait_for (Hl_client.User_feed.close feed)
          | Ok updates ->
            t.own_fills <- `On feed;
            let reconnected = ref false in
            don't_wait_for
              (Pipe.iter_without_pushback updates ~f:(function
                | Resync _ -> reconnected := true
                | Position _ -> ()
                | Fills { is_snapshot; fills; _ } ->
                  if (not is_snapshot) || !reconnected
                  then
                    List.iter fills ~f:(fun (f : User_fill.t) ->
                      match f.cloid with
                      | None -> ()
                      | Some cloid ->
                        don't_wait_for
                          (enqueue t (fun () ->
                             if Follower_core.is_resting_child t.core cloid
                             then (
                               let fill = fill_of_user_fill f in
                               t.metrics.fills <- t.metrics.fills + 1;
                               t.pnl
                               <- Pnl.on_fill t.pnl ~leader:t.core.follow.leader fill;
                               let%map () = apply t (Mirror (Follower_fill fill)) in
                               update_pnl_metrics t)
                             else return ())))))))

and resync t =
  let leader = t.core.follow.leader in
  let follower = t.core.follow.follower in
  let take weight =
    Rate_limit.take
      ~time_source:(Time_source.read_only t.time_source)
      t.rate_limit
      ~weight
  in
  let%bind () = check_builder t in
  let%bind () = take Rate_limit.Weight.clearinghouse_state in
  let%bind leader_state = Hl_client.Info.clearinghouse_state ~user:leader t.api in
  let%bind () = take Rate_limit.Weight.clearinghouse_state in
  let%bind follower_state = Hl_client.Info.clearinghouse_state ~user:follower t.api in
  let%bind () = take Rate_limit.Weight.all_mids in
  let%bind mids = Hl_client.Info.all_mids t.api in
  match
    Or_error.all_unit
      [ Or_error.ignore_m leader_state
      ; Or_error.ignore_m follower_state
      ; Or_error.ignore_m mids
      ]
  with
  | Error err ->
    t.metrics.resync_failures <- t.metrics.resync_failures + 1;
    t.last_error <- Some ("resync failed: " ^ Error.to_string_hum err);
    Log.Global.info_s
      [%message "resync failed" ~follower:(follower : Address.t) (err : Error.t)];
    return ()
  | Ok () ->
    let leader_state = ok_exn leader_state in
    let follower_state = ok_exn follower_state in
    let mids = ok_exn mids in
    let positions (s : Clearinghouse_state.t) =
      List.filter_map s.positions ~f:(fun p ->
        if Size.is_zero p.szi then None else Some (p.coin, p.szi))
      |> Map.of_alist_reduce (module Symbol) ~f:(fun a _ -> a)
    in
    let follower_positions = positions follower_state in
    if not
         ([%equal: Size.t Map.M(Symbol).t]
            follower_positions
            t.core.mirror.follower_positions)
    then t.metrics.resync_repairs <- t.metrics.resync_repairs + 1;
    let equity = follower_state.margin_summary.account_value in
    if Option.is_none t.start_equity then t.start_equity <- Some equity;
    Option.iter t.start_equity ~f:(fun start ->
      t.metrics.equity_change <- Usd.to_float Usd.(equity - start));
    t.metrics.resyncs <- t.metrics.resyncs + 1;
    t.last_resync <- Some (now t);
    let marks =
      List.filter_map mids ~f:(fun (coin, px) ->
        if Map.mem t.core.specs coin then Some (coin, px) else None)
      |> Map.of_alist_reduce (module Symbol) ~f:(fun a _ -> a)
    in
    let%map () =
      apply
        t
        (Mirror
           (Resync
              { leader =
                  { equity = leader_state.margin_summary.account_value
                  ; positions = positions leader_state
                  }
              ; follower = { equity; positions = follower_positions; open_orders = [] }
              ; marks
              }))
    in
    update_pnl_metrics t
;;

let check_day t =
  let today = utc_date (now t) in
  if Date.( > ) today t.day
  then (
    t.day <- today;
    apply t (Mirror Start_day))
  else return ()
;;

let on_leader_update t (update : Leader_hub.Update.t) =
  if t.drop_leader_updates
  then return ()
  else (
    match update with
    | Resync -> enqueue t (fun () -> resync t)
    | Position { coin; szi; mark; fill_time_ms } ->
      t.metrics.leader_updates <- t.metrics.leader_updates + 1;
      let received = now t in
      enqueue t (fun () ->
        let mark =
          match mark with
          | Some _ -> mark
          | None -> Map.find t.core.mirror.marks coin
        in
        match mark with
        | None -> resync t
        | Some mark ->
          let lag_from =
            match fill_time_ms with
            | Some ms -> Time_ns.of_int_ns_since_epoch (ms * 1_000_000)
            | None -> received
          in
          apply t ~lag_from (Mirror (Leader_position { symbol = coin; size = szi; mark }))))
;;

let resync_now t = enqueue t (fun () -> resync t)

let rec resync_loop t =
  let%bind () =
    Deferred.any_unit
      [ Time_source.after t.time_source t.config.resync_interval; Ivar.read t.stopped ]
  in
  if Ivar.is_full t.stopped
  then return ()
  else (
    let%bind () =
      enqueue t (fun () ->
        let%bind () = check_day t in
        resync t)
    in
    resync_loop t)
;;

(* Market ticks for the parents waiting on them, every [algo_tick]. The book is the latest
   from the feed (none until its first snapshot); the volume is the feed's cumulative
   traded size, which the scheduler only differences. *)
let rec algo_loop t =
  let%bind () =
    Deferred.any_unit
      [ Time_source.after t.time_source t.config.algo_tick; Ivar.read t.stopped ]
  in
  if Ivar.is_full t.stopped
  then return ()
  else (
    let%bind () =
      match Follower_core.market_symbols t.core with
      | [] -> return ()
      | symbols ->
        enqueue t (fun () ->
          Deferred.List.iter ~how:`Sequential symbols ~f:(fun symbol ->
            match Hashtbl.find t.market.books symbol with
            | Some book when Market_data.L2_book.has_snapshot book ->
              apply
                t
                (Market
                   { symbol
                   ; now_ns = Time_ns.to_int_ns_since_epoch (now t)
                   ; book = Execution_algos.Book.of_l2_book book
                   ; traded =
                       Option.value
                         (Hashtbl.find t.market.traded symbol)
                         ~default:Size.zero
                   })
            | Some _ | None -> return ()))
    in
    algo_loop t)
;;

let specs_of_meta (meta : Meta.t) =
  List.fold
    meta.universe
    ~init:(Map.empty (module Symbol), Map.empty (module Symbol))
    ~f:(fun (specs, assets) (a : Meta.Asset_meta.t) ->
      match Meta.asset_of_coin meta a.name with
      | None -> specs, assets
      | Some asset ->
        ( Map.set specs ~key:a.name ~data:(Rounding.Spec.of_asset_meta a)
        , Map.set assets ~key:a.name ~data:asset ))
;;

let start
  ?(time_source = Time_source.wall_clock ())
  ~hub
  ~rate_limit
  ~api
  (config : Config.t)
  =
  let open Deferred.Or_error.Let_syntax in
  let follow = config.follow in
  let%bind () = Deferred.return (Safety.check_config api) in
  let%bind () = Deferred.return (Follower_config.validate follow) in
  let%bind () =
    Rate_limit.take
      ~time_source:(Time_source.read_only time_source)
      rate_limit
      ~weight:Rate_limit.Weight.meta
    |> Deferred.ok
  in
  let%bind meta = Hl_client.Info.meta api in
  let specs, assets = specs_of_meta meta in
  let journal_dir =
    Option.map config.journal_root ~f:(fun root -> Journal.dir ~root follow)
  in
  let%bind previous =
    match journal_dir with
    | None -> return []
    | Some dir -> Deferred.ok (Journal.load dir)
  in
  let%bind core =
    match Journal.inputs previous with
    | [] -> return (Follower_core.create ~follow ~specs)
    | inputs ->
      let%bind core, _ = Deferred.return (Follower_core.replay inputs) in
      if Address.equal core.follow.follower follow.follower
         && Address.equal core.follow.leader follow.leader
      then return core
      else Deferred.Or_error.error_string "journal belongs to another follow"
  in
  let journal = Option.map journal_dir ~f:(fun dir -> Journal.Writer.create ~dir ()) in
  let t =
    { config
    ; api
    ; time_source
    ; rate_limit
    ; exec = Exec.create config.signer api ~account:follow.follower
    ; assets
    ; sequencer = Sequencer.create ~continue_on_error:true ()
    ; metrics = Metrics.create ()
    ; journal
    ; core
    ; pnl = Pnl.empty
    ; start_equity = None
    ; day = utc_date (Time_source.now time_source)
    ; leader_updates = None
    ; source = None
    ; last_resync = None
    ; drop_leader_updates = false
    ; last_error = None
    ; builder_state = Unchecked
    ; builder_checked_at = None
    ; market = Market.create ()
    ; own_fills = `Off
    ; reports = Queue.create ()
    ; totals = Execution_algos.Cost_report.Totals.empty
    ; stopped = Ivar.create ()
    }
  in
  (* A fresh journal starts with the configuration; a resumed one records the
     (re)configuration of this run on top of the replayed state. *)
  let%bind () =
    enqueue t (fun () ->
      match previous with
      | [] ->
        let time = now t in
        Option.iter t.journal ~f:(fun j ->
          Journal.Writer.input j ~time (Configure { follow; specs });
          Journal.Writer.output j ~time Follower_core.Output.empty);
        Deferred.unit
      | _ :: _ -> apply t (Configure { follow; specs }))
    |> Deferred.ok
  in
  let%bind updates = Leader_hub.subscribe hub ~leader:follow.leader in
  t.leader_updates <- Some updates;
  t.source <- Leader_hub.source hub ~leader:follow.leader;
  let%map () = Deferred.ok (resync_now t) in
  don't_wait_for
    (Pipe.iter updates ~f:(fun update ->
       (* Not waiting for the order to be answered keeps reading the feed; updates queue
          on the sequencer and collapse into the latest position there. *)
       don't_wait_for (on_leader_update t update);
       Deferred.unit));
  don't_wait_for (resync_loop t);
  don't_wait_for (algo_loop t);
  t
;;

let pause t ~reason = enqueue t (fun () -> apply t (Pause reason))
let resume t = enqueue t (fun () -> apply t Resume)

let reconfigure t (follow : Follower_config.t) =
  if not
       (Address.equal follow.follower t.core.follow.follower
        && Address.equal follow.leader t.core.follow.leader)
  then return (Or_error.error_string "reconfigure cannot change the follower or leader")
  else (
    match Follower_config.validate follow with
    | Error _ as e -> return e
    | Ok () ->
      let%map () =
        enqueue t (fun () -> apply t (Configure { follow; specs = t.core.specs }))
      in
      Ok ())
;;

let idle t = Throttle.prior_jobs_done t.sequencer

let stop t =
  if Ivar.is_full t.stopped
  then return ()
  else (
    let%bind () = enqueue t (fun () -> apply t Stop) in
    Ivar.fill_if_empty t.stopped ();
    Option.iter t.leader_updates ~f:Pipe.close_read;
    let%bind () =
      Deferred.List.iter ~how:`Parallel (Hashtbl.data t.market.feeds) ~f:(fun feed ->
        let module F = (val feed : Market_data.Feed.S) in
        F.close ())
    in
    let%bind () =
      match t.own_fills with
      | `On feed -> Hl_client.User_feed.close feed
      | `Off | `Opening -> return ()
    in
    match t.journal with
    | None -> return ()
    | Some j -> Journal.Writer.close j)
;;

let sizes_json m =
  `Assoc
    (Map.to_alist m
     |> List.map ~f:(fun (s, x) -> Symbol.to_string s, `String (Size.to_string x)))
;;

let agent_address t =
  match t.config.signer with
  | Agent key -> Some (Hl_client.Signing.Private_key.address key)
  | Hook _ | Unsigned -> None
;;

let last_error t =
  match t.last_error, t.core.status with
  | Some e, _ -> Some e
  | None, Paused reason -> Some ("paused: " ^ reason)
  | None, (Running | Stopped) -> None
;;

(* The follower's positions with their attributed entry price and pnl, in the shape
   hl-copy-api's [/me] reads: numbers, not strings. *)
let positions_json t =
  let m = t.core.mirror in
  let equity = Usd.to_float m.follower_equity in
  `List
    (Map.to_alist m.follower_positions
     |> List.map ~f:(fun (symbol, size) ->
       let p = Pnl.position t.pnl ~leader:t.core.follow.leader symbol in
       let mark = Map.find m.marks symbol in
       let unrealized =
         Option.value_map mark ~default:0. ~f:(fun mark ->
           Usd.to_float (Pnl.Position.unrealized p ~mark))
       in
       let leverage =
         match mark with
         | Some mark when Float.(equity > 0.) ->
           Usd.to_float (Caps.notional size mark) /. equity
         | _ -> 0.
       in
       `Assoc
         [ "coin", `String (Symbol.to_string symbol)
         ; "size", `Float (Size.to_float size)
         ; "entry_px", `Float (Price.to_float p.avg_entry)
         ; "unrealized_pnl", `Float unrealized
         ; "leverage", `Float leverage
         ]))
;;

let builder_json t =
  match t.config.builder with
  | None -> `Null
  | Some builder ->
    let opt f = Option.value_map ~default:`Null ~f in
    `Assoc
      [ "address", `String (Address.to_string builder.builder)
      ; "fee_tenths_bp", `Int builder.fee_tenths_bp
      ; "approved", `Bool (Builder_state.approved t.builder_state)
      ; ( "max_approved_tenths_bp"
        , opt (fun x -> `Int x) (Builder_state.max_tenths_bp t.builder_state) )
      ; "note", opt (fun x -> `String x) (Builder_state.note builder t.builder_state)
      ]
;;

let report_json ((time, r) : Time_ns.t * Execution_algos.Cost_report.t) =
  `Assoc
    [ "time", `String (Time_ns.to_string_iso8601_basic time ~zone:Time_float.Zone.utc)
    ; "algo", `String r.algo
    ; "outcome", `String (Execution_algos.Cost_report.Outcome.to_string r.outcome)
    ; "side", `String (if Side.is_buy r.side then "buy" else "sell")
    ; "target", `Float (Size.to_float r.target)
    ; "filled", `Float (Size.to_float r.filled)
    ; "avg_px", `Float (Price.to_float r.avg_px)
    ; "arrival_px", `Float (Price.to_float r.arrival_px)
    ; "children", `Int r.children
    ; "maker_filled", `Float (Size.to_float r.maker_filled)
    ; "fees", `Float r.fees
    ; "arrival_slippage_bps", `Float r.arrival_slippage_bps
    ; "shortfall", `Float r.shortfall
    ; "shortfall_bps", `Float r.shortfall_bps
    ]
;;

(* The follow's algorithm, the parents being worked, the last finished ones and totals. *)
let execution_json t =
  let totals = t.totals in
  `Assoc
    [ "algo", `String (Exec_algo.name t.core.follow.algo)
    ; ( "active"
      , `List
          (List.map t.core.execs ~f:(fun (e : Follower_core.Exec.t) ->
             let open Execution_algos in
             `Assoc
               [ "cloid", `String (Cloid.to_string e.order.cloid)
               ; "coin", `String (Symbol.to_string e.order.symbol)
               ; "algo", `String (Algo.name (Scheduler.algo e.sched))
               ; "side", `String (if Side.is_buy e.order.side then "buy" else "sell")
               ; "size", `Float (Size.to_float e.order.size)
               ; "filled", `Float (Size.to_float (Scheduler.filled e.sched))
               ; "working", `Float (Size.to_float (Scheduler.working_size e.sched))
               ; "children", `Int (Scheduler.children e.sched)
               ])) )
    ; "recent", `List (Queue.to_list t.reports |> List.rev |> List.map ~f:report_json)
    ; ( "totals"
      , `Assoc
          [ "parents", `Int totals.parents
          ; "filled_parents", `Int totals.filled_parents
          ; "target_notional", `Float totals.target_notional
          ; "filled_notional", `Float totals.filled_notional
          ; "fees", `Float totals.fees
          ; "shortfall", `Float totals.shortfall
          ; ( "shortfall_bps"
            , `Float (Execution_algos.Cost_report.Totals.shortfall_bps totals) )
          ; ( "slippage_bps"
            , `Float (Execution_algos.Cost_report.Totals.slippage_bps totals) )
          ; "fill_rate", `Float (Execution_algos.Cost_report.Totals.fill_rate totals)
          ] )
    ]
;;

let status_json t =
  let core = t.core in
  let m = core.mirror in
  `Assoc
    [ "follower", `String (Address.to_string core.follow.follower)
    ; "leader", `String (Address.to_string core.follow.leader)
    ; "state", `String (Follower_core.Status.to_string core.status)
    ; "pnl", `Float (t.metrics.realized_pnl +. t.metrics.unrealized_pnl)
    ; "positions", positions_json t
    ; ( "last_error"
      , match last_error t with
        | None -> `Null
        | Some e -> `String e )
    ; ( "agent"
      , match agent_address t with
        | None -> `Null
        | Some a -> `String (Address.to_string a) )
    ; "status", `String (Follower_core.Status.to_string core.status)
    ; ( "reason"
      , match core.status with
        | Paused reason -> `String reason
        | Running | Stopped -> `Null )
    ; ( "leader_source"
      , match t.source with
        | None -> `Null
        | Some Websocket -> `String "websocket"
        | Some Polling -> `String "polling" )
    ; "leader_equity", `String (Usd.to_string m.leader_equity)
    ; "follower_equity", `String (Usd.to_string m.follower_equity)
    ; "leader_positions", sizes_json m.leader_positions
    ; "follower_positions", sizes_json m.follower_positions
    ; "pending", `Int (List.length m.pending)
    ; "margin_cap", Option.value_map core.margin_cap ~default:`Null ~f:(fun x -> `Float x)
    ; "shortfall", `String (Usd.to_string core.shortfall)
    ; ( "last_resync"
      , Option.value_map t.last_resync ~default:`Null ~f:(fun time ->
          `String (Time_ns.to_string_iso8601_basic time ~zone:Time_float.Zone.utc)) )
    ; "metrics", Metrics.to_json t.metrics
    ; "builder", builder_json t
    ; "execution", execution_json t
    ]
;;

module For_testing = struct
  let drop_leader_updates t b = t.drop_leader_updates <- b
end
