#!/usr/bin/env bash
#
# clearbit_watchonly.sh — Core-faithful WATCH-ONLY import differential test.
#
# PARITY BAR (Core v31.99): the importdescriptors path on a
# disable_private_keys wallet (src/wallet/rpc/backup.cpp:302 — Core's ONLY
# remaining watch-only import path; legacy importaddress/importpubkey return
# -32601 on the oracle itself and are probed INFORMATIONALLY only).
# Full ground-truth citations + check semantics: watchonly/wo_lib.py.
#
# clearbit divergences honoured (from clearbit_import.sh): external keys are
# LEGACY P2PKH (its external-key path is hash160-committing/legacy-
# constrained, per the import-arm precedent), so the pubkey descriptor here
# is pkh(PUB) instead of wpkh(PUB); blank createwallet + hex sethdseed for
# the funding wallet.
#
# Flow: fund external offline keys A/B/W (1 coinbase each) + 101 -> M
# (tip 104) BEFORE any import; createwallet wo (dpk, blank);
# importdescriptors addr(A)#chk + pkh(PUBW)#chk ts=0; negatives (-5 / -4);
# addr(B)#chk ts=0 must credit the PRE-IMPORT funding; observability;
# nonspend; legacy probe (informational).
#
# SKIP-vs-FAIL: only binary/boot preconditions may use GAP_RE vocabulary;
# missing watch-only RPCs are FAILs.
#
# Summary line (stdout): "WATCHONLY clearbit: PASS|FAIL ...". exit 0/1.
# Touches ONLY /tmp/hashhog-wofleet-clearbit/ and ports 41407 (RPC) / 41427
# (P2P). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

BASEDIR="/home/work/hashhog"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WO_LIB="$SCRIPT_DIR/wo_lib.py"
BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
DATADIR="/tmp/hashhog-wofleet-clearbit"
NETDIR="$DATADIR/regtest"            # clearbit appends the network subdir
COOKIE_FILE="$NETDIR/.cookie"
RPC_PORT=41407
P2P_PORT=41427
LOG="$DATADIR/node.log"
NODE_PID=""
COOKIE=""

# Same FIXED 16-byte hex seed the other clearbit wallet cells use (clearbit
# sethdseed takes HEX, not WIF — documented divergence).
SEED="000102030405060708090a0b0c0d0e0f"

log() { echo "[watchonly] $*" >&2; }
fail() { echo "WATCHONLY clearbit: FAIL $*"; exit 1; }
boot_gap() { echo "WATCHONLY clearbit: FAIL cannot boot: $*"; exit 1; }

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

# ── RPC helper (cookie auth; explicit path — clearbit shape). ──────────────
# usage: rpc <path> <method> <params-json>
rpc() {
    local path="$1" method="$2" params="${3:-[]}"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT$path" 2>/dev/null
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
fuser -k "${RPC_PORT}/tcp" >/dev/null 2>&1 || true
fuser -k "${P2P_PORT}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || boot_gap "clearbit binary not found at $BIN"
[[ -f "$WO_LIB" ]] || fail "wo_lib.py absent at $WO_LIB"
python3 -c "import coincurve" 2>/dev/null || boot_gap "python coincurve not installed"

# ── 2. Offline external keys (LEGACY P2PKH per clearbit precedent). ────────
KEYS="$DATADIR/keys.json"
python3 "$WO_LIB" keys --addr-kind p2pkh >"$KEYS"
[[ -s "$KEYS" ]] || fail "offline key construction produced no output"
read -r A_ADDR B_ADDR W_ADDR M_ADDR < <(python3 -c '
import json,sys
k=json.load(open(sys.argv[1]))
print(k["A"]["addr"], k["B"]["addr"], k["W"]["addr"], k["M"]["addr"])
' "$KEYS")
[[ -n "$A_ADDR" && -n "$M_ADDR" ]] || fail "could not extract external addresses"
log "A=$A_ADDR B=$B_ADDR W=$W_ADDR M=$M_ADDR"

# ── 3. Launch clearbit on regtest (--regtest flag). ────────────────────────
log "launching clearbit (regtest) -> $LOG"
"$BIN" --regtest --datadir="$DATADIR" --port="$P2P_PORT" --rpcport="$RPC_PORT" \
    >"$LOG" 2>&1 &
NODE_PID=$!
sleep 1
kill -0 "$NODE_PID" 2>/dev/null || boot_gap "node exited immediately (see $LOG)"
deadline=$(( $(date +%s) + 45 )); up=0
while (( $(date +%s) < deadline )); do
    [[ -z "$COOKIE" && -f "$COOKIE_FILE" ]] && COOKIE="$(cat "$COOKIE_FILE" 2>/dev/null)"
    if [[ -n "$COOKIE" ]] && rpc "/" getblockcount | grep -q '"result"'; then up=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || boot_gap "node exited during startup (see $LOG)"
    sleep 1
done
[[ "$up" == 1 ]] || boot_gap "RPC never responded within 45s"
log "RPC ready"

# ── 4. Funding wallet w1 (blank + hex sethdseed) + PRE-IMPORT funding. ─────
r=$(rpc "/" createwallet '["w1",false,true]')
echo "$r" | grep -q '"error":{' && log "note: createwallet w1: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
r=$(rpc "/wallet/w1" sethdseed "[true,\"$SEED\"]")
echo "$r" | grep -q '"error":{' && log "note: sethdseed w1: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
for spec in "1 $A_ADDR" "1 $B_ADDR" "1 $W_ADDR" "101 $M_ADDR"; do
    n=${spec%% *}; ad=${spec#* }
    r=$(rpc "/" generatetoaddress "[$n,\"$ad\"]")
    echo "$r" | grep -q '"error":{' && fail "generatetoaddress $n->$ad errored: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
done
H=$(rpc "/" getblockcount | grep -o '"result":[0-9]*' | head -1 | sed 's/"result"://')
[[ "${H:-0}" -eq 104 ]] || fail "tip height ${H:-?} != 104 after pre-import funding"
log "pre-import funding done at tip $H"

# ── 5. The Core-faithful watch-only sequence (shared engine). ──────────────
OUT=$(python3 "$WO_LIB" check --impl clearbit \
    --base-url "http://127.0.0.1:$RPC_PORT" \
    --cookie "$COOKIE_FILE" \
    --routing path --keys "$KEYS" \
    --watch-wallet wo --fallback-wallet w1)
rc=$?
[[ -n "$OUT" ]] || fail "checker produced no verdict line (rc=$rc)"
echo "WATCHONLY clearbit: $OUT"
exit $rc
