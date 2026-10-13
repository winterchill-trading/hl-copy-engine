(** Why Hyperliquid refused an order, from the error text of an order status or an
    [{"status": "err"}] response. The texts are the exchange's (and hl-sim's, which copies
    them). *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      | Insufficient_margin (** ["Insufficient margin to place order."] *)
      | No_liquidity
      (** an IOC that found nothing inside its limit:
          ["Order could not immediately match against any resting orders."] *)
      | Agent_invalid
      (** the agent is unknown, expired or deregistered:
          ["User or API Wallet ... does not exist."] *)
      | Rate_limited
      | Other of string
    [@@deriving bin_io, sexp, compare, equal]
  end
end

type t = Stable.V1.t =
  | Insufficient_margin
  | No_liquidity
  | Agent_invalid
  | Rate_limited
  | Other of string
[@@deriving bin_io, sexp, compare, equal]

val classify : string -> t

(** Short name for metrics labels: [margin], [no_liquidity], [agent], [rate_limited],
    [other]. *)
val label : t -> string
