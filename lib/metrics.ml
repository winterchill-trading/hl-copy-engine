open! Core

module Summary = struct
  type t =
    { window : float array
    ; mutable next : int
    ; mutable count : int
    ; mutable sum : float
    ; mutable max : float option
    }
  [@@deriving sexp_of]

  let create ?(window = 1024) () =
    { window = Array.create ~len:(Int.max 1 window) 0.
    ; next = 0
    ; count = 0
    ; sum = 0.
    ; max = None
    }
  ;;

  let add t x =
    t.window.(t.next) <- x;
    t.next <- (t.next + 1) % Array.length t.window;
    t.count <- t.count + 1;
    t.sum <- t.sum +. x;
    t.max
    <- Some
         (match t.max with
          | None -> x
          | Some m -> Float.max m x)
  ;;

  let count t = t.count
  let sum t = t.sum
  let max t = t.max

  let quantile t q =
    let n = Int.min t.count (Array.length t.window) in
    if n = 0
    then None
    else (
      let samples = Array.sub t.window ~pos:0 ~len:n in
      Array.sort samples ~compare:Float.compare;
      let rank =
        Float.iround_up_exn (Float.clamp_exn q ~min:0. ~max:1. *. Float.of_int n)
      in
      Some samples.(Int.clamp_exn (rank - 1) ~min:0 ~max:(n - 1)))
  ;;
end

type t =
  { mutable leader_updates : int
  ; mutable orders : int
  ; mutable fills : int
  ; rejects : int Hashtbl.M(String).t
  ; mutable resyncs : int
  ; mutable resync_failures : int
  ; mutable resync_repairs : int
  ; lag_ms : Summary.t
  ; slippage_bps : Summary.t
  ; mutable realized_pnl : float
  ; mutable unrealized_pnl : float
  ; mutable equity_change : float
  ; mutable paused : bool
  }
[@@deriving sexp_of]

let create () =
  { leader_updates = 0
  ; orders = 0
  ; fills = 0
  ; rejects = Hashtbl.create (module String)
  ; resyncs = 0
  ; resync_failures = 0
  ; resync_repairs = 0
  ; lag_ms = Summary.create ()
  ; slippage_bps = Summary.create ()
  ; realized_pnl = 0.
  ; unrealized_pnl = 0.
  ; equity_change = 0.
  ; paused = false
  }
;;

let reject t r = Hashtbl.incr t.rejects (Reject.label r)
let total_rejects t = Hashtbl.data t.rejects |> List.sum (module Int) ~f:Fn.id
let number x = if Float.is_integer x then sprintf "%.0f" x else sprintf "%.6g" x

let prometheus follows =
  let buf = Buffer.create 4096 in
  let family name kind help rows =
    bprintf buf "# HELP %s %s\n# TYPE %s %s\n" name help name kind;
    List.iter follows ~f:(fun (~follower, ~leader, t) ->
      List.iter (rows t) ~f:(fun (suffix, extra, value) ->
        let labels =
          sprintf "follower=%S,leader=%S" follower leader
          :: List.map extra ~f:(fun (k, v) -> sprintf "%s=%S" k v)
        in
        bprintf buf "%s%s{%s} %s\n" name suffix (String.concat ~sep:"," labels) value))
  in
  let counter name help f =
    family name "counter" help (fun t -> [ "", [], Int.to_string (f t) ])
  in
  let gauge name help f = family name "gauge" help (fun t -> [ "", [], number (f t) ]) in
  let summary name help f =
    family name "summary" help (fun t ->
      let s = f t in
      List.filter_map [ 0.5; 0.9; 0.99 ] ~f:(fun q ->
        Option.map (Summary.quantile s q) ~f:(fun v ->
          "", [ "quantile", number q ], number v))
      @ [ "_sum", [], number (Summary.sum s)
        ; "_count", [], Int.to_string (Summary.count s)
        ])
  in
  counter "hl_copy_leader_updates_total" "Leader position updates received." (fun t ->
    t.leader_updates);
  counter "hl_copy_orders_total" "IOC orders sent." (fun t -> t.orders);
  counter "hl_copy_fills_total" "Orders that filled, fully or partly." (fun t -> t.fills);
  family "hl_copy_rejects_total" "counter" "Orders rejected, by reason." (fun t ->
    Hashtbl.to_alist t.rejects
    |> List.sort ~compare:[%compare: string * int]
    |> List.map ~f:(fun (reason, n) -> "", [ "reason", reason ], Int.to_string n));
  counter "hl_copy_resyncs_total" "Resyncs from clearinghouseState." (fun t -> t.resyncs);
  counter "hl_copy_resync_failures_total" "Resyncs that failed to fetch." (fun t ->
    t.resync_failures);
  counter
    "hl_copy_resync_repairs_total"
    "Resyncs that corrected the follower's derived positions."
    (fun t -> t.resync_repairs);
  summary
    "hl_copy_lag_ms"
    "Leader fill (exchange time) to follower order sent, milliseconds."
    (fun t -> t.lag_ms);
  summary
    "hl_copy_slippage_bps"
    "Follower fill price against the mark, adverse positive, basis points."
    (fun t -> t.slippage_bps);
  gauge
    "hl_copy_realized_pnl_usd"
    "Realized PnL attributed to the leader, before fees."
    (fun t -> t.realized_pnl);
  gauge "hl_copy_unrealized_pnl_usd" "Unrealized PnL at the last marks." (fun t ->
    t.unrealized_pnl);
  gauge "hl_copy_equity_change_usd" "Follower equity minus its equity at start." (fun t ->
    t.equity_change);
  gauge "hl_copy_paused" "1 when the follow is paused or stopped." (fun t ->
    if t.paused then 1. else 0.);
  Buffer.contents buf
;;

let summary_json s =
  let opt = Option.value_map ~default:`Null ~f:(fun x -> `Float x) in
  `Assoc
    [ "count", `Int (Summary.count s)
    ; "p50", opt (Summary.quantile s 0.5)
    ; "p99", opt (Summary.quantile s 0.99)
    ; "max", opt (Summary.max s)
    ]
;;

let to_json t =
  `Assoc
    [ "leader_updates", `Int t.leader_updates
    ; "orders", `Int t.orders
    ; "fills", `Int t.fills
    ; ( "rejects"
      , `Assoc
          (Hashtbl.to_alist t.rejects
           |> List.sort ~compare:[%compare: string * int]
           |> List.map ~f:(fun (k, v) -> k, `Int v)) )
    ; "resyncs", `Int t.resyncs
    ; "resync_failures", `Int t.resync_failures
    ; "resync_repairs", `Int t.resync_repairs
    ; "lag_ms", summary_json t.lag_ms
    ; "slippage_bps", summary_json t.slippage_bps
    ; "realized_pnl", `Float t.realized_pnl
    ; "unrealized_pnl", `Float t.unrealized_pnl
    ; "equity_change", `Float t.equity_change
    ]
;;
