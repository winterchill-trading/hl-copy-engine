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
    - Stopped: like paused, and final; later inputs other than [Configure] change nothing.
    - Insufficient margin: the account leverage the follower holds when the reject arrives
      becomes a leverage cap (on top of the configured one), so the mirror stops growing
      positions it cannot pay for; the rejected notional is added to [shortfall]. A
      resume, a new UTC day or a [Configure] lifts the cap.
    - An agent reject (unknown or expired agent) pauses the follow until resumed: the user
      must approve the agent again. *)

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
  end

  type t = Stable.V1.t =
    | Configure of
        { follow : Follower_config.t
        ; specs : Rounding.Spec.t Mirror.Symbol_map.t
        } (** the first input of every journal; later ones reconfigure *)
    | Mirror of Mirror.Event.t
    | Order_rejected of
        { cloid : Cloid.t
        ; message : string
        } (** the order is closed; [message] is the exchange's error text *)
    | Pause of string
    | Resume
    | Stop
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
  type t =
    { plan : Plan.t (** what to send now; empty unless running (cancels excepted) *)
    ; notices : Notice.t list
    }
  [@@deriving bin_io, sexp, compare, equal]

  val empty : t
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
