#!/usr/bin/env bash
#
# haskoin_chaintxstats.sh — self-contained getchaintxstats Core-parity test.
#
# Mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh: the getchaintxstats
# RPC is READ-ONLY chain statistics, NOT consensus, but must match Bitcoin Core
# EXACTLY for a given chain shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:1809-1898 (getchaintxstats).
#   - "time"                      = the FINAL block's RAW header nTime.
#   - "txcount"                   = cumulative #txs genesis..pindex.
#   - "window_final_block_hash"   = pindex block hash (64-hex).
#   - "window_final_block_height" = pindex height.
#   - "window_block_count"        = the resolved window size.
#   - "window_interval"           = MTP(pindex) - MTP(ancestor) [11-block MTP],
#                                   emitted ONLY when window_block_count > 0.
#   - "window_tx_count"           = txcount(pindex) - txcount(pindex-nblocks),
#                                   emitted ONLY when window_block_count > 0.
#   - "txrate"                    = window_tx_count / window_interval,
#                                   emitted ONLY when window_interval > 0.
#   ERROR CODES: -5 "Block not found"; -8 invalid/out-of-range count.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + ports. Both nodes mine the SAME number of EMPTY blocks
#   to the SAME deterministic p2wpkh address — identical chain SHAPE (every
#   block = 1 coinbase tx, so txcount = height+1 and window_tx_count = nblocks).
#   Count/height/shape fields are asserted EXACTLY against Core; the
#   time-dependent fields (time / window_interval / txrate) are asserted
#   PRESENT + correctly-typed + emit-condition-correct, NOT byte-equal.
#
# Summary line (stdout):
#   PASS: CHAINTXSTATS haskoin: PASS txcount=ok window=ok shape=ok nblocks0=ok
#   FAIL: CHAINTXSTATS haskoin: FAIL <short reason>
#
# Touches ONLY /tmp/hk-chaintxstats/ + /tmp/hk-chaintxstats-core/ and ports
#   22790/22810 (haskoin RPC/P2P) + 22792/22812 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$(find "$BASEDIR/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

export haskoin_datadir="$BASEDIR/haskoin"   # BIP-39 wordlist resolution at runtime

HK_DATADIR="/tmp/hk-chaintxstats"
HK_RPC=22790
HK_P2P=22810
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""

CORE_DATADIR="/tmp/hk-chaintxstats-core"
CORE_RPC=22792
CORE_P2P=22812
CORE_LOG="$CORE_DATADIR/core.log"

SECRET="1111111111111111111111111111111111111111111111111111111111111112"
NBLOCKS=120        # mine 120 empty blocks -> txcount = 121, window(10) tx = 10
WINDOW=10

HK_PID=""
CORE_BG=""
ADDR=""

log() { echo "[chaintxstats:haskoin] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$HK_PID" ]] && kill -0 "$HK_PID" 2>/dev/null; then
        kill "$HK_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HK_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HK_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$HK_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "CHAINTXSTATS haskoin: PASS txcount=$1 window=$2 shape=$3 nblocks0=$4"
    exit 0
}
fail() {
    echo "CHAINTXSTATS haskoin: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "hk-chaintxstats" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HK_RPC}/${HK_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$HK_DATADIR" "$CORE_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "haskoin binary not found (build with: cabal build exe:haskoin)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive the deterministic bcrt1 p2wpkh mining address. ──────────────
ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic mining address (Core test_framework import failed)"
[[ "$ADDR" == bcrt1* ]] || fail "derived address is not a regtest bech32 address: '$ADDR'"
log "deterministic mining address: $ADDR"

# ── JSON-RPC helpers. ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}
hk_rpc() {
    curl -s --max-time 90 -u "$HK_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HK_RPC/" 2>/dev/null
}
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 3. Launch the Core regtest oracle (-listen=0). ────────────────────────
launch_core_once() {
    # PID-scoped stop of OUR previous attempt (port-kill removed: 2026-06-10 fuser incident).
    if [[ -n "${CORE_BG:-}" ]]; then
        kill "$CORE_BG" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CORE_BG" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_BG" 2>/dev/null || true
    fi
    for __hp in "${CORE_RPC}" "${CORE_P2P}"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            core_cli_retry getblockcount >/dev/null && return 0
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch haskoin on regtest (--listen False, RPC-only). ──────────────
log "launching haskoin (regtest) rpc=:$HK_RPC p2p=:$HK_P2P -> $HK_LOG"
"$NODE_BIN" --network Regtest --datadir "$HK_DATADIR" node \
    --rpcport "$HK_RPC" --port "$HK_P2P" --listen False --metricsport 0 \
    >"$HK_LOG" 2>&1 &
HK_PID=$!
hk_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        echo "$(hk_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$HK_PID" 2>/dev/null || { tail -n 30 "$HK_LOG" >&2 2>/dev/null || true; fail "haskoin exited during startup (see $HK_LOG)"; }
    sleep 1
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 90s"
echo "$(hk_rpc getblockcount '[]')" | grep -q '"result"' || fail "haskoin RPC never responded within 90s"
log "haskoin RPC ready"

# ── 5. Mine NBLOCKS empty blocks to the SAME address on BOTH nodes. ───────
log "mining $NBLOCKS empty blocks to $ADDR on Core"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $NBLOCKS"

log "mining $NBLOCKS empty blocks to $ADDR on haskoin"
GEN_OUT=$(hk_rpc generatetoaddress "[$NBLOCKS, \"$ADDR\"]")
echo "$GEN_OUT" | grep -q '"result"' || fail "haskoin generatetoaddress failed: $GEN_OUT"
HK_HEIGHT=$(jpy "$(hk_rpc getblockcount '[]')" "d['result']")
[[ "$HK_HEIGHT" == "$NBLOCKS" ]] || fail "haskoin height after mining is $HK_HEIGHT, expected $NBLOCKS"

# ── 6. Query getchaintxstats <WINDOW> <tip> on BOTH. ──────────────────────
CORE_TIP=$(core_cli_retry getbestblockhash)
HK_TIP=$(jpy "$(hk_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$CORE_TIP" && -n "$HK_TIP" ]] || fail "could not read both tip hashes (core='$CORE_TIP' hk='$HK_TIP')"

CORE_STATS=$(core_cli_retry getchaintxstats "$WINDOW" "$CORE_TIP")
[[ -n "$CORE_STATS" ]] || fail "Core getchaintxstats produced no output"
HK_STATS_ENV=$(hk_rpc getchaintxstats "[$WINDOW, \"$HK_TIP\"]")
echo "$HK_STATS_ENV" | grep -q '"result"' || fail "haskoin getchaintxstats errored: $HK_STATS_ENV"
HK_STATS=$(jpy "$HK_STATS_ENV" "json.dumps(d['result'])")
[[ -n "$HK_STATS" ]] || fail "haskoin getchaintxstats result empty"

log "Core    stats: $CORE_STATS"
log "haskoin stats: $HK_STATS"

c() { jpy "$CORE_STATS" "d.get('$1')"; }
r() { jpy "$HK_STATS"   "d.get('$1')"; }

# ── 7. EXACT count/height matches against Core. ───────────────────────────
C_TXCOUNT=$(c txcount);        R_TXCOUNT=$(r txcount)
C_WTX=$(c window_tx_count);    R_WTX=$(r window_tx_count)
C_WBC=$(c window_block_count); R_WBC=$(r window_block_count)
C_WFH=$(c window_final_block_height); R_WFH=$(r window_final_block_height)

EXP_TXCOUNT=$(( NBLOCKS + 1 ))
[[ "$C_TXCOUNT" == "$EXP_TXCOUNT" ]] || fail "Core txcount=$C_TXCOUNT != expected $EXP_TXCOUNT (oracle/chain-shape unexpected)"
[[ "$C_WTX"     == "$WINDOW"      ]] || fail "Core window_tx_count=$C_WTX != expected $WINDOW (oracle/chain-shape unexpected)"

TXCOUNT_T="ok"; WINDOW_T="ok"
[[ "$R_TXCOUNT" == "$C_TXCOUNT" ]] || TXCOUNT_T="bad"
[[ "$R_WTX"  == "$C_WTX"  ]] || WINDOW_T="bad"
[[ "$R_WBC"  == "$C_WBC"  ]] || WINDOW_T="bad"
[[ "$R_WFH"  == "$C_WFH"  ]] || WINDOW_T="bad"

if [[ "$TXCOUNT_T" != "ok" ]]; then
    fail "txcount mismatch vs Core: haskoin=$R_TXCOUNT core=$C_TXCOUNT (expected $EXP_TXCOUNT)"
fi
if [[ "$WINDOW_T" != "ok" ]]; then
    fail "window-count fields mismatch vs Core: tx(r=$R_WTX,c=$C_WTX) block_count(r=$R_WBC,c=$C_WBC) final_height(r=$R_WFH,c=$C_WFH)"
fi

# ── 8. SHAPE checks: final_block_hash 64-hex; time-dependent fields present + typed. ─
SHAPE_T="ok"
R_HASH=$(r window_final_block_hash)
[[ "$R_HASH" =~ ^[0-9a-f]{64}$ ]] || { SHAPE_T="bad"; log "window_final_block_hash not 64-hex: '$R_HASH'"; }

R_TIME=$(r time)
if ! [[ "$R_TIME" =~ ^[0-9]+$ ]] || [[ "$R_TIME" -le 0 ]]; then
    SHAPE_T="bad"; log "time absent/non-integer/non-positive: '$R_TIME'"
fi

R_WINT=$(r window_interval)
if ! [[ "$R_WINT" =~ ^-?[0-9]+$ ]] || [[ "$R_WINT" -lt 0 ]]; then
    SHAPE_T="bad"; log "window_interval absent/non-integer/negative (window>0): '$R_WINT'"
fi

R_RATE=$(r txrate)
if [[ "$R_WINT" =~ ^[0-9]+$ ]] && [[ "$R_WINT" -gt 0 ]]; then
    if ! [[ "$R_RATE" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
        SHAPE_T="bad"; log "txrate absent/non-numeric while window_interval>0: '$R_RATE'"
    fi
else
    [[ -z "$R_RATE" ]] || { SHAPE_T="bad"; log "txrate present despite window_interval==0: '$R_RATE'"; }
fi

[[ "$SHAPE_T" == "ok" ]] || fail "shape/type/emit-condition check failed (see log)"

# ── 9. EMIT-CONDITION: nblocks=0 drops the 3 window extras. ───────────────
NBLOCKS0_T="ok"
HK0_ENV=$(hk_rpc getchaintxstats "[0, \"$HK_TIP\"]")
echo "$HK0_ENV" | grep -q '"result"' || fail "haskoin getchaintxstats 0 errored: $HK0_ENV"
HK0=$(jpy "$HK0_ENV" "json.dumps(d['result'])")
HAS_EXTRAS=$(jpy "$HK0" "any(k in d for k in ('window_interval','window_tx_count','txrate'))")
[[ "$HAS_EXTRAS" == "false" ]] || { NBLOCKS0_T="bad"; log "nblocks=0 did NOT drop window extras: $HK0"; }
HK0_WBC=$(jpy "$HK0" "d.get('window_block_count')")
[[ "$HK0_WBC" == "0" ]] || { NBLOCKS0_T="bad"; log "nblocks=0 window_block_count != 0: '$HK0_WBC'"; }
HK0_TXC=$(jpy "$HK0" "d.get('txcount')")
[[ "$HK0_TXC" == "$EXP_TXCOUNT" ]] || { NBLOCKS0_T="bad"; log "nblocks=0 txcount wrong: '$HK0_TXC'"; }
[[ "$NBLOCKS0_T" == "ok" ]] || fail "nblocks=0 emit-condition check failed (see log)"

# ── 10. ERROR-CODE parity: -5 (block not found), -8 (invalid count). ──────
ERR_BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(jpy "$(hk_rpc getchaintxstats "[10, \"$ERR_BAD_HASH\"]")" "d['error']['code']")
[[ "$E5" == "-5" ]] || fail "expected error -5 (Block not found) for unknown blockhash, got '$E5'"
BIG=$(( NBLOCKS + 10 ))
E8=$(jpy "$(hk_rpc getchaintxstats "[$BIG, \"$HK_TIP\"]")" "d['error']['code']")
[[ "$E8" == "-8" ]] || fail "expected error -8 (Invalid block count) for out-of-range nblocks, got '$E8'"
E8N=$(jpy "$(hk_rpc getchaintxstats "[-1, \"$HK_TIP\"]")" "d['error']['code']")
[[ "$E8N" == "-8" ]] || fail "expected error -8 (Invalid block count) for negative nblocks, got '$E8N'"

log "PASS: haskoin getchaintxstats matches Core on count/height/shape + emit-conditions + error codes"
pass "$TXCOUNT_T" "$WINDOW_T" "$SHAPE_T" "$NBLOCKS0_T"
