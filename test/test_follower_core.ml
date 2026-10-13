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

(* Feeds inputs, printing each output; [f] may compute the next inputs from the last
   output (to fill the orders it placed). *)
let run t inputs =
  List.fold inputs ~init:t ~f:(fun t input ->
    let t, (out : Follower_core.Output.t) = Follower_core.apply t input in
    print_s [%sexp (out : Follower_core.Output.t)];
    t)
;;

let last_place (out : Follower_core.Output.t) = List.last_exn (Plan.places out.plan)

let%expect_test "resync plans the scaled target; a fill closes the order" =
  let t = Follower_core.create ~follow:(follow ()) ~specs in
  let t, out = Follower_core.apply t (resync ~leader:[ btc, "1" ] ~follower:[] ()) in
  print_s [%sexp (out : Follower_core.Output.t)];
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
    ((plan ((actions ()) (notes ()))) (notices ()))
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
       (Margin_capped (leverage 0.2) (shortfall 10000)))))
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
    ((plan ((actions ()) (notes ()))) (notices ()))
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
     (notices ((Rejected Agent_invalid) (Paused "agent rejected"))))
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
    Bin_prot.Writer.to_string Follower_core.Input.Stable.V1.bin_writer_t input
  in
  let decode s = Bin_prot.Reader.of_string Follower_core.Input.Stable.V1.bin_reader_t s in
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
