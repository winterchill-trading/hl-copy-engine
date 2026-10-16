# test/ (AGENTS.md)

Pure-core tests (including no-trade band skips and Impact estimates from market ticks),
journal tests (day files, reload, a tampered output is detected, version 1 and 2 files next
to a version 3 one), rate limit,
reject classification, metrics, safety, the leader hub against `hl-sim` (one leader over the
websocket, one polled past the limit), and the follower against `hl-sim` with strict signatures
and an approved agent.

- Tests use loopback only.
- Promote expect output with `dune promote` only after reading each diff.
- Run from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-engine/runtest`.
