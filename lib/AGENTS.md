# lib/ (AGENTS.md)

The `hl_copy_engine` library. `Follower_core` is the pure state machine (pause, resume, stop,
leverage and agent-reject handling, replay, and the parents worked by `execution-algos`
schedulers, `Exec`). `Follower` is the actor that performs the effects: resync of both
accounts, IOC and add-liquidity-only execution, market ticks from the public feed, the
account's own fills for resting children, builder fee handling. `Engine` supervises followers from
the follow directory and serves `/metrics`, `/status` and `/healthz`.

Build from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-engine/all`.

Rules that matter here:

- New effects go in `Follower`, never in `Follower_core`.
- Inputs, outputs and journal entries are versioned (`Stable.V2`, with `V1` still read); a new
  event kind means a new version, not an edit.
- `Algo_bridge` must match `Hl_copy_core.Exec_algo` and `Execution_algos.Algo` one to one
  (`test/test_algo_bridge.ml` checks the shapes).
- The mainnet guard lives in `Safety`. Every exchange URL goes through it.
