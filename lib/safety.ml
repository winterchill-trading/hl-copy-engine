open! Core

let testnet_host = "api.hyperliquid-testnet.xyz"

let is_mainnet_host host =
  let host = String.lowercase host |> String.chop_suffix_if_exists ~suffix:"." in
  (not (String.equal host testnet_host))
  && (String.equal host "hyperliquid.xyz"
      || String.is_suffix host ~suffix:".hyperliquid.xyz")
;;

let check_url uri =
  match Uri.host uri with
  | Some host when is_mainnet_host host ->
    Or_error.error_s
      [%message "refusing a Hyperliquid mainnet URL; use hl-sim or testnet" host]
  | None | Some _ -> Ok ()
;;

let check_config (config : Hl_client.Config.t) =
  Or_error.combine_errors_unit [ check_url config.base_url; check_url config.ws_url ]
;;
