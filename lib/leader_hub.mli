(** Leader position updates, shared by every follower of a leader.

    Hyperliquid serves user subscriptions for at most 10 distinct addresses per IP, so the
    hub keeps one websocket ({!Hl_client.User_feed}) carrying one [userFills] subscription
    per leader address, whatever the number of followers (the feed fans each address out
    to its consumers). Leaders beyond [max_ws_users] are polled instead: one
    [clearinghouseState] request per leader every [poll_interval], paced by the shared
    {!Rate_limit} bucket and fanned out the same way.

    Polling reads positions rather than [userFills] (which the design mentions as the
    fallback) because the mirror copies positions: [clearinghouseState] weighs 2 against
    [userFills]'s 20 plus 1 per 20 fills, and it cannot miss a fill. *)

open! Core
open! Async
open Hl_protocol

module Update : sig
  type t =
    | Position of
        { coin : Coin.t
        ; szi : Size.t (** signed, absolute *)
        ; mark : Price.t option
        (** websocket: the price of the leader's latest fill in [coin]; polling: the
            position value over its size (none when flat) *)
        ; fill_time_ms : int option (** websocket: the exchange time of that fill *)
        }
    | Resync
    (** the connection was replaced; fills missed meanwhile follow, but the follower
        should also resync from [clearinghouseState] *)
  [@@deriving sexp_of]
end

module Source : sig
  type t =
    | Websocket
    | Polling
  [@@deriving sexp_of, compare, equal]
end

type t

val create
  :  ?max_ws_users:int (** default {!Hl_client.User_feed.default_max_users} *)
  -> ?poll_interval:Time_ns.Span.t (** default 5 s *)
  -> ?time_source:Time_source.t
  -> rate_limit:Rate_limit.t
  -> Hl_client.Config.t
  -> t

(** A new consumer of [leader]'s updates. Close the reader to unsubscribe; the last
    consumer of a polled leader stops its poller. Updates are written without pushback. *)
val subscribe : t -> leader:Address.t -> Update.t Pipe.Reader.t Or_error.t Deferred.t

(** How [leader] is followed, if anyone follows it. *)
val source : t -> leader:Address.t -> Source.t option

(** Followed leaders and their consumer counts. *)
val leaders : t -> (Address.t * Source.t * int) list

val close : t -> unit Deferred.t
