open! Core
open! Async
open Hl_copy_engine

let t0 = Time_ns.of_int_ns_since_epoch 1_700_000_000_000_000_000
let at ms = Time_ns.add t0 (Time_ns.Span.of_int_ms ms)

let show = function
  | `Ok -> print_endline "ok"
  | `Wait span -> printf "wait %s\n" (Time_ns.Span.to_string_hum span)
;;

let%expect_test "a full bucket serves the burst, then refills at the per-minute rate" =
  let t = Rate_limit.create ~capacity:10 ~per_minute:60 in
  show (Rate_limit.try_take t ~now:(at 0) ~weight:8);
  show (Rate_limit.try_take t ~now:(at 0) ~weight:2);
  show (Rate_limit.try_take t ~now:(at 0) ~weight:2);
  (* One token per second. *)
  show (Rate_limit.try_take t ~now:(at 1500) ~weight:2);
  show (Rate_limit.try_take t ~now:(at 2000) ~weight:2);
  (* Never above capacity, and an oversized weight is clamped so it still goes through. *)
  printf "%.1f\n" (Rate_limit.available t ~now:(at 600_000));
  show (Rate_limit.try_take t ~now:(at 600_000) ~weight:25);
  printf "taken %d\n" (Rate_limit.taken t);
  [%expect
    {|
    ok
    ok
    wait 2s
    wait 500ms
    ok
    10.0
    ok
    taken 37
    |}];
  return ()
;;

let%expect_test "hyperliquid budget: about 150 followers resyncing two accounts every 30 \
                 s"
  =
  (* The design's estimate: clearinghouseState weighs 2, so two accounts every 30 s cost 8
     per minute per follower. allMids is shared by the engine, not per follower. *)
  List.iter [ 150; 160; 200 ] ~f:(fun followers ->
    let t = Rate_limit.hyperliquid () in
    let refused = ref 0 in
    for second = 0 to 599 do
      for follower = 0 to followers - 1 do
        if (second + follower) % 30 = 0
        then
          List.iter
            Rate_limit.Weight.[ clearinghouse_state; clearinghouse_state ]
            ~f:(fun weight ->
              match Rate_limit.try_take t ~now:(at (second * 1000)) ~weight with
              | `Ok -> ()
              | `Wait _ -> incr refused)
      done
    done;
    printf "%d followers: taken %d refused %d\n" followers (Rate_limit.taken t) !refused);
  [%expect
    {|
    150 followers: taken 12000 refused 0
    160 followers: taken 12800 refused 0
    200 followers: taken 13180 refused 1410
    |}];
  return ()
;;

let%expect_test "take waits on the time source" =
  let time_source = Time_source.create ~now:t0 () in
  let t = Rate_limit.create ~capacity:2 ~per_minute:60 in
  let ro = Time_source.read_only time_source in
  let%bind () = Rate_limit.take ~time_source:ro t ~weight:2 in
  let second = Rate_limit.take ~time_source:ro t ~weight:2 in
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  printf "after 0 s: %b\n" (Deferred.is_determined second);
  let%bind () = Time_source.advance_by_alarms_by time_source (Time_ns.Span.of_sec 1.) in
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  printf "after 1 s: %b\n" (Deferred.is_determined second);
  let%bind () = Time_source.advance_by_alarms_by time_source (Time_ns.Span.of_sec 1.) in
  let%bind () = second in
  printf "after 2 s: %b\n" (Deferred.is_determined second);
  [%expect {|
    after 0 s: false
    after 1 s: false
    after 2 s: true
    |}];
  return ()
;;
