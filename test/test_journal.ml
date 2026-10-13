open! Core
open! Async
open Hl_copy_core
open Hl_copy_engine
module Size = Market_data.Size
module Price = Market_data.Price
module Symbol = Market_data.Symbol

let btc = Symbol.of_string "BTC"

let follow =
  Follower_config.create
    ~follower:(Address.of_string "0x00000000000000000000000000000000000000f1")
    ~leader:(Address.of_string "0x1eade50000000000000000000000000000000000")
    ()
;;

let specs =
  Map.singleton (module Symbol) btc (Rounding.Spec.hyperliquid_perp ~sz_decimals:5)
;;

let inputs =
  [ Follower_core.Input.Configure { follow; specs }
  ; Mirror
      (Resync
         { leader =
             { equity = Usd.of_string "100000"
             ; positions = Map.singleton (module Symbol) btc (Size.of_string "1")
             }
         ; follower =
             { equity = Usd.of_string "10000"
             ; positions = Map.empty (module Symbol)
             ; open_orders = []
             }
         ; marks = Map.singleton (module Symbol) btc (Price.of_string "100000")
         })
  ; Mirror
      (Leader_position
         { symbol = btc; size = Size.of_string "-0.5"; mark = Price.of_string "99000" })
  ]
;;

(* 23:59:59 UTC, so the third input lands in the next day's file. *)
let t0 = Time_ns.of_string_with_utc_offset "2026-10-13T23:59:58Z"

let%expect_test "write, reload across a day boundary, verify" =
  let root = Filename_unix.temp_dir "hl-copy-journal" "" in
  let dir = Journal.dir ~root follow in
  let w = Journal.Writer.create ~dir () in
  let state = ref None in
  List.iteri inputs ~f:(fun i input ->
    let time = Time_ns.add t0 (Time_ns.Span.of_int_sec i) in
    Journal.Writer.input w ~time input;
    let t, output =
      match !state, input with
      | None, Configure { follow; specs } ->
        Follower_core.create ~follow ~specs, Follower_core.Output.empty
      | Some t, input -> Follower_core.apply t input
      | None, _ -> assert false
    in
    state := Some t;
    Journal.Writer.output w ~time output);
  let%bind () = Journal.Writer.close w in
  let%bind files = Sys.readdir dir in
  print_s [%sexp (Array.to_list files |> List.sort ~compare:String.compare : string list)];
  [%expect {| (2026-10-13.journal 2026-10-14.journal) |}];
  let%bind entries = Journal.load dir in
  let verified = ok_exn (Journal.verify entries) in
  print_s
    [%message
      ""
        ~entries:(List.length entries : int)
        ~inputs:(verified.inputs : int)
        ~outputs:(verified.outputs : int)
        ~orders:(verified.orders : int)
        ~mismatch:(Option.is_some verified.mismatch : bool)
        ~same_final:(Option.equal [%equal: Follower_core.t] verified.final !state : bool)];
  [%expect
    {|
    ((entries 6) (inputs 3) (outputs 3) (orders 2) (mismatch false)
     (same_final true))
    |}];
  (* A tampered output is reported with the input it follows. *)
  let tampered =
    List.mapi entries ~f:(fun i e ->
      match e with
      | Output { time_ns; _ } when i = 5 ->
        Journal.Entry.Output { time_ns; output = Follower_core.Output.empty }
      | e -> e)
  in
  (match (ok_exn (Journal.verify tampered)).mismatch with
   | None -> print_endline "no mismatch"
   | Some (index, _, _) -> printf "mismatch after input %d\n" index);
  [%expect {| mismatch after input 2 |}];
  let%bind missing = Journal.load (root ^/ "missing") in
  print_s [%sexp (List.length missing : int)];
  [%expect {| 0 |}];
  return ()
;;

let%expect_test "entry digest (changes need a new Stable version)" =
  print_endline Journal.digest;
  [%expect {| be6e0083a6a5e35db171a1d14cecb1a7 |}];
  return ()
;;
