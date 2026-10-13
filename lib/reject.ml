open! Core

module Stable = struct
  module V1 = struct
    type t =
      | Insufficient_margin
      | No_liquidity
      | Agent_invalid
      | Rate_limited
      | Other of string
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let classify message =
  let m = String.lowercase message in
  let has s = String.is_substring m ~substring:s in
  if has "insufficient margin"
  then Insufficient_margin
  else if has "could not immediately match"
  then No_liquidity
  else if has "api wallet" || has "agent"
  then Agent_invalid
  else if has "rate limit" || has "too many"
  then Rate_limited
  else Other message
;;

let label = function
  | Insufficient_margin -> "margin"
  | No_liquidity -> "no_liquidity"
  | Agent_invalid -> "agent"
  | Rate_limited -> "rate_limited"
  | Other _ -> "other"
;;
