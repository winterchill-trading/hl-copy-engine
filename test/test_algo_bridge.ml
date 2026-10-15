open! Core
open Hl_copy_engine

(* The core library keeps its own copy of the algorithm type; the two must stay the same
   shape so a follow file and the scheduler agree. *)
let%expect_test "same bin_prot shape as execution-algos" =
  let d = Bin_prot.Shape.eval_to_digest_string in
  print_s
    [%message
      ""
        ~core:(d Hl_copy_core.Exec_algo.Stable.V1.bin_shape_t : string)
        ~algos:(d Execution_algos.Algo.Stable.V1.bin_shape_t : string)];
  [%expect
    {|
    ((core 3a486612be155bbf3411a99a085779a6)
     (algos 3a486612be155bbf3411a99a085779a6))
    |}]
;;

let%expect_test "round trip of every default" =
  List.iter
    Execution_algos.Algo.[ Immediate; twap; vwap; pov; passive; iceberg; adaptive ]
    ~f:(fun a ->
      let back = Algo_bridge.to_algo (Algo_bridge.of_algo a) in
      assert ([%equal: Execution_algos.Algo.t] a back);
      (* the same sexp text on both sides *)
      assert (
        Sexp.equal
          (Execution_algos.Algo.sexp_of_t a)
          (Hl_copy_core.Exec_algo.sexp_of_t (Algo_bridge.of_algo a))));
  [%expect {| |}]
;;
