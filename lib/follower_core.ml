open! Core
open Hl_copy_core
module Size = Market_data.Size
module Price = Market_data.Price

module Status = struct
  type t =
    | Running
    | Paused of string
    | Stopped
  [@@deriving bin_io, sexp, compare, equal]

  let to_string = function
    | Running -> "running"
    | Paused _ -> "paused"
    | Stopped -> "stopped"
  ;;
end

module Input = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Configure of
            { follow : Follower_config.Stable.V1.t
            ; specs : Rounding.Spec.Stable.V1.t Mirror.Symbol_map.t
            }
        | Mirror of Mirror.Event.Stable.V1.t
        | Order_rejected of
            { cloid : Cloid.Stable.V1.t
            ; message : string
            }
        | Pause of string
        | Resume
        | Stop
      [@@deriving bin_io, sexp, compare, equal]
    end

    module V2 = struct
      type t =
        | Configure of
            { follow : Follower_config.Stable.V2.t
            ; specs : Rounding.Spec.Stable.V1.t Mirror.Symbol_map.t
            }
        | Mirror of Mirror.Event.Stable.V1.t
        | Order_rejected of
            { cloid : Cloid.Stable.V1.t
            ; message : string
            }
        | Pause of string
        | Resume
        | Stop
        | Market of
            { symbol : Market_data.Symbol.Stable.V1.t
            ; now_ns : int
            ; book : Execution_algos.Book.Stable.V1.t
            ; traded : Size.Stable.V1.t
            }
      [@@deriving bin_io, sexp, compare, equal]

      let of_v1 : V1.t -> t = function
        | Configure { follow; specs } ->
          Configure { follow = Follower_config.Stable.V2.of_v1 follow; specs }
        | Mirror e -> Mirror e
        | Order_rejected { cloid; message } -> Order_rejected { cloid; message }
        | Pause r -> Pause r
        | Resume -> Resume
        | Stop -> Stop
      ;;
    end

    module V3 = struct
      type t =
        | Configure of
            { follow : Follower_config.Stable.V3.t
            ; specs : Rounding.Spec.Stable.V1.t Mirror.Symbol_map.t
            }
        | Mirror of Mirror.Event.Stable.V1.t
        | Order_rejected of
            { cloid : Cloid.Stable.V1.t
            ; message : string
            }
        | Pause of string
        | Resume
        | Stop
        | Market of
            { symbol : Market_data.Symbol.Stable.V1.t
            ; now_ns : int
            ; book : Execution_algos.Book.Stable.V1.t
            ; traded : Size.Stable.V1.t
            }
      [@@deriving bin_io, sexp, compare, equal]

      let of_v2 : V2.t -> t = function
        | Configure { follow; specs } ->
          Configure { follow = Follower_config.Stable.V3.of_v2 follow; specs }
        | Mirror e -> Mirror e
        | Order_rejected { cloid; message } -> Order_rejected { cloid; message }
        | Pause r -> Pause r
        | Resume -> Resume
        | Stop -> Stop
        | Market { symbol; now_ns; book; traded } ->
          Market { symbol; now_ns; book; traded }
      ;;

      let of_v1 v1 = of_v2 (V2.of_v1 v1)
    end
  end

  include Stable.V3
end

module Notice = struct
  type t =
    | Margin_capped of
        { leverage : float
        ; shortfall : Usd.t
        }
    | Rejected of Reject.t
    | Paused of string
    | Resumed
    | Stopped
    | Dropped_while_paused of Plan.Order.t
  [@@deriving bin_io, sexp, compare, equal]
end

module Output = struct
  module Stable = struct
    module V1 = struct
      type t =
        { plan : Plan.Stable.V1.t
        ; notices : Notice.t list
        }
      [@@deriving bin_io, sexp, compare, equal]
    end

    module V2 = struct
      type t =
        { plan : Plan.Stable.V1.t
        ; notices : Notice.t list
        ; post_only : Cloid.Stable.V1.t list [@sexp.list]
        ; reports : Execution_algos.Cost_report.Stable.V1.t list [@sexp.list]
        }
      [@@deriving bin_io, sexp, compare, equal]

      let of_v1 ({ plan; notices } : V1.t) =
        { plan; notices; post_only = []; reports = [] }
      ;;

      let to_v1 { plan; notices; post_only = _; reports = _ } : V1.t = { plan; notices }
    end

    module V3 = struct
      type t =
        { plan : Plan.Stable.V2.t
        ; notices : Notice.t list
        ; post_only : Cloid.Stable.V1.t list [@sexp.list]
        ; reports : Execution_algos.Cost_report.Stable.V1.t list [@sexp.list]
        }
      [@@deriving bin_io, sexp, compare, equal]

      let of_v2 ({ plan; notices; post_only; reports } : V2.t) =
        { plan = Plan.Stable.V2.of_v1 plan; notices; post_only; reports }
      ;;

      let to_v2 { plan; notices; post_only; reports } : V2.t =
        { plan = Plan.Stable.V2.to_v1 plan; notices; post_only; reports }
      ;;

      let of_v1 v1 = of_v2 (V2.of_v1 v1)
      let to_v1 t = V2.to_v1 (to_v2 t)
    end
  end

  include Stable.V3

  let empty = { plan = Plan.empty; notices = []; post_only = []; reports = [] }

  let append a b =
    { plan = Plan.append a.plan b.plan
    ; notices = a.notices @ b.notices
    ; post_only = a.post_only @ b.post_only
    ; reports = a.reports @ b.reports
    }
  ;;
end

(* One parent order (an order the mirror planned) worked by a scheduler. Child [k] has the
   client order id of the parent with [k] in bits 40 and up of its sequence half, so child
   0 is the parent's own id: an [Immediate] parent sends exactly the mirror's order. *)
module Exec = struct
  type t =
    { order : Plan.Order.t (** the mirror's order: its cloid is the parent's *)
    ; prefix : int (** high half of the parent's client order id *)
    ; seq : int (** low half *)
    ; sched : Execution_algos.Scheduler.t
    ; posted : int list (** ids of post-only children *)
    }
  [@@deriving bin_io, sexp, compare, equal]

  let child_bits = 40

  let split cloid =
    let hex = String.chop_prefix_if_exists (Cloid.to_string cloid) ~prefix:"0x" in
    if String.length hex <> 32
    then None
    else
      Option.both
        (Int.of_string_opt ("0x" ^ String.prefix hex 16))
        (Int.of_string_opt ("0x" ^ String.suffix hex 16))
  ;;

  let child_cloid t id =
    Cloid.create ~follower:t.prefix ~seq:(t.seq lor (id lsl child_bits))
  ;;

  (* The child id [cloid] names in this parent, if any. *)
  let child_of t cloid =
    match split cloid with
    | Some (prefix, seq)
      when prefix = t.prefix && seq land ((1 lsl child_bits) - 1) = t.seq ->
      Some (seq lsr child_bits)
    | _ -> None
  ;;
end

type t =
  { follow : Follower_config.t
  ; specs : Rounding.Spec.t Mirror.Symbol_map.t
  ; mirror : Mirror.t
  ; status : Status.t
  ; margin_cap : float option
  ; shortfall : Usd.t
  ; rejects : int
  ; consecutive_rejects : int
  ; execs : Exec.t list
  }
[@@deriving bin_io, sexp, compare, equal]

let is_running t =
  match t.status with
  | Running -> true
  | Paused _ | Stopped -> false
;;

let effective_caps t =
  let caps = t.follow.caps in
  match t.margin_cap with
  | None -> caps
  | Some cap ->
    let max_leverage =
      match caps.max_leverage with
      | None -> cap
      | Some configured -> Float.min configured cap
    in
    { caps with max_leverage = Some max_leverage }
;;

(* The mirror's config follows the follow, the specs and the margin cap; its client order
   id prefix only depends on the leader, so it is stable across reconfigurations. *)
let sync_config t =
  let config = Follower_config.mirror_config t.follow ~specs:t.specs in
  { t with mirror = { t.mirror with config = { config with caps = effective_caps t } } }
;;

let create ~follow ~specs =
  let t =
    { follow
    ; specs
    ; mirror = Mirror.create (Follower_config.mirror_config follow ~specs)
    ; status = (if follow.paused then Paused "config" else Running)
    ; margin_cap = None
    ; shortfall = Usd.zero
    ; rejects = 0
    ; consecutive_rejects = 0
    ; execs = []
    }
  in
  sync_config t
;;

let band_uses_impact t =
  match t.follow.band with
  | Some { slippage = Impact _; _ } -> true
  | Some { slippage = Fixed_bps _; _ } | None -> false
;;

let market_symbols t =
  let parents =
    List.filter_map t.execs ~f:(fun (e : Exec.t) ->
      match Execution_algos.Scheduler.algo e.sched with
      | Immediate -> None
      | Twap _ | Vwap _ | Pov _ | Passive _ | Adaptive _ -> Some e.order.symbol)
  in
  (* a band estimating its slippage from the book needs every traded symbol's book *)
  let band = if band_uses_impact t then Set.to_list t.mirror.managed else [] in
  List.dedup_and_sort (parents @ band) ~compare:Market_data.Symbol.compare
;;

(* The expected slippage of the order that would close the symbol's gap now (one lot when
   there is none), walked on the tick's book with [Impact.estimate]: what a band with
   [Impact] slippage charges. Positive when adverse; an empty side keeps the last one. *)
let update_slippage_estimate t ~symbol ~book =
  match Map.find t.specs symbol with
  | None -> t
  | Some (spec : Rounding.Spec.t) ->
    let m = t.mirror in
    let current =
      List.fold
        m.pending
        ~init:(Option.value (Map.find m.follower_positions symbol) ~default:Size.zero)
        ~f:(fun acc (p : Mirror.Pending.t) ->
          if Market_data.Symbol.equal p.symbol symbol && not p.cancel_requested
          then Size.(acc + p.remaining)
          else acc)
    in
    let gap =
      match Mirror.target m symbol with
      | Some target, _ -> Size.(target - current)
      | None, _ -> Size.zero
    in
    let side : Market_data.Side.t = if Size.is_negative gap then Sell else Buy in
    let size = if Size.is_zero gap then spec.lot else Size.abs gap in
    (match Execution_algos.Impact.estimate book ~side ~size with
     | None -> t
     | Some e ->
       { t with
         mirror = Mirror.on_slippage_estimate m ~symbol ~bps:(Float.max 0. e.slippage_bps)
       })
;;

let is_resting_child t cloid =
  List.exists t.execs ~f:(fun (e : Exec.t) ->
    match Exec.child_of e cloid with
    | None -> false
    | Some id ->
      List.mem e.posted id ~equal:Int.equal
      && List.exists (Execution_algos.Scheduler.working e.sched) ~f:(fun w ->
        w.child.id = id))
;;

let follower_leverage t =
  let m = t.mirror in
  if not (Usd.is_positive m.follower_equity)
  then 0.
  else (
    let notional =
      Map.fold m.follower_positions ~init:Usd.zero ~f:(fun ~key ~data acc ->
        match Map.find m.marks key with
        | None -> acc
        | Some mark -> Usd.(acc + Caps.notional data mark))
    in
    Usd.to_float notional /. Usd.to_float m.follower_equity)
;;

(* While not running, places are dropped and closed in the mirror straight away, so the
   mirror never waits for an order that was not sent. Cancels still go out. *)
let gate t (plan : Plan.t) =
  if is_running t
  then t, { Output.empty with plan }
  else (
    let dropped = Plan.places plan in
    let mirror =
      List.fold dropped ~init:t.mirror ~f:(fun m (o : Plan.Order.t) ->
        Mirror.on_order_closed m o.cloid)
    in
    let actions =
      List.filter plan.actions ~f:(function
        | Plan.Action.Place _ -> false
        | Cancel _ -> true)
    in
    ( { t with mirror }
    , { Output.empty with
        plan = { plan with actions }
      ; notices = List.map dropped ~f:(fun o -> Notice.Dropped_while_paused o)
      } ))
;;

let cancel_all t =
  let to_cancel =
    List.filter t.mirror.pending ~f:(fun (p : Mirror.Pending.t) -> not p.cancel_requested)
  in
  let pending =
    List.map t.mirror.pending ~f:(fun (p : Mirror.Pending.t) ->
      { p with cancel_requested = true })
  in
  ( { t with mirror = { t.mirror with pending } }
  , List.map to_cancel ~f:(fun (p : Mirror.Pending.t) ->
      Plan.Action.Cancel { symbol = p.symbol; cloid = p.cloid }) )
;;

let pause t reason =
  let t = { t with status = Paused reason } in
  let t, cancels = cancel_all t in
  ( t
  , { Output.empty with
      plan = { Plan.empty with actions = cancels }
    ; notices = [ Paused reason ]
    } )
;;

let lift_cap t = sync_config { t with margin_cap = None; shortfall = Usd.zero }

let resume t =
  let t = lift_cap { t with status = Running; consecutive_rejects = 0 } in
  let t = { t with mirror = Mirror.start_day t.mirror } in
  let mirror, plan = Mirror.rebalance t.mirror in
  let t, out = gate { t with mirror } plan in
  t, { out with notices = Resumed :: out.notices }
;;

(* [close]: the rejected order was the whole parent (closes it in the mirror); a child of
   a parent still being worked leaves the parent open. *)
let on_reject ?(close = true) ?pending t ~cloid ~message =
  let pending =
    match pending with
    | Some _ -> pending
    | None ->
      List.find t.mirror.pending ~f:(fun (p : Mirror.Pending.t) ->
        Cloid.equal p.cloid cloid)
  in
  let t =
    { t with
      mirror = (if close then Mirror.on_order_closed t.mirror cloid else t.mirror)
    ; rejects = t.rejects + 1
    ; consecutive_rejects = t.consecutive_rejects + 1
    }
  in
  let reject = Reject.classify message in
  let rejected = Notice.Rejected reject in
  match reject with
  | Insufficient_margin ->
    let notional =
      match pending with
      | None -> Usd.zero
      | Some p ->
        (match Map.find t.mirror.marks p.symbol with
         | None -> Usd.zero
         | Some mark -> Caps.notional p.remaining mark)
    in
    let leverage = follower_leverage t in
    let margin_cap =
      Some
        (match t.margin_cap with
         | None -> leverage
         | Some cap -> Float.min cap leverage)
    in
    let shortfall = Usd.(t.shortfall + notional) in
    ( sync_config { t with margin_cap; shortfall }
    , { Output.empty with
        notices = [ rejected; Margin_capped { leverage; shortfall = notional } ]
      } )
  | Agent_invalid ->
    let t, out = pause t "agent rejected" in
    t, { out with notices = rejected :: out.notices }
  | No_liquidity | Rate_limited | Other _ ->
    t, { Output.empty with notices = [ rejected ] }
;;

let on_mirror t (event : Mirror.Event.t) =
  let t =
    match event with
    | Follower_fill { cloid = Some cloid; _ }
      when List.exists t.mirror.pending ~f:(fun (p : Mirror.Pending.t) ->
             Cloid.equal p.cloid cloid) -> { t with consecutive_rejects = 0 }
    | Start_day -> lift_cap t
    | _ -> t
  in
  let mirror, plan = Mirror.apply t.mirror event in
  gate { t with mirror } plan
;;

let configure t ~follow ~specs =
  let was_paused_by_config =
    match t.status with
    | Paused "config" -> true
    | _ -> false
  in
  let t = lift_cap { t with follow; specs } in
  match t.status with
  | Stopped ->
    (* A new run on top of a stopped journal: the mirror state (and with it the client
       order id sequence) carries over. *)
    let t =
      { t with
        status = (if follow.paused then Paused "config" else Running)
      ; consecutive_rejects = 0
      }
    in
    let mirror, plan = Mirror.rebalance t.mirror in
    gate { t with mirror } plan
  | Running when follow.paused -> pause t "config"
  | Paused _ when was_paused_by_config && not follow.paused -> resume t
  | Running | Paused _ ->
    let mirror, plan = Mirror.rebalance t.mirror in
    gate { t with mirror } plan
;;

(* The input at the mirror's level: places and cancels name parent orders. *)
let apply_mirror t (input : Input.t) =
  match t.status, input with
  | _, Configure { follow; specs } -> configure t ~follow ~specs
  | Stopped, _ -> t, Output.empty
  | _, Mirror event -> on_mirror t event
  | _, Order_rejected { cloid; message } -> on_reject t ~cloid ~message
  | Running, Pause reason -> pause t reason
  | Paused _, Pause _ -> t, Output.empty
  | Running, Resume -> t, Output.empty
  | Paused _, Resume -> resume t
  | _, Market _ -> t, Output.empty
  | (Running | Paused _), Stop ->
    let t, out = pause t "stopped" in
    { t with status = Stopped }, { out with notices = [ Stopped ] }
;;

(* {2 Execution: parents and their children} *)

(* Fees the venue does not report with an IOC answer are estimated at Hyperliquid's base
   perpetual tier (4.5 bp taker, 1.5 bp maker) for the cost reports. *)
let estimated_fee ~maker ~size ~price =
  Size.to_float size *. Price.to_float price *. (if maker then 1.5 else 4.5) /. 10_000.
;;

let find_child t cloid =
  List.find_map t.execs ~f:(fun (e : Exec.t) ->
    Option.map (Exec.child_of e cloid) ~f:(fun id -> e, id))
;;

let replace_exec t (e : Exec.t) =
  { t with
    execs =
      List.map t.execs ~f:(fun (x : Exec.t) ->
        if Cloid.equal x.order.cloid e.order.cloid then e else x)
  }
;;

(* Child actions in the mirror's terms. *)
let to_plan (e : Exec.t) (actions : Execution_algos.Child.Action.t list) =
  let posted = ref e.posted in
  let post_only = ref [] in
  let plan =
    List.map actions ~f:(fun (a : Execution_algos.Child.Action.t) ->
      match a with
      | Place c ->
        let cloid = Exec.child_cloid e c.id in
        if c.post_only
        then (
          posted := c.id :: !posted;
          post_only := cloid :: !post_only);
        Plan.Action.Place
          { cloid
          ; symbol = e.order.symbol
          ; side = c.side
          ; size = c.size
          ; limit_px = c.limit_px
          ; reduce_only = e.order.reduce_only
          }
      | Cancel id ->
        Plan.Action.Cancel { symbol = e.order.symbol; cloid = Exec.child_cloid e id })
  in
  ( { e with posted = !posted }
  , { Output.empty with
      plan = { Plan.empty with actions = plan }
    ; post_only = List.rev !post_only
    } )
;;

(* A finished parent leaves the list, closes in the mirror and reports its costs. *)
let settle t (e : Exec.t) =
  if not (Execution_algos.Scheduler.is_done e.sched)
  then replace_exec t e, Output.empty
  else (
    let t =
      { t with
        execs =
          List.filter t.execs ~f:(fun (x : Exec.t) ->
            not (Cloid.equal x.order.cloid e.order.cloid))
      ; mirror = Mirror.on_order_closed t.mirror e.order.cloid
      }
    in
    let end_px = Map.find t.mirror.marks e.order.symbol in
    let report = Execution_algos.Scheduler.report ?end_px e.sched in
    t, { Output.empty with reports = Option.to_list report })
;;

let step_exec t (e : Exec.t) event =
  let sched, actions = Execution_algos.Scheduler.apply e.sched event in
  let e, out = to_plan { e with sched } actions in
  let t, settled = settle t e in
  t, Output.append out settled
;;

let min_size (spec : Rounding.Spec.t) ~min_notional ~mark =
  let lot = Size.to_units spec.lot in
  let m = Price.to_units mark in
  if m <= 0 || lot <= 0
  then spec.lot
  else (
    let units = Fixed_decimal.div_units (Usd.to_units min_notional) m in
    Size.of_units ((units + lot - 1) / lot * lot))
;;

(* A planned place becomes a parent. Parents below the venue's minimum order (a full close
   of a small position) always go out as one IOC. *)
let start_exec t (o : Plan.Order.t) =
  match Exec.split o.cloid, Map.find t.specs o.symbol with
  | None, _ | _, None ->
    t, { Output.empty with plan = { Plan.empty with actions = [ Place o ] } }
  | Some (prefix, seq), Some spec ->
    let mark = Option.value (Map.find t.mirror.marks o.symbol) ~default:o.limit_px in
    let min_size =
      min_size spec ~min_notional:(effective_caps t).min_order_notional ~mark
    in
    let algo : Execution_algos.Algo.t =
      if Size.( < ) o.size min_size then Immediate else Algo_bridge.to_algo t.follow.algo
    in
    let parent =
      Execution_algos.Parent.create
        ~side:o.side
        ~size:o.size
        ~limit_px:o.limit_px
        ~reference_px:mark
        ~lot:spec.lot
        ~min_size
        ~equity:(Usd.to_float t.mirror.follower_equity)
        ()
    in
    let e =
      { Exec.order = o
      ; prefix
      ; seq
      ; sched = Execution_algos.Scheduler.create algo parent
      ; posted = []
      }
    in
    let t = { t with execs = t.execs @ [ e ] } in
    (match algo with
     | Immediate ->
       (* no market data needed: one IOC at the mirror's limit, now *)
       step_exec
         t
         e
         (Tick { now_ns = 0; book = Execution_algos.Book.empty; traded = Size.zero })
     | Twap _ | Vwap _ | Pov _ | Passive _ | Adaptive _ -> t, Output.empty)
;;

(* The mirror's plan in wire terms: places become parents, cancels of parents cancel their
   resting children. *)
let dispatch t (out : Output.t) =
  let t, outs =
    List.fold_map out.plan.actions ~init:t ~f:(fun t action ->
      match action with
      | Plan.Action.Place o -> start_exec t o
      | Cancel { cloid; _ } as cancel ->
        (match
           List.find t.execs ~f:(fun (e : Exec.t) -> Cloid.equal e.order.cloid cloid)
         with
         | Some e ->
           (* IOC children are normally gone already; cancelling them too is the same
              safety net as cancelling a plain IOC order *)
           let ioc_cancels =
             List.filter_map (Execution_algos.Scheduler.working e.sched) ~f:(fun w ->
               if w.child.post_only
               then None
               else
                 Some
                   (Plan.Action.Cancel
                      { symbol = e.order.symbol; cloid = Exec.child_cloid e w.child.id }))
           in
           let t, out = step_exec t e Cancel in
           ( t
           , Output.append
               { Output.empty with plan = { Plan.empty with actions = ioc_cancels } }
               out )
         | None ->
           t, { Output.empty with plan = { Plan.empty with actions = [ cancel ] } }))
  in
  let wire = List.fold outs ~init:Output.empty ~f:Output.append in
  (* cancels go before places, as in the mirror's plans *)
  let cancels, places =
    List.partition_tf wire.plan.actions ~f:(function
      | Plan.Action.Cancel _ -> true
      | Place _ -> false)
  in
  ( t
  , { wire with
      plan = { actions = cancels @ places; notes = out.plan.notes }
    ; notices = out.notices @ wire.notices
    ; reports = out.reports @ wire.reports
    } )
;;

(* Open parents as the mirror's in-flight orders: what they may still fill. *)
let parents_in_flight t =
  List.map t.execs ~f:(fun (e : Exec.t) ->
    let left = Execution_algos.Scheduler.remaining e.sched in
    { Mirror.Pending.cloid = e.order.cloid
    ; symbol = e.order.symbol
    ; remaining =
        (if Market_data.Side.equal e.order.side Buy then left else Size.neg left)
    ; cancel_requested =
        List.exists t.mirror.pending ~f:(fun (p : Mirror.Pending.t) ->
          Cloid.equal p.cloid e.order.cloid && p.cancel_requested)
    })
;;

let dispatch_input t input =
  let t, out = apply_mirror t input in
  dispatch t out
;;

let apply t (input : Input.t) =
  match t.status, input with
  | Stopped, (Mirror _ | Order_rejected _ | Market _ | Pause _ | Resume | Stop) ->
    t, Output.empty
  | _, Mirror (Follower_fill ({ cloid = Some cloid; _ } as fill)) ->
    (match find_child t cloid with
     | None -> dispatch_input t input
     | Some (e, id) ->
       let maker = List.mem e.posted id ~equal:Int.equal in
       let fee =
         if Usd.is_zero fill.fee
         then estimated_fee ~maker ~size:fill.size ~price:fill.price
         else Usd.to_float fill.fee
       in
       let t, out =
         apply_mirror t (Mirror (Follower_fill { fill with cloid = Some e.order.cloid }))
       in
       let t, out = dispatch t out in
       (match
          List.find t.execs ~f:(fun (x : Exec.t) ->
            Cloid.equal x.order.cloid e.order.cloid)
        with
        | None -> t, out
        | Some e ->
          let t, out' =
            step_exec
              t
              e
              (Fill { child = id; size = fill.size; price = fill.price; fee; maker })
          in
          t, Output.append out out'))
  | _, Mirror (Order_closed cloid) ->
    (match find_child t cloid with
     | None -> dispatch_input t input
     | Some (e, id) -> step_exec t e (Closed id))
  | _, Order_rejected { cloid; message } ->
    (match find_child t cloid with
     | None -> dispatch_input t input
     | Some (e, id) ->
       (* the parent's in-flight size before the close: the margin shortfall *)
       let pending =
         List.find t.mirror.pending ~f:(fun (p : Mirror.Pending.t) ->
           Cloid.equal p.cloid e.order.cloid)
       in
       let t, out = step_exec t e (Closed id) in
       let reject = Reject.classify message in
       (* the account cannot pay or sign: stop working the parent *)
       let t, out =
         match
           ( reject
           , List.find t.execs ~f:(fun (x : Exec.t) ->
               Cloid.equal x.order.cloid e.order.cloid) )
         with
         | (Insufficient_margin | Agent_invalid), Some e ->
           let t, out' = step_exec t e Cancel in
           t, Output.append out out'
         | _ -> t, out
       in
       (* [settle] already closed a finished parent in the mirror *)
       let t, rejected =
         on_reject ~close:false ?pending t ~cloid:e.order.cloid ~message
       in
       let t, rejected = dispatch t rejected in
       t, Output.append out rejected)
  | _, Mirror (Resync { leader; follower; marks }) ->
    let follower =
      { follower with open_orders = follower.open_orders @ parents_in_flight t }
    in
    dispatch_input t (Mirror (Resync { leader; follower; marks }))
  | _, Market { symbol; now_ns; book; traded } ->
    let t = if band_uses_impact t then update_slippage_estimate t ~symbol ~book else t in
    List.fold t.execs ~init:(t, Output.empty) ~f:(fun (t, out) (e : Exec.t) ->
      if Market_data.Symbol.equal e.order.symbol symbol
      then (
        (* [e] may be stale after an earlier parent settled; take the current one *)
        match
          List.find t.execs ~f:(fun (x : Exec.t) ->
            Cloid.equal x.order.cloid e.order.cloid)
        with
        | None -> t, out
        | Some e ->
          let t, out' = step_exec t e (Tick { now_ns; book; traded }) in
          t, Output.append out out')
      else t, out)
  | _, (Configure _ | Mirror _ | Pause _ | Resume | Stop) -> dispatch_input t input
;;

let replay inputs =
  match inputs with
  | Input.Configure { follow; specs } :: rest ->
    let t, outputs =
      List.fold_map rest ~init:(create ~follow ~specs) ~f:(fun t input -> apply t input)
    in
    Ok (t, Output.empty :: outputs)
  | [] -> Or_error.error_string "empty journal"
  | first :: _ ->
    Or_error.error_s [%message "journal must start with Configure" (first : Input.t)]
;;
