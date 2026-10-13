open! Core
open! Async
open Hl_protocol

type t =
  { server : Hl_sim.Server.t
  ; http : (Socket.Address.Inet.t, int) Cohttp_async.Server.t
  ; base_url : Uri.t
  }

let maker = Address.of_string "0x00000000000000000000000000000000000000b0"
let config t ?address () = Hl_client.Config.create ?address ~base_url:t.base_url ()

let asset coin =
  match coin with
  | "BTC" -> 0
  | "ETH" -> 1
  | "SOL" -> 2
  | _ -> raise_s [%message "unknown coin" coin]
;;

let order ~coin ~is_buy ~px ~sz ~tif =
  { Order_request.asset = Asset.of_int (asset coin)
  ; is_buy
  ; limit_px = Price.of_string px
  ; sz = Size.of_string sz
  ; reduce_only = false
  ; order_type = Limit { tif }
  ; cloid = None
  }
;;

let send t ~address orders =
  match%map Hl_client.Exchange.place_orders (config t ~address ()) orders with
  | Ok (Ok (Order statuses)) ->
    List.iter statuses ~f:(function
      | Error message -> raise_s [%message "order failed" message]
      | _ -> ())
  | response ->
    raise_s [%message "order failed" (response : Exchange_response.t Or_error.t)]
;;

let rest t ~coin ~is_buy ~px ~sz =
  send t ~address:maker [ order ~coin ~is_buy ~px ~sz ~tif:Gtc ]
;;

let trade t ~address ~coin ~is_buy ~sz =
  let px = if is_buy then "101000" else "99000" in
  send t ~address [ order ~coin ~is_buy ~px ~sz ~tif:Ioc ]
;;

let start ?config () =
  Log.Global.set_output [];
  let server = Hl_sim.Server.create ?config (Hl_sim.Adapt.create_exchange ()) in
  let%bind http = Hl_sim.Server.listen server ~port:0 in
  let base_url =
    Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:(Hl_sim.Server.port http) ()
  in
  let t = { server; http; base_url } in
  let%map () =
    send
      t
      ~address:maker
      (List.concat_map (List.range 0 10) ~f:(fun i ->
         [ order
             ~coin:"BTC"
             ~is_buy:true
             ~px:(Int.to_string (99_990 - (10 * i)))
             ~sz:"2"
             ~tif:Gtc
         ; order
             ~coin:"BTC"
             ~is_buy:false
             ~px:(Int.to_string (100_010 + (10 * i)))
             ~sz:"2"
             ~tif:Gtc
         ]))
  in
  t
;;

let stop t = Cohttp_async.Server.close t.http

let position t address coin =
  let state =
    Clearinghouse_state.t_of_yojson
      (Hl_sim.Server.handle_info t.server (Clearinghouse_state { user = address }))
  in
  match Clearinghouse_state.find_position state (Coin.of_string coin) with
  | None -> Size.zero
  | Some p -> p.szi
;;

let rec wait_until ?(timeout = Time_ns.Span.of_int_sec 10) ~what f =
  match%bind f () with
  | true -> return ()
  | false ->
    if Time_ns.Span.(timeout <= zero)
    then raise_s [%message "timed out waiting" what]
    else (
      let step = Time_ns.Span.of_int_ms 20 in
      let%bind () = Clock_ns.after step in
      wait_until ~timeout:Time_ns.Span.(timeout - step) ~what f)
;;
