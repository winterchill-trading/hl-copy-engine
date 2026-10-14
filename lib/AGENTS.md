# lib/ (AGENTS.md)

The `hl_copy_engine` library. `Follower_core` is the pure state machine (pause, resume, stop,
leverage and agent-reject handling, replay). `Follower` is the actor that performs the effects:
resync of both accounts, IOC execution, builder fee handling. `Engine` supervises followers from
the follow directory and serves `/metrics`, `/status` and `/healthz`.

Build from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-engine/all`.

Rules that matter here:

- New effects go in `Follower`, never in `Follower_core`.
- Inputs are versioned (`Input.Stable.V1`); a new event kind means a new version, not an edit.
- The mainnet guard lives in `Safety`. Every exchange URL goes through it.
