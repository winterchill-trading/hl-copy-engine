(* Execution algorithms against hl-sim in process, strict signatures: the follower works
   each leader change as a parent with TWAP, passive and adaptive algorithms, reading the
   book from the simulator's websocket and its resting fills from its own userFills. The
   static book: bids from 99990 down, asks from 100010 up, 2 BTC per level. *)

open! Core
open! Async
open Hl_protocol
open Hl_copy_core
open Hl_copy_engine
module Signing = Hl_client.Signing

let user_key = Sim.key 0x41
let agent_key = Sim.key 0x42
let leader_key = Sim.key 0x43
let seller_key = Sim.key 0x44
let user = Signing.Private_key.address user_key
let leader = Signing.Private_key.address leader_key
let seller = Signing.Private_key.address seller_key

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

let start_follower ?journal_root sim algo =
  let api = Sim.config sim () in
  let hub = Leader_hub.create ~rate_limit:(Rate_limit.hyperliquid ()) api in
  let follow = Follower_config.create ~algo ~follower:user ~leader () in
  let%map follower =
    Follower.start
      ~hub
      ~rate_limit:(Rate_limit.hyperliquid ())
      ~api
      (Follower.Config.create
         ?journal_root
         ~algo_tick:(Time_ns.Span.of_int_ms 100)
         ~signer:(Agent agent_key)
         follow)
    >>| ok_exn
  in
  hub, follower
;;

let reports follower =
  match Follower.status_json follower with
  | `Assoc fields ->
    (match List.Assoc.find_exn fields "execution" ~equal:String.equal with
     | `Assoc e -> List.Assoc.find_exn e "recent" ~equal:String.equal
     | _ -> assert false)
  | _ -> assert false
;;

let print_reports follower =
  match reports follower with
  | `List rs ->
    List.iter rs ~f:(fun r ->
      let get k = Yojson.Safe.Util.member k r in
      printf
        "%s %s target %s filled %s children %d maker %s\n"
        (Yojson.Safe.Util.to_string (get "algo"))
        (Yojson.Safe.Util.to_string (get "outcome"))
        (Float.to_string (Yojson.Safe.Util.to_number (get "target")))
        (Float.to_string (Yojson.Safe.Util.to_number (get "filled")))
        (Yojson.Safe.Util.to_int (get "children"))
        (Float.to_string (Yojson.Safe.Util.to_number (get "maker_filled"))))
  | _ -> assert false
;;

let run_case ?journal_root algo ~after_place =
  let%bind sim = Sim.start ~strict:true () in
  let%bind () = approve sim in
  let%bind hub, follower = start_follower ?journal_root sim algo in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 200) in
  let%bind () =
    Sim.trade ~key:leader_key sim ~address:leader ~coin:"BTC" ~is_buy:true ~sz:"0.5"
  in
  let%bind () =
    Sim.wait_until ~what:"a parent starts" (fun () ->
      let%map () = Follower.idle follower in
      not (List.is_empty (Follower.state follower).execs))
  in
  let%bind () = after_place sim in
  let%bind () =
    Sim.wait_until ~timeout:(Time_ns.Span.of_int_sec 20) ~what:"parents done" (fun () ->
      let%map () = Follower.idle follower in
      List.is_empty (Follower.state follower).execs)
  in
  printf
    "leader %s follower %s\n"
    (Size.to_string (Sim.position sim leader "BTC"))
    (Size.to_string (Sim.position sim user "BTC"));
  print_reports follower;
  let%bind () = Follower.stop follower in
  let%bind () = Leader_hub.close hub in
  let%bind () = Sim.stop sim in
  return follower
;;

let%expect_test "twap: the follower buys in slices" =
  let journal_root = Filename_unix.temp_dir "hl-copy-algo" "" in
  let%bind follower =
    run_case
      ~journal_root
      (Twap { duration_ms = 1_200; slices = 3; max_participation = None })
      ~after_place:(fun _ -> return ())
  in
  [%expect
    {|
    leader 0.5 follower 0.5
    twap filled target 0.5 filled 0.5 children 3 maker 0.
    |}];
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
  return ()
;;

let%expect_test "passive: rests at the bid, then sweeps at the timeout" =
  let%bind _ =
    run_case
      (Passive { display = 1.; timeout_ms = 1_000 })
      ~after_place:(fun _ -> return ())
  in
  [%expect
    {|
    leader 0.5 follower 0.5
    passive filled target 0.5 filled 0.5 children 2 maker 0.
    |}];
  return ()
;;

let%expect_test "adaptive: a small parent rests and is filled by a seller as the maker" =
  let%bind _ =
    run_case
      (Adaptive
         { small_ratio = 1.
         ; depth_bps = 10
         ; max_behind_bps = 10_000
         ; max_drift_bps = 50
         ; timeout_ms = 5_000
         })
      ~after_place:(fun sim ->
        (* a seller takes the bid: the maker's 2 BTC first, then the follower's child *)
        let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 400) in
        Sim.trade ~key:seller_key sim ~address:seller ~coin:"BTC" ~is_buy:false ~sz:"3")
  in
  [%expect
    {|
    leader 0.5 follower 0.5
    adaptive filled target 0.5 filled 0.5 children 1 maker 0.5
    |}];
  return ()
;;
