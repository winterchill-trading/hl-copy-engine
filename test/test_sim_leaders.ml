(* Following one of hl-sim's simulated leaders (the -leaders accounts) with noise traders
   making the market. Time is driven by hand: market ticks and leader decisions happen
   only when the test calls them, so each leader change can be checked once the follower
   has caught up. Fill sizes depend on the random book, so the test prints only whether
   the follower ended within a lot of its target (resyncing, as the timer would, when an
   IOC left a remainder). *)

open! Core
open! Async
open Hl_protocol
open Hl_copy_core
open Hl_copy_engine
module Signing = Hl_client.Signing
module Market_sim = Exchange_core_engine.Market_sim

let user_key = Sim.key 0x11
let agent_key = Sim.key 0x22
let user = Signing.Private_key.address user_key
let btc = Coin.of_string "BTC"
let lot = Size.of_string "0.00001"

let position server address =
  let state =
    Clearinghouse_state.t_of_yojson
      (Hl_sim.Server.handle_info server (Clearinghouse_state { user = address }))
  in
  match Clearinghouse_state.find_position state btc with
  | None -> Size.zero
  | Some p -> p.szi
;;

let%expect_test "a follower copies a simulated trend leader through ten decisions" =
  Log.Global.set_output [];
  let ex = Hl_sim.Adapt.create_exchange () in
  let server =
    Hl_sim.Server.create
      ~config:{ Hl_sim.Server.Config.default with strict_signatures = true }
      ex
  in
  let market =
    Market_sim.create
      { Market_sim.Config.default with seed = 3; noise_traders = 40; symbols = [ btc ] }
      ex
  in
  let leaders =
    Hl_sim.Leaders.create
      { Hl_sim.Leaders.Config.default with seed = 3; count = 1; coins = [ btc ] }
      ex
  in
  let leader = Hl_sim.Leaders.address 0 in
  let tick_market n =
    for _ = 1 to n do
      Hl_sim.Server.mutate server ~f:(fun _ -> Market_sim.tick market)
    done
  in
  tick_market 300;
  let%bind http = Hl_sim.Server.listen server ~port:0 in
  let api =
    Hl_client.Config.create
      ~base_url:
        (Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:(Hl_sim.Server.port http) ())
      ()
  in
  let%bind () =
    Hl_client.Client.approve_agent
      (Hl_client.Client.trading ~key:user_key api)
      ~agent_address:(Signing.Private_key.address agent_key)
      ~agent_name:"copy"
    >>| ok_exn
    >>| ignore
  in
  let rate_limit = Rate_limit.hyperliquid () in
  let hub = Leader_hub.create ~rate_limit api in
  (* Leaders hold $100,000 and the follower $1,000,000: 0.1 copies sizes one for one. A
     wide bound, because the leader's own IOC orders take the liquidity near the touch. *)
  let follow =
    Follower_config.create
      ~mode:(Multiplier 0.1)
      ~slippage_bps:100
      ~follower:user
      ~leader
      ()
  in
  let%bind follower =
    Follower.start
      ~hub
      ~rate_limit
      ~api
      (Follower.Config.create ~signer:(Agent agent_key) follow)
    >>| ok_exn
  in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 200) in
  let target () =
    match Mirror.target (Follower.state follower).mirror btc with
    | Some target, _ -> target
    | None, _ -> Size.zero
  in
  let rec catch_up resyncs =
    let%bind () = Follower.idle follower in
    if Size.(abs (position server user - target ()) <= lot) || resyncs >= 20
    then return resyncs
    else (
      let%bind () = Follower.resync_now follower in
      catch_up (resyncs + 1))
  in
  let%bind rounds =
    Deferred.List.init ~how:`Sequential 10 ~f:(fun _ ->
      tick_market 50;
      let before = position server leader in
      Hl_sim.Server.mutate server ~f:(fun _ -> Hl_sim.Leaders.tick leaders);
      let now = position server leader in
      if Size.equal before now
      then return None
      else (
        let%bind () =
          Sim.wait_until ~what:"leader update" (fun () ->
            let%map () = Follower.idle follower in
            Map.find (Follower.state follower).mirror.leader_positions btc
            |> Option.value ~default:Size.zero
            |> Size.equal now)
        in
        let%map resyncs = catch_up 0 in
        Some (Size.(abs (position server user - target ()) <= lot), resyncs)))
  in
  let changes = List.filter_opt rounds in
  let m = Follower.metrics follower in
  print_s
    [%message
      ""
        ~leader_changes:(List.length changes : int)
        ~all_within_a_lot:(List.for_all changes ~f:fst : bool)
        ~lag_p99_under_100ms:
          (Option.value_map
             (Metrics.Summary.quantile m.lag_ms 0.99)
             ~default:false
             ~f:(fun x -> Float.(x < 100.))
           : bool)];
  [%expect {| ((leader_changes 9) (all_within_a_lot true) (lag_p99_under_100ms true)) |}];
  let%bind () = Follower.stop follower in
  let%bind () = Leader_hub.close hub in
  Cohttp_async.Server.close http
;;
