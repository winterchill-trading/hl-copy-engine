(* Builder fees against hl-sim in process, with -strict-signatures: the follower's orders
   go out without the builder field until the account approves the fee, then carry it, and
   the builder account is credited. *)

open! Core
open! Async
open Hl_protocol
open Hl_copy_core
open Hl_copy_engine
module Signing = Hl_client.Signing

(* Throwaway keys, valid only on the simulator. *)
let user_key = Sim.key 0x11
let agent_key = Sim.key 0x22
let leader_key = Sim.key 0x33
let user = Signing.Private_key.address user_key
let leader = Signing.Private_key.address leader_key

(* 0x44 is the simulator's maker. *)
let builder = Signing.Private_key.address (Sim.key 0x55)

(* 1 bp of notional. *)
let fee = { Builder_fee.builder; fee_tenths_bp = 10 }
let owner sim = Hl_client.Client.trading ~key:user_key (Sim.config sim ())

let approve_agent sim =
  match%map
    Hl_client.Client.approve_agent
      (owner sim)
      ~agent_address:(Signing.Private_key.address agent_key)
      ~agent_name:"copy"
  with
  | Ok (Ok Default) -> ()
  | r -> raise_s [%message "approve failed" (r : Exchange_response.t Or_error.t)]
;;

let approve_builder_fee sim ~max_fee_tenths_bp =
  match%map
    Hl_client.Client.approve_builder_fee (owner sim) ~builder ~max_fee_tenths_bp
  with
  | Ok (Ok Default) -> ()
  | r -> raise_s [%message "approve failed" (r : Exchange_response.t Or_error.t)]
;;

(* The first info request for an address funds it on the simulator, which also gives the
   builder the $100 account value a builder needs. *)
let equity sim address =
  let%map state =
    Hl_client.Info.clearinghouse_state ~user:address (Sim.config sim ()) >>| ok_exn
  in
  state.margin_summary.account_value
;;

(* Within one lot: the follower's equity drifts from the leader's with fees, so a 1:1 copy
   can land a lot short. *)
let follow_until sim follower ~size =
  Sim.wait_until ~what:"follower reaches the leader" (fun () ->
    let%bind () = Follower.idle follower in
    if Size.(
         abs (Sim.position sim user "BTC" - Size.of_string size)
         <= Size.of_string "0.00001")
    then return true
    else (
      let%map () = Follower.resync_now follower in
      false))
;;

let leader_trade sim ~is_buy ~sz =
  let%bind () = Sim.trade ~key:leader_key sim ~address:leader ~coin:"BTC" ~is_buy ~sz in
  Clock_ns.after (Time_ns.Span.of_int_ms 100)
;;

let print_builder follower =
  let m = Follower.metrics follower in
  let status = Follower.status_json follower in
  print_s
    [%message
      ""
        ~orders:(m.orders : int)
        ~rejects:(Metrics.total_rejects m : int)
        ~builder_fee_orders:(m.builder_fee_orders : int)
        ~builder_fee_skipped:(m.builder_fee_skipped : int)];
  print_endline (Yojson.Safe.to_string (Yojson.Safe.Util.member "builder" status))
;;

let%expect_test "builder fee only once approved, and the builder is paid" =
  let%bind sim = Sim.start ~strict:true () in
  let%bind () = approve_agent sim in
  let%bind builder_start = equity sim builder in
  let api = Sim.config sim () in
  let hub = Leader_hub.create ~rate_limit:(Rate_limit.hyperliquid ()) api in
  let%bind follower =
    Follower.start
      ~hub
      ~rate_limit:(Rate_limit.hyperliquid ())
      ~api
      (Follower.Config.create
         ~builder:fee
         ~signer:(Agent agent_key)
         (Follower_config.create ~follower:user ~leader ()))
    >>| ok_exn
  in
  let%bind () = Follower.idle follower in
  (* Not approved: the order goes out without the builder and still fills. *)
  let%bind () = leader_trade sim ~is_buy:true ~sz:"0.5" in
  let%bind () = follow_until sim follower ~size:"0.5" in
  print_builder follower;
  let%bind builder_unpaid = equity sim builder in
  print_s [%message "" ~builder_paid:(Usd.(builder_unpaid - builder_start) : Usd.t)];
  [%expect
    {|
    ((orders 1) (rejects 0) (builder_fee_orders 0) (builder_fee_skipped 1))
    {"address":"0xe1fae9b4fab2f5726677ecfa912d96b0b683e6a9","fee_tenths_bp":10,"approved":false,"max_approved_tenths_bp":0,"note":"builder fee not approved: 0 tenths of a bp approved, 10 needed"}
    (builder_paid 0)
    |}];
  (* Approved above the fee: the next resync sees it, and orders carry the builder. *)
  let%bind () = approve_builder_fee sim ~max_fee_tenths_bp:25 in
  let%bind max = Hl_client.Info.max_builder_fee api ~user ~builder in
  print_s [%message "" (max : int Or_error.t)];
  let%bind () = Follower.resync_now follower in
  let%bind () = leader_trade sim ~is_buy:false ~sz:"0.5" in
  let%bind () = follow_until sim follower ~size:"0" in
  print_builder follower;
  let%bind builder_paid = equity sim builder in
  (* 0.5 BTC near 100000 at 1 bp is about $5. *)
  print_s [%message "" ~builder_paid:(Usd.(builder_paid - builder_unpaid) : Usd.t)];
  [%expect
    {|
    (max (Ok 25))
    ((orders 2) (rejects 0) (builder_fee_orders 1) (builder_fee_skipped 1))
    {"address":"0xe1fae9b4fab2f5726677ecfa912d96b0b683e6a9","fee_tenths_bp":10,"approved":true,"max_approved_tenths_bp":25,"note":null}
    (builder_paid 4.9995)
    |}];
  (* Revoked (a rate of 0) right after a check: the engine does not ask again for 5
     minutes, so the next order goes out with the builder and is refused; that marks the
     approval as gone, the next resync confirms it, and the retry goes out without it. *)
  let%bind () = approve_builder_fee sim ~max_fee_tenths_bp:0 in
  let%bind () = Follower.resync_now follower in
  let%bind () = leader_trade sim ~is_buy:true ~sz:"0.2" in
  let%bind () = follow_until sim follower ~size:"0.2" in
  print_builder follower;
  let%bind builder_end = equity sim builder in
  print_s [%message "" ~builder_paid:(Usd.(builder_end - builder_paid) : Usd.t)];
  [%expect
    {|
    ((orders 4) (rejects 1) (builder_fee_orders 2) (builder_fee_skipped 2))
    {"address":"0xe1fae9b4fab2f5726677ecfa912d96b0b683e6a9","fee_tenths_bp":10,"approved":false,"max_approved_tenths_bp":0,"note":"builder fee not approved: 0 tenths of a bp approved, 10 needed"}
    (builder_paid 0)
    |}];
  let%bind () = Follower.stop follower in
  let%bind () = Leader_hub.close hub in
  Sim.stop sim
;;
