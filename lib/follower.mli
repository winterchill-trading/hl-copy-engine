(** The actor that runs one follow against a Hyperliquid API (hl-sim or testnet).

    It subscribes to the leader through the shared {!Leader_hub}, turns every update,
    order result, resync, timer and command into a {!Follower_core.Input.t}, applies it,
    and sends the resulting plan: IOC orders inside the slippage bound, signed by the
    follower's agent. Everything runs on one sequencer, so a resync never interleaves with
    an order in flight, and every input and output is journaled ({!Journal}) so the run
    replays deterministically.

    On start it reads [meta] (lot and tick per coin), replays the follow's journal if
    there is one (so client order ids continue where they stopped), and resyncs both
    accounts from [clearinghouseState] before sending anything. It then resyncs every
    [resync_interval] (default 30 s), after every leader reconnect, and after an order
    request that failed in transport (the order may or may not have gone through).

    Orders fill or die at once, so the order response is the fill: [Filled] becomes a
    follower fill (fees are not in the response; the next resync's equity includes them)
    and closes the order, [Error] becomes a reject. *)

open! Core
open! Async
open Hl_copy_core

module Signer : sig
  type t =
    | Agent of Hl_client.Signing.Private_key.t
    (** the follower's approved agent ({!Hl_client.Client.trading_with_agent}) *)
    | Hook of Hl_client.Exchange.sign
    (** an external signer, e.g. a key store that decrypts the agent key *)
    | Unsigned (** hl-sim without [-strict-signatures] only: acts through [X-Address] *)
end

module Config : sig
  type t =
    { follow : Follower_config.t
    ; signer : Signer.t
    ; resync_interval : Time_ns.Span.t
    ; journal_root : string option (** no journal when [None] *)
    }

  (** 30 s resyncs, no journal. *)
  val create
    :  ?resync_interval:Time_ns.Span.t
    -> ?journal_root:string
    -> signer:Signer.t
    -> Follower_config.t
    -> t
end

type t

(** Refuses a mainnet [api] (see {!Safety}). [api] is the venue's address; the follower's
    account is set from the follow. *)
val start
  :  ?time_source:Time_source.t
  -> hub:Leader_hub.t
  -> rate_limit:Rate_limit.t
  -> api:Hl_client.Config.t
  -> Config.t
  -> t Or_error.t Deferred.t

val follow : t -> Follower_config.t
val state : t -> Follower_core.t
val metrics : t -> Metrics.t

(** Cancels open orders and stops placing; the mirror keeps tracking. *)
val pause : t -> reason:string -> unit Deferred.t

(** Lifts a pause and the margin cap, and rebalances. *)
val resume : t -> unit Deferred.t

(** Applies a new version of the follow (caps, mode, slippage, paused). The follower and
    leader addresses must not change. *)
val reconfigure : t -> Follower_config.t -> unit Or_error.t Deferred.t

(** Resyncs both accounts now (normally on the timer). *)
val resync_now : t -> unit Deferred.t

(** Cancels open orders, unsubscribes and closes the journal. Idempotent. *)
val stop : t -> unit Deferred.t

(** Becomes determined when every input queued so far has been applied and its orders
    answered. *)
val idle : t -> unit Deferred.t

(** The address of the agent signing this follower's orders, when it is a key. *)
val agent_address : t -> Address.t option

(** The last reject or resync error (cleared by the next fill), or the pause reason. *)
val last_error : t -> string option

(** For [/status]: [follower], [leader], [state] (running, paused, stopped), [pnl]
    (attributed realized plus unrealized, USD), [positions] (a list of [coin], [size],
    [entry_px], [unrealized_pnl], [leverage], all numbers), [last_error], and details
    (equities, both positions maps, margin cap, last resync, metrics). *)
val status_json : t -> Yojson.Safe.t

module For_testing : sig
  (** While set, leader updates are dropped (as if the websocket missed them); only a
      resync brings the follower back in line. *)
  val drop_leader_updates : t -> bool -> unit
end
