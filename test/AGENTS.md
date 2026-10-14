# test/ (AGENTS.md)

Pure-core tests, journal tests (day files, reload, a tampered output is detected), rate limit,
reject classification, metrics, safety, the leader hub against `hl-sim` (one leader over the
websocket, one polled past the limit), and the follower against `hl-sim` with strict signatures
and an approved agent.

- Tests use loopback only.
- Promote expect output with `dune promote` only after reading each diff.
- Run from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-engine/runtest`.
