(** Refuses Hyperliquid mainnet. The engine signs orders, so it only ever talks to the
    simulator or testnet; mainnet is blocked whatever the flags say. *)

open! Core

(** [Error] for a URL whose host is Hyperliquid's mainnet API ([api.hyperliquid.xyz]) or
    any other [hyperliquid.xyz] host except testnet ([api.hyperliquid-testnet.xyz]). Hosts
    are compared case-insensitively, with any trailing dot removed. *)
val check_url : Uri.t -> unit Or_error.t

(** Both URLs of a client config. *)
val check_config : Hl_client.Config.t -> unit Or_error.t
