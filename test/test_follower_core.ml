open! Core
open Hl_copy_core
open Hl_copy_engine
module Size = Market_data.Size
module Price = Market_data.Price
module Symbol = Market_data.Symbol

let btc = Symbol.of_string "BTC"
let eth = Symbol.of_string "ETH"
let leader = Address.of_string "0x1eade50000000000000000000000000000000000"
let follower = Address.of_string "0x00000000000000000000000000000000000000f1"

let specs =
  Map.of_alist_exn
    (module Symbol)
    [ btc, Rounding.Spec.hyperliquid_perp ~sz_decimals:5
    ; eth, Rounding.Spec.hyperliquid_perp ~sz_decimals:4
    ]
;;

let follow ?(caps = Caps.none) ?(paused = false) () =
  { (Follower_config.create ~caps ~follower ~leader ()) with paused }
;;

let sizes l =
  Map.of_alist_exn (module Symbol) (List.map l ~f:(fun (s, x) -> s, Size.of_string x))
;;

let resync ?(leader_equity = "100000") ?(follower_equity = "10000") ~leader ~follower () =
  Follower_core.Input.Mirror
    (Resync
       { leader = { equity = Usd.of_string leader_equity; positions = sizes leader }
       ; follower =
           { equity = Usd.of_string follower_equity
           ; positions = sizes follower
           ; open_orders = []
           }
       ; marks =
           Map.of_alist_exn
             (module Symbol)
             [ btc, Price.of_string "100000"; eth, Price.of_string "4000" ]
       })
;;

let position symbol size mark =
  Follower_core.Input.Mirror
    (Leader_position { symbol; size = Size.of_string size; mark = Price.of_string mark })
;;

let filled (o : Plan.Order.t) size =
  Follower_core.Input.Mirror
    (Follower_fill
       { time_ns = 0
       ; symbol = o.symbol
       ; side = o.side
       ; size = Size.of_string size
       ; price = o.limit_px
       ; fee = Usd.zero
       ; closed_pnl = Usd.zero
       ; cloid = Some o.cloid
       })
;;

let closed (o : Plan.Order.t) = Follower_core.Input.Mirror (Order_closed o.cloid)

(* Cost-report floats are rounded to 1e-6 before printing: arm64 fuses multiply-adds that
   amd64 does not, so the last digits of [shortfall] differ between a laptop and CI. *)
let show (out : Follower_core.Output.t) =
  let r x = Float.round_decimal x ~decimal_digits:6 in
  print_s
    [%sexp
      ({ out with
         reports =
           List.map out.reports ~f:(fun (c : Execution_algos.Cost_report.t) ->
             { c with
               fees = r c.fees
             ; arrival_slippage_bps = r c.arrival_slippage_bps
             ; shortfall = r c.shortfall
             ; shortfall_bps = r c.shortfall_bps
             })
       }
       : Follower_core.Output.t)]
;;

(* Feeds inputs, printing each output; [f] may compute the next inputs from the last
   output (to fill the orders it placed). *)
let run t inputs =
  List.fold inputs ~init:t ~f:(fun t input ->
    let t, (out : Follower_core.Output.t) = Follower_core.apply t input in
    show out;
    t)
;;

let last_place (out : Follower_core.Output.t) = List.last_exn (Plan.places out.plan)

let%expect_test "resync plans the scaled target; a fill closes the order" =
  let t = Follower_core.create ~follow:(follow ()) ~specs in
  let t, out = Follower_core.apply t (resync ~leader:[ btc, "1" ] ~follower:[] ()) in
  show out;
  [%expect
    {|
    ((plan
      ((actions
        ((Place
          ((cloid 0x01eade50000000000000000000000000) (symbol BTC) (side Buy)
           (size 0.1) (limit_px 100200) (reduce_only false)))))
       (notes ())))
     (notices ()))
    |}];
  let t = run t [ filled (last_place out) "0.1"; closed (last_place out) ] in
  [%expect
    {|
    ((plan ((actions ()) (notes ()))) (notices ())
     (reports
      (((algo immediate) (side Buy) (target 0.1) (filled 0.1) (avg_px 100200)
        (arrival_px 100000) (end_px 100000) (arrival_ns 0) (end_ns 0)
        (children 1) (maker_filled 0) (fees 4.509) (arrival_slippage_bps 20)
        (shortfall 24.509) (shortfall_bps 24.509) (outcome Filled)))))
    ((plan ((actions ()) (notes ()))) (notices ()))
    |}];
  print_s
    [%message
      ""
        ~positions:(t.mirror.follower_positions : Size.t Mirror.Symbol_map.t)
        ~pending:(t.mirror.pending : Mirror.Pending.t list)
        ~status:(t.status : Follower_core.Status.t)];
  [%expect {| ((positions ((BTC 0.1))) (pending ()) (status Running)) |}]
;;

let%expect_test "an insufficient-margin reject caps leverage at what the account holds" =
  let t = Follower_core.create ~follow:(follow ()) ~specs in
  let t, out =
    Follower_core.apply t (resync ~leader:[ btc, "1" ] ~follower:[ eth, "0.5" ] ())
  in
  let o = last_place out in
  let t =
    run
      t
      [ Order_rejected
          { cloid = o.cloid; message = "Insufficient margin to place order." }
      ]
  in
  [%expect
    {|
    ((plan ((actions ()) (notes ())))
     (notices
      ((Rejected Insufficient_margin)
       (Margin_capped (leverage 0.2) (shortfall 10000))))
     (reports
      (((algo immediate) (side Buy) (target 0.1) (filled 0) (avg_px 0)
        (arrival_px 100000) (end_px 100000) (arrival_ns 0) (end_ns 0)
        (children 1) (maker_filled 0) (fees 0) (arrival_slippage_bps 0)
        (shortfall 0) (shortfall_bps 0) (outcome Unfilled)))))
    |}];
  print_s
    [%message
      ""
        ~margin_cap:(t.margin_cap : float option)
        ~caps:(Follower_core.effective_caps t : Caps.t)
        ~shortfall:(t.shortfall : Usd.t)];
  [%expect
    {|
    ((margin_cap (0.2))
     (caps
      ((max_leverage (0.2)) (max_notional_per_symbol ()) (max_daily_loss ())
       (allowlist ()) (min_order_notional 10)))
     (shortfall 10000))
    |}];
  (* The leader adds to BTC: the cap holds the follower where it is. *)
  let t = run t [ position btc "2" "100000" ] in
  [%expect
    {|
    ((plan
      ((actions ())
       (notes
        (((symbol BTC) (reason (Capped (Leverage (wanted 2.2) (limit 0.2)))))))))
     (notices ()))
    |}];
  (* A new day lifts the cap. *)
  let _t = run t [ Mirror Start_day; Mirror Rebalance ] in
  [%expect
    {|
    ((plan ((actions ()) (notes ()))) (notices ()))
    ((plan
      ((actions
        ((Place
          ((cloid 0x01eade50000000000000000000000001) (symbol BTC) (side Buy)
           (size 0.2) (limit_px 100200) (reduce_only false)))))
       (notes ())))
     (notices ()))
    |}]
;;

let%expect_test "pause cancels, drops places, resume replans; an agent reject pauses" =
  let t = Follower_core.create ~follow:(follow ()) ~specs in
  let t, out = Follower_core.apply t (resync ~leader:[ btc, "1" ] ~follower:[] ()) in
  let o = last_place out in
  let t = run t [ Pause "manual" ] in
  [%expect
    {|
    ((plan
      ((actions
        ((Cancel (symbol BTC) (cloid 0x01eade50000000000000000000000000))))
       (notes ())))
     (notices ((Paused manual))))
    |}];
  let t = run t [ closed o; position btc "2" "100000" ] in
  [%expect
    {|
    ((plan ((actions ()) (notes ()))) (notices ())
     (reports
      (((algo immediate) (side Buy) (target 0.1) (filled 0) (avg_px 0)
        (arrival_px 100000) (end_px 100000) (arrival_ns 0) (end_ns 0)
        (children 1) (maker_filled 0) (fees 0) (arrival_slippage_bps 0)
        (shortfall 0) (shortfall_bps 0) (outcome Cancelled)))))
    ((plan ((actions ()) (notes ())))
     (notices
      ((Dropped_while_paused
        ((cloid 0x01eade50000000000000000000000001) (symbol BTC) (side Buy)
         (size 0.2) (limit_px 100200) (reduce_only false))))))
    |}];
  print_s [%sexp (t.mirror.pending : Mirror.Pending.t list)];
  [%expect {| () |}];
  let t = run t [ Resume ] in
  [%expect
    {|
    ((plan
      ((actions
        ((Place
          ((cloid 0x01eade50000000000000000000000002) (symbol BTC) (side Buy)
           (size 0.2) (limit_px 100200) (reduce_only false)))))
       (notes ())))
     (notices (Resumed)))
    |}];
  let o = List.last_exn t.mirror.pending in
  let t =
    run
      t
      [ Order_rejected
          { cloid = o.cloid
          ; message =
              "User or API Wallet 0x04c6000000000000000000000000000000000000 does not \
               exist."
          }
      ]
  in
  [%expect
    {|
    ((plan ((actions ()) (notes ())))
     (notices ((Rejected Agent_invalid) (Paused "agent rejected")))
     (reports
      (((algo immediate) (side Buy) (target 0.2) (filled 0) (avg_px 0)
        (arrival_px 100000) (end_px 100000) (arrival_ns 0) (end_ns 0)
        (children 1) (maker_filled 0) (fees 0) (arrival_slippage_bps 0)
        (shortfall 0) (shortfall_bps 0) (outcome Unfilled)))))
    |}];
  print_s [%sexp (t.status : Follower_core.Status.t)];
  [%expect {| (Paused "agent rejected") |}];
  let t = run t [ Stop; position btc "0" "100000"; Resume ] in
  [%expect
    {|
    ((plan ((actions ()) (notes ()))) (notices (Stopped)))
    ((plan ((actions ()) (notes ()))) (notices ()))
    ((plan ((actions ()) (notes ()))) (notices ()))
    |}];
  print_s [%sexp (t.status : Follower_core.Status.t)];
  [%expect {| Stopped |}]
;;

let%expect_test "config: paused by the file, unpaused by the next version" =
  let t = Follower_core.create ~follow:(follow ~paused:true ()) ~specs in
  let t = run t [ resync ~leader:[ btc, "1" ] ~follower:[] () ] in
  [%expect
    {|
    ((plan ((actions ()) (notes ())))
     (notices
      ((Dropped_while_paused
        ((cloid 0x01eade50000000000000000000000000) (symbol BTC) (side Buy)
         (size 0.1) (limit_px 100200) (reduce_only false))))))
    |}];
  let caps = { Caps.none with max_notional_per_symbol = Some (Usd.of_string "5000") } in
  let _t = run t [ Configure { follow = follow ~caps (); specs } ] in
  [%expect
    {|
    ((plan
      ((actions
        ((Place
          ((cloid 0x01eade50000000000000000000000001) (symbol BTC) (side Buy)
           (size 0.05) (limit_px 100200) (reduce_only false)))))
       (notes
        (((symbol BTC)
          (reason (Capped (Symbol_notional (wanted 10000) (limit 5000)))))))))
     (notices (Resumed)))
    |}]
;;

let%expect_test "replay: the same inputs give the same outputs, through bin_io" =
  let inputs =
    [ Follower_core.Input.Configure { follow = follow (); specs }
    ; resync ~leader:[ btc, "1"; eth, "-3" ] ~follower:[] ()
    ; position btc "1.5" "101000"
    ; Pause "manual"
    ; position eth "-1" "3900"
    ; Resume
    ; Mirror Start_day
    ; position btc "0" "99000"
    ]
  in
  let encode input =
    Bin_prot.Writer.to_string Follower_core.Input.Stable.V2.bin_writer_t input
  in
  let decode s = Bin_prot.Reader.of_string Follower_core.Input.Stable.V2.bin_reader_t s in
  let t1, out1 = ok_exn (Follower_core.replay inputs) in
  let t2, out2 =
    ok_exn (Follower_core.replay (List.map inputs ~f:(Fn.compose decode encode)))
  in
  print_s
    [%message
      ""
        ~same_state:([%equal: Follower_core.t] t1 t2 : bool)
        ~same_outputs:([%equal: Follower_core.Output.t list] out1 out2 : bool)
        ~orders:
          (List.sum (module Int) out1 ~f:(fun o -> List.length (Plan.places o.plan))
           : int)];
  [%expect {| ((same_state true) (same_outputs true) (orders 5)) |}];
  print_s [%sexp (Follower_core.replay (List.tl_exn inputs) |> Result.is_error : bool)];
  [%expect {| true |}]
;;

(* {2 Execution algorithms} *)

let follow_with algo = { (follow ()) with algo }

let book ~bid ~ask =
  Execution_algos.Book.create
    ~bids:[ Price.of_string bid, Size.of_string "1" ]
    ~asks:[ Price.of_string ask, Size.of_string "1" ]
;;

let market ?(symbol = btc) ~s ~bid ~ask ~traded () =
  Follower_core.Input.Market
    { symbol
    ; now_ns = s * 1_000_000_000
    ; book = book ~bid ~ask
    ; traded = Size.of_string traded
    }
;;

let child_fill (o : Plan.Order.t) size =
  Follower_core.Input.Mirror
    (Follower_fill
       { time_ns = 0
       ; symbol = o.symbol
       ; side = o.side
       ; size = Size.of_string size
       ; price = Price.of_string "100010"
       ; fee = Usd.zero
       ; closed_pnl = Usd.zero
       ; cloid = Some o.cloid
       })
;;

let places (out : Follower_core.Output.t) = Plan.places out.plan

let print_wire (out : Follower_core.Output.t) =
  List.iter out.plan.actions ~f:(function
    | Place o ->
      printf
        "place %s %s %s @ %s%s\n"
        (Cloid.to_string o.cloid)
        (Sexp.to_string (Market_data.Side.sexp_of_t o.side))
        (Size.to_string o.size)
        (Price.to_string o.limit_px)
        (if List.mem out.post_only o.cloid ~equal:Cloid.equal then " post-only" else "")
    | Cancel { cloid; _ } -> printf "cancel %s\n" (Cloid.to_string cloid));
  List.iter out.reports ~f:(fun r ->
    printf
      "report %s %s filled %s of %s, shortfall %.2f USD\n"
      r.algo
      (Execution_algos.Cost_report.Outcome.to_string r.outcome)
      (Size.to_string r.filled)
      (Size.to_string r.target)
      r.shortfall)
;;

let%expect_test "twap: the parent waits for market ticks, children carry derived ids" =
  let algo : Exec_algo.t =
    Twap { duration_ms = 4_000; slices = 2; max_participation = None }
  in
  let t = Follower_core.create ~follow:(follow_with algo) ~specs in
  (* the leader holds 1 BTC: the mirror wants 0.1, as one parent, nothing sent yet *)
  let t, out = Follower_core.apply t (resync ~leader:[ btc, "1" ] ~follower:[] ()) in
  print_wire out;
  print_s [%sexp (Follower_core.market_symbols t : Symbol.t list)];
  [%expect {| (BTC) |}];
  let step t input =
    let t, out = Follower_core.apply t input in
    print_wire out;
    t, out
  in
  let t, out = step t (market ~s:0 ~bid:"99990" ~ask:"100010" ~traded:"5" ()) in
  [%expect {| place 0x01eade50000000000000000000000000 Buy 0.05 @ 100200 |}];
  let first = List.hd_exn (places out) in
  let t, _ = step t (child_fill first "0.05") in
  let t, _ = step t (Mirror (Order_closed first.cloid)) in
  [%expect {| |}];
  (* a resync while the parent is open: the mirror counts it in flight, plans nothing *)
  let t, _ = step t (resync ~leader:[ btc, "1" ] ~follower:[ btc, "0.05" ] ()) in
  [%expect {| |}];
  let t, out = step t (market ~s:2 ~bid:"99990" ~ask:"100010" ~traded:"6" ()) in
  [%expect {| place 0x01eade50000000000000010000000000 Buy 0.05 @ 100200 |}];
  let second = List.hd_exn (places out) in
  let t, _ = step t (child_fill second "0.05") in
  let t, _ = step t (Mirror (Order_closed second.cloid)) in
  [%expect {| report twap filled filled 0.1 of 0.1, shortfall 5.50 USD |}];
  print_s
    [%message
      ""
        ~positions:(t.mirror.follower_positions : Size.t Mirror.Symbol_map.t)
        ~pending:(t.mirror.pending : Mirror.Pending.t list)
        ~execs:(List.length t.execs : int)];
  [%expect {| ((positions ((BTC 0.1))) (pending ()) (execs 0)) |}]
;;

let%expect_test "passive: a post-only child; pause cancels it and closes the parent" =
  let t =
    Follower_core.create
      ~follow:
        (follow_with Exec_algo.Stable.V1.(Passive { display = 1.; timeout_ms = 30_000 }))
      ~specs
  in
  let t, _ = Follower_core.apply t (resync ~leader:[ btc, "1" ] ~follower:[] ()) in
  let t, out =
    Follower_core.apply t (market ~s:0 ~bid:"99990" ~ask:"100010" ~traded:"5" ())
  in
  print_wire out;
  let child = List.hd_exn (places out) in
  print_s [%sexp (Follower_core.is_resting_child t child.cloid : bool)];
  [%expect
    {|
    place 0x01eade50000000000000000000000000 Buy 0.1 @ 99990 post-only
    true
    |}];
  let t, out = Follower_core.apply t (Pause "manual") in
  print_wire out;
  [%expect {| cancel 0x01eade50000000000000000000000000 |}];
  let t, out = Follower_core.apply t (Mirror (Order_closed child.cloid)) in
  print_wire out;
  print_s [%sexp (t.mirror.pending : Mirror.Pending.t list)];
  [%expect
    {|
    report passive cancelled filled 0 of 0.1, shortfall 0.00 USD
    ()
    |}]
;;

let%expect_test "a parent below the minimum order goes out at once" =
  let algo : Exec_algo.t =
    Twap { duration_ms = 4_000; slices = 2; max_participation = None }
  in
  let t = Follower_core.create ~follow:(follow_with algo) ~specs in
  (* a follower of 5 USD holds the scaled 0.00005 BTC; the leader closes: the full close
     (5 USD, under the 10 USD minimum) goes out as one IOC *)
  let t, _ =
    Follower_core.apply
      t
      (resync ~leader:[ btc, "1" ] ~follower:[ btc, "0.00005" ] ~follower_equity:"5" ())
  in
  let t, out = Follower_core.apply t (position btc "0" "100000") in
  print_wire out;
  print_s [%sexp (Follower_core.market_symbols t : Symbol.t list)];
  [%expect
    {|
    place 0x01eade50000000000000000000000000 Sell 0.00005 @ 99800
    ()
    |}]
;;
