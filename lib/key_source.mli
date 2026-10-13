(** Agent keys for followers, from the key store the API writes
    ({!Hl_copy_core.Key_store}: [<state_dir>/agents/<account>.key], sealed under
    [HL_COPY_MASTER_KEY]). The engine opens the follower's agent in memory when the
    follower starts. Keys are never logged. *)

open! Core
open! Async
open Hl_copy_core

(** The signer of [follow.follower]'s agent. Fails when the account has no agent (never
    approved, or revoked), when it expired ([valid_until] before [now]), or when the file
    does not open; the follow then does not start, and the error shows in [/status]. The
    user approves a new agent, after which the follow file's next change starts the
    follower with it. *)
val keystore_signer
  :  ?now:(unit -> Time_ns.t)
  -> Key_store.t
  -> Follower_config.t
  -> Follower.Signer.t Or_error.t Deferred.t
