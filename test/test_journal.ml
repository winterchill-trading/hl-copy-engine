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
  [%expect {| (2026-10-13.v3.journal 2026-10-14.v3.journal) |}];
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

let%expect_test "entry digests (changes need a new Stable version)" =
  print_endline Journal.digest;
  (* version 2: every journal before the no-trade band *)
  print_endline Journal.digest_v2;
  (* the version 1 digest is the one every journal before execution algorithms carries *)
  print_endline Journal.digest_v1;
  [%expect
    {|
    54a76185cac96b2ee58b77075c330b22
    3b696e1a7d85f4da3caf9f38c7556e31
    be6e0083a6a5e35db171a1d14cecb1a7
    |}];
  return ()
;;

let mirror_event : Follower_core.Input.t -> Mirror.Event.t = function
  | Mirror e -> e
  | _ -> assert false
;;

let%expect_test "a version 1 journal still loads, replays and verifies" =
  let root = Filename_unix.temp_dir "hl-copy-journal-v1" "" in
  let dir = Journal.dir ~root follow in
  (* written the way the engine did before execution algorithms *)
  let w =
    Market_data.Framed.Writer.create
      ~digest:Journal.digest_v1
      Journal.Entry.Stable.V1.bin_writer_t
      ~path_for_date:(fun date -> dir ^/ Date.to_string date ^ ".journal")
      ()
  in
  let v1_inputs : Follower_core.Input.Stable.V1.t list =
    [ Configure { follow = Follower_config.Stable.V3.to_v1 follow; specs }
    ; Mirror (mirror_event (List.nth_exn inputs 1))
    ; Mirror (mirror_event (List.nth_exn inputs 2))
    ]
  in
  let state = ref None in
  List.iteri v1_inputs ~f:(fun i input ->
    let time = Time_ns.add t0 (Time_ns.Span.of_int_sec i) in
    let time_ns = Time_ns.to_int_ns_since_epoch time in
    Market_data.Framed.Writer.append
      w
      (Journal.Entry.Stable.V1.Input { time_ns; input })
      ~time;
    let t, output =
      match !state, Follower_core.Input.Stable.V3.of_v1 input with
      | None, Configure { follow; specs } ->
        Follower_core.create ~follow ~specs, Follower_core.Output.empty
      | Some t, input -> Follower_core.apply t input
      | None, _ -> assert false
    in
    state := Some t;
    Market_data.Framed.Writer.append
      w
      (Journal.Entry.Stable.V1.Output
         { time_ns; output = Follower_core.Output.Stable.V3.to_v1 output })
      ~time);
  let%bind () = Market_data.Framed.Writer.close w in
  (* a restart on the same day writes a version 2 file next to it *)
  let w2 = Journal.Writer.create ~dir () in
  Journal.Writer.input w2 ~time:(Time_ns.add t0 (Time_ns.Span.of_int_sec 3)) Resume;
  Journal.Writer.output
    w2
    ~time:(Time_ns.add t0 (Time_ns.Span.of_int_sec 3))
    Follower_core.Output.empty;
  let%bind () = Journal.Writer.close w2 in
  let%bind files = Sys.readdir dir in
  print_s [%sexp (Array.to_list files |> List.sort ~compare:String.compare : string list)];
  let%bind entries = Journal.load dir in
  let verified = ok_exn (Journal.verify entries) in
  print_s
    [%message
      ""
        ~entries:(List.length entries : int)
        ~legacy:
          (List.count entries ~f:(function
             | Legacy_output _ -> true
             | Input _ | Output _ -> false)
           : int)
        ~mismatch:(Option.is_some verified.mismatch : bool)
        ~orders:(verified.orders : int)];
  [%expect
    {|
    (2026-10-13.journal 2026-10-14.journal 2026-10-14.v3.journal)
    ((entries 8) (legacy 3) (mismatch false) (orders 2))
    |}];
  return ()
;;

let%expect_test "a version 2 journal still loads, replays and verifies" =
  let root = Filename_unix.temp_dir "hl-copy-journal-v2" "" in
  let dir = Journal.dir ~root follow in
  (* written the way the engine did before the no-trade band *)
  let w =
    Market_data.Framed.Writer.create
      ~digest:Journal.digest_v2
      Journal.Entry.Stable.V2.bin_writer_t
      ~path_for_date:(fun date -> dir ^/ Date.to_string date ^ ".v2.journal")
      ()
  in
  let state = ref None in
  List.iteri (List.take inputs 3) ~f:(fun i input ->
    let time = Time_ns.add t0 (Time_ns.Span.of_int_sec i) in
    let time_ns = Time_ns.to_int_ns_since_epoch time in
    let v2_input : Follower_core.Input.Stable.V2.t =
      match input with
      | Configure { follow; specs } ->
        Configure { follow = Follower_config.Stable.V3.to_v2 follow; specs }
      | Mirror e -> Mirror e
      | _ -> assert false
    in
    Market_data.Framed.Writer.append
      w
      (Journal.Entry.Stable.V2.Input { time_ns; input = v2_input })
      ~time;
    let t, output =
      match !state, input with
      | None, Configure { follow; specs } ->
        Follower_core.create ~follow ~specs, Follower_core.Output.empty
      | Some t, input -> Follower_core.apply t input
      | None, _ -> assert false
    in
    state := Some t;
    Market_data.Framed.Writer.append
      w
      (Journal.Entry.Stable.V2.Output
         { time_ns; output = Follower_core.Output.Stable.V3.to_v2 output })
      ~time);
  let%bind () = Market_data.Framed.Writer.close w in
  (* a restart on the same day writes a version 3 file next to it *)
  let w3 = Journal.Writer.create ~dir () in
  Journal.Writer.input w3 ~time:(Time_ns.add t0 (Time_ns.Span.of_int_sec 3)) Resume;
  Journal.Writer.output
    w3
    ~time:(Time_ns.add t0 (Time_ns.Span.of_int_sec 3))
    Follower_core.Output.empty;
  let%bind () = Journal.Writer.close w3 in
  let%bind files = Sys.readdir dir in
  print_s [%sexp (Array.to_list files |> List.sort ~compare:String.compare : string list)];
  let%bind entries = Journal.load dir in
  let verified = ok_exn (Journal.verify entries) in
  print_s
    [%message
      ""
        ~entries:(List.length entries : int)
        ~mismatch:(Option.is_some verified.mismatch : bool)
        ~orders:(verified.orders : int)];
  [%expect
    {|
    (2026-10-13.v2.journal 2026-10-14.v2.journal 2026-10-14.v3.journal)
    ((entries 8) (mismatch false) (orders 2))
    |}];
  return ()
;;
