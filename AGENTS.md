# AGENTS.md (hl-copy-engine)

## Purpose

The mirroring service of the copy-trading platform: one follower actor per follow subscribes to
its leader, keeps mirror state in the pure core of `hl-copy-core`, and sends IOC orders signed by
the follower's agent key. A supervisor watches a directory of follow files and serves metrics and
status over HTTP. It refuses mainnet URLs.

Workspace-wide rules, the repository map and the CI model are in
`../oxcaml-claude-skills/AGENTS.md`. Read that first.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The `hl_copy_engine` library: `Follower_core`, `Journal`, `Leader_hub`, `Rate_limit`, `Follower`, `Engine`, `Key_source`, `Metrics`, `Reject`, `Safety` ([lib/AGENTS.md](lib/AGENTS.md)) |
| `bin/` | The `hl-copy-engine` executable: `run`, `approve-agent`, `replay` ([bin/AGENTS.md](bin/AGENTS.md)) |
| `test/` | Pure-core, journal, rate limit, leader hub, and end-to-end tests against `hl-sim` ([test/AGENTS.md](test/AGENTS.md)) |
| `scripts/` | `e2e-sim.sh`: the engine on one follow against `hl-sim` for 60 seconds |
| `.github/` | CI workflow ([.github/AGENTS.md](.github/AGENTS.md)) |
| `README.md` | Running, follow files, builder fees, the follow lifecycle, metrics, tests |

## Build and test

From this repository, inside the workspace:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-engine/all @hl-copy-engine/runtest
```

For parallel work give the build its own directory, relative to the workspace root:
`DUNE_BUILD_DIR=_build-hl-copy-engine` in front of the same command.

Standalone, with the published dependencies:

```sh
opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git
opam install . --deps-only --with-test
dune build && dune test
```

Format only this repository, after the tests pass:
`dune build --root .. @hl-copy-engine/fmt --auto-promote`. Never run `dune fmt` at the workspace root.

## Conventions

- Core style: `open! Core`, an `.mli` for every module, labelled arguments, expect tests and
  Base_quickcheck properties.
- The follower core stays pure: state and event in, state and plan out. Effects live in `Follower`.
- Journals are Bin_prot day files headed by an entry digest. Any change to the entry type needs a
  new digest and a replay test; `Journal.verify` must still replay the journals already on disk.
- The engine reads only files written by `hl-copy-api`. Do not give it a database connection.
- Metrics names are part of the operator's dashboards; rename only with a note in the README.
- Odoc on every public value; comments at every pinned limit, saying what and why.

## Dependencies and dependents

- Depends on `hl-copy-core`, `hl-client`, `hl-protocol`, `market-data`, `exchange-core` and
  `fixed-decimal`. Test-only: `hl-sim` and `exchange-core-engine`. The pin order is in
  `.github/workflows/ci.yml`.
- Used by `../hl-copy-api` (writes the follow files and the key store, reads `/status`) and by the
  deployment files in `../infra` (`compose/`, `charts/`).
- Spec: `../specs/repos/hl-copy-engine.md`; the design is in `../specs/design/copytrading.md`.

## CI

`.github/workflows/ci.yml` has two jobs. `build` runs `shellcheck scripts/*.sh`, then the
`ox-setup` action (the switch and the pinned siblings, cached on the pins), then `dune build` and
`dune test`. `obj-magic` calls the shared reusable workflow from `infra`.

Check a run with one `gh run list --limit 1` and at most one
`gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- The API writes the database first, then the follow and key files. The engine rescans the follow
  files every second, so the files are the engine's only input.
- A follower whose agent was revoked is paused on the next scan; one whose agent was rotated is
  restarted. Tests that rotate keys must wait for both transitions.
- Rejects are classified from the exchange's error text. A new wording needs a case in `Reject`
  and a test.
- A replayed journal output that differs from the recorded one is a defect until proven otherwise;
  `Journal.verify` compares every output.
- Fees per fill are not in the engine yet: pnl is taken from resync equity and is before fees.
  Say so in any number you quote.

## Where to read more

- `README.md`, `../specs/repos/hl-copy-engine.md`, `../specs/design/copytrading.md`
- `../oxcaml-claude-skills/AGENTS.md`, `../oxcaml-claude-skills/GOTCHAS.md`
- Skill: `../oxcaml-claude-skills/skills/oxcaml-performance` before optimising the follower loop

## Never do

- Install or upgrade opam packages that change the compiler, `core`, `base`, `async` or
  `ppx_jane` on the shared switch. Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Point the engine at a mainnet URL, or remove the mainnet guard in `Safety`.
- Publish, tag or release.
- Commit credentials. The master key comes from `HL_COPY_MASTER_KEY` in the environment only.
- Print agent keys, signatures or the master key.
