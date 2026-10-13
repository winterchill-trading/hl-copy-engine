open! Core
open! Async
open Hl_copy_core

let keystore_signer ?(now = Time_ns.now) keys (follow : Follower_config.t) =
  (* Small files, read synchronously like the API writes them. *)
  Deferred.return
    (let open Or_error.Let_syntax in
     let%bind entry = Hl_copy_keystore.Agent_keys.active keys ~owner:follow.follower in
     let%bind (entry : Hl_copy_keystore.Agent_keys.Entry.t) =
       match entry with
       | Some entry -> Ok entry
       | None ->
         Or_error.error_s
           [%message "no active agent" ~follower:(follow.follower : Address.t)]
     in
     let now_ms = Time_ns.to_int_ns_since_epoch (now ()) / 1_000_000 in
     let%bind () =
       match entry.valid_until_ms with
       | Some until when until <= now_ms ->
         Or_error.error_s
           [%message
             "agent expired"
               ~follower:(follow.follower : Address.t)
               ~agent:(entry.agent_address : Address.t)]
       | _ -> Ok ()
     in
     let%bind secret = Hl_copy_keystore.Agent_keys.secret keys entry in
     let%bind key =
       Hl_client.Signing.Private_key.of_hex (Hl_copy_keystore.Sealed.to_hex secret)
     in
     if Address.equal (Hl_client.Signing.Private_key.address key) entry.agent_address
     then Ok (Follower.Signer.Agent key)
     else
       Or_error.error_s
         [%message
           "sealed key does not match the agent address"
             ~agent:(entry.agent_address : Address.t)])
;;
