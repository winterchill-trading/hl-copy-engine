open! Core
open Hl_copy_engine

let%expect_test "exchange error texts" =
  List.iter
    [ "Insufficient margin to place order. asset=0"
    ; "Order could not immediately match against any resting orders. asset=0"
    ; "User or API Wallet 0x04c6000000000000000000000000000000000000 does not exist."
    ; "Too many requests"
    ; "Order must have minimum value of $10."
    ]
    ~f:(fun message ->
      let r = Reject.classify message in
      print_s [%message (Reject.label r) (r : Reject.t)]);
  [%expect
    {|
    (margin (r Insufficient_margin))
    (no_liquidity (r No_liquidity))
    (agent (r Agent_invalid))
    (rate_limited (r Rate_limited))
    (other (r (Other "Order must have minimum value of $10.")))
    |}]
;;
