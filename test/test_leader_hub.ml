open! Core
open! Async
open Hl_protocol
open Hl_copy_engine

let leader_a = Address.of_string "0x1eade50000000000000000000000000000000001"
let leader_b = Address.of_string "0x1eade50000000000000000000000000000000002"

let take_positions reader ~n =
  let rec loop acc n =
    if n = 0
    then return (List.rev acc)
    else (
      match%bind Pipe.read reader with
      | `Eof -> return (List.rev acc)
      | `Ok (Leader_hub.Update.Position { coin; szi; mark; _ }) ->
        loop
          ((Coin.to_string coin, Size.to_string szi, Option.is_some mark) :: acc)
          (n - 1)
      | `Ok Resync -> loop acc n)
  in
  loop [] n
;;

let%expect_test "one websocket leader, one polled leader past the limit, shared consumers"
  =
  let%bind sim = Sim.start () in
  let rate_limit = Rate_limit.hyperliquid () in
  let hub =
    Leader_hub.create
      ~max_ws_users:1
      ~poll_interval:(Time_ns.Span.of_int_ms 100)
      ~rate_limit
      (Sim.config sim ())
  in
  let%bind a1 = Leader_hub.subscribe hub ~leader:leader_a >>| ok_exn in
  let%bind a2 = Leader_hub.subscribe hub ~leader:leader_a >>| ok_exn in
  let%bind b1 = Leader_hub.subscribe hub ~leader:leader_b >>| ok_exn in
  let%bind b2 = Leader_hub.subscribe hub ~leader:leader_b >>| ok_exn in
  print_s [%sexp (Leader_hub.leaders hub : (Address.t * Leader_hub.Source.t * int) list)];
  [%expect
    {|
    ((0x1eade50000000000000000000000000000000001 Websocket 2)
     (0x1eade50000000000000000000000000000000002 Polling 2))
    |}];
  (* Let the websocket subscription land before trading. *)
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 200) in
  let%bind () = Sim.trade sim ~address:leader_a ~coin:"BTC" ~is_buy:true ~sz:"0.5" in
  let%bind () = Sim.trade sim ~address:leader_b ~coin:"BTC" ~is_buy:false ~sz:"0.3" in
  let%bind p1 = take_positions a1 ~n:1
  and p2 = take_positions a2 ~n:1
  and p3 = take_positions b1 ~n:1
  and p4 = take_positions b2 ~n:1 in
  print_s [%sexp (p1 @ p2 @ p3 @ p4 : (string * string * bool) list)];
  [%expect {| ((BTC 0.5 true) (BTC 0.5 true) (BTC -0.3 true) (BTC -0.3 true)) |}];
  (* The polled leader closes: an update with size zero. *)
  let%bind () = Sim.trade sim ~address:leader_b ~coin:"BTC" ~is_buy:true ~sz:"0.3" in
  let%bind b1' = Leader_hub.subscribe hub ~leader:leader_b >>| ok_exn in
  let%bind closes = take_positions b1' ~n:2 in
  print_s [%sexp (closes : (string * string * bool) list)];
  [%expect {| ((BTC -0.3 false) (BTC 0 false)) |}];
  List.iter [ a1; a2; b1; b2; b1' ] ~f:Pipe.close_read;
  let%bind () = Leader_hub.close hub in
  let%bind () = Sim.stop sim in
  return ()
;;
