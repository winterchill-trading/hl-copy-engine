(** The pure state of one follow: {!Hl_copy_core.Mirror} plus what the engine adds around
    it (pause and stop, the margin cap after an insufficient-margin reject, reject
    counters).

    Every input the actor ({!Follower}) sees goes through {!apply}, and {!apply} is a pure
    function: the same inputs give the same outputs, byte for byte, which is what makes a
    journal replay deterministic. Nothing here reads a clock; time enters only through the
    inputs (a [Start_day] at the UTC day boundary is an input like any other).

    Rules on top of the mirror:

    - Paused: inputs still update the mirror, so a resume starts from the right state, but
      no order is placed. A place the mirror planned is dropped and closed in the mirror
      at once, so it never counts as in flight. Pausing cancels every open order of the
      follow (IOC orders are normally already gone, so this is a safety net).
    - Stopped: like paused, and later inputs change nothing until a [Configure], which
      starts a new run (a restart replaying the journal) from the mirror state as it was.
    - Insufficient margin: the account leverage the follower holds when the reject arrives
      becomes a leverage cap (on top of the configured one), so the mirror stops growing
      positions it cannot pay for; the rejected notional is added to [shortfall]. A
      resume, a new UTC day or a [Configure] lifts the cap.
    - An agent reject (unknown or expired agent) pauses the follow until resumed: the user
      must approve the agent again.

    Execution: every place the mirror plans becomes a parent worked by an
    [Execution_algos.Scheduler] with the follow's algorithm ({!Follower_config.t.algo}).
    [Immediate] (the default) sends the mirror's order unchanged. Other algorithms wait
    for [Market] inputs and send child orders; the mirror counts the parent as in flight
    (also across a resync) until its scheduler is done, and each finished parent adds a
    cost report to the output. Parents below the minimum order notional always go out as
    [Immediate]. Fees missing from fills (IOC answers carry none) are estimated at 4.5 bp
    taker and 1.5 bp maker for the reports. *)

open! Core
open Hl_copy_core

module Status : sig
  type t =
    | Running
    | Paused of string (** why *)
    | Stopped
  [@@deriving bin_io, sexp, compare, equal]

  val to_string : t -> string
end

module Input : sig
  module Stable : sig
    (** Journals written before execution algorithms; read through {!V2.of_v1}. *)
    module V1 : sig
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

    module V2 : sig
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
            ; traded : Market_data.Size.Stable.V1.t
            }
      [@@deriving bin_io, sexp, compare, equal]

      val of_v1 : V1.t -> t
    end
  end

  type t = Stable.V2.t =
    | Configure of
        { follow : Follower_config.t
        ; specs : Rounding.Spec.t Mirror.Symbol_map.t
        } (** the first input of every journal; later ones reconfigure *)
    | Mirror of Mirror.Event.t
    (** A [Follower_fill] or [Order_closed] naming a child order goes to its parent's
        scheduler; the mirror sees the fill under the parent's client order id, and the
        parent's close once the scheduler is done. *)
    | Order_rejected of
        { cloid : Cloid.t
        ; message : string
        } (** the order is closed; [message] is the exchange's error text *)
    | Pause of string
    | Resume
    | Stop
    | Market of
        { symbol : Market_data.Symbol.t
        ; now_ns : int (** nanoseconds since the epoch *)
        ; book : Execution_algos.Book.t
        ; traded : Market_data.Size.t (** cumulative market volume, any origin *)
        }
    (** A market tick for the parents in [symbol] (time, book, volume): what drives every
        algorithm but [Immediate] *)
  [@@deriving bin_io, sexp, compare, equal]
end

module Notice : sig
  (** What changed besides the plan, for logs and metrics. *)
  type t =
    | Margin_capped of
        { leverage : float
        ; shortfall : Usd.t (** the notional of the rejected order *)
        }
    | Rejected of Reject.t
    | Paused of string
    | Resumed
    | Stopped
    | Dropped_while_paused of Plan.Order.t
  [@@deriving bin_io, sexp, compare, equal]
end

module Output : sig
  module Stable : sig
    module V1 : sig
      type t =
        { plan : Plan.Stable.V1.t
        ; notices : Notice.t list
        }
      [@@deriving bin_io, sexp, compare, equal]
    end

    module V2 : sig
      type t =
        { plan : Plan.Stable.V1.t
        ; notices : Notice.t list
        ; post_only : Cloid.Stable.V1.t list
        ; reports : Execution_algos.Cost_report.Stable.V1.t list
        }
      [@@deriving bin_io, sexp, compare, equal]

      val of_v1 : V1.t -> t
      val to_v1 : t -> V1.t
    end
  end

  type t = Stable.V2.t =
    { plan : Plan.t
    (** what to send now, in wire terms (child orders); empty unless running (cancels
        excepted) *)
    ; notices : Notice.t list
    ; post_only : Cloid.t list
    (** places of [plan] to send add-liquidity-only (resting) instead of IOC *)
    ; reports : Execution_algos.Cost_report.t list (** parents finished by this input *)
    }
  [@@deriving bin_io, sexp, compare, equal]

  val empty : t
  val append : t -> t -> t
end

(** One parent order (a place the mirror planned) and the scheduler working it. Child
    [k]'s client order id is the parent's with [k] in bits 40 and up of its sequence half,
    so child 0 is the parent's own id and an [Immediate] parent sends exactly the mirror's
    order. *)
module Exec : sig
  type t =
    { order : Plan.Order.t
    ; prefix : int
    ; seq : int
    ; sched : Execution_algos.Scheduler.t
    ; posted : int list (** ids of post-only children *)
    }
  [@@deriving bin_io, sexp, compare, equal]

  val child_cloid : t -> int -> Cloid.t

  (** The child id a client order id names in this parent. *)
  val child_of : t -> Cloid.t -> int option
end

type t =
  { follow : Follower_config.t
  ; specs : Rounding.Spec.t Mirror.Symbol_map.t
  ; mirror : Mirror.t
  ; status : Status.t
  ; margin_cap : float option (** account leverage cap from a margin reject *)
  ; shortfall : Usd.t (** rejected notional since the cap was set *)
  ; rejects : int
  ; consecutive_rejects : int (** reset by a fill of one of the follow's orders *)
  ; execs : Exec.t list (** parents being worked, oldest first *)
  }
[@@deriving bin_io, sexp, compare, equal]

(** The state after a first [Configure]: running unless [follow.paused], and nothing
    planned until the first leader position or resync. *)
val create : follow:Follower_config.t -> specs:Rounding.Spec.t Mirror.Symbol_map.t -> t

val apply : t -> Input.t -> t * Output.t

(** Folds inputs from the start: the first must be [Configure]. Returns the final state
    and one output per input (the first is {!Output.empty}). *)
val replay : Input.t list -> (t * Output.t list) Or_error.t

(** The caps the mirror uses: the configured ones with {!margin_cap} folded into
    [max_leverage]. *)
val effective_caps : t -> Caps.t

(** [sum |size| * mark / equity] over the follower's positions (0 when equity is not
    positive). *)
val follower_leverage : t -> float

val is_running : t -> bool

(** Symbols with a parent waiting for market ticks (any algorithm but [Immediate]). *)
val market_symbols : t -> Market_data.Symbol.t list

(** Whether [cloid] is a post-only child still resting (its fills come from the account's
    fill feed, not from an order answer). *)
val is_resting_child : t -> Cloid.t -> bool
