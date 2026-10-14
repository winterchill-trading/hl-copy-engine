# bin/ (AGENTS.md)

The `hl-copy-engine` executable with three commands: `run` (the supervisor, with the builder
address and fee flags), `approve-agent` (local approval for runs without a browser wallet), and
`replay` (checks a journal against the core). The flags are in the root `README.md`.

Build and run from the repository root: `opam exec --switch 5.2.0+ox -- dune exec hl-copy-engine -- run -help`.

Rules that matter here:

- `approve-agent` is for local runs; in production the user's wallet signs the approval through
  `hl-copy-api`.
- A new command gets a README line.
