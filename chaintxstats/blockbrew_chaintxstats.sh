#!/usr/bin/env bash
#
# blockbrew_chaintxstats.sh — self-contained getchaintxstats Core-parity test.
#
# The first RPC-surface green-cell after the wallet + mempool-policy chapters.
# Read-only chain statistics — NOT consensus, but byte-exact-shaped against
# Bitcoin Core (bitcoin-core/src/rpc/blockchain.cpp getchaintxstats).
#
# WHAT IT PROVES
#   getchaintxstats on blockbrew returns the SAME count/height/shape fields
#   Bitcoin Core returns for an IDENTICAL chain shape, and honours the same
#   optional-field emit conditions + error codes.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (own scratch datadir + ports). Both nodes mine the SAME number of
#   EMPTY blocks (only a coinbase each) to the SAME fixed-key p2wpkh address, so
#   the chain shape is identical: txcount == height+1, and the window tx count
#   equals the window block count. We assert those COUNT/HEIGHT fields EXACTLY:
#       - txcount                    (cumulative #txs genesis..tip)
#       - window_tx_count            (txcount(tip) - txcount(tip-nblocks))
#       - window_block_count         (the resolved window size)
#       - window_final_block_height  (tip height)
#   and the SHAPE of window_final_block_hash (64-hex, == the tip hash).
#
#   Time-dependent fields differ between two independent regtest nodes (each
#   stamps its own wall-clock nTime), so we DON'T assert equality on them —
#   only PRESENCE + type + the Core emit-condition rules:
#       - "time"          present, an int, == the tip's RAW header nTime (we
#                         cross-check against getblockheader.time, not mediantime)
#       - "window_interval" present + an int + >= 0 when window_block_count > 0
#       - "txrate"        present when window_block_count > 0 and interval > 0
#       - nblocks=0 DROPS window_interval / window_tx_count / txrate entirely.
#
#   We also assert the two Core error codes are matched:
#       - unknown blockhash  -> -5  (RPC_INVALID_ADDRESS_OR_KEY, "Block not found")
#       - nblocks >= height  -> -8  (RPC_INVALID_PARAMETER, invalid block count)
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/blockbrew_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: CHAINTXSTATS blockbrew: PASS txcount=ok window=ok shape=ok nblocks0=ok
#   FAIL: CHAINTXSTATS blockbrew: FAIL <short reason>
#
# Touches ONLY /tmp/ctxstats-blockbrew/ + /tmp/ctxstats-core-bb/ and ports
#   21893/21913 (blockbrew RPC/P2P), 21895/21915 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # for key_to_p2wpkh helper

BB_DATADIR="/tmp/ctxstats-blockbrew"
BB_RPC=21893
BB_P2P=21913
BB_LOG="$BB_DATADIR/node.log"
BB_URL="http://127.0.0.1:${BB_RPC}"
BB_COOKIE_FILE="$BB_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/ctxstats-core-bb"
CORE_RPC=21895
CORE_P2P=21915
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one fixed p2wpkh mining address used on BOTH
# nodes, so the chain shapes are identical (empty blocks, 1 coinbase each).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS_MINE=120     # mine this many blocks on each node
NBLOCKS_WIN=30       # the window size we cross-assert exactly

BB_PID=""
BB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[chaintxstats:blockbrew] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BB_PID" ]] && kill -0 "$BB_PID" 2>/dev/null; then
        kill "$BB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "CHAINTXSTATS blockbrew: PASS txcount=ok window=ok shape=ok nblocks0=ok"
    exit 0
}
fail() {
    echo "CHAINTXSTATS blockbrew: FAIL $*"
    exit 1
}

# ── JSON field extractor (jq-free; stdlib python3). ───────────────────────
# jget <json> <path...> : path is a sequence of keys into result; prints the
# value or the literal "<MISSING>" if any key is absent. Used to assert both
# presence and value.
jget() {
    local js="$1"; shift
    python3 - "$js" "$@" <<'PY'
import sys, json
js = sys.argv[1]
keys = sys.argv[2:]
try:
    d = json.loads(js)
except Exception:
    print("<PARSE-ERR>"); sys.exit(0)
cur = d
for k in keys:
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        print("<MISSING>"); sys.exit(0)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("<NULL>")
else:
    print(cur)
PY
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
if ss -tln 2>/dev/null | grep -qE ":(${BB_RPC}|${BB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BB_RPC}/${BB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "blockbrew binary not found at $NODE_BIN (run build-all.sh blockbrew)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive the shared fixed-key p2wpkh mining address. ─────────────────
MINE_ADDR=$(python3 - "$TF_PATH" "$SECRET" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
priv = ECKey(); priv.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(priv.get_pubkey().get_bytes(), main=False))
PY
)
[[ -n "$MINE_ADDR" ]] || fail "failed to derive p2wpkh mining address from test_framework"
log "shared mining address: $MINE_ADDR"

# ── 3. Launch the Core oracle on regtest. ─────────────────────────────────
log "launching Core oracle rpc=:$CORE_RPC"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < core_deadline )); do
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
    || fail "Core oracle RPC never responded within 60s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch blockbrew on regtest (isolated: no peers). ──────────────────
log "launching blockbrew (regtest) rpc=:$BB_RPC p2p=:$BB_P2P -> $BB_LOG"
# -metricsport=0 disables the Prometheus listener, which otherwise binds the
# fixed 0.0.0.0:9332 and would COLLIDE with the live mainnet blockbrew's
# metrics port (we must never touch the live fleet).
"$NODE_BIN" \
    -network=regtest -datadir="$BB_DATADIR" \
    -listen="127.0.0.1:${BB_P2P}" -rpcbind="127.0.0.1:${BB_RPC}" \
    -maxoutbound=0 -nolisten -metricsport=0 \
    >"$BB_LOG" 2>&1 &
BB_PID=$!
log "blockbrew pid=$BB_PID"
bb_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < bb_deadline )); do
    if [[ -z "$BB_COOKIE" && -f "$BB_COOKIE_FILE" ]]; then
        BB_COOKIE=$(cat "$BB_COOKIE_FILE")
    fi
    if [[ -n "$BB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "$BB_URL/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BB_PID" 2>/dev/null || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew exited during startup (see $BB_LOG)"; }
    sleep 1
done
[[ -n "$BB_COOKIE" ]] || fail "blockbrew cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$BB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$BB_URL/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "blockbrew RPC never responded within 60s"
log "blockbrew RPC ready"

# ── blockbrew RPC helper. ─────────────────────────────────────────────────
bb_rpc() {  # bb_rpc <method> <params-json> ; prints raw JSON-RPC envelope
    curl -s --max-time 90 -u "$BB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "$BB_URL/" 2>/dev/null
}
core_rpc() {  # core_rpc <method> <params...> ; prints the bare result (cli)
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>&1
}

# ── 5. Mine the SAME number of empty blocks on BOTH nodes. ────────────────
log "mining $NBLOCKS_MINE blocks on Core"
core_rpc generatetoaddress "$NBLOCKS_MINE" "$MINE_ADDR" >/dev/null 2>&1
CORE_H=$(core_rpc getblockcount)
[[ "$CORE_H" == "$NBLOCKS_MINE" ]] || fail "Core height $CORE_H != expected $NBLOCKS_MINE"

log "mining $NBLOCKS_MINE blocks on blockbrew"
bb_rpc generatetoaddress "[$NBLOCKS_MINE,\"$MINE_ADDR\"]" >/dev/null 2>&1
BB_H_ENV=$(bb_rpc getblockcount "[]")
BB_H=$(jget "$BB_H_ENV" result)
[[ "$BB_H" == "$NBLOCKS_MINE" ]] || fail "blockbrew height $BB_H != expected $NBLOCKS_MINE (env=$BB_H_ENV)"
log "both nodes at height $NBLOCKS_MINE"

# ── 6. getchaintxstats <NBLOCKS_WIN> on both, against the tip. ────────────
CORE_TIP=$(core_rpc getbestblockhash)
BB_TIP=$(jget "$(bb_rpc getbestblockhash "[]")" result)

CORE_STATS=$(core_rpc getchaintxstats "$NBLOCKS_WIN" "$CORE_TIP")
BB_STATS_ENV=$(bb_rpc getchaintxstats "[$NBLOCKS_WIN,\"$BB_TIP\"]")
# bb returns an envelope {result:{...}}; lift to the result object for jget.
BB_ERR=$(jget "$BB_STATS_ENV" error)
[[ "$BB_ERR" == "<NULL>" || "$BB_ERR" == "<MISSING>" ]] || fail "blockbrew getchaintxstats returned error: $BB_ERR (env=$BB_STATS_ENV)"
BB_STATS=$(python3 - "$BB_STATS_ENV" <<'PY'
import sys, json
print(json.dumps(json.loads(sys.argv[1])["result"]))
PY
)

log "CORE  stats: $CORE_STATS"
log "BBREW stats: $BB_STATS"

# Helper: extract a top-level field from a getchaintxstats RESULT object.
cf() { jget "$CORE_STATS" "$1"; }   # core field
bf() { jget "$BB_STATS"   "$1"; }   # blockbrew field

# ── 7a. EXACT count/height assertions (identical chain shape). ────────────
# txcount = height+1 (genesis + one coinbase per empty block).
EXP_TXCOUNT=$(( NBLOCKS_MINE + 1 ))
C_TXCOUNT=$(cf txcount); B_TXCOUNT=$(bf txcount)
[[ "$C_TXCOUNT" == "$EXP_TXCOUNT" ]] || fail "Core txcount=$C_TXCOUNT != expected $EXP_TXCOUNT (oracle sanity)"
[[ "$B_TXCOUNT" == "$EXP_TXCOUNT" ]] || fail "blockbrew txcount=$B_TXCOUNT != Core/expected $EXP_TXCOUNT"
[[ "$B_TXCOUNT" == "$C_TXCOUNT"   ]] || fail "txcount mismatch: blockbrew=$B_TXCOUNT core=$C_TXCOUNT"

# window_tx_count = NBLOCKS_WIN (one coinbase per block in the window).
C_WTX=$(cf window_tx_count); B_WTX=$(bf window_tx_count)
[[ "$C_WTX" == "$NBLOCKS_WIN" ]] || fail "Core window_tx_count=$C_WTX != expected $NBLOCKS_WIN (oracle sanity)"
[[ "$B_WTX" == "$NBLOCKS_WIN" ]] || fail "blockbrew window_tx_count=$B_WTX != Core/expected $NBLOCKS_WIN"
[[ "$B_WTX" == "$C_WTX"       ]] || fail "window_tx_count mismatch: blockbrew=$B_WTX core=$C_WTX"

# window_block_count = NBLOCKS_WIN.
C_WBC=$(cf window_block_count); B_WBC=$(bf window_block_count)
[[ "$B_WBC" == "$NBLOCKS_WIN" && "$C_WBC" == "$NBLOCKS_WIN" ]] \
    || fail "window_block_count mismatch: blockbrew=$B_WBC core=$C_WBC expected=$NBLOCKS_WIN"

# window_final_block_height = tip height.
C_WFH=$(cf window_final_block_height); B_WFH=$(bf window_final_block_height)
[[ "$B_WFH" == "$NBLOCKS_MINE" && "$C_WFH" == "$NBLOCKS_MINE" ]] \
    || fail "window_final_block_height mismatch: blockbrew=$B_WFH core=$C_WFH expected=$NBLOCKS_MINE"
log "txcount/window count+height exact-match OK (txcount=$B_TXCOUNT window_tx=$B_WTX block_count=$B_WBC height=$B_WFH)"

# ── 7b. SHAPE assertions for window_final_block_hash. ─────────────────────
# 64 lowercase hex chars, AND == the node's own tip hash (we don't compare the
# two nodes' hashes — they may differ; we compare each node to ITS OWN tip).
B_WFBH=$(bf window_final_block_hash)
[[ "$B_WFBH" =~ ^[0-9a-f]{64}$ ]] || fail "blockbrew window_final_block_hash not 64-hex: '$B_WFBH'"
[[ "$B_WFBH" == "$BB_TIP" ]]      || fail "blockbrew window_final_block_hash=$B_WFBH != its tip $BB_TIP"
C_WFBH=$(cf window_final_block_hash)
[[ "$C_WFBH" =~ ^[0-9a-f]{64}$ ]] || fail "Core window_final_block_hash not 64-hex: '$C_WFBH' (oracle sanity)"
log "window_final_block_hash shape OK (64-hex, == own tip)"

# ── 7c. PRESENCE + type + emit-condition for time-dependent fields. ───────
# "time" == the tip's RAW header nTime (cross-checked against getblockheader.time,
# NOT mediantime). This is the Core semantic most likely to be wrong.
B_TIME=$(bf time)
[[ "$B_TIME" =~ ^[0-9]+$ ]] || fail "blockbrew 'time' missing/non-int: '$B_TIME'"
BB_HDR=$(bb_rpc getblockheader "[\"$BB_TIP\",true]")
BB_HDR_TIME=$(jget "$BB_HDR" result time)
BB_HDR_MTP=$(jget "$BB_HDR" result mediantime)
[[ "$B_TIME" == "$BB_HDR_TIME" ]] \
    || fail "blockbrew 'time'=$B_TIME != tip RAW header nTime=$BB_HDR_TIME (must be raw nTime, not MTP=$BB_HDR_MTP)"
if [[ "$BB_HDR_TIME" != "$BB_HDR_MTP" && "$B_TIME" == "$BB_HDR_MTP" ]]; then
    fail "blockbrew 'time' equals mediantime ($BB_HDR_MTP) not raw nTime ($BB_HDR_TIME) — wrong Core semantic"
fi
log "'time' == raw header nTime OK (time=$B_TIME nTime=$BB_HDR_TIME mtp=$BB_HDR_MTP)"

# "window_interval" present, int, >= 0 when window_block_count > 0.
B_WI=$(bf window_interval)
[[ "$B_WI" =~ ^[0-9]+$ ]] || fail "blockbrew window_interval missing/non-int with window>0: '$B_WI'"
(( B_WI >= 0 )) || fail "blockbrew window_interval negative: $B_WI"

# "txrate" present (window>0 and interval>0 on a 120-block regtest chain).
B_TR=$(bf txrate)
[[ "$B_TR" != "<MISSING>" && "$B_TR" != "<NULL>" ]] \
    || fail "blockbrew txrate missing with window>0 and interval=$B_WI>0"
# numeric (int or float)
[[ "$B_TR" =~ ^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] || fail "blockbrew txrate non-numeric: '$B_TR'"
log "window_interval + txrate present/typed OK (interval=$B_WI txrate=$B_TR)"

# ── 7d. nblocks=0 DROPS window_interval / window_tx_count / txrate. ───────
BB_ZERO_ENV=$(bb_rpc getchaintxstats "[0]")
BB_ZERO=$(python3 - "$BB_ZERO_ENV" <<'PY'
import sys, json
d = json.loads(sys.argv[1])
if d.get("error"):
    print("ERR:" + json.dumps(d["error"])); raise SystemExit
print(json.dumps(d["result"]))
PY
)
[[ "$BB_ZERO" == ERR:* ]] && fail "blockbrew getchaintxstats 0 errored: ${BB_ZERO#ERR:}"
for drop in window_interval window_tx_count txrate; do
    v=$(jget "$BB_ZERO" "$drop")
    [[ "$v" == "<MISSING>" ]] || fail "blockbrew nblocks=0 must DROP '$drop' but it is present: $v"
done
# window_block_count must still be present and == 0; time/txcount/hash/height present.
Z_WBC=$(jget "$BB_ZERO" window_block_count)
[[ "$Z_WBC" == "0" ]] || fail "blockbrew nblocks=0 window_block_count=$Z_WBC != 0"
for keep in time txcount window_final_block_hash window_final_block_height; do
    v=$(jget "$BB_ZERO" "$keep")
    [[ "$v" != "<MISSING>" ]] || fail "blockbrew nblocks=0 dropped required field '$keep'"
done
# Cross-check Core also drops them at nblocks=0.
CORE_ZERO=$(core_rpc getchaintxstats 0)
for drop in window_interval window_tx_count txrate; do
    v=$(jget "$CORE_ZERO" "$drop")
    [[ "$v" == "<MISSING>" ]] || fail "Core nblocks=0 unexpectedly has '$drop' (oracle sanity): $v"
done
log "nblocks=0 emit-conditions OK (3 window extras dropped, base fields kept)"

# ── 7e. Error codes match Core: -5 unknown hash, -8 nblocks>=height. ──────
# unknown blockhash -> -5
BB_E5=$(bb_rpc getchaintxstats "[1,\"0000000000000000000000000000000000000000000000000000000000000abc\"]")
E5_CODE=$(jget "$BB_E5" error code)
[[ "$E5_CODE" == "-5" ]] || fail "blockbrew unknown-blockhash error code=$E5_CODE != -5 (env=$BB_E5)"
# nblocks >= height -> -8
BB_E8=$(bb_rpc getchaintxstats "[$(( NBLOCKS_MINE + 50 ))]")
E8_CODE=$(jget "$BB_E8" error code)
[[ "$E8_CODE" == "-8" ]] || fail "blockbrew nblocks-too-big error code=$E8_CODE != -8 (env=$BB_E8)"
# negative nblocks -> -8
BB_ENEG=$(bb_rpc getchaintxstats "[-1]")
ENEG_CODE=$(jget "$BB_ENEG" error code)
[[ "$ENEG_CODE" == "-8" ]] || fail "blockbrew negative-nblocks error code=$ENEG_CODE != -8 (env=$BB_ENEG)"
log "error codes OK (-5 unknown hash, -8 nblocks>=height, -8 negative)"

# ── 8. All green. ─────────────────────────────────────────────────────────
log "PASS: txcount + window counts/height EXACT-match Core; hash+time shapes Core-correct; nblocks=0 drops window extras; error codes match"
pass
