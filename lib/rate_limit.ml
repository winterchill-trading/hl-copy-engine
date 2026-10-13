open! Core
open! Async

module Weight = struct
  let clearinghouse_state = 2
  let all_mids = 2
  let open_orders = 2
  let meta = 20
  let user_fills = 20
  let exchange ~batch = 1 + (batch / 40)
end

type t =
  { capacity : float
  ; per_ns : float
  ; mutable tokens : float
  ; mutable last : Time_ns.t option
  ; mutable taken : int
  ; queue : unit Sequencer.t [@sexp.opaque]
  }
[@@deriving sexp_of]

let create ~capacity ~per_minute =
  if capacity <= 0 || per_minute <= 0
  then raise_s [%message "Rate_limit.create" (capacity : int) (per_minute : int)];
  { capacity = Float.of_int capacity
  ; per_ns = Float.of_int per_minute /. 60e9
  ; tokens = Float.of_int capacity
  ; last = None
  ; taken = 0
  ; queue = Sequencer.create ~continue_on_error:true ()
  }
;;

let hyperliquid () = create ~capacity:1200 ~per_minute:1200

let refill t ~now =
  (match t.last with
   | None -> ()
   | Some last ->
     let elapsed = Time_ns.Span.to_ns (Time_ns.diff now last) in
     if Float.(elapsed > 0.)
     then t.tokens <- Float.min t.capacity (t.tokens +. (elapsed *. t.per_ns)));
  match t.last with
  | Some last when Time_ns.( < ) now last -> ()
  | _ -> t.last <- Some now
;;

let available t ~now =
  refill t ~now;
  t.tokens
;;

let try_take t ~now ~weight =
  refill t ~now;
  let w = Float.min t.capacity (Float.of_int (Int.max 0 weight)) in
  if Float.(t.tokens >= w)
  then (
    t.tokens <- t.tokens -. w;
    t.taken <- t.taken + weight;
    `Ok)
  else (
    let ns = Float.round_up ((w -. t.tokens) /. t.per_ns) in
    `Wait (Time_ns.Span.of_ns ns))
;;

let take ?(time_source = Time_source.wall_clock ()) t ~weight =
  Throttle.enqueue t.queue (fun () ->
    let rec loop () =
      match try_take t ~now:(Time_source.now time_source) ~weight with
      | `Ok -> return ()
      | `Wait span ->
        let%bind () = Time_source.after time_source span in
        loop ()
    in
    loop ())
;;

let taken t = t.taken
