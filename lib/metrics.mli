(** Per-follow counters and summaries, rendered as Prometheus text for [/metrics] and as
    JSON for [/status]. *)

open! Core

module Summary : sig
  (** Count, sum and maximum of every sample, and quantiles over the last [window]
      samples. *)
  type t [@@deriving sexp_of]

  (** default window 1024 *)
  val create : ?window:int -> unit -> t

  val add : t -> float -> unit
  val count : t -> int
  val sum : t -> float
  val max : t -> float option

  (** Nearest-rank quantile of the window, [q] in [[0, 1]]; [None] when empty. *)
  val quantile : t -> float -> float option
end

type t =
  { mutable leader_updates : int
  ; mutable orders : int
  ; mutable fills : int
  ; rejects : int Hashtbl.M(String).t (** by {!Reject.label} *)
  ; mutable resyncs : int
  ; mutable resync_failures : int
  ; mutable resync_repairs : int
  (** resyncs whose follower positions differed from the state derived from fills *)
  ; lag_ms : Summary.t (** leader fill (exchange time) to follower order sent *)
  ; slippage_bps : Summary.t (** follower fill price against the mark, adverse positive *)
  ; mutable realized_pnl : float
  ; mutable unrealized_pnl : float
  ; mutable equity_change : float (** follower equity minus its equity at start *)
  ; mutable paused : bool
  ; mutable builder_fee_orders : int (** orders sent with the [builder] field *)
  ; mutable builder_fee_skipped : int
  (** orders sent without it because the follower has not approved the fee *)
  ; parents : int Hashtbl.M(String).t
  (** finished parent orders, keyed ["<algo> <outcome>"] *)
  ; arrival_slippage_bps : Summary.t (** per filled parent, adverse positive *)
  ; mutable shortfall_usd : float (** implementation shortfall summed over parents *)
  ; mutable exec_fees_usd : float (** fees in the cost reports (estimated for IOCs) *)
  ; mutable target_notional_usd : float (** parents' size at their arrival prices *)
  ; mutable band_skips : int
  (** rebalances held back inside the no-trade band ([Within_band] notes) *)
  ; mutable band_saved_usd : float (** their estimated cost, summed *)
  }
[@@deriving sexp_of]

val create : unit -> t
val reject : t -> Reject.t -> unit

(** Counts a finished parent's cost report. *)
val parent : t -> Execution_algos.Cost_report.t -> unit

(** Counts one [Within_band] note and its saved cost (USD). *)
val band_skip : t -> saved:float -> unit

val total_rejects : t -> int

(** Prometheus text exposition of several follows, labelled
    [{follower="0x...", leader="0x..."}]. *)
val prometheus : (follower:string * leader:string * t) list -> string

val to_json : t -> Yojson.Safe.t
