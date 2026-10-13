open! Core
open! Async
open Hl_copy_core
open Hl_copy_engine

(* Throwaway master and agent keys. *)
let master = ok_exn (Key_store.Master_key.of_hex (String.make 64 'a'))
let other_master = ok_exn (Key_store.Master_key.of_hex (String.make 64 'b'))
let agent = Hl_client.Signing.Private_key.address (Sim.key 0x22)
let owner = Hl_client.Signing.Private_key.address (Sim.key 0x11)
let leader = Address.of_string "0x1eade50000000000000000000000000000000000"
let follow = Follower_config.create ~follower:owner ~leader ()
let t0 = Time_ns.of_int_ns_since_epoch 1_800_000_000_000_000_000
let now () = t0

let show keys =
  let%map signer = Key_source.keystore_signer ~now keys follow in
  match signer with
  | Ok (Follower.Signer.Agent key) ->
    print_s
      [%message "agent" ~address:(Hl_client.Signing.Private_key.address key : Address.t)]
  | Ok (Hook _ | Unsigned) -> print_endline "unexpected signer"
  | Error err -> print_s [%message "error" ~_:(Error.sexp_of_t err : Sexp.t)]
;;

let%expect_test "the account's agent key opens; missing, expired or wrong master key fail"
  =
  let state_dir = Filename_unix.temp_dir "hl-copy-state" "" in
  let keys = ok_exn (Key_store.create ~master_key:master ~state_dir ()) in
  let%bind () = show keys in
  [%expect
    {| (error ("no agent" (follower 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a))) |}];
  ignore
    (ok_exn
       (Key_store.put
          keys
          ~account:owner
          ~agent_address:agent
          ~agent_name:"hl-copy"
          ~created:t0
          ~valid_until:(Time_ns.add t0 (Time_ns.Span.of_sec 1.))
          ~private_key:(String.make 64 '2')
          ())
     : Key_store.Entry.t);
  let%bind () = show keys in
  [%expect {| (agent (address 0x1563915e194d8cfba1943570603f7606a3115508)) |}];
  let%bind () = show (ok_exn (Key_store.create ~master_key:other_master ~state_dir ())) in
  [%expect {| (error "cannot open agent key (wrong master key or tampered file)") |}];
  let%bind expired =
    Key_source.keystore_signer
      ~now:(fun () -> Time_ns.add t0 (Time_ns.Span.of_sec 2.))
      keys
      follow
  in
  print_s [%sexp (Result.is_error expired : bool)];
  [%expect {| true |}];
  return ()
;;
