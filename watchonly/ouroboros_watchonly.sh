#!/usr/bin/env bash
#
# ouroboros_watchonly.sh — Core-faithful WATCH-ONLY import differential test.
#
# PARITY BAR (Core v31.99): the importdescriptors path on a
# disable_private_keys wallet (src/wallet/rpc/backup.cpp:302 — Core's ONLY
# remaining watch-only import path; legacy importaddress/importpubkey return
# -32601 on the oracle itself and are probed INFORMATIONALLY only).
# Full ground-truth citations + check semantics: watchonly/wo_lib.py.
#
# Flow: fund external offline keys A/B/W (1 coinbase each) + 101 -> M
# (tip 104) BEFORE any import; createwallet wo (dpk, blank);
# importdescriptors addr(A)#chk + wpkh(PUBW)#chk ts=0; negatives (-5 / -4);
# addr(B)#chk ts=0 must credit the PRE-IMPORT funding; observability;
# nonspend; legacy probe (informational).
#
# SKIP-vs-FAIL: only binary/boot preconditions may use GAP_RE vocabulary;
# missing watch-only RPCs are FAILs.
#
# Summary line (stdout): "WATCHONLY ouroboros: PASS|FAIL ...". exit 0/1.
# Touches ONLY /tmp/hashhog-wofleet-ouroboros/ and ports 21402 (RPC) / 21422
# (P2P). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

BASEDIR="${HASHHOG_ROOT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WO_LIB="$SCRIPT_DIR/wo_lib.py"
OURO_DIR="$BASEDIR/ouroboros"
DATADIR="/tmp/hashhog-wofleet-ouroboros"
RPC_PORT=21402
P2P_PORT=21422
LOG="$DATADIR/node.log"
NODE_PID=""
COOKIE=""

log() { echo "[watchonly] $*" >&2; }
fail() { echo "WATCHONLY ouroboros: FAIL $*"; exit 1; }
boot_gap() { echo "WATCHONLY ouroboros: FAIL cannot boot: $*"; exit 1; }

cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NODE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    [[ -n "${HASHHOG_KEEP_SCRATCH:-}" ]] || rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── RPC helpers (cookie auth; wallet-scoped variant — ouroboros shape). ────
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 120 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}
wrpc() {
    local wallet="$1" method="$2" params="${3:-[]}"
    curl -s --max-time 120 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/wallet/$wallet" 2>/dev/null
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    boot_gap "port ${RPC_PORT}/${P2P_PORT} already LISTENING (refusing to kill: fuser-on-ephemeral-port killed mainnet nodes, 2026-06-10 incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || boot_gap "ouroboros checkout not found at $OURO_DIR"
OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"
[[ -f "$WO_LIB" ]] || fail "wo_lib.py absent at $WO_LIB"
python3 -c "import coincurve" 2>/dev/null || boot_gap "python coincurve not installed"

# ── 2. Offline external keys. ──────────────────────────────────────────────
KEYS="$DATADIR/keys.json"
python3 "$WO_LIB" keys --addr-kind p2wpkh >"$KEYS"
[[ -s "$KEYS" ]] || fail "offline key construction produced no output"
read -r A_ADDR B_ADDR W_ADDR M_ADDR < <(python3 -c '
import json,sys
k=json.load(open(sys.argv[1]))
print(k["A"]["addr"], k["B"]["addr"], k["W"]["addr"], k["M"]["addr"])
' "$KEYS")
[[ -n "$A_ADDR" && -n "$M_ADDR" ]] || fail "could not extract external addresses"
log "A=$A_ADDR B=$B_ADDR W=$W_ADDR M=$M_ADDR"

# ── 3. Launch ouroboros on regtest (slow Python boot: 150s budget). ────────
log "launching ouroboros: $OURO_PY -m ouroboros.cli (rpc=$RPC_PORT p2p=$P2P_PORT)"
(
    cd "$OURO_DIR" || exit 1
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$DATADIR" \
        start --force --rpc-port "$RPC_PORT" --p2p-port "$P2P_PORT"
) >"$LOG" 2>&1 &
NODE_PID=$!
deadline=$(( $(date +%s) + 150 )); up=0
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" ]]; then
        for c in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
            if [[ -f "$c" ]]; then COOKIE=$(cat "$c"); break; fi
        done
    fi
    if [[ -n "$COOKIE" ]] && rpc getblockcount | grep -q '"result"'; then up=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || { tail -20 "$LOG" >&2 || true; boot_gap "node exited during startup (see $LOG)"; }
    sleep 1
done
[[ "$up" == 1 ]] || boot_gap "RPC never responded within 150s"
log "RPC ready"

# ── 4. Funding wallet W1 + PRE-IMPORT funding (mining scoped to W1). ───────
r=$(rpc createwallet '["W1"]')
echo "$r" | grep -q '"name":"W1"' || fail "createwallet W1 failed: $(echo "$r" | head -c 160)"
for spec in "1 $A_ADDR" "1 $B_ADDR" "1 $W_ADDR" "101 $M_ADDR"; do
    n=${spec%% *}; ad=${spec#* }
    r=$(wrpc W1 generatetoaddress "[$n, \"$ad\"]")
    echo "$r" | grep -q '"error":{' && fail "generatetoaddress $n->$ad errored: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
done
H=$(rpc getblockcount | grep -o '"result":[0-9]*' | head -1 | sed 's/"result"://')
[[ "${H:-0}" -eq 104 ]] || fail "tip height ${H:-?} != 104 after pre-import funding"
log "pre-import funding done at tip $H"

# ── 5. The Core-faithful watch-only sequence (shared engine). ──────────────
OUT=$(python3 "$WO_LIB" check --impl ouroboros \
    --base-url "http://127.0.0.1:$RPC_PORT" \
    --cookie "$DATADIR/.cookie" --cookie "$DATADIR/regtest/.cookie" \
    --routing path --keys "$KEYS" \
    --watch-wallet wo --fallback-wallet W1 --timeout 120)
rc=$?
[[ -n "$OUT" ]] || fail "checker produced no verdict line (rc=$rc)"
echo "WATCHONLY ouroboros: $OUT"
exit $rc
