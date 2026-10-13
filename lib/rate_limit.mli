(** A token bucket for Hyperliquid's REST weight budget: 1200 weight per minute per IP
    (see the rate limits page of the API docs). Info requests cost 2
    ([clearinghouseState], [allMids], [openOrders]) or 20 ([userFills], [meta]); an
    exchange request costs [1 + floor(batch / 40)].

    The bucket starts full and refills continuously. One bucket is shared by everything an
    engine process sends, so a burst of resyncs cannot starve order placement of more than
    the burst itself. *)

open! Core
open! Async

module Weight : sig
  val clearinghouse_state : int
  val all_mids : int
  val open_orders : int
  val meta : int
  val user_fills : int

  (** [maxBuilderFee] is not in the weight-2 list of the docs, so it costs 20 like every
      other info request. *)
  val max_builder_fee : int

  (** [1 + batch / 40]. *)
  val exchange : batch:int -> int
end

type t [@@deriving sexp_of]

(** Hyperliquid's documented budget: 1200 per minute, bucket of 1200. *)
val hyperliquid : unit -> t

(** Requires positive [capacity] and [per_minute]. The bucket starts full at the first
    call that passes a time. *)
val create : capacity:int -> per_minute:int -> t

(** Takes [weight] if available at [now], else says how long until it will be. A weight
    above [capacity] is clamped to [capacity] so it can still go through. *)
val try_take : t -> now:Time_ns.t -> weight:int -> [ `Ok | `Wait of Time_ns.Span.t ]

(** Waits on [time_source] until [weight] is available, then takes it. Callers are served
    in order. *)
val take : ?time_source:Time_source.t -> t -> weight:int -> unit Deferred.t

(** Tokens available at [now]. *)
val available : t -> now:Time_ns.t -> float

(** Total weight taken so far. *)
val taken : t -> int
