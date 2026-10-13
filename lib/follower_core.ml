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
  end

  include Stable.V1
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
  type t =
    { plan : Plan.t
    ; notices : Notice.t list
    }
  [@@deriving bin_io, sexp, compare, equal]

  let empty = { plan = Plan.empty; notices = [] }
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
    }
  in
  sync_config t
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
  then t, { Output.plan; notices = [] }
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
    , { Output.plan = { plan with actions }
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
  t, { Output.plan = { Plan.empty with actions = cancels }; notices = [ Paused reason ] }
;;

let lift_cap t = sync_config { t with margin_cap = None; shortfall = Usd.zero }

let resume t =
  let t = lift_cap { t with status = Running; consecutive_rejects = 0 } in
  let t = { t with mirror = Mirror.start_day t.mirror } in
  let mirror, plan = Mirror.rebalance t.mirror in
  let t, out = gate { t with mirror } plan in
  t, { out with notices = Resumed :: out.notices }
;;

let on_reject t ~cloid ~message =
  let pending =
    List.find t.mirror.pending ~f:(fun (p : Mirror.Pending.t) ->
      Cloid.equal p.cloid cloid)
  in
  let t =
    { t with
      mirror = Mirror.on_order_closed t.mirror cloid
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
    , { Output.plan = Plan.empty
      ; notices = [ rejected; Margin_capped { leverage; shortfall = notional } ]
      } )
  | Agent_invalid ->
    let t, out = pause t "agent rejected" in
    t, { out with notices = rejected :: out.notices }
  | No_liquidity | Rate_limited | Other _ ->
    t, { Output.plan = Plan.empty; notices = [ rejected ] }
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

let apply t (input : Input.t) =
  match t.status, input with
  | _, Configure { follow; specs } -> configure t ~follow ~specs
  | Stopped, _ -> t, Output.empty
  | _, Mirror event -> on_mirror t event
  | _, Order_rejected { cloid; message } -> on_reject t ~cloid ~message
  | Running, Pause reason -> pause t reason
  | Paused _, Pause _ -> t, Output.empty
  | Running, Resume -> t, Output.empty
  | Paused _, Resume -> resume t
  | (Running | Paused _), Stop ->
    let t, out = pause t "stopped" in
    { t with status = Stopped }, { out with notices = [ Stopped ] }
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
