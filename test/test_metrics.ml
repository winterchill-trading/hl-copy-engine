open! Core
open Hl_copy_engine

let%expect_test "summary quantiles over the window" =
  let s = Metrics.Summary.create ~window:4 () in
  print_s [%sexp (Metrics.Summary.quantile s 0.5 : float option)];
  List.iter [ 10.; 1.; 7.; 3.; 5. ] ~f:(Metrics.Summary.add s);
  (* The window holds the last four samples: 1, 7, 3, 5. *)
  print_s
    [%message
      ""
        ~count:(Metrics.Summary.count s : int)
        ~sum:(Metrics.Summary.sum s : float)
        ~max:(Metrics.Summary.max s : float option)
        ~p50:(Metrics.Summary.quantile s 0.5 : float option)
        ~p99:(Metrics.Summary.quantile s 0.99 : float option)];
  [%expect {|
    ()
    ((count 5) (sum 26) (max (10)) (p50 (3)) (p99 (7)))
    |}]
;;

let%expect_test "prometheus text" =
  let t = Metrics.create () in
  t.orders <- 3;
  t.fills <- 2;
  t.leader_updates <- 4;
  Metrics.reject t Insufficient_margin;
  Metrics.reject t No_liquidity;
  Metrics.reject t No_liquidity;
  Metrics.Summary.add t.lag_ms 12.;
  Metrics.Summary.add t.slippage_bps 1.5;
  t.realized_pnl <- -2.25;
  print_string
    (Metrics.prometheus
       [ ( ~follower:"0x00000000000000000000000000000000000000f1"
         , ~leader:"0x1eade50000000000000000000000000000000000"
         , t )
       ]);
  [%expect
    {|
    # HELP hl_copy_leader_updates_total Leader position updates received.
    # TYPE hl_copy_leader_updates_total counter
    hl_copy_leader_updates_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 4
    # HELP hl_copy_orders_total IOC orders sent.
    # TYPE hl_copy_orders_total counter
    hl_copy_orders_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 3
    # HELP hl_copy_fills_total Orders that filled, fully or partly.
    # TYPE hl_copy_fills_total counter
    hl_copy_fills_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 2
    # HELP hl_copy_rejects_total Orders rejected, by reason.
    # TYPE hl_copy_rejects_total counter
    hl_copy_rejects_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000",reason="margin"} 1
    hl_copy_rejects_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000",reason="no_liquidity"} 2
    # HELP hl_copy_resyncs_total Resyncs from clearinghouseState.
    # TYPE hl_copy_resyncs_total counter
    hl_copy_resyncs_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 0
    # HELP hl_copy_resync_failures_total Resyncs that failed to fetch.
    # TYPE hl_copy_resync_failures_total counter
    hl_copy_resync_failures_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 0
    # HELP hl_copy_resync_repairs_total Resyncs that corrected the follower's derived positions.
    # TYPE hl_copy_resync_repairs_total counter
    hl_copy_resync_repairs_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 0
    # HELP hl_copy_lag_ms Leader fill (exchange time) to follower order sent, milliseconds.
    # TYPE hl_copy_lag_ms summary
    hl_copy_lag_ms{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000",quantile="0.5"} 12
    hl_copy_lag_ms{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000",quantile="0.9"} 12
    hl_copy_lag_ms{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000",quantile="0.99"} 12
    hl_copy_lag_ms_sum{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 12
    hl_copy_lag_ms_count{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 1
    # HELP hl_copy_slippage_bps Follower fill price against the mark, adverse positive, basis points.
    # TYPE hl_copy_slippage_bps summary
    hl_copy_slippage_bps{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000",quantile="0.5"} 1.5
    hl_copy_slippage_bps{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000",quantile="0.9"} 1.5
    hl_copy_slippage_bps{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000",quantile="0.99"} 1.5
    hl_copy_slippage_bps_sum{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 1.5
    hl_copy_slippage_bps_count{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 1
    # HELP hl_copy_realized_pnl_usd Realized PnL attributed to the leader, before fees.
    # TYPE hl_copy_realized_pnl_usd gauge
    hl_copy_realized_pnl_usd{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} -2.25
    # HELP hl_copy_unrealized_pnl_usd Unrealized PnL at the last marks.
    # TYPE hl_copy_unrealized_pnl_usd gauge
    hl_copy_unrealized_pnl_usd{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 0
    # HELP hl_copy_equity_change_usd Follower equity minus its equity at start.
    # TYPE hl_copy_equity_change_usd gauge
    hl_copy_equity_change_usd{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 0
    # HELP hl_copy_builder_fee_orders_total Orders sent with the builder fee.
    # TYPE hl_copy_builder_fee_orders_total counter
    hl_copy_builder_fee_orders_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 0
    # HELP hl_copy_builder_fee_skipped_total Orders sent without the builder fee because the follower has not approved it.
    # TYPE hl_copy_builder_fee_skipped_total counter
    hl_copy_builder_fee_skipped_total{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 0
    # HELP hl_copy_paused 1 when the follow is paused or stopped.
    # TYPE hl_copy_paused gauge
    hl_copy_paused{follower="0x00000000000000000000000000000000000000f1",leader="0x1eade50000000000000000000000000000000000"} 0
    |}];
  print_endline (Yojson.Safe.to_string (Metrics.to_json t));
  [%expect
    {| {"leader_updates":4,"orders":3,"fills":2,"rejects":{"margin":1,"no_liquidity":2},"resyncs":0,"resync_failures":0,"resync_repairs":0,"lag_ms":{"count":1,"p50":12.0,"p99":12.0,"max":12.0},"slippage_bps":{"count":1,"p50":1.5,"p99":1.5,"max":1.5},"realized_pnl":-2.25,"unrealized_pnl":0.0,"equity_change":0.0,"builder_fee_orders":0,"builder_fee_skipped":0} |}]
;;
