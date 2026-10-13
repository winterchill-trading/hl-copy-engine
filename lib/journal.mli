(** Per-follow journal: every {!Follower_core.Input.t} the actor applied, each followed by
    the {!Follower_core.Output.t} it produced, as Bin_prot frames in {!Market_data.Framed}
    files (one per UTC day, headed by {!digest}):
    [<root>/<follower>-<leader>/<YYYY-MM-DD>.journal].

    Inputs are enough to rebuild the state ({!Follower_core.replay}); outputs are kept so
    {!verify} can check that a replay produces exactly what the live run sent. *)

open! Core
open! Async
open Hl_copy_core

module Entry : sig
  module Stable : sig
    module V1 : sig
      type t =
        | Input of
            { time_ns : int
            ; input : Follower_core.Input.Stable.V1.t
            }
        | Output of
            { time_ns : int
            ; output : Follower_core.Output.t
            }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  type t = Stable.V1.t =
    | Input of
        { time_ns : int
        ; input : Follower_core.Input.t
        }
    | Output of
        { time_ns : int
        ; output : Follower_core.Output.t
        }
  [@@deriving bin_io, sexp, compare, equal]
end

(** Hex [bin_shape] digest of {!Entry.Stable.V1.t}. *)
val digest : string

(** [<root>/<follower>-<leader>]. *)
val dir : root:string -> Follower_config.t -> string

module Writer : sig
  type t

  (** Appends to [dir]'s file of the day, creating it as needed. *)
  val create : ?flush_interval:Time_ns.Span.t -> dir:string -> unit -> t

  val input : t -> time:Time_ns.t -> Follower_core.Input.t -> unit
  val output : t -> time:Time_ns.t -> Follower_core.Output.t -> unit
  val flush : t -> unit Deferred.t
  val close : t -> unit Deferred.t
end

(** Every entry of every journal file in [dir], files in date order. A missing directory
    is an empty journal. *)
val load : string -> Entry.t list Deferred.t

val inputs : Entry.t list -> Follower_core.Input.t list

module Verified : sig
  type t =
    { inputs : int
    ; outputs : int (** recorded outputs compared *)
    ; orders : int (** places in the recorded outputs *)
    ; mismatch : (int * Follower_core.Output.t * Follower_core.Output.t) option
    (** the first output that differs: input number, recorded, replayed *)
    ; final : Follower_core.t option
    }
  [@@deriving sexp_of]
end

(** Replays the inputs and compares every recorded output with the replayed one. *)
val verify : Entry.t list -> Verified.t Or_error.t
