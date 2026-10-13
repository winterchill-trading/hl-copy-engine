(** Agent keys for followers, from hl-copy-api's key store ({!Hl_copy_keystore}): the API
    seals each user's agent key under the master key ([HL_COPY_MASTER_KEY]) in
    [<dir>/<owner>.sexp]; the engine opens the user's [Active] agent in memory when a
    follower starts. Keys are never logged. *)

open! Core
open! Async
open Hl_copy_core

(** The signer of [follow.follower]'s active agent. Fails when the user has no active
    agent, or when it expired ([valid_until_ms] before [now]); the user must approve a new
    one, after which the follow file's next change restarts the follower with it. *)
val keystore_signer
  :  ?now:(unit -> Time_ns.t)
  -> Hl_copy_keystore.Agent_keys.t
  -> Follower_config.t
  -> Follower.Signer.t Or_error.t Deferred.t
