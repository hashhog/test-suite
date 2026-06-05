#!/usr/bin/env bash
#
# nimrod_chaintxstats.sh — self-contained getchaintxstats RPC-parity test.
#
# The first RPC-surface green-cell after the wallet + mempool-policy chapters.
# getchaintxstats is read-only chain statistics — NOT consensus — but it must be
# Core-EXACT. This harness proves nimrod's getchaintxstats matches a REAL
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
#   Launch BOTH a real bitcoind regtest oracle AND nimrod on their own scratch
#   datadirs + unique ports. Mine the SAME number of empty blocks (HEIGHT=121)
#   on each. Empty regtest blocks each carry exactly one coinbase tx, so for a
#   chain of height H the cumulative tx count is H+1 and the per-window tx count
#   is exactly the window size. That makes the COUNT/height/shape fields fully
#   deterministic and identical between the two nodes:
#       txcount                   = height + 1                (= 122)
#       window_tx_count           = WINDOW                    (= 120)
#       window_block_count        = WINDOW                    (= 120)
#       window_final_block_height = height                    (= 121)
#       window_final_block_hash   = 64-hex (shape; the two nodes mine to
#                                   different addresses so hashes differ, but
#                                   the SHAPE + tip-equality-with-its-own-
#                                   getbestblockhash is asserted).
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
#   txcount   : nimrod txcount == oracle txcount == height+1, on the
#               getchaintxstats(WINDOW,tip) call.
#   window    : nimrod window_tx_count == oracle == WINDOW, window_block_count
#               == WINDOW, window_final_block_height == height, on the
#               (WINDOW,tip) call; window_interval present + >= 0; txrate present
#               + numeric.
#   shape     : window_final_block_hash is 64-hex and equals nimrod's
#               getbestblockhash (tip), error codes match (-5 unknown hash,
#               -8 out-of-range nblocks).
#   nblocks0  : getchaintxstats(0,tip) emits time/txcount/window_final_block_*/
#               window_block_count=0 and OMITS window_interval/window_tx_count/
#               txrate (the nblocks=0 drop rule), matching the oracle's omission.
#
# UNIFORM INTERFACE (mirrors test-suite/policy/nimrod_policy.sh): no required
#   args, set -uo pipefail, idempotent, trap cleanup, scratch /tmp + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS: CHAINTXSTATS nimrod: PASS txcount=ok window=ok shape=ok nblocks0=ok
#   FAIL: CHAINTXSTATS nimrod: FAIL <short reason>
#
# Touches ONLY /tmp/ctxstats-nimrod/ + /tmp/ctxstats-nimrod-core/ and ports
#   39991/40011 (nimrod) + 39993/40013 (Core). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node (haskoin is mid-sync — leave it).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
BITCOIND="$BASEDIR/bitcoin-core/build/bin/bitcoind"
BITCOINCLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"     # for a wallet-free mining address

NM_DATADIR="/tmp/ctxstats-nimrod"
NM_RPC=39991
NM_P2P=40011
NM_LOG="$NM_DATADIR/node.log"
NM_COOKIE_FILE="$NM_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/ctxstats-nimrod-core"
CORE_RPC=39993
CORE_P2P=40013
CORE_LOG="$CORE_DATADIR/core.log"

# Mine HEIGHT empty blocks on BOTH nodes, then query a WINDOW strictly less than
# HEIGHT (Core requires nblocks < pindex->nHeight; nblocks==height is out of
# range). HEIGHT=121 / WINDOW=120 makes the window math land on a round 120.
HEIGHT=121             # blocks mined on BOTH nodes (chain height)
WINDOW=120             # getchaintxstats window size (must be < HEIGHT)

# Fixed deterministic test secret -> a wallet-free p2wpkh mining address.
# nimrod's getnewaddress requires a loaded wallet; mining to an explicit address
# (the coinbase output script is irrelevant to tx counts) avoids that dependency.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NM_PID=""
NM_COOKIE=""
CORE_PID=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[chaintxstats:nimrod] $*" >&2; }

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CORE_PID" ]]; then
        "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
        for _ in $(seq 1 15); do kill -0 "$CORE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_PID" 2>/dev/null || true
    fi
    if [[ -n "$NM_PID" ]] && kill -0 "$NM_PID" 2>/dev/null; then
        kill "$NM_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NM_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NM_PID" 2>/dev/null || true
    fi
    fuser -k "${NM_RPC}/tcp"   2>/dev/null || true
    fuser -k "${NM_P2P}/tcp"   2>/dev/null || true
    fuser -k "${CORE_RPC}/tcp" 2>/dev/null || true
    fuser -k "${CORE_P2P}/tcp" 2>/dev/null || true
    rm -rf "$NM_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {  # pass <txcount> <window> <shape> <nblocks0>
    echo "CHAINTXSTATS nimrod: PASS txcount=$1 window=$2 shape=$3 nblocks0=$4"
    exit 0
}
fail() {
    echo "CHAINTXSTATS nimrod: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "ctxstats-nimrod-core" 2>/dev/null || true
pkill -f "ctxstats-nimrod" 2>/dev/null || true
fuser -k "${NM_RPC}/tcp"   2>/dev/null || true
fuser -k "${NM_P2P}/tcp"   2>/dev/null || true
fuser -k "${CORE_RPC}/tcp" 2>/dev/null || true
fuser -k "${CORE_P2P}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$NM_DATADIR" "$CORE_DATADIR"
mkdir -p "$NM_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1   || fail "curl not found on PATH"
command -v jq   >/dev/null 2>&1   || fail "jq not found on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
[[ -x "$NODE_BIN" ]]    || fail "nimrod binary not found at $NODE_BIN (run: cd nimrod && nimble build -d:release -y)"
[[ -x "$BITCOIND" ]]    || fail "bitcoind not found at $BITCOIND"
[[ -x "$BITCOINCLI" ]]  || fail "bitcoin-cli not found at $BITCOINCLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# ── RPC helpers. ──────────────────────────────────────────────────────────
# nm_rpc <method> <json-params-array>  -> raw JSON-RPC response on stdout.
nm_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 60 -u "$NM_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$NM_RPC/" 2>/dev/null
}
# core_cli <args...> -> bitcoin-cli output.
core_cli() {
    "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>/dev/null
}
gj() { echo "$1" | jq -r "$2"; }   # gj <json> <filter>

# ── 2. Derive a wallet-free p2wpkh mining address (deterministic). ────────
MINE_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null)
[[ -n "$MINE_ADDR" ]] || MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
log "wallet-free mining address: $MINE_ADDR"

# ── 3. Launch the real bitcoind regtest oracle. ───────────────────────────
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

# ── 4. Launch nimrod on regtest. ──────────────────────────────────────────
log "launching nimrod (regtest) rpc=:$NM_RPC p2p=:$NM_P2P -> $NM_LOG"
"$NODE_BIN" --network=regtest --datadir="$NM_DATADIR" \
    --port="$NM_P2P" --rpcport="$NM_RPC" start >"$NM_LOG" 2>&1 &
NM_PID=$!
log "nimrod pid=$NM_PID"
deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$NM_COOKIE" && -f "$NM_COOKIE_FILE" ]]; then
        NM_COOKIE=$(cat "$NM_COOKIE_FILE")
    fi
    if [[ -n "$NM_COOKIE" ]]; then
        r=$(nm_rpc getblockcount)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$NM_PID" 2>/dev/null || { tail -n 20 "$NM_LOG" >&2 2>/dev/null || true; fail "nimrod exited during startup (see $NM_LOG)"; }
    sleep 1
done
[[ -n "$NM_COOKIE" ]] || fail "nimrod cookie never appeared within 60s"
r=$(nm_rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "nimrod RPC never responded within 60s"
log "nimrod RPC ready"

# ── 5. Mine the SAME number of empty blocks on BOTH nodes. ────────────────
log "mining $HEIGHT blocks on bitcoind oracle"
core_cli generatetoaddress "$HEIGHT" "$MINE_ADDR" >/dev/null 2>&1 \
    || fail "core generatetoaddress failed"
CORE_H=$(core_cli getblockcount)
[[ "$CORE_H" == "$HEIGHT" ]] || fail "core height $CORE_H != $HEIGHT after mining"

log "mining $HEIGHT blocks on nimrod"
gr=$(nm_rpc generatetoaddress "[$HEIGHT, \"$MINE_ADDR\"]")
echo "$gr" | grep -q '"result"' || fail "nimrod generatetoaddress failed: $gr"
NM_H=$(nm_rpc getblockcount | jq -r '.result')
[[ "$NM_H" == "$HEIGHT" ]] || fail "nimrod height $NM_H != $HEIGHT after mining"
NM_TIP=$(nm_rpc getbestblockhash | jq -r '.result')
[[ "$NM_TIP" =~ ^[0-9a-fA-F]{64}$ ]] || fail "nimrod getbestblockhash bad: '$NM_TIP'"
log "both nodes at height $HEIGHT (nimrod tip $NM_TIP)"

# ── 6. getchaintxstats(WINDOW, tip) on BOTH. ──────────────────────────────
log "calling getchaintxstats($WINDOW, tip) on both nodes"
CORE_S=$(core_cli getchaintxstats "$WINDOW")
[[ -n "$CORE_S" ]] || fail "core getchaintxstats($WINDOW) returned nothing"
NM_RESP=$(nm_rpc getchaintxstats "[$WINDOW, \"$NM_TIP\"]")
NM_ERR=$(echo "$NM_RESP" | jq -r '.error // empty')
[[ -z "$NM_ERR" || "$NM_ERR" == "null" ]] || fail "nimrod getchaintxstats errored: $NM_ERR"
NM_S=$(echo "$NM_RESP" | jq -c '.result')
[[ -n "$NM_S" && "$NM_S" != "null" ]] || fail "nimrod getchaintxstats($WINDOW, tip) returned no result: $NM_RESP"

log "core  : $CORE_S"
log "nimrod: $NM_S"

CORE_TXCOUNT=$(gj "$CORE_S" '.txcount')
CORE_WTC=$(gj "$CORE_S" '.window_tx_count')
CORE_WBC=$(gj "$CORE_S" '.window_block_count')
CORE_WFBH=$(gj "$CORE_S" '.window_final_block_height')

NM_TXCOUNT=$(gj "$NM_S" '.txcount')
NM_WTC=$(gj "$NM_S" '.window_tx_count')
NM_WBC=$(gj "$NM_S" '.window_block_count')
NM_WFBH=$(gj "$NM_S" '.window_final_block_height')
NM_WFB_HASH=$(gj "$NM_S" '.window_final_block_hash')
NM_TIME=$(gj "$NM_S" '.time')
NM_WI=$(gj "$NM_S" '.window_interval')
NM_TXRATE=$(gj "$NM_S" '.txrate')

# ── CHECK 1: txcount (exact match to oracle AND == height+1). ─────────────
EXPECT_TXCOUNT=$(( HEIGHT + 1 ))
[[ "$CORE_TXCOUNT" == "$EXPECT_TXCOUNT" ]] \
    || fail "sanity: core txcount=$CORE_TXCOUNT != expected $EXPECT_TXCOUNT (oracle drift)"
[[ "$NM_TXCOUNT" == "$EXPECT_TXCOUNT" ]] \
    || fail "txcount mismatch: nimrod=$NM_TXCOUNT core=$CORE_TXCOUNT expected=$EXPECT_TXCOUNT"
[[ "$NM_TXCOUNT" == "$CORE_TXCOUNT" ]] \
    || fail "txcount nimrod=$NM_TXCOUNT != core=$CORE_TXCOUNT"
log "CHECK txcount: nimrod=$NM_TXCOUNT == core=$CORE_TXCOUNT == height+1 ($EXPECT_TXCOUNT) OK"
TXCOUNT_T=ok

# ── CHECK 2: window fields (exact, window>0). ─────────────────────────────
# Empty blocks -> window_tx_count == WINDOW; window_block_count == WINDOW;
# window_final_block_height == HEIGHT.
[[ "$CORE_WTC" == "$WINDOW" ]] \
    || fail "sanity: core window_tx_count=$CORE_WTC != $WINDOW (oracle drift)"
[[ "$NM_WTC" == "$WINDOW" ]] \
    || fail "window_tx_count mismatch: nimrod=$NM_WTC expected=$WINDOW (core=$CORE_WTC)"
[[ "$NM_WTC" == "$CORE_WTC" ]] \
    || fail "window_tx_count nimrod=$NM_WTC != core=$CORE_WTC"
[[ "$NM_WBC" == "$WINDOW" && "$CORE_WBC" == "$WINDOW" ]] \
    || fail "window_block_count: nimrod=$NM_WBC core=$CORE_WBC expected=$WINDOW"
[[ "$NM_WFBH" == "$HEIGHT" && "$CORE_WFBH" == "$HEIGHT" ]] \
    || fail "window_final_block_height: nimrod=$NM_WFBH core=$CORE_WFBH expected=$HEIGHT"
# Time-dependent fields: present + correctly typed + emit-condition (window>0).
[[ "$NM_WI" =~ ^-?[0-9]+$ ]] \
    || fail "window_interval not an integer (window>0): '$NM_WI'"
(( NM_WI >= 0 )) \
    || fail "window_interval negative: $NM_WI"
[[ "$NM_TXRATE" =~ ^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]] \
    || fail "txrate missing/not-numeric when window_interval>0: '$NM_TXRATE'"
log "CHECK window: window_tx_count=$NM_WTC==$CORE_WTC, window_block_count=$NM_WBC, window_final_block_height=$NM_WFBH, window_interval=$NM_WI(>=0), txrate=$NM_TXRATE OK"
WINDOW_T=ok

# ── CHECK 3: shape (hash shape + tip equality + error codes). ─────────────
[[ "$NM_WFB_HASH" =~ ^[0-9a-fA-F]{64}$ ]] \
    || fail "window_final_block_hash not 64-hex: '$NM_WFB_HASH'"
[[ "$NM_WFB_HASH" == "$NM_TIP" ]] \
    || fail "window_final_block_hash $NM_WFB_HASH != nimrod tip $NM_TIP"
[[ "$NM_TIME" =~ ^[0-9]+$ ]] \
    || fail "time not a positive integer: '$NM_TIME'"
(( NM_TIME > 1000000000 )) \
    || fail "time not a sane unix timestamp: $NM_TIME"
# Error code -5 (RPC_INVALID_ADDRESS_OR_KEY) for an unknown blockhash.
BADHASH="dead00000000000000000000000000000000000000000000000000000000beef"
ERR5=$(nm_rpc getchaintxstats "[1, \"$BADHASH\"]" | jq -r '.error.code // empty')
[[ "$ERR5" == "-5" ]] \
    || fail "unknown blockhash should error -5 (RPC_INVALID_ADDRESS_OR_KEY), got '$ERR5'"
# Error code -8 (RPC_INVALID_PARAMETER) for out-of-range nblocks (>= height).
ERR8=$(nm_rpc getchaintxstats "[$(( HEIGHT + 5 )), \"$NM_TIP\"]" | jq -r '.error.code // empty')
[[ "$ERR8" == "-8" ]] \
    || fail "out-of-range nblocks should error -8 (RPC_INVALID_PARAMETER), got '$ERR8'"
# Core parity on the error codes (oracle must agree).
CORE_ERR5=$(core_cli getchaintxstats 1 "$BADHASH" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
CORE_ERR8=$(core_cli getchaintxstats "$(( HEIGHT + 5 ))" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_ERR5" == "-5" ]] || log "note: core unknown-hash error code='$CORE_ERR5' (expected -5)"
[[ "$CORE_ERR8" == "-8" ]] || log "note: core out-of-range error code='$CORE_ERR8' (expected -8)"
log "CHECK shape: hash=$NM_WFB_HASH(64-hex,==tip), time=$NM_TIME(sane), err(unknown-hash)=$ERR5, err(out-of-range)=$ERR8 OK"
SHAPE_T=ok

# ── CHECK 4: nblocks=0 drops the three window_* extras. ───────────────────
log "calling getchaintxstats(0, tip) on both nodes"
CORE_S0=$(core_cli getchaintxstats 0)
NM_RESP0=$(nm_rpc getchaintxstats "[0, \"$NM_TIP\"]")
NM_ERR0=$(echo "$NM_RESP0" | jq -r '.error // empty')
[[ -z "$NM_ERR0" || "$NM_ERR0" == "null" ]] || fail "nimrod getchaintxstats(0) errored: $NM_ERR0"
NM_S0=$(echo "$NM_RESP0" | jq -c '.result')
[[ -n "$NM_S0" && "$NM_S0" != "null" ]] || fail "nimrod getchaintxstats(0, tip) returned no result: $NM_RESP0"
log "core(0)  : $CORE_S0"
log "nimrod(0): $NM_S0"

# Must keep: time, txcount, window_final_block_hash/height, window_block_count=0.
NM0_WBC=$(gj "$NM_S0" '.window_block_count')
NM0_TXCOUNT=$(gj "$NM_S0" '.txcount')
[[ "$NM0_WBC" == "0" ]] || fail "nblocks=0: window_block_count should be 0, got '$NM0_WBC'"
[[ "$NM0_TXCOUNT" == "$EXPECT_TXCOUNT" ]] \
    || fail "nblocks=0: txcount should still be $EXPECT_TXCOUNT, got '$NM0_TXCOUNT'"
# Must DROP: window_interval, window_tx_count, txrate.
for f in window_interval window_tx_count txrate; do
    has=$(echo "$NM_S0" | jq "has(\"$f\")")
    [[ "$has" == "false" ]] || fail "nblocks=0: nimrod must OMIT $f, but it is present"
    chas=$(echo "$CORE_S0" | jq "has(\"$f\")")
    [[ "$chas" == "false" ]] || log "note: core(0) unexpectedly has $f"
done
# Oracle parity: core must also omit them and agree on the kept fields.
CORE0_WBC=$(gj "$CORE_S0" '.window_block_count')
CORE0_TXCOUNT=$(gj "$CORE_S0" '.txcount')
[[ "$CORE0_WBC" == "0" ]] || fail "sanity: core(0) window_block_count=$CORE0_WBC != 0"
[[ "$CORE0_TXCOUNT" == "$EXPECT_TXCOUNT" ]] || fail "sanity: core(0) txcount=$CORE0_TXCOUNT != $EXPECT_TXCOUNT"
log "CHECK nblocks0: window_block_count=0, txcount kept ($NM0_TXCOUNT), interval/tx_count/txrate DROPPED OK"
NBLOCKS0_T=ok

# ── Verdict. ───────────────────────────────────────────────────────────────
log "PASS: getchaintxstats matches bitcoind oracle for chain shape (counts/heights exact, time-fields emit-correct)"
pass "$TXCOUNT_T" "$WINDOW_T" "$SHAPE_T" "$NBLOCKS0_T"
