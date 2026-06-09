#!/usr/bin/env bash
#
# blockbrew_watchonly.sh — Core-faithful WATCH-ONLY import differential test.
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
# Summary line (stdout): "WATCHONLY blockbrew: PASS|FAIL ...". exit 0/1.
# Touches ONLY /tmp/hashhog-wofleet-blockbrew/ and ports 41403 (RPC) / 41423
# (P2P). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

BASEDIR="/home/work/hashhog"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WO_LIB="$SCRIPT_DIR/wo_lib.py"
BIN="$BASEDIR/blockbrew/blockbrew"
DATADIR="/tmp/hashhog-wofleet-blockbrew"
RPC_PORT=41403
P2P_PORT=41423
COOKIE_FILE="$DATADIR/regtest/.cookie"
LOG="$DATADIR/node.log"
NODE_PID=""
COOKIE=""

# Same canonical BIP-39 mnemonic the other blockbrew wallet cells use (the
# funding wallet is only a checker fallback target here).
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

log() { echo "[watchonly] $*" >&2; }
fail() { echo "WATCHONLY blockbrew: FAIL $*"; exit 1; }
boot_gap() { echo "WATCHONLY blockbrew: FAIL cannot boot: $*"; exit 1; }

cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NODE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    fuser -k "${RPC_PORT}/tcp" >/dev/null 2>&1 || true
    fuser -k "${P2P_PORT}/tcp" >/dev/null 2>&1 || true
    [[ -n "${HASHHOG_KEEP_SCRATCH:-}" ]] || rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── RPC helper (cookie auth; optional /wallet/<name> — blockbrew shape). ───
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}" path=""
    [[ -n "$wallet" ]] && path="/wallet/$wallet"
    curl -s --max-time 120 ${COOKIE:+-u "$COOKIE"} \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:${RPC_PORT}/${path#/}" 2>/dev/null
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
fuser -k "${RPC_PORT}/tcp" >/dev/null 2>&1 || true
fuser -k "${P2P_PORT}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || boot_gap "blockbrew binary not found at $BIN"
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

# ── 3. Launch blockbrew on regtest (single-dash flags, no listeners). ──────
log "launching blockbrew (regtest) -> $LOG"
"$BIN" \
    -network=regtest -datadir="$DATADIR" \
    -listen="127.0.0.1:${P2P_PORT}" -rpcbind="127.0.0.1:${RPC_PORT}" \
    -maxoutbound=0 -nolisten \
    >"$LOG" 2>&1 &
NODE_PID=$!
deadline=$(( $(date +%s) + 45 )); up=0
while (( $(date +%s) < deadline )); do
    [[ -z "$COOKIE" && -f "$COOKIE_FILE" ]] && COOKIE=$(cat "$COOKIE_FILE")
    if [[ -n "$COOKIE" ]] && rpc getblockcount | grep -q '"result"'; then up=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || boot_gap "node exited during startup (see $LOG)"
    sleep 1
done
[[ "$up" == 1 ]] || boot_gap "RPC never responded within 45s"
log "RPC ready"

# ── 4. Funding wallet w1 (RESTORED-mnemonic shape) + PRE-IMPORT funding. ───
CW1="[\"w1\", false, false, \"\", false, true, false, \"\", \"\", \"$MNEMONIC\"]"
r=$(rpc createwallet "$CW1")
if ! echo "$r" | grep -q '"name":"w1"'; then
    log "note: 10-arg createwallet failed, trying name-only: $(echo "$r" | head -c 120)"
    r=$(rpc createwallet '["w1"]')
    echo "$r" | grep -q '"error":{' && log "note: createwallet w1 failed entirely"
fi
for spec in "1 $A_ADDR" "1 $B_ADDR" "1 $W_ADDR" "101 $M_ADDR"; do
    n=${spec%% *}; ad=${spec#* }
    r=$(rpc generatetoaddress "[$n, \"$ad\"]")
    echo "$r" | grep -q '"error":{' && fail "generatetoaddress $n->$ad errored: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
done
H=$(rpc getblockcount | grep -o '"result":[0-9]*' | head -1 | sed 's/"result"://')
[[ "${H:-0}" -eq 104 ]] || fail "tip height ${H:-?} != 104 after pre-import funding"
log "pre-import funding done at tip $H"

# ── 5. The Core-faithful watch-only sequence (shared engine). ──────────────
OUT=$(python3 "$WO_LIB" check --impl blockbrew \
    --base-url "http://127.0.0.1:$RPC_PORT" \
    --cookie "$COOKIE_FILE" \
    --routing path --keys "$KEYS" \
    --watch-wallet wo --fallback-wallet w1)
rc=$?
[[ -n "$OUT" ]] || fail "checker produced no verdict line (rc=$rc)"
echo "WATCHONLY blockbrew: $OUT"
exit $rc
