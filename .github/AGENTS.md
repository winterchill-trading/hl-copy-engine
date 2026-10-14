# .github/ (AGENTS.md)

`workflows/ci.yml` lints `scripts/`, builds and tests this repository with the shared `ox-setup`
action, and calls the `obj-magic` reusable workflow from `infra`.

- The pin list must match the org dependencies in `dune-project`; a new org dependency gets its
  pin in the same commit, in dependency order.
- Keep the `concurrency` block.
- Check a run with one `gh run list --limit 1`, and at most one `gh run watch <id> --exit-status`.
