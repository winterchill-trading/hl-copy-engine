open! Core
module E = Hl_copy_core.Exec_algo
module A = Execution_algos.Algo

let to_algo : E.t -> A.t = function
  | Immediate -> Immediate
  | Twap { duration_ms; slices; max_participation } ->
    Twap { duration_ms; slices; max_participation }
  | Vwap { duration_ms; slices; max_participation } ->
    Vwap { duration_ms; slices; max_participation }
  | Pov { participation; max_duration_ms } -> Pov { participation; max_duration_ms }
  | Passive { display; timeout_ms } -> Passive { display; timeout_ms }
  | Adaptive { small_ratio; depth_bps; max_behind_bps; max_drift_bps; timeout_ms } ->
    Adaptive { small_ratio; depth_bps; max_behind_bps; max_drift_bps; timeout_ms }
;;

let of_algo : A.t -> E.t = function
  | Immediate -> Immediate
  | Twap { duration_ms; slices; max_participation } ->
    Twap { duration_ms; slices; max_participation }
  | Vwap { duration_ms; slices; max_participation } ->
    Vwap { duration_ms; slices; max_participation }
  | Pov { participation; max_duration_ms } -> Pov { participation; max_duration_ms }
  | Passive { display; timeout_ms } -> Passive { display; timeout_ms }
  | Adaptive { small_ratio; depth_bps; max_behind_bps; max_drift_bps; timeout_ms } ->
    Adaptive { small_ratio; depth_bps; max_behind_bps; max_drift_bps; timeout_ms }
;;
