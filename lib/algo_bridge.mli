(** Converts a follow's {!Hl_copy_core.Exec_algo.t} into the scheduler's
    [Execution_algos.Algo.t]. The two types have the same constructors and fields (the
    core library keeps its own copy so it does not depend on execution-algos); the
    bin_prot digests are checked equal in [test/test_algo_bridge.ml]. *)

open! Core

val to_algo : Hl_copy_core.Exec_algo.t -> Execution_algos.Algo.t
val of_algo : Execution_algos.Algo.t -> Hl_copy_core.Exec_algo.t
