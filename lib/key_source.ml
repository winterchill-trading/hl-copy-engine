open! Core
open! Async
open Hl_copy_core

let keystore_signer ?(now = Time_ns.now) keys (follow : Follower_config.t) =
  (* One small file, read synchronously like the API writes it. *)
  Deferred.return
    (let open Or_error.Let_syntax in
     let%bind found = Key_store.get keys ~account:follow.follower in
     let%bind (entry : Key_store.Entry.t), hex =
       match found with
       | Some found -> Ok found
       | None ->
         Or_error.error_s [%message "no agent" ~follower:(follow.follower : Address.t)]
     in
     let%bind () =
       match entry.valid_until with
       | Some until when Time_ns.( <= ) until (now ()) ->
         Or_error.error_s
           [%message
             "agent expired"
               ~follower:(follow.follower : Address.t)
               ~agent:(entry.agent_address : Address.t)]
       | _ -> Ok ()
     in
     let%bind key = Hl_client.Signing.Private_key.of_hex hex in
     if Address.equal (Hl_client.Signing.Private_key.address key) entry.agent_address
     then Ok (Follower.Signer.Agent key)
     else
       Or_error.error_s
         [%message
           "the sealed key does not match the agent address"
             ~agent:(entry.agent_address : Address.t)])
;;
