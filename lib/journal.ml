open! Core
open! Async
open Hl_copy_core

module Entry = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Input of
            { time_ns : int
            ; input : Follower_core.Input.Stable.V1.t
            }
        | Output of
            { time_ns : int
            ; output : Follower_core.Output.Stable.V1.t
            }
      [@@deriving bin_io, sexp, compare, equal]
    end

    module V2 = struct
      type t =
        | Input of
            { time_ns : int
            ; input : Follower_core.Input.Stable.V2.t
            }
        | Output of
            { time_ns : int
            ; output : Follower_core.Output.Stable.V2.t
            }
        | Legacy_output of
            { time_ns : int
            ; output : Follower_core.Output.Stable.V1.t
            }
      [@@deriving bin_io, sexp, compare, equal]

      let of_v1 : V1.t -> t = function
        | Input { time_ns; input } ->
          Input { time_ns; input = Follower_core.Input.Stable.V2.of_v1 input }
        | Output { time_ns; output } -> Legacy_output { time_ns; output }
      ;;
    end
  end

  include Stable.V2
end

let digest = Bin_prot.Shape.eval_to_digest_string Entry.Stable.V2.bin_shape_t
let digest_v1 = Bin_prot.Shape.eval_to_digest_string Entry.Stable.V1.bin_shape_t

let dir ~root (follow : Follower_config.t) =
  root
  ^/ sprintf "%s-%s" (Address.to_string follow.follower) (Address.to_string follow.leader)
;;

(* Version 2 files get their own name, so a restart on the day of an upgrade never appends
   to a version 1 file (the writer refuses another digest). Names sort by date, and a
   day's version 1 file before its version 2 one. *)
let file_name date = Date.to_string date ^ ".v2.journal"

module Writer = struct
  type t = Entry.t Market_data.Framed.Writer.t

  let create ?flush_interval ~dir () =
    Market_data.Framed.Writer.create
      ?flush_interval
      ~digest
      Entry.Stable.V2.bin_writer_t
      ~path_for_date:(fun date -> dir ^/ file_name date)
      ()
  ;;

  let input t ~time input =
    Market_data.Framed.Writer.append
      t
      (Entry.Input { time_ns = Time_ns.to_int_ns_since_epoch time; input })
      ~time
  ;;

  let output t ~time output =
    Market_data.Framed.Writer.append
      t
      (Entry.Output { time_ns = Time_ns.to_int_ns_since_epoch time; output })
      ~time
  ;;

  let flush = Market_data.Framed.Writer.flush
  let close = Market_data.Framed.Writer.close
end

let load dir =
  match%bind Sys.is_directory dir with
  | `No | `Unknown -> return []
  | `Yes ->
    let%bind names = Sys.readdir dir in
    let files =
      Array.to_list names
      |> List.filter ~f:(String.is_suffix ~suffix:".journal")
      |> List.sort ~compare:String.compare
    in
    let%map entries =
      Deferred.List.map ~how:`Sequential files ~f:(fun name ->
        let path = dir ^/ name in
        match%bind Market_data.Framed.read_digest path with
        | Some d when String.equal d digest_v1 ->
          let%map entries, _tail =
            Market_data.Framed.load_file
              ~digest:digest_v1
              Entry.Stable.V1.bin_reader_t
              path
          in
          List.map entries ~f:Entry.Stable.V2.of_v1
        | _ ->
          let%map entries, _tail =
            Market_data.Framed.load_file ~digest Entry.Stable.V2.bin_reader_t path
          in
          entries)
    in
    List.concat entries
;;

let inputs entries =
  List.filter_map entries ~f:(function
    | Entry.Input { input; _ } -> Some input
    | Output _ | Legacy_output _ -> None)
;;

module Verified = struct
  type t =
    { inputs : int
    ; outputs : int
    ; orders : int
    ; mismatch : (int * Follower_core.Output.t * Follower_core.Output.t) option
    ; final : Follower_core.t option
    }
  [@@deriving sexp_of]
end

let verify entries =
  let open Or_error.Let_syntax in
  let%map final, replayed = Follower_core.replay (inputs entries) in
  let replayed = Array.of_list replayed in
  (* Each recorded output belongs to the input just before it. *)
  let _, outputs, orders, mismatch =
    List.fold
      entries
      ~init:(-1, 0, 0, None)
      ~f:(fun (index, outputs, orders, mismatch) entry ->
        match entry with
        | Input _ -> index + 1, outputs, orders, mismatch
        | Output _ | Legacy_output _ ->
          (* a version 1 output predates parents and reports: compare what it had *)
          let output, same =
            match entry with
            | Legacy_output { output; _ } ->
              let output = Follower_core.Output.Stable.V2.of_v1 output in
              ( output
              , fun replayed ->
                  [%equal: Follower_core.Output.Stable.V1.t]
                    (Follower_core.Output.Stable.V2.to_v1 output)
                    (Follower_core.Output.Stable.V2.to_v1 replayed) )
            | Output { output; _ } ->
              output, fun replayed -> [%equal: Follower_core.Output.t] output replayed
            | Input _ -> assert false
          in
          let orders = orders + List.length (Plan.places output.plan) in
          let mismatch =
            match mismatch with
            | Some _ -> mismatch
            | None ->
              if index >= 0 && index < Array.length replayed && same replayed.(index)
              then None
              else
                Some
                  ( index
                  , output
                  , if index >= 0 && index < Array.length replayed
                    then replayed.(index)
                    else Follower_core.Output.empty )
          in
          index, outputs + 1, orders, mismatch)
  in
  { Verified.inputs = Array.length replayed
  ; outputs
  ; orders
  ; mismatch
  ; final = Some final
  }
;;
