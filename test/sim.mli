(** hl-sim in process, on a free port, for the integration tests. *)

open! Core
open! Async
open Hl_protocol

type t =
  { server : Hl_sim.Server.t
  ; http : (Socket.Address.Inet.t, int) Cohttp_async.Server.t
  ; base_url : Uri.t
  }

(** Starts the server with a static BTC book from {!maker}: ten levels of 2 BTC each side,
    bids from 99990 down and asks from 100010 up, 10 apart. With [strict], every request
    must be signed ([-strict-signatures]). *)
val start : ?strict:bool -> unit -> t Deferred.t

(** A throwaway key made of one repeated hex digit pair, e.g. [key 0x11]. Never funded
    anywhere but the simulator. *)
val key : int -> Hl_client.Signing.Private_key.t

val stop : t -> unit Deferred.t
val config : t -> ?address:Address.t -> unit -> Hl_client.Config.t
val maker : Address.t

(** An IOC 1% through 100000 for [address]: unsigned ([X-Address]), or signed with [key]
    (whose address is then the account). *)
val trade
  :  ?key:Hl_client.Signing.Private_key.t
  -> t
  -> address:Address.t
  -> coin:string
  -> is_buy:bool
  -> sz:string
  -> unit Deferred.t

(** Resting GTC orders for [maker]. *)
val rest : t -> coin:string -> is_buy:bool -> px:string -> sz:string -> unit Deferred.t

(** The signed position of [address] in [coin] on the simulator. *)
val position : t -> Address.t -> string -> Size.t

val wait_until
  :  ?timeout:Time_ns.Span.t
  -> what:string
  -> (unit -> bool Deferred.t)
  -> unit Deferred.t
