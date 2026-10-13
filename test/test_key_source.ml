open! Core
open! Async
open Hl_copy_core
open Hl_copy_engine
module Agent_keys = Hl_copy_keystore.Agent_keys
module Sealed = Hl_copy_keystore.Sealed

(* Throwaway master and agent keys. *)
let master = ok_exn (Sealed.Master_key.of_hex (String.make 64 'a'))
let other_master = ok_exn (Sealed.Master_key.of_hex (String.make 64 'b'))
let agent_secret = ok_exn (Sealed.of_hex (String.make 64 '2'))
let agent = Hl_client.Signing.Private_key.address (Sim.key 0x22)
let owner = Hl_client.Signing.Private_key.address (Sim.key 0x11)
let leader = Address.of_string "0x1eade50000000000000000000000000000000000"
let follow = Follower_config.create ~follower:owner ~leader ()
let now_ms = 1_800_000_000_000
let now () = Time_ns.of_int_ns_since_epoch (now_ms * 1_000_000)

let show keys =
  let%map signer = Key_source.keystore_signer ~now keys follow in
  match signer with
  | Ok (Follower.Signer.Agent key) ->
    print_s
      [%message "agent" ~address:(Hl_client.Signing.Private_key.address key : Address.t)]
  | Ok (Hook _ | Unsigned) -> print_endline "unexpected signer"
  | Error err -> print_s [%message "error" ~_:(Error.sexp_of_t err : Sexp.t)]
;;

let%expect_test "the active agent's key opens; pending, expired or wrong master key fail" =
  let dir = Filename_unix.temp_dir "hl-copy-keys" "" in
  let keys = Agent_keys.create ~dir master in
  let%bind () = show keys in
  [%expect
    {|
    (error
     ("no active agent" (follower 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)))
    |}];
  let add ~valid_until_ms =
    ok_exn
      (Agent_keys.add_pending
         keys
         ~owner
         ~agent_address:agent
         ~agent_name:"hl-copy"
         ~nonce:now_ms
         ~created_ms:now_ms
         ~valid_until_ms
         ~secret:agent_secret)
    |> ignore
  in
  add ~valid_until_ms:(Some (now_ms + 1_000));
  let%bind () = show keys in
  [%expect
    {|
    (error
     ("no active agent" (follower 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)))
    |}];
  ignore
    (ok_exn (Agent_keys.activate keys ~owner ~agent_address:agent) : Agent_keys.Entry.t);
  let%bind () = show keys in
  [%expect {| (agent (address 0x1563915e194d8cfba1943570603f7606a3115508)) |}];
  let%bind () = show (Agent_keys.create ~dir other_master) in
  [%expect
    {|
    (error
     (("agent key" (agent 0x1563915e194d8cfba1943570603f7606a3115508))
      "cannot open sealed box"))
    |}];
  let%bind expired =
    Key_source.keystore_signer
      ~now:(fun () -> Time_ns.of_int_ns_since_epoch ((now_ms + 2_000) * 1_000_000))
      keys
      follow
  in
  print_s [%sexp (Result.is_error expired : bool)];
  [%expect {| true |}];
  return ()
;;
