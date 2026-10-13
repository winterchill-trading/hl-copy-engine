(* The engine on hl-sim: follow files in a directory start, reconfigure and stop
   followers; /metrics and /status describe them. *)

open! Core
open! Async
open Hl_protocol
open Hl_copy_core
open Hl_copy_engine
module Signing = Hl_client.Signing

let user_key = Sim.key 0x11
let agent_key = Sim.key 0x22
let leader_key = Sim.key 0x33
let user = Signing.Private_key.address user_key
let leader = Signing.Private_key.address leader_key

let approve sim =
  let owner = Hl_client.Client.trading ~key:user_key (Sim.config sim ()) in
  Hl_client.Client.approve_agent
    owner
    ~agent_address:(Signing.Private_key.address agent_key)
    ~agent_name:"copy"
  >>| ok_exn
  >>| ignore
;;

let write dir (follow : Follower_config.t) =
  (* Write then rename, as the API does, so a scan never reads half a file. *)
  let path = dir ^/ Follower_config.file_name follow in
  let%bind () =
    Writer.save (path ^ ".tmp") ~contents:(Follower_config.to_file_contents follow)
  in
  Unix.rename ~src:(path ^ ".tmp") ~dst:path
;;

let get engine path =
  let uri =
    Uri.make
      ~scheme:"http"
      ~host:"127.0.0.1"
      ~port:(Option.value_exn (Engine.port engine))
      ~path
      ()
  in
  let%bind _, body = Cohttp_async.Client.get uri in
  Cohttp_async.Body.to_string body
;;

let positions sim =
  printf
    "leader %s follower %s\n"
    (Size.to_string (Sim.position sim leader "BTC"))
    (Size.to_string (Sim.position sim user "BTC"))
;;

let%expect_test "follow files drive followers; metrics and status" =
  let%bind sim = Sim.start ~strict:true () in
  let%bind () = approve sim in
  let dir = Filename_unix.temp_dir "hl-copy-follows" "" in
  let follow = Follower_config.create ~follower:user ~leader () in
  let%bind () = write dir follow in
  let%bind () = Writer.save (dir ^/ "broken.sexp") ~contents:"(follower" in
  let config =
    Engine.Config.create
      ~scan_interval:(Time_ns.Span.of_int_ms 100)
      ~api:(Sim.config sim ())
      ~configs_dir:dir
      ~signer_for:(fun _ -> return (Ok (Follower.Signer.Agent agent_key)))
      ()
  in
  let%bind engine = Engine.start ~port:0 config >>| ok_exn in
  print_s [%sexp (List.map (Engine.errors engine) ~f:fst : string list)];
  let follower = Option.value_exn (Engine.find engine ~follower:user ~leader) in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 200) in
  let%bind () =
    Sim.trade ~key:leader_key sim ~address:leader ~coin:"BTC" ~is_buy:true ~sz:"0.3"
  in
  let%bind () =
    Sim.wait_until ~what:"follower copies" (fun () ->
      return (Size.equal (Sim.position sim user "BTC") (Size.of_string "0.3")))
  in
  positions sim;
  [%expect {|
    (broken.sexp)
    leader 0.3 follower 0.3
    |}];
  (* Paused by the file: the leader's next trade is not copied. *)
  let%bind () = write dir { follow with paused = true } in
  let%bind () =
    Sim.wait_until ~what:"paused" (fun () ->
      return (not (Follower_core.is_running (Follower.state follower))))
  in
  let%bind () =
    Sim.trade ~key:leader_key sim ~address:leader ~coin:"BTC" ~is_buy:true ~sz:"0.2"
  in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 300) in
  let%bind () = Follower.idle follower in
  positions sim;
  [%expect {| leader 0.5 follower 0.3 |}];
  (* Unpaused with a notional cap: the follower catches up to the cap. *)
  let%bind () =
    write
      dir
      { follow with
        caps = { Caps.none with max_notional_per_symbol = Some (Usd.of_string "40000") }
      }
  in
  let%bind () =
    Sim.wait_until ~what:"resumed and capped" (fun () ->
      let%map () = Follower.idle follower in
      Size.(Sim.position sim user "BTC" > of_string "0.3"))
  in
  positions sim;
  [%expect {| leader 0.5 follower 0.39996 |}];
  let%bind metrics = get engine "/metrics" in
  String.split_lines metrics
  |> List.filter ~f:(fun l ->
    List.exists
      [ "hl_copy_orders_total{"
      ; "hl_copy_fills_total{"
      ; "hl_copy_followers "
      ; "hl_copy_config_errors "
      ]
      ~f:(fun prefix -> String.is_prefix l ~prefix))
  |> List.iter ~f:print_endline;
  [%expect
    {|
    hl_copy_orders_total{follower="0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a",leader="0x5cbdd86a2fa8dc4bddd8a8f69dba48572eec07fb"} 2
    hl_copy_fills_total{follower="0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a",leader="0x5cbdd86a2fa8dc4bddd8a8f69dba48572eec07fb"} 2
    hl_copy_followers 1
    hl_copy_config_errors 1
    |}];
  let%bind status = get engine "/status" in
  let json = Yojson.Safe.from_string status in
  let open Yojson.Safe.Util in
  let f = json |> member "followers" |> index 0 in
  print_s
    [%message
      ""
        ~status:(f |> member "status" |> to_string : string)
        ~leader_source:(f |> member "leader_source" |> to_string : string)
        ~follower_positions:
          (f |> member "follower_positions" |> Yojson.Safe.to_string : string)
        ~leaders:(json |> member "leaders" |> to_list |> List.length : int)
        ~errors:(json |> member "errors" |> to_list |> List.length : int)];
  [%expect
    {|
    ((status running) (leader_source websocket)
     (follower_positions "{\"BTC\":\"0.39996\"}") (leaders 1) (errors 1))
    |}];
  (* Removing the file stops the follower. *)
  let%bind () = Unix.unlink (dir ^/ Follower_config.file_name follow) in
  let%bind () =
    Sim.wait_until ~what:"stopped" (fun () ->
      return (List.is_empty (Engine.followers engine)))
  in
  print_s [%sexp ((Follower.state follower).status : Follower_core.Status.t)];
  [%expect {| Stopped |}];
  let%bind () = Engine.stop engine in
  Sim.stop sim
;;

let%expect_test "the engine refuses mainnet" =
  let%bind result =
    Engine.start
      (Engine.Config.create
         ~api:(Hl_client.Config.mainnet ())
         ~configs_dir:"/nonexistent"
         ~signer_for:(fun _ -> return (Ok Follower.Signer.Unsigned))
         ())
  in
  print_s [%sexp (Result.is_error result : bool)];
  [%expect {| true |}];
  return ()
;;
