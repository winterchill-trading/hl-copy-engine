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
# every other account $1,000,000, so this copies the leader's sizes one for one), ALGO
# (empty: Immediate; otherwise the follow's execution algorithm as a sexp, e.g.
# "(Twap (duration_ms 6000) (slices 3) (max_participation ()))"), BAND (empty: no
# no-trade band; otherwise the follow's band as a sexp, e.g. "((fee_bps 4.5) (slippage
# (Fixed_bps 5)) (risk_aversion 20) (vol_bps 300) (cost_model Proportional))").
#
# At the end it prints a summary line: the follower's fills and fees (from its userFills),
# the band's skips and saved cost, and the tracking error: the root mean square, over the
# samples, of |target - follower position| x mid / follower equity in basis points, with
# the target the mode's image of the leader's position (both equities from
# clearinghouseState).
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
algo="${ALGO:-}"
band="${BAND:-}"
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
 (slippage_bps $slippage_bps) (paused false)${algo:+ (algo $algo)}${band:+ (band $band)})
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

# One JSON line per sample: both accounts' positions and equities, and the mids.
sample() {
  python3 - "$base" "$leader" "$follower" <<'PY' >>"$log_dir/samples.ndjson"
import json, sys, urllib.request
base, leader, follower = sys.argv[1:4]
def info(body):
    req = urllib.request.Request(base + "/info", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))
def account(user):
    s = info({"type": "clearinghouseState", "user": user})
    return {"equity": float(s["marginSummary"]["accountValue"]),
            "positions": {p["position"]["coin"]: float(p["position"]["szi"])
                          for p in s["assetPositions"]}}
print(json.dumps({"leader": account(leader), "follower": account(follower),
                  "mids": {k: float(v) for k, v in info({"type": "allMids"}).items()}}))
PY
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
  sample
done

echo "e2e: metrics" >&2
curl -s "http://127.0.0.1:$engine_port/metrics" | grep -v '^#' |
  sed -E 's/\{follower="[^"]*",leader="[^"]*",?/{/; s/\{\}//'
curl -s "http://127.0.0.1:$engine_port/status" >"$log_dir/status.json"
echo "e2e: execution (cost reports of finished parents)" >&2
python3 -c 'import json,sys
for f in json.load(open(sys.argv[1]))["followers"]:
    e = f["execution"]
    print("algo", e["algo"], "active", len(e["active"]), json.dumps(e["totals"]))
    for r in e["recent"][:5]:
        print("  ", r["algo"], r["outcome"], r["side"], r["target"], "filled", r["filled"],
              "children", r["children"], "slippage_bps %.2f" % r["arrival_slippage_bps"],
              "shortfall %.2f" % r["shortfall"])' "$log_dir/status.json"

echo "e2e: summary" >&2
curl -s "$base/info" -d "{\"type\":\"userFills\",\"user\":\"$follower\"}" >"$log_dir/follower-fills.json"
python3 - "$log_dir" "$mode" <<'PY'
import json, math, re, sys
log_dir, mode = sys.argv[1:3]
fills = json.load(open(log_dir + "/follower-fills.json"))
fees = sum(float(f.get("fee", 0)) for f in fills)
k = re.match(r"\(Multiplier ([0-9.]+)\)", mode)
k = float(k.group(1)) if k else 1.0
squares = []
for line in open(log_dir + "/samples.ndjson"):
    s = json.loads(line)
    lead, fol = s["leader"], s["follower"]
    if lead["equity"] <= 0 or fol["equity"] <= 0:
        continue
    gap = 0.0
    for coin in set(lead["positions"]) | set(fol["positions"]):
        target = lead["positions"].get(coin, 0.0) * k * fol["equity"] / lead["equity"]
        gap += abs(target - fol["positions"].get(coin, 0.0)) * s["mids"].get(coin, 0.0)
    squares.append((gap / fol["equity"] * 1e4) ** 2)
te = math.sqrt(sum(squares) / len(squares)) if squares else float("nan")
status = json.load(open(log_dir + "/status.json"))["followers"][0]
band = status.get("band") or {}
print("summary fills %d fees %.4f band_skips %d band_saved_usd %.4f tracking_error_bps %.1f samples %d"
      % (len(fills), fees, band.get("skips", 0), band.get("saved_usd", 0.0), te, len(squares)))
PY

kill "$engine_pid"
wait "$engine_pid" 2>/dev/null || true
engine_pid=""

echo "e2e: replaying the journal" >&2
"$engine_exe" replay "$log_dir/journal/$follower-$leader"
echo "e2e: logs and status in $log_dir" >&2
