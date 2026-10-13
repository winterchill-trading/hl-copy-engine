(** Supervises followers: one {!Follower} per follow file in a directory, a shared
    {!Leader_hub} and {!Rate_limit}, and an HTTP endpoint with [/metrics] (Prometheus
    text), [/status] (JSON) and [/healthz].

    The directory holds {!Hl_copy_core.Follower_config} sexp files ([*.sexp]), which the
    API writes. It is rescanned every [scan_interval]: a new file starts a follower, a
    changed file reconfigures it in place (or restarts it when the follower or leader
    address changed), a removed file stops it. A file that does not parse is logged and
    counted, and the follower it used to describe keeps running on the last good version.
    Two files describing the same follower and leader are refused. Files are read whole;
    the API should write them atomically (write, then rename). *)

open! Core
open! Async
open Hl_copy_core

module Config : sig
  type t =
    { api : Hl_client.Config.t (** hl-sim or testnet; mainnet is refused *)
    ; configs_dir : string
    ; journal_root : string option
    ; scan_interval : Time_ns.Span.t
    ; resync_interval : Time_ns.Span.t
    ; max_ws_users : int (** leaders followed over the websocket before polling *)
    ; leader_poll_interval : Time_ns.Span.t
    ; signer_for : Follower_config.t -> Follower.Signer.t Or_error.t Deferred.t
    (** how the follow's orders are signed: the key store, or a key from the environment
        in tests *)
    ; agent_of : (Follower_config.t -> Address.t option Or_error.t) option
    (** the account's current agent, checked on every scan: [None] (revoked) pauses the
        follower, a different address restarts it with the new key, and a follow that
        could not start is retried as soon as it changes *)
    }

  (** Scan every second, resync every 30 s, 10 websocket leaders, poll others every 5 s,
      no journal. *)
  val create
    :  ?journal_root:string
    -> ?scan_interval:Time_ns.Span.t
    -> ?resync_interval:Time_ns.Span.t
    -> ?max_ws_users:int
    -> ?leader_poll_interval:Time_ns.Span.t
    -> ?agent_of:(Follower_config.t -> Address.t option Or_error.t)
    -> api:Hl_client.Config.t
    -> configs_dir:string
    -> signer_for:(Follower_config.t -> Follower.Signer.t Or_error.t Deferred.t)
    -> unit
    -> t
end

type t

(** Scans once, starts the followers found, then keeps scanning. With [port], serves HTTP
    there (0 picks a free port; see {!port}). *)
val start : ?port:int -> Config.t -> t Or_error.t Deferred.t

(** Rescans the directory now. *)
val scan : t -> unit Deferred.t

val followers : t -> Follower.t list
val find : t -> follower:Address.t -> leader:Address.t -> Follower.t option

(** Follow files not running, with the error: unparsable, duplicate, or failed to start
    (retried when the file or the account's agent changes, or after 30 s). *)
val errors : t -> (string * Error.t) list

val port : t -> int option
val metrics_text : t -> string
val status_json : t -> Yojson.Safe.t

(** Stops every follower, the hub and the HTTP server. *)
val stop : t -> unit Deferred.t
