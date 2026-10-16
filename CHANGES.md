# Changes

All notable changes to this package. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semantic
versioning once released.

## Unreleased

### Added

- No-trade band per follow (`band` in the follow file, hl-copy-core's `No_trade_band`):
  rebalances inside the band are held back and recorded as `Within_band` notes in the
  journaled outputs; with `Impact` slippage the follower subscribes to the coin's book
  and sets the mirror's estimate from each journaled market tick.
- `hl_copy_band_skips_total` and `hl_copy_band_saved_usd`; a `band` object in each
  follower's `/status`.
- `scripts/e2e-sim.sh`: `BAND`, and a summary line with fill records, fees, band skips,
  saved cost and tracking error.

### Changed

- Journal entries version 3 (`<date>.v3.journal`); version 1 and 2 files still load,
  replay and verify. `Follower_core.Input.Stable.V3`, `Output.Stable.V3`.

## 0.1.0

- Follower actors over the pure `Follower_core`, leader hub, rate limit, journals with
  replay, agent keys from the key store, builder fees, execution algorithms, metrics and
  status, mainnet refused.
