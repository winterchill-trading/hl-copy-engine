open! Core
open Hl_copy_engine

let%expect_test "mainnet hosts are refused, testnet and the simulator are not" =
  List.iter
    [ "https://api.hyperliquid.xyz"
    ; "wss://api.hyperliquid.xyz/ws"
    ; "https://API.Hyperliquid.XYZ./info"
    ; "https://hyperliquid.xyz"
    ; "https://api-ui.hyperliquid.xyz"
    ; "https://api.hyperliquid-testnet.xyz"
    ; "wss://api.hyperliquid-testnet.xyz/ws"
    ; "http://localhost:3000"
    ; "http://127.0.0.1:3510"
    ]
    ~f:(fun url ->
      printf
        "%-40s %s\n"
        url
        (match Safety.check_url (Uri.of_string url) with
         | Ok () -> "ok"
         | Error _ -> "refused"));
  [%expect
    {|
    https://api.hyperliquid.xyz              refused
    wss://api.hyperliquid.xyz/ws             refused
    https://API.Hyperliquid.XYZ./info        refused
    https://hyperliquid.xyz                  refused
    https://api-ui.hyperliquid.xyz           refused
    https://api.hyperliquid-testnet.xyz      ok
    wss://api.hyperliquid-testnet.xyz/ws     ok
    http://localhost:3000                    ok
    http://127.0.0.1:3510                    ok
    |}]
;;
