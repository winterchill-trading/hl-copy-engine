(* The follower against hl-sim in process, with -strict-signatures: the follower account
   approves an agent, and every order the engine sends must carry the agent's signature.
   The leader trades by hand against a static book, so each change is known. *)

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
let btc = Coin.of_string "BTC"
let lot = Size.of_string "0.00001"

let approve sim =
  let owner = Hl_client.Client.trading ~key:user_key (Sim.config sim ()) in
  match%map
    Hl_client.Client.approve_agent
      owner
      ~agent_address:(Signing.Private_key.address agent_key)
      ~agent_name:"copy"
  with
  | Ok (Ok Default) -> ()
  | r -> raise_s [%message "approve failed" (r : Exchange_response.t Or_error.t)]
;;

let start_follower ?journal_root ?caps ?mode sim =
  let api = Sim.config sim () in
  let hub = Leader_hub.create ~rate_limit:(Rate_limit.hyperliquid ()) api in
  let follow = Follower_config.create ?caps ?mode ~follower:user ~leader () in
  let%map follower =
    Follower.start
      ~hub
      ~rate_limit:(Rate_limit.hyperliquid ())
      ~api
      (Follower.Config.create ?journal_root ~signer:(Agent agent_key) follow)
    >>| ok_exn
  in
  hub, follower
;;

let target follower =
  match Mirror.target (Follower.state follower).mirror btc with
  | Some target, _ -> target
  | None, notes -> raise_s [%message "no target" (notes : Plan.Note.t list)]
;;

(* Waits until the follower's position on the simulator is within one lot of its capped
   target, resyncing (as the 30 s timer would) if the IOC left a remainder. *)
let settle sim follower =
  let%bind () = Follower.idle follower in
  let%bind () =
    Sim.wait_until ~what:"follower within a lot of its target" (fun () ->
      let%bind () = Follower.idle follower in
      let diff = Size.(abs (Sim.position sim user "BTC" - target follower)) in
      if Size.(diff <= lot)
      then return true
      else (
        let%map () = Follower.resync_now follower in
        false))
  in
  printf
    "leader %s follower %s target %s\n"
    (Size.to_string (Sim.position sim leader "BTC"))
    (Size.to_string (Sim.position sim user "BTC"))
    (Size.to_string (target follower));
  return ()
;;

let leader_trade sim ~is_buy ~sz =
  let%bind () = Sim.trade ~key:leader_key sim ~address:leader ~coin:"BTC" ~is_buy ~sz in
  (* The fill reaches the follower over the websocket. *)
  Clock_ns.after (Time_ns.Span.of_int_ms 100)
;;

let%expect_test "the follower tracks each leader change within a lot, with agent-signed \
                 orders"
  =
  let%bind sim = Sim.start ~strict:true () in
  let%bind () = approve sim in
  let journal_root = Filename_unix.temp_dir "hl-copy-engine" "" in
  let%bind hub, follower = start_follower ~journal_root sim in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 200) in
  let%bind () = leader_trade sim ~is_buy:true ~sz:"0.5" in
  let%bind () = settle sim follower in
  let%bind () = leader_trade sim ~is_buy:false ~sz:"0.8" in
  let%bind () = settle sim follower in
  let%bind () = leader_trade sim ~is_buy:true ~sz:"0.3" in
  let%bind () = settle sim follower in
  [%expect
    {|
    leader 0.5 follower 0.5 target 0.5
    leader -0.3 follower -0.3 target -0.3
    leader 0 follower 0 target 0
    |}];
  let m = Follower.metrics follower in
  print_s
    [%message
      ""
        ~leader_updates:(m.leader_updates : int)
        ~orders:(m.orders : int)
        ~fills:(m.fills : int)
        ~rejects:(Metrics.total_rejects m : int)
        ~lag_samples:(Metrics.Summary.count m.lag_ms : int)
        ~lag_under_1s:
          (Option.value_map (Metrics.Summary.max m.lag_ms) ~default:false ~f:(fun x ->
             Float.(x < 1000.))
           : bool)];
  [%expect
    {|
    ((leader_updates 3) (orders 3) (fills 3) (rejects 0) (lag_samples 3)
     (lag_under_1s true))
    |}];
  (* Every order was the agent's: the simulator's fills for the user. *)
  let%bind fills = Hl_client.Info.user_fills ~user (Sim.config sim ()) >>| ok_exn in
  print_s
    [%sexp
      (List.map fills ~f:(fun (f : User_fill.t) ->
         Side.to_wire f.side, Size.to_string f.sz, Option.is_some f.cloid)
       : (string * string * bool) list)];
  [%expect {| ((B 0.3 true) (A 0.8 true) (B 0.5 true)) |}];
  let%bind () = Follower.stop follower in
  let%bind () = Leader_hub.close hub in
  (* The journal replays to the same outputs. *)
  let%bind entries =
    Journal.load (Journal.dir ~root:journal_root (Follower.follow follower))
  in
  let verified = ok_exn (Journal.verify entries) in
  print_s
    [%message
      ""
        ~orders:(verified.orders : int)
        ~mismatch:(Option.is_some verified.mismatch : bool)];
  [%expect {| ((orders 3) (mismatch false)) |}];
  Sim.stop sim
;;
