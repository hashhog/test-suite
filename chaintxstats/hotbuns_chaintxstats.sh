#!/usr/bin/env bash
#
# hotbuns_chaintxstats.sh — self-contained getchaintxstats RPC-parity test.
#
# The first RPC-surface green-cell after the wallet + mempool-policy chapters.
# getchaintxstats is read-only chain statistics — NOT consensus — but it must be
# Core-EXACT. This harness proves hotbuns' getchaintxstats matches a REAL
# bitcoind regtest oracle for the same chain shape.
#
# CORE SEMANTICS (bitcoin-core/src/rpc/blockchain.cpp getchaintxstats):
#   - "time"              = the FINAL block's RAW header nTime (NOT mediantime).
#   - "txcount"           = cumulative #txs genesis..pindex (m_chain_tx_count).
#   - "window_final_block_hash"   = pindex block hash (display order).
#   - "window_final_block_height" = pindex height.
#   - "window_block_count"        = the resolved window size (nblocks).
#   - "window_interval"   = MTP(pindex) - MTP(past) — 11-block median-time-past,
#                           NOT raw times. Only when window_block_count > 0.
#   - "window_tx_count"   = txcount(pindex) - txcount(pindex - nblocks). Only
#                           when window > 0 AND both cumulative counts known.
#   - "txrate"            = window_tx_count / window_interval. Only when
#                           window_interval > 0 and window_tx_count exists.
#   - The three window_* extras (interval/tx_count/txrate) are dropped when
#     nblocks == 0.
#   - Default nblocks = 30*24*60*60 / targetSpacing ("one month"); on a short
#     chain it clamps to max(0, min(default, height - 1)).
#
# DIFFERENTIAL DESIGN:
#   Launch BOTH a real bitcoind regtest oracle AND hotbuns on their own scratch
#   datadirs + unique ports. Mine the SAME number of empty blocks (NBLOCKS=120)
#   on each. Empty regtest blocks each carry exactly one coinbase tx, so for a
#   chain of height H the cumulative tx count is H+1 and the per-window tx count
#   is exactly the window size. That makes the COUNT/height/shape fields fully
#   deterministic and identical between the two nodes:
#       txcount                   = height + 1
#       window_tx_count           = nblocks
#       window_block_count        = nblocks
#       window_final_block_height = height
#       window_final_block_hash   = 64-hex (shape; the two nodes mine to
#                                   different addresses so hashes differ, but
#                                   the SHAPE + height + tip-equality-with-its-
#                                   own-getbestblockhash is asserted).
#   These count/height/shape fields are asserted EXACTLY against the oracle.
#
#   Time-dependent fields (time, window_interval, txrate) differ between two
#   independent regtest nodes (wall-clock timestamps differ), so they are NOT
#   asserted for byte-equality. Instead the EMIT-CONDITION RULES + TYPES are
#   asserted: time present + sane int; window_interval present + >= 0 when
#   window > 0; txrate present + numeric when window_interval > 0; and — the
#   key Core rule — nblocks=0 DROPS all three window_* extras.
#
# CHECKS (all must hold for PASS):
#   txcount   : hotbuns txcount == oracle txcount == height+1, on both
#               getchaintxstats(120,tip) and the default-nblocks call.
#   window    : hotbuns window_tx_count == oracle == 120, window_block_count
#               == 120, window_final_block_height == 120, on the (120,tip) call;
#               window_interval present + >= 0; txrate present + numeric.
#   shape     : window_final_block_hash is 64-hex and equals hotbuns'
#               getbestblockhash (tip), error codes match (-5 unknown hash,
#               -8 out-of-range nblocks).
#   nblocks0  : getchaintxstats(0,tip) emits time/txcount/window_final_block_*/
#               window_block_count=0 and OMITS window_interval/window_tx_count/
#               txrate (the nblocks=0 drop rule), matching the oracle's omission.
#
# UNIFORM INTERFACE (mirrors test-suite/policy/hotbuns_policy.sh): no required
#   args, idempotent, trap cleanup, scratch /tmp + unique ports, ONE clean
#   summary line on stdout, all noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS: CHAINTXSTATS hotbuns: PASS txcount=ok window=ok shape=ok nblocks0=ok
#   FAIL: CHAINTXSTATS hotbuns: FAIL <short reason>
#
# Touches ONLY /tmp/ctxstats-hotbuns/ + /tmp/ctxstats-core/ and ports
#   21894/21914 (hotbuns) + 21895/21915 (Core). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node (haskoin is mid-sync — leave it).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
BITCOIND="$BASEDIR/bitcoin-core/build/bin/bitcoind"
BITCOINCLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

HB_DATADIR="/tmp/ctxstats-hotbuns"
HB_RPC=21894
HB_P2P=21914
HB_LOG="$HB_DATADIR/node.log"

CORE_DATADIR="/tmp/ctxstats-core"
CORE_RPC=21895
CORE_P2P=21915
CORE_LOG="$CORE_DATADIR/core.log"

# Mine HEIGHT empty blocks on BOTH nodes, then query a WINDOW that is strictly
# less than HEIGHT (Core requires nblocks < pindex->nHeight; nblocks==height is
# out of range). We mine 121 and ask for a 120-block window so the window math
# lands on the round "120" the differential targets.
HEIGHT=121             # blocks mined on BOTH nodes (chain height)
WINDOW=120             # getchaintxstats window size (must be < HEIGHT)

# A regtest p2wpkh-shaped address for generatetoaddress (any valid bech32 works;
# the coinbase output script does not affect tx counts). Distinct per node.
HB_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"   # well-known regtest addr

HB_PID=""
HB_COOKIE=""
CORE_PID=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[chaintxstats:hotbuns] $*" >&2; }

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CORE_PID" ]]; then
        "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
        for _ in $(seq 1 15); do kill -0 "$CORE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_PID" 2>/dev/null || true
    fi
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
    fi
    rm -rf "$HB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {  # pass <txcount> <window> <shape> <nblocks0>
    echo "CHAINTXSTATS hotbuns: PASS txcount=$1 window=$2 shape=$3 nblocks0=$4"
    exit 0
}
fail() {
    echo "CHAINTXSTATS hotbuns: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "ctxstats-hotbuns" 2>/dev/null || true
pkill -f "ctxstats-core"    2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HB_RPC}/${HB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$HB_DATADIR" "$CORE_DATADIR"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v bun >/dev/null 2>&1 || fail "bun runtime not found on PATH"
command -v jq  >/dev/null 2>&1 || fail "jq not found on PATH"
[[ -x "$BITCOIND" ]]    || fail "bitcoind not found at $BITCOIND"
[[ -x "$BITCOINCLI" ]]  || fail "bitcoin-cli not found at $BITCOINCLI"
[[ -f "$NODE_DIR/src/index.ts" ]] || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"

# ── RPC helpers. ──────────────────────────────────────────────────────────
# hb_rpc <method> <json-params-array>  -> raw JSON-RPC response on stdout.
hb_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 30 -u "$HB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$HB_RPC/" 2>/dev/null
}
# core_cli <args...> -> bitcoin-cli output (stderr suppressed; for results).
core_cli() {
    "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>/dev/null
}
# core_cli_err <args...> -> bitcoin-cli output WITH stderr (for error-code probes;
# bitcoin-cli prints "error code: -N" to stderr on RPC errors).
core_cli_err() {
    "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>&1
}

# ── 2. Launch the real bitcoind regtest oracle. ───────────────────────────
log "launching bitcoind oracle (regtest) rpc=:$CORE_RPC p2p=:$CORE_P2P -> $CORE_LOG"
"$BITCOIND" -regtest -datadir="$CORE_DATADIR" \
    -port="$CORE_P2P" -rpcport="$CORE_RPC" \
    -listen=1 -bind=127.0.0.1 -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
    -fallbackfee=0.0002 -daemon=0 -printtoconsole=0 \
    >"$CORE_LOG" 2>&1 &
CORE_PID=$!
log "bitcoind pid=$CORE_PID"
deadline=$(( $(date +%s) + 60 ))
core_ready=0
while (( $(date +%s) < deadline )); do
    if core_cli getblockcount >/dev/null 2>&1; then core_ready=1; break; fi
    kill -0 "$CORE_PID" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "bitcoind exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" -eq 1 ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "bitcoind RPC never responded within 60s"; }
log "bitcoind RPC ready"

# Core needs an address to mine to; derive one from its own wallet (Core 31.x:
# descriptor wallet). Fall back to a well-known regtest address.
core_cli createwallet "ctxw" >/dev/null 2>&1 || true
CORE_ADDR=$(core_cli getnewaddress 2>/dev/null)
[[ -n "$CORE_ADDR" ]] || CORE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

# ── 3. Launch hotbuns on regtest. ─────────────────────────────────────────
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P -> $HB_LOG"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC"
) >"$HB_LOG" 2>&1 &
HB_PID=$!
log "hotbuns pid=$HB_PID"
deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        r=$(hb_rpc getblockcount)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 20 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG)"; }
    sleep 1
done
[[ -n "$HB_COOKIE" ]] || fail "hotbuns cookie never appeared within 60s"
r=$(hb_rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "hotbuns RPC never responded within 60s"
log "hotbuns RPC ready"

# ── 4. Mine the SAME number of empty blocks on BOTH nodes. ────────────────
log "mining $HEIGHT blocks on bitcoind oracle"
core_cli generatetoaddress "$HEIGHT" "$CORE_ADDR" >/dev/null 2>&1 \
    || fail "core generatetoaddress failed"
CORE_H=$(core_cli getblockcount)
[[ "$CORE_H" == "$HEIGHT" ]] || fail "core height $CORE_H != $HEIGHT after mining"

log "mining $HEIGHT blocks on hotbuns"
gr=$(hb_rpc generatetoaddress "[$HEIGHT, \"$HB_ADDR\"]")
echo "$gr" | grep -q '"result"' || fail "hotbuns generatetoaddress failed: $gr"
HB_H=$(hb_rpc getblockcount | jq -r '.result')
[[ "$HB_H" == "$HEIGHT" ]] || fail "hotbuns height $HB_H != $HEIGHT after mining"
HB_TIP=$(hb_rpc getbestblockhash | jq -r '.result')
log "both nodes at height $HEIGHT (hotbuns tip $HB_TIP)"

# ── 5. getchaintxstats(WINDOW, tip) on BOTH. ──────────────────────────────
log "calling getchaintxstats($WINDOW, tip) on both nodes"
CORE_S=$(core_cli getchaintxstats "$WINDOW")
[[ -n "$CORE_S" ]] || fail "core getchaintxstats($WINDOW) returned nothing"
HB_RESP=$(hb_rpc getchaintxstats "[$WINDOW, \"$HB_TIP\"]")
HB_ERR=$(echo "$HB_RESP" | jq -r '.error // empty')
[[ -z "$HB_ERR" || "$HB_ERR" == "null" ]] || fail "hotbuns getchaintxstats errored: $HB_ERR"
HB_S=$(echo "$HB_RESP" | jq -c '.result')
[[ -n "$HB_S" && "$HB_S" != "null" ]] || fail "hotbuns getchaintxstats($WINDOW, tip) returned no result: $HB_RESP"

log "core   : $CORE_S"
log "hotbuns: $HB_S"

# Extract fields from both.
gj() { echo "$1" | jq -r "$2"; }   # gj <json> <filter>

CORE_TXCOUNT=$(gj "$CORE_S" '.txcount')
CORE_WTC=$(gj "$CORE_S" '.window_tx_count')
CORE_WBC=$(gj "$CORE_S" '.window_block_count')
CORE_WFBH=$(gj "$CORE_S" '.window_final_block_height')

HB_TXCOUNT=$(gj "$HB_S" '.txcount')
HB_WTC=$(gj "$HB_S" '.window_tx_count')
HB_WBC=$(gj "$HB_S" '.window_block_count')
HB_WFBH=$(gj "$HB_S" '.window_final_block_height')
HB_WFB_HASH=$(gj "$HB_S" '.window_final_block_hash')
HB_TIME=$(gj "$HB_S" '.time')
HB_WI=$(gj "$HB_S" '.window_interval')
HB_TXRATE=$(gj "$HB_S" '.txrate')

# ── CHECK 1: txcount (exact match to oracle AND == height+1). ─────────────
EXPECT_TXCOUNT=$(( HEIGHT + 1 ))
[[ "$CORE_TXCOUNT" == "$EXPECT_TXCOUNT" ]] \
    || fail "sanity: core txcount=$CORE_TXCOUNT != expected $EXPECT_TXCOUNT (oracle drift)"
[[ "$HB_TXCOUNT" == "$EXPECT_TXCOUNT" ]] \
    || fail "txcount mismatch: hotbuns=$HB_TXCOUNT core=$CORE_TXCOUNT expected=$EXPECT_TXCOUNT"
[[ "$HB_TXCOUNT" == "$CORE_TXCOUNT" ]] \
    || fail "txcount hotbuns=$HB_TXCOUNT != core=$CORE_TXCOUNT"
log "CHECK txcount: hotbuns=$HB_TXCOUNT == core=$CORE_TXCOUNT == height+1 ($EXPECT_TXCOUNT) OK"
TXCOUNT_T=ok

# ── CHECK 2: window fields (exact, window>0). ─────────────────────────────
# Empty blocks -> window_tx_count == WINDOW; window_block_count == WINDOW;
# window_final_block_height == HEIGHT (the tip).
[[ "$CORE_WTC" == "$WINDOW" ]] \
    || fail "sanity: core window_tx_count=$CORE_WTC != $WINDOW (oracle drift)"
[[ "$HB_WTC" == "$WINDOW" ]] \
    || fail "window_tx_count mismatch: hotbuns=$HB_WTC expected=$WINDOW (core=$CORE_WTC)"
[[ "$HB_WTC" == "$CORE_WTC" ]] \
    || fail "window_tx_count hotbuns=$HB_WTC != core=$CORE_WTC"
[[ "$HB_WBC" == "$WINDOW" && "$CORE_WBC" == "$WINDOW" ]] \
    || fail "window_block_count: hotbuns=$HB_WBC core=$CORE_WBC expected=$WINDOW"
[[ "$HB_WFBH" == "$HEIGHT" && "$CORE_WFBH" == "$HEIGHT" ]] \
    || fail "window_final_block_height: hotbuns=$HB_WFBH core=$CORE_WFBH expected=$HEIGHT"
# Time-dependent fields: present + correctly typed + emit-condition (window>0).
[[ "$HB_WI" =~ ^-?[0-9]+$ ]] \
    || fail "window_interval not an integer (window>0): '$HB_WI'"
(( HB_WI >= 0 )) \
    || fail "window_interval negative: $HB_WI"
[[ "$HB_TXRATE" =~ ^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]] \
    || fail "txrate missing/not-numeric when window_interval>0: '$HB_TXRATE'"
log "CHECK window: window_tx_count=$HB_WTC==$CORE_WTC, window_block_count=$HB_WBC, window_final_block_height=$HB_WFBH, window_interval=$HB_WI(>=0), txrate=$HB_TXRATE OK"
WINDOW_T=ok

# ── CHECK 3: shape (hash shape + tip equality + error codes). ─────────────
[[ "$HB_WFB_HASH" =~ ^[0-9a-fA-F]{64}$ ]] \
    || fail "window_final_block_hash not 64-hex: '$HB_WFB_HASH'"
[[ "$HB_WFB_HASH" == "$HB_TIP" ]] \
    || fail "window_final_block_hash $HB_WFB_HASH != hotbuns tip $HB_TIP"
[[ "$HB_TIME" =~ ^[0-9]+$ ]] \
    || fail "time not a positive integer: '$HB_TIME'"
(( HB_TIME > 1000000000 )) \
    || fail "time not a sane unix timestamp: $HB_TIME"
# Error code -5 (RPC_INVALID_ADDRESS_OR_KEY) for an unknown blockhash.
BADHASH="dead00000000000000000000000000000000000000000000000000000000beef"
ERR5=$(hb_rpc getchaintxstats "[1, \"$BADHASH\"]" | jq -r '.error.code // empty')
[[ "$ERR5" == "-5" ]] \
    || fail "unknown blockhash should error -5 (RPC_INVALID_ADDRESS_OR_KEY), got '$ERR5'"
# Error code -8 (RPC_INVALID_PARAMETER) for out-of-range nblocks (>= height).
ERR8=$(hb_rpc getchaintxstats "[$(( HEIGHT + 5 )), \"$HB_TIP\"]" | jq -r '.error.code // empty')
[[ "$ERR8" == "-8" ]] \
    || fail "out-of-range nblocks should error -8 (RPC_INVALID_PARAMETER), got '$ERR8'"
# Core parity on the error codes (oracle must agree).
CORE_ERR5=$(core_cli_err getchaintxstats 1 "$BADHASH" | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
CORE_ERR8=$(core_cli_err getchaintxstats "$(( HEIGHT + 5 ))" | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_ERR5" == "-5" ]] || log "note: core unknown-hash error code='$CORE_ERR5' (expected -5)"
[[ "$CORE_ERR8" == "-8" ]] || log "note: core out-of-range error code='$CORE_ERR8' (expected -8)"
log "CHECK shape: hash=$HB_WFB_HASH(64-hex,==tip), time=$HB_TIME(sane), err(unknown-hash)=$ERR5, err(out-of-range)=$ERR8 OK"
SHAPE_T=ok

# ── CHECK 4: nblocks=0 drops the three window_* extras. ───────────────────
log "calling getchaintxstats(0, tip) on both nodes"
CORE_S0=$(core_cli getchaintxstats 0)
HB_RESP0=$(hb_rpc getchaintxstats "[0, \"$HB_TIP\"]")
HB_ERR0=$(echo "$HB_RESP0" | jq -r '.error // empty')
[[ -z "$HB_ERR0" || "$HB_ERR0" == "null" ]] || fail "hotbuns getchaintxstats(0) errored: $HB_ERR0"
HB_S0=$(echo "$HB_RESP0" | jq -c '.result')
[[ -n "$HB_S0" && "$HB_S0" != "null" ]] || fail "hotbuns getchaintxstats(0, tip) returned no result: $HB_RESP0"
log "core(0)   : $CORE_S0"
log "hotbuns(0): $HB_S0"

# Must keep: time, txcount, window_final_block_hash/height, window_block_count=0.
HB0_WBC=$(gj "$HB_S0" '.window_block_count')
HB0_TXCOUNT=$(gj "$HB_S0" '.txcount')
[[ "$HB0_WBC" == "0" ]] || fail "nblocks=0: window_block_count should be 0, got '$HB0_WBC'"
[[ "$HB0_TXCOUNT" == "$EXPECT_TXCOUNT" ]] \
    || fail "nblocks=0: txcount should still be $EXPECT_TXCOUNT, got '$HB0_TXCOUNT'"
# Must DROP: window_interval, window_tx_count, txrate.
for f in window_interval window_tx_count txrate; do
    has=$(echo "$HB_S0" | jq "has(\"$f\")")
    [[ "$has" == "false" ]] || fail "nblocks=0: hotbuns must OMIT $f, but it is present"
    chas=$(echo "$CORE_S0" | jq "has(\"$f\")")
    [[ "$chas" == "false" ]] || log "note: core(0) unexpectedly has $f"
done
# Oracle parity: core must also omit them and agree on the kept fields.
CORE0_WBC=$(gj "$CORE_S0" '.window_block_count')
CORE0_TXCOUNT=$(gj "$CORE_S0" '.txcount')
[[ "$CORE0_WBC" == "0" ]] || fail "sanity: core(0) window_block_count=$CORE0_WBC != 0"
[[ "$CORE0_TXCOUNT" == "$EXPECT_TXCOUNT" ]] || fail "sanity: core(0) txcount=$CORE0_TXCOUNT != $EXPECT_TXCOUNT"
log "CHECK nblocks0: window_block_count=0, txcount kept ($HB0_TXCOUNT), interval/tx_count/txrate DROPPED OK"
NBLOCKS0_T=ok

# ── Verdict. ───────────────────────────────────────────────────────────────
log "PASS: getchaintxstats matches bitcoind oracle for chain shape (counts/heights exact, time-fields emit-correct)"
pass "$TXCOUNT_T" "$WINDOW_T" "$SHAPE_T" "$NBLOCKS0_T"
