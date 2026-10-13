#!/usr/bin/env bash
# End-to-end run on the simulator: hl-sim with simulated leaders and strict signatures,
# one follower account that approves an agent, and hl-copy-engine copying leader 0 for
# RUN_FOR seconds. Prints the leader's and the follower's positions every SAMPLE_S
# seconds, the engine's metrics, and checks that the follow's journal replays to the same
# orders.
#
# Assumed layout: hl-copy-engine is checked out next to its sibling repositories inside
# one dune workspace (a directory with dune-workspace and dune-project files containing
# '(lang dune 3.17)'), so dune builds hl-sim and the libraries from source:
#
#   <root>/hl-copy-engine <root>/hl-copy-core <root>/hl-sim <root>/hl-client ...
#
# Environment overrides: WORKSPACE (<root>), OPAM_SWITCH (5.2.0+ox), DUNE_BUILD_DIR
# (<root>/_build-hl-copy-engine), SEED (7), RUN_FOR (60), SAMPLE_S (10), RESYNC_S (10),
# SIM_PORT (3560), ENGINE_PORT (9960), LOG_DIR (a temporary directory), LEADER (leader
# 0's address), SLIPPAGE_BPS (50), NOISE_TRADERS (40: the simulated book is thin and the
# leader's own IOC orders take what is near the touch, so the follower needs a deeper book
# and a wider bound than the 20 bps default to keep up), MODE ("(Multiplier 0.1)": the simulated leaders hold $100,000 and
# every other account $1,000,000, so this copies the leader's sizes one for one).
#
# The two keys below are throwaway keys for the simulator only. Never put a real key in
# this script; the engine refuses mainnet URLs regardless.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
if [[ ! -f "$root/dune-workspace" && ! -f "$root/dune-project" ]]; then
  echo "e2e: $root is not a dune workspace root (see the header of $0)" >&2
  exit 1
fi

switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-hl-copy-engine}"
seed="${SEED:-7}"
run_for="${RUN_FOR:-60}"
sample_s="${SAMPLE_S:-10}"
resync_s="${RESYNC_S:-10}"
sim_port="${SIM_PORT:-3560}"
engine_port="${ENGINE_PORT:-9960}"
leader="${LEADER:-0x1eade50000000000000000000000000000000000}"
mode="${MODE:-(Multiplier 0.1)}"
slippage_bps="${SLIPPAGE_BPS:-50}"
noise_traders="${NOISE_TRADERS:-40}"
log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hl-copy-e2e.XXXXXX")}"
mkdir -p "$log_dir/follows" "$log_dir/journal"

# Throwaway simulator keys: account 0x11..11 and its agent 0x22..22.
export HL_COPY_E2E_USER_KEY=0x1111111111111111111111111111111111111111111111111111111111111111
export HL_COPY_E2E_AGENT_KEY=0x2222222222222222222222222222222222222222222222222222222222222222
follower=0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a

for port in "$sim_port" "$engine_port"; do
  if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "e2e: port $port is in use; set SIM_PORT or ENGINE_PORT" >&2
    exit 1
  fi
done

echo "e2e: building hl-sim and hl-copy-engine (switch $switch, build dir $DUNE_BUILD_DIR)" >&2
(cd "$root" && opam exec --switch "$switch" -- \
  dune build --root . hl-sim/bin/main.exe "$(basename "$repo")/bin/main.exe")
build="$DUNE_BUILD_DIR/default"
sim_exe="$build/hl-sim/bin/main.exe"
engine_exe="$build/$(basename "$repo")/bin/main.exe"

sim_pid=""
engine_pid=""
cleanup() {
  for pid in "$engine_pid" "$sim_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT INT TERM

base="http://127.0.0.1:$sim_port"
echo "e2e: hl-sim on $sim_port (seed $seed, 3 leaders, strict signatures), log $log_dir/sim.log" >&2
"$sim_exe" -port "$sim_port" -seed "$seed" -leaders 3 -strict-signatures \
  -noise-traders "$noise_traders" \
  >"$log_dir/sim.log" 2>&1 &
sim_pid=$!
for _ in $(seq 1 50); do
  if curl -sf "$base/info" -d '{"type":"meta"}' >/dev/null 2>&1; then break; fi
  if ! kill -0 "$sim_pid" 2>/dev/null; then
    echo "e2e: hl-sim exited early:" >&2
    cat "$log_dir/sim.log" >&2
    exit 1
  fi
  sleep 0.2
done

echo "e2e: approving the agent" >&2
"$engine_exe" approve-agent -base-url "$base" \
  -user-key-env HL_COPY_E2E_USER_KEY -agent-key-env HL_COPY_E2E_AGENT_KEY

cat >"$log_dir/follows/$follower-$leader.sexp" <<SEXP
((follower $follower) (leader $leader) (mode $mode)
 (caps ((max_leverage (5)) (max_notional_per_symbol ()) (max_daily_loss ())
        (allowlist ()) (min_order_notional 10)))
 (slippage_bps $slippage_bps) (paused false))
SEXP

echo "e2e: engine on $engine_port for ${run_for}s, log $log_dir/engine.log" >&2
"$engine_exe" run -base-url "$base" -configs-dir "$log_dir/follows" \
  -journal-dir "$log_dir/journal" -port "$engine_port" -resync-s "$resync_s" \
  -agent-key-env HL_COPY_E2E_AGENT_KEY 2>"$log_dir/engine.log" &
engine_pid=$!

position() {
  curl -s "$base/info" -d "{\"type\":\"clearinghouseState\",\"user\":\"$1\"}" |
    python3 -c 'import json,sys; s=json.load(sys.stdin); print(" ".join(p["position"]["coin"]+"="+p["position"]["szi"] for p in s["assetPositions"]) or "flat", "equity="+s["marginSummary"]["accountValue"])'
}

elapsed=0
while ((elapsed < run_for)); do
  sleep "$sample_s"
  elapsed=$((elapsed + sample_s))
  if ! kill -0 "$engine_pid" 2>/dev/null; then
    echo "e2e: the engine exited early:" >&2
    cat "$log_dir/engine.log" >&2
    exit 1
  fi
  printf '%4ss  leader %s\n       follower %s\n' "$elapsed" "$(position "$leader")" "$(position "$follower")"
done

echo "e2e: metrics" >&2
curl -s "http://127.0.0.1:$engine_port/metrics" | grep -v '^#' |
  sed -E 's/\{follower="[^"]*",leader="[^"]*",?/{/; s/\{\}//'
curl -s "http://127.0.0.1:$engine_port/status" >"$log_dir/status.json"

kill "$engine_pid"
wait "$engine_pid" 2>/dev/null || true
engine_pid=""

echo "e2e: replaying the journal" >&2
"$engine_exe" replay "$log_dir/journal/$follower-$leader"
echo "e2e: logs and status in $log_dir" >&2
