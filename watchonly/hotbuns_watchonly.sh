#!/usr/bin/env bash
#
# hotbuns_watchonly.sh — Core-faithful WATCH-ONLY import differential test.
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
# Summary line (stdout): "WATCHONLY hotbuns: PASS|FAIL ...". exit 0/1.
# Touches ONLY /tmp/hashhog-wofleet-hotbuns/ and ports 21404 (RPC) / 21424
# (P2P). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

BASEDIR="/home/work/hashhog"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WO_LIB="$SCRIPT_DIR/wo_lib.py"
NODE_DIR="$BASEDIR/hotbuns"
DATADIR="/tmp/hashhog-wofleet-hotbuns"
RPC_PORT=21404
P2P_PORT=21424
LOG="$DATADIR/node.log"
NODE_PID=""
COOKIE=""

# Same canonical BIP-39 mnemonic the other hotbuns wallet cells use (the
# funding wallet is only a checker fallback target here).
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

log() { echo "[watchonly] $*" >&2; }
fail() { echo "WATCHONLY hotbuns: FAIL $*"; exit 1; }
boot_gap() { echo "WATCHONLY hotbuns: FAIL cannot boot: $*"; exit 1; }

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

# ── RPC helper (cookie auth; optional /wallet/<name> — hotbuns shape). ─────
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}"
    local url="http://127.0.0.1:$RPC_PORT/"
    [[ -n "$wallet" ]] && url="http://127.0.0.1:$RPC_PORT/wallet/$wallet"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$url" 2>/dev/null
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    boot_gap "port ${RPC_PORT}/${P2P_PORT} already LISTENING (refusing to kill: fuser-on-ephemeral-port killed mainnet nodes, 2026-06-10 incident)"
fi
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
command -v bun >/dev/null 2>&1 || boot_gap "bun runtime not found on PATH"
[[ -f "$NODE_DIR/src/index.ts" ]] || boot_gap "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"
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

# ── 3. Launch hotbuns on regtest (bun runtime). ────────────────────────────
log "launching hotbuns (regtest) rpc=:$RPC_PORT p2p=:$P2P_PORT -> $LOG"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$DATADIR" \
        --port="$P2P_PORT" --rpcport="$RPC_PORT"
) >"$LOG" 2>&1 &
NODE_PID=$!
deadline=$(( $(date +%s) + 60 )); up=0
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
[[ "$up" == 1 ]] || boot_gap "RPC never responded within 60s"
log "RPC ready"

# ── 4. Funding wallet w1 (9-arg Core-shape createwallet) + funding. ────────
r=$(rpc createwallet "[\"w1\", false, false, \"\", false, true, false, \"$MNEMONIC\", \"\"]")
echo "$r" | grep -q '"name":"w1"' || fail "createwallet w1 failed: $(echo "$r" | head -c 160)"
for spec in "1 $A_ADDR" "1 $B_ADDR" "1 $W_ADDR" "101 $M_ADDR"; do
    n=${spec%% *}; ad=${spec#* }
    r=$(rpc generatetoaddress "[$n, \"$ad\"]" w1)
    echo "$r" | grep -q '"error":{' && fail "generatetoaddress $n->$ad errored: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
done
H=$(rpc getblockcount | grep -o '"result":[0-9]*' | head -1 | sed 's/"result"://')
[[ "${H:-0}" -eq 104 ]] || fail "tip height ${H:-?} != 104 after pre-import funding"
log "pre-import funding done at tip $H"

# ── 5. The Core-faithful watch-only sequence (shared engine). ──────────────
OUT=$(python3 "$WO_LIB" check --impl hotbuns \
    --base-url "http://127.0.0.1:$RPC_PORT" \
    --cookie "$DATADIR/.cookie" --cookie "$DATADIR/regtest/.cookie" \
    --routing path --keys "$KEYS" \
    --watch-wallet wo --fallback-wallet w1)
rc=$?
[[ -n "$OUT" ]] || fail "checker produced no verdict line (rc=$rc)"
echo "WATCHONLY hotbuns: $OUT"
exit $rc
