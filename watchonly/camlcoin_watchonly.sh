#!/usr/bin/env bash
#
# camlcoin_watchonly.sh — Core-faithful WATCH-ONLY import differential test.
#
# PARITY BAR (Core v31.99): the importdescriptors path on a
# disable_private_keys wallet (src/wallet/rpc/backup.cpp:302 — Core's ONLY
# remaining watch-only import path; legacy importaddress/importpubkey return
# -32601 on the oracle itself and are probed INFORMATIONALLY only).
# Full ground-truth citations + check semantics: watchonly/wo_lib.py.
#
# camlcoin divergences honoured (from camlcoin_import.sh): SINGLE global
# wallet (no createwallet / multiwallet routing — the checker's createwallet
# attempts will record dpk=unavailable and fall back to the global wallet),
# and listunspent carries NO address field (the checker matches by
# scriptPubKey hex, then by total amount).
#
# Flow: fund external offline keys A/B/W (1 coinbase each) + 101 -> M
# (tip 104) BEFORE any import; importdescriptors addr(A)#chk +
# wpkh(PUBW)#chk ts=0; negatives (-5 / -4); addr(B)#chk ts=0 must credit
# the PRE-IMPORT funding; observability; nonspend; legacy probe.
#
# SKIP-vs-FAIL: only binary/boot preconditions may use GAP_RE vocabulary;
# missing watch-only RPCs are FAILs.
#
# Summary line (stdout): "WATCHONLY camlcoin: PASS|FAIL ...". exit 0/1.
# Touches ONLY /tmp/hashhog-wofleet-camlcoin/ and ports 41405 (RPC) / 41425
# (P2P). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

BASEDIR="/home/work/hashhog"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WO_LIB="$SCRIPT_DIR/wo_lib.py"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
DATADIR="/tmp/hashhog-wofleet-camlcoin"
RPC_PORT=21405
P2P_PORT=21425
LOG="$DATADIR/node.log"
NODE_PID=""
COOKIE=""

log() { echo "[watchonly] $*" >&2; }
fail() { echo "WATCHONLY camlcoin: FAIL $*"; exit 1; }
boot_gap() { echo "WATCHONLY camlcoin: FAIL cannot boot: $*"; exit 1; }

cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NODE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    pkill -f "hashhog-wofleet-camlcoin" 2>/dev/null || true
    [[ -n "${HASHHOG_KEEP_SCRATCH:-}" ]] || rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── RPC helper (cookie auth; single global wallet — camlcoin shape). ───────
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:${RPC_PORT}/" 2>/dev/null
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    boot_gap "port ${RPC_PORT}/${P2P_PORT} already LISTENING (refusing to kill: fuser-on-ephemeral-port killed mainnet nodes, 2026-06-10 incident)"
fi
pkill -f "hashhog-wofleet-camlcoin" 2>/dev/null || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$NODE_BIN" ]] || boot_gap "camlcoin binary not found at $NODE_BIN"
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

# ── 3. Launch camlcoin on regtest. ─────────────────────────────────────────
log "launching camlcoin regtest (rpc=$RPC_PORT p2p=$P2P_PORT)"
"$NODE_BIN" --network regtest --datadir "$DATADIR" \
    --port "$P2P_PORT" --rpcport "$RPC_PORT" \
    >"$LOG" 2>&1 &
NODE_PID=$!
deadline=$(( $(date +%s) + 45 )); up=0
while (( $(date +%s) < deadline )); do
    [[ -z "$COOKIE" && -f "$DATADIR/.cookie" ]] && COOKIE=$(cat "$DATADIR/.cookie")
    if [[ -n "$COOKIE" ]] && rpc getblockcount | grep -q '"result"'; then up=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || boot_gap "node exited during startup (see $LOG)"
    sleep 1
done
[[ "$up" == 1 ]] || boot_gap "RPC never responded within 45s"
log "RPC ready"

# ── 4. PRE-IMPORT funding (no funding wallet: single global wallet). ───────
for spec in "1 $A_ADDR" "1 $B_ADDR" "1 $W_ADDR" "101 $M_ADDR"; do
    n=${spec%% *}; ad=${spec#* }
    r=$(rpc generatetoaddress "[$n, \"$ad\"]")
    echo "$r" | grep -q '"error":{' && fail "generatetoaddress $n->$ad errored: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
done
H=$(rpc getblockcount | grep -o '"result":[0-9]*' | head -1 | sed 's/"result"://')
[[ "${H:-0}" -eq 104 ]] || fail "tip height ${H:-?} != 104 after pre-import funding"
log "pre-import funding done at tip $H"

# ── 5. The Core-faithful watch-only sequence (shared engine). ──────────────
OUT=$(python3 "$WO_LIB" check --impl camlcoin \
    --base-url "http://127.0.0.1:$RPC_PORT" \
    --cookie "$DATADIR/.cookie" \
    --routing global --keys "$KEYS" \
    --watch-wallet wo --fallback-wallet "")
rc=$?
[[ -n "$OUT" ]] || fail "checker produced no verdict line (rc=$rc)"
echo "WATCHONLY camlcoin: $OUT"
exit $rc
