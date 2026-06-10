#!/usr/bin/env bash
#
# lunarblock_watchonly.sh — Core-faithful WATCH-ONLY import differential test.
#
# PARITY BAR (Core v31.99): the importdescriptors path on a
# disable_private_keys wallet (src/wallet/rpc/backup.cpp:302 — Core's ONLY
# remaining watch-only import path; legacy importaddress/importpubkey return
# -32601 on the oracle itself and are probed INFORMATIONALLY only).
# Full ground-truth citations + check semantics: watchonly/wo_lib.py.
#
# lunarblock divergences honoured (from lunarblock_import.sh): LuaJIT launch
# via setsid + cd with LUA_PATH and --nov2transport; importmnemonic wallet
# model (no createwallet — the checker's attempts will record
# dpk=unavailable and fall back to the importmnemonic'd w1); RPC has no
# cookie auth on regtest.
#
# Flow: fund external offline keys A/B/W (1 coinbase each) + 101 -> M
# (tip 104) BEFORE any import; importdescriptors addr(A)#chk +
# wpkh(PUBW)#chk ts=0; negatives (-5 / -4); addr(B)#chk ts=0 must credit
# the PRE-IMPORT funding; observability; nonspend; legacy probe.
#
# SKIP-vs-FAIL: only binary/interpreter/boot preconditions may use GAP_RE
# vocabulary; missing watch-only RPCs are FAILs.
#
# Summary line (stdout): "WATCHONLY lunarblock: PASS|FAIL ...". exit 0/1.
# Touches ONLY /tmp/hashhog-wofleet-lunarblock/ and ports 21409 (RPC) /
# 21429 (P2P). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

BASEDIR="${HASHHOG_ROOT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WO_LIB="$SCRIPT_DIR/wo_lib.py"
LB_DIR="$BASEDIR/lunarblock"
DATADIR="/tmp/hashhog-wofleet-lunarblock"
RPC_PORT=21409
P2P_PORT=21429
RPC_URL="http://127.0.0.1:${RPC_PORT}"
LOG="$DATADIR/node.log"
NODE_PID=""

MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

log() { echo "[watchonly] $*" >&2; }
fail() { echo "WATCHONLY lunarblock: FAIL $*"; exit 1; }
boot_gap() { echo "WATCHONLY lunarblock: FAIL cannot boot: $*"; exit 1; }

cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]]; then
        kill -TERM "-${NODE_PID}" 2>/dev/null || kill -TERM "$NODE_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 0.4
        done
        kill -KILL "-${NODE_PID}" 2>/dev/null || kill -KILL "$NODE_PID" 2>/dev/null || true
    fi
    [[ -n "${HASHHOG_KEEP_SCRATCH:-}" ]] || rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── RPC helper (no cookie auth on lunarblock regtest; explicit URL). ───────
# usage: rpc <url> <method> <params-json>
rpc() {
    local url="$1" method="$2" params="${3:-[]}"
    curl -s --max-time 120 -X POST "$url" \
        -H 'content-type: application/json' \
        --data "{\"jsonrpc\":\"1.0\",\"id\":\"wo\",\"method\":\"${method}\",\"params\":${params}}" 2>/dev/null
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    boot_gap "port ${RPC_PORT}/${P2P_PORT} already LISTENING (refusing to kill: fuser-on-ephemeral-port killed mainnet nodes, 2026-06-10 incident)"
fi
sleep 0.5
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
command -v luajit >/dev/null 2>&1 || boot_gap "luajit not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]] || boot_gap "lunarblock src/main.lua not found at $LB_DIR"
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

# ── 3. Launch lunarblock on regtest (smoke-harness recipe). ────────────────
log "launching lunarblock regtest node -> $LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$DATADIR' \
    --port '$P2P_PORT' --rpcport '$RPC_PORT' --nov2transport" \
    >"$LOG" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"
up=0
for _ in $(seq 1 90); do
    if ! kill -0 "$NODE_PID" 2>/dev/null; then
        tail -20 "$LOG" >&2 || true
        boot_gap "node exited before RPC came up (see $LOG)"
    fi
    resp="$(rpc "$RPC_URL" getblockchaininfo '[]' || true)"
    if echo "$resp" | grep -q '"chain":[[:space:]]*"regtest"'; then up=1; break; fi
    sleep 0.5
done
[[ "$up" == 1 ]] || boot_gap "RPC never reported chain=regtest within timeout"
log "RPC up (chain=regtest)"

# ── 4. Funding wallet w1 (importmnemonic model) + PRE-IMPORT funding. ──────
r=$(rpc "$RPC_URL" importmnemonic "[\"$MNEMONIC\",\"\",\"w1\"]")
echo "$r" | grep -q '"w1"' || log "note: importmnemonic w1 did not confirm: $(echo "$r" | head -c 160)"
for spec in "1 $A_ADDR" "1 $B_ADDR" "1 $W_ADDR" "101 $M_ADDR"; do
    n=${spec%% *}; ad=${spec#* }
    r=$(rpc "$RPC_URL/wallet/w1" generatetoaddress "[$n,\"$ad\"]")
    echo "$r" | grep -q '"error":{' && fail "generatetoaddress $n->$ad errored: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
done
H=$(rpc "$RPC_URL" getblockcount '[]' | grep -o '"result":[0-9]*' | head -1 | sed 's/"result"://')
[[ "${H:-0}" -eq 104 ]] || fail "tip height ${H:-?} != 104 after pre-import funding"
log "pre-import funding done at tip $H"

# ── 5. The Core-faithful watch-only sequence (shared engine). ──────────────
# No cookie files exist on lunarblock regtest -> checker sends no auth.
OUT=$(python3 "$WO_LIB" check --impl lunarblock \
    --base-url "$RPC_URL" \
    --cookie "$DATADIR/.cookie" --cookie "$DATADIR/regtest/.cookie" \
    --routing path --keys "$KEYS" \
    --watch-wallet wo --fallback-wallet w1 --timeout 120)
rc=$?
[[ -n "$OUT" ]] || fail "checker produced no verdict line (rc=$rc)"
echo "WATCHONLY lunarblock: $OUT"
exit $rc
