#!/usr/bin/env bash
#
# camlcoin_chaintxstats.sh — self-contained getchaintxstats Core-parity test.
#
# The first RPC-surface green-cell after the wallet + mempool-policy chapters.
# getchaintxstats is READ-ONLY chain statistics — NOT consensus — but must match
# Bitcoin Core EXACTLY for a given chain shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:1809-1898 (getchaintxstats).
#   SIGNATURE: getchaintxstats ( nblocks "blockhash" ). Both args optional.
#   ALGORITHM (the load-bearing semantics this test asserts):
#     - "time"                      = the FINAL block's RAW header nTime (NOT mediantime).
#     - "txcount"                   = cumulative #txs genesis..pindex (m_chain_tx_count).
#                                     INCLUDES the genesis coinbase, so for empty
#                                     blocks txcount = height + 1.
#     - "window_final_block_hash"   = pindex block hash (64-hex).
#     - "window_final_block_height" = pindex height.
#     - "window_block_count"        = the resolved window size (blockcount).
#     - "window_interval"           = MTP(pindex) - MTP(ancestor)  [11-block median-time-past],
#                                     emitted ONLY when window_block_count > 0.
#     - "window_tx_count"           = txcount(pindex) - txcount(pindex - nblocks),
#                                     emitted ONLY when window_block_count > 0 and both
#                                     chain_tx_counts are known.
#     - "txrate"                    = window_tx_count / window_interval,
#                                     emitted ONLY when window_interval > 0.
#   ERROR CODES: -5 (RPC_INVALID_ADDRESS_OR_KEY) "Block not found";
#                -8 (RPC_INVALID_PARAMETER) "Block is not in main chain" /
#                   "Invalid block count: should be between 0 and the block's height - 1".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports. Both nodes mine the SAME number of EMPTY
#   blocks (NBLOCKS) to the SAME deterministic p2wpkh address — so they have the
#   identical chain SHAPE (every block = 1 coinbase tx, so txcount = height + 1
#   and window_tx_count = nblocks). The count/height/shape fields are asserted
#   EXACTLY against Core; the time-dependent fields (time / window_interval /
#   txrate) are asserted PRESENT + correctly-typed + emit-condition-correct,
#   NOT byte-equal (the two regtest nodes mine with independent wall-clocks).
#
# WHAT MUST MATCH CORE EXACTLY (per chain shape):
#   * txcount                    == Core's txcount                    (= NBLOCKS+1)
#   * window_tx_count            == Core's window_tx_count            (= window)
#   * window_block_count         == Core's window_block_count         (= window)
#   * window_final_block_height  == Core's window_final_block_height  (= NBLOCKS)
#   * window_final_block_hash    is a 64-hex string (shape; the two chains differ
#                                  in coinbase scriptSig so the literal hash differs)
# WHAT MUST BE PRESENT + SANE (not byte-equal — timestamps diverge):
#   * time                       present, integer, > 0
#   * window_interval            present (window>0), integer, >= 0
#   * txrate                     present (window>0 AND window_interval>0), number >= 0
# EMIT-CONDITION RULE (nblocks=0): window_interval / window_tx_count / txrate ALL dropped.
# ERROR-CODE RULES: bad blockhash -> -5; out-of-range count -> -8.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/camlcoin_policy.sh): no
#   required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: CHAINTXSTATS camlcoin: PASS txcount=ok window=ok shape=ok nblocks0=ok
#   FAIL: CHAINTXSTATS camlcoin: FAIL <short reason>
#
# Touches ONLY /tmp/ctxstats-camlcoin/ + /tmp/ctxstats-core-camlcoin/ and ports
#   21895/21915 (camlcoin RPC/P2P) + 21893/21913 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

CC_DATADIR="/tmp/ctxstats-camlcoin"
CC_RPC=21895
CC_P2P=21915
CC_LOG="$CC_DATADIR/node.log"

CORE_DATADIR="/tmp/ctxstats-core-camlcoin"
CORE_RPC=21893
CORE_P2P=21913
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to, so
# both chains have the identical SHAPE (empty blocks, 1 coinbase tx each).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=120        # mine 120 empty blocks -> txcount = 121, window(10) tx = 10
WINDOW=10          # the nblocks window argument used for the count assertions

CC_PID=""
CC_COOKIE=""
CORE_BG=""
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[chaintxstats:camlcoin] $*" >&2; }

# ── Wait (up to ~30s) for a TCP port to become free before binding. ────────
# Guards against the kernel still holding a just-killed node's listen socket
# (TIME_WAIT / slow release) when we relaunch on the same port — the cause of
# spurious "exited during startup (EADDRINUSE)" on back-to-back runs.
wait_port_free() {  # wait_port_free <port>
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): NEVER kills by port.
    local port="$1"
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":${port} " || return 0
        sleep 1
    done
    return 1
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CC_PID" ]] && kill -0 "$CC_PID" 2>/dev/null; then
        kill "$CC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$CC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <txcount> <window> <shape> <nblocks0>
pass() {
    echo "CHAINTXSTATS camlcoin: PASS txcount=$1 window=$2 shape=$3 nblocks0=$4"
    exit 0
}
fail() {
    echo "CHAINTXSTATS camlcoin: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "ctxstats-camlcoin" >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${CC_RPC}/${CC_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$CC_DATADIR" "$CORE_DATADIR"
mkdir -p "$CC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "camlcoin binary not found at $NODE_BIN (build with: dune build)"
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

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# cc_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
# Retries up to 3x on a transient EMPTY response (dropped connection / RPC
# server momentarily not accepting): an empty body carries neither "result"
# nor "error", so a genuine JSON-RPC error response is returned immediately and
# never retried (no real failure is masked).
cc_rpc() {
    local attempt resp
    for attempt in 1 2 3; do
        resp=$(curl -s --max-time 90 -u "$CC_COOKIE" \
            --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
            "http://127.0.0.1:$CC_RPC/" 2>/dev/null)
        if echo "$resp" | grep -q '"result"\|"error"'; then
            echo "$resp"; return 0
        fi
        sleep 1
    done
    echo "$resp"  # last (possibly empty) attempt; caller surfaces the failure
}

# jpy <json> <expr>   (expr references parsed object as `d`)
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

# ── 3. Launch the Core regtest oracle. ────────────────────────────────────
wait_port_free "$CORE_RPC" || fail "Core RPC port $CORE_RPC still busy after 30s (another node holds it)"
wait_port_free "$CORE_P2P" || fail "Core P2P port $CORE_P2P still busy after 30s (another node holds it)"
log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < core_deadline )); do
    if core_cli getblockcount >/dev/null 2>&1; then break; fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
core_cli getblockcount >/dev/null 2>&1 || fail "Core oracle RPC never responded within 120s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch camlcoin on regtest. ────────────────────────────────────────
wait_port_free "$CC_RPC" || fail "camlcoin RPC port $CC_RPC still busy after 30s (another node holds it)"
wait_port_free "$CC_P2P" || fail "camlcoin P2P port $CC_P2P still busy after 30s (another node holds it)"
log "launching camlcoin (regtest) rpc=:$CC_RPC p2p=:$CC_P2P -> $CC_LOG"
"$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
    --port "$CC_P2P" --rpcport "$CC_RPC" >"$CC_LOG" 2>&1 &
CC_PID=$!
cc_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < cc_deadline )); do
    if [[ -z "$CC_COOKIE" && -f "$CC_DATADIR/.cookie" ]]; then
        CC_COOKIE=$(cat "$CC_DATADIR/.cookie")
    fi
    if [[ -n "$CC_COOKIE" ]]; then
        echo "$(cc_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$CC_PID" 2>/dev/null || { tail -n 20 "$CC_LOG" >&2 2>/dev/null || true; fail "camlcoin exited during startup (see $CC_LOG)"; }
    sleep 1
done
[[ -n "$CC_COOKIE" ]] || fail "camlcoin cookie never appeared within 120s"
echo "$(cc_rpc getblockcount '[]')" | grep -q '"result"' || fail "camlcoin RPC never responded within 120s"
log "camlcoin RPC ready"

# ── 5. Mine NBLOCKS empty blocks to the SAME address on BOTH nodes. ───────
log "mining $NBLOCKS empty blocks to $ADDR on Core"
core_cli generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $NBLOCKS"

log "mining $NBLOCKS empty blocks to $ADDR on camlcoin"
GEN_OUT=$(cc_rpc generatetoaddress "[$NBLOCKS, \"$ADDR\"]")
echo "$GEN_OUT" | grep -q '"result"' || fail "camlcoin generatetoaddress failed: $GEN_OUT"
CC_HEIGHT=$(jpy "$(cc_rpc getblockcount '[]')" "d['result']")
[[ "$CC_HEIGHT" == "$NBLOCKS" ]] || fail "camlcoin height after mining is $CC_HEIGHT, expected $NBLOCKS"

# ── 6. Query getchaintxstats <WINDOW> <tip> on BOTH. ──────────────────────
CORE_TIP=$(core_cli getbestblockhash 2>/dev/null)
CC_TIP=$(jpy "$(cc_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$CORE_TIP" && -n "$CC_TIP" ]] || fail "could not read both tip hashes (core='$CORE_TIP' caml='$CC_TIP')"

CORE_STATS=$(core_cli getchaintxstats "$WINDOW" "$CORE_TIP" 2>/dev/null)
[[ -n "$CORE_STATS" ]] || fail "Core getchaintxstats produced no output"
CC_STATS_ENV=$(cc_rpc getchaintxstats "[$WINDOW, \"$CC_TIP\"]")
echo "$CC_STATS_ENV" | grep -q '"result"' || fail "camlcoin getchaintxstats errored: $CC_STATS_ENV"
CC_STATS=$(jpy "$CC_STATS_ENV" "json.dumps(d['result'])")
[[ -n "$CC_STATS" ]] || fail "camlcoin getchaintxstats result empty"

log "Core     stats: $CORE_STATS"
log "camlcoin stats: $CC_STATS"

# Field extractors (bare result JSON in, value out).
c() { jpy "$CORE_STATS" "d.get('$1')"; }
r() { jpy "$CC_STATS"   "d.get('$1')"; }

# ── 7. EXACT count/height matches against Core. ───────────────────────────
C_TXCOUNT=$(c txcount);        R_TXCOUNT=$(r txcount)
C_WTX=$(c window_tx_count);    R_WTX=$(r window_tx_count)
C_WBC=$(c window_block_count); R_WBC=$(r window_block_count)
C_WFH=$(c window_final_block_height); R_WFH=$(r window_final_block_height)

# Sanity vs the known chain shape (empty blocks): txcount = height+1, window = WINDOW.
EXP_TXCOUNT=$(( NBLOCKS + 1 ))
[[ "$C_TXCOUNT" == "$EXP_TXCOUNT" ]] || fail "Core txcount=$C_TXCOUNT != expected $EXP_TXCOUNT (oracle/chain-shape unexpected)"
[[ "$C_WTX"     == "$WINDOW"      ]] || fail "Core window_tx_count=$C_WTX != expected $WINDOW (oracle/chain-shape unexpected)"

TXCOUNT_T="ok"; WINDOW_T="ok"
[[ "$R_TXCOUNT" == "$C_TXCOUNT" ]] || TXCOUNT_T="bad"
[[ "$R_WTX"  == "$C_WTX"  ]] || WINDOW_T="bad"
[[ "$R_WBC"  == "$C_WBC"  ]] || WINDOW_T="bad"
[[ "$R_WFH"  == "$C_WFH"  ]] || WINDOW_T="bad"

if [[ "$TXCOUNT_T" != "ok" ]]; then
    fail "txcount mismatch vs Core: camlcoin=$R_TXCOUNT core=$C_TXCOUNT (expected $EXP_TXCOUNT)"
fi
if [[ "$WINDOW_T" != "ok" ]]; then
    fail "window-count fields mismatch vs Core: tx(r=$R_WTX,c=$C_WTX) block_count(r=$R_WBC,c=$C_WBC) final_height(r=$R_WFH,c=$C_WFH)"
fi

# ── 8. SHAPE checks: final_block_hash is 64-hex; time-dependent fields present + typed. ─
SHAPE_T="ok"
R_HASH=$(r window_final_block_hash)
[[ "$R_HASH" =~ ^[0-9a-f]{64}$ ]] || { SHAPE_T="bad"; log "window_final_block_hash not 64-hex: '$R_HASH'"; }

# time = raw header nTime: present + integer + > 0.
R_TIME=$(r time)
if ! [[ "$R_TIME" =~ ^[0-9]+$ ]] || [[ "$R_TIME" -le 0 ]]; then
    SHAPE_T="bad"; log "time absent/non-integer/non-positive: '$R_TIME'"
fi

# window_interval present (window>0), integer, >= 0.
R_WINT=$(r window_interval)
if ! [[ "$R_WINT" =~ ^-?[0-9]+$ ]] || [[ "$R_WINT" -lt 0 ]]; then
    SHAPE_T="bad"; log "window_interval absent/non-integer/negative (window>0): '$R_WINT'"
fi

# txrate present + numeric when window>0 AND window_interval>0.
R_RATE=$(r txrate)
if [[ "$R_WINT" =~ ^[0-9]+$ ]] && [[ "$R_WINT" -gt 0 ]]; then
    if ! [[ "$R_RATE" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
        SHAPE_T="bad"; log "txrate absent/non-numeric while window_interval>0: '$R_RATE'"
    fi
else
    # window_interval == 0 -> txrate MUST be absent (Core emit-condition).
    [[ -z "$R_RATE" ]] || { SHAPE_T="bad"; log "txrate present despite window_interval==0: '$R_RATE'"; }
fi

[[ "$SHAPE_T" == "ok" ]] || fail "shape/type/emit-condition check failed (see log)"

# ── 9. EMIT-CONDITION: nblocks=0 drops the 3 window extras. ───────────────
NBLOCKS0_T="ok"
CC0_ENV=$(cc_rpc getchaintxstats "[0, \"$CC_TIP\"]")
echo "$CC0_ENV" | grep -q '"result"' || fail "camlcoin getchaintxstats 0 errored: $CC0_ENV"
CC0=$(jpy "$CC0_ENV" "json.dumps(d['result'])")
HAS_EXTRAS=$(jpy "$CC0" "any(k in d for k in ('window_interval','window_tx_count','txrate'))")
[[ "$HAS_EXTRAS" == "false" ]] || { NBLOCKS0_T="bad"; log "nblocks=0 did NOT drop window extras: $CC0"; }
# window_block_count must be 0; the core non-window fields must still be present.
CC0_WBC=$(jpy "$CC0" "d.get('window_block_count')")
[[ "$CC0_WBC" == "0" ]] || { NBLOCKS0_T="bad"; log "nblocks=0 window_block_count != 0: '$CC0_WBC'"; }
CC0_TXC=$(jpy "$CC0" "d.get('txcount')")
[[ "$CC0_TXC" == "$EXP_TXCOUNT" ]] || { NBLOCKS0_T="bad"; log "nblocks=0 txcount wrong: '$CC0_TXC'"; }
[[ "$NBLOCKS0_T" == "ok" ]] || fail "nblocks=0 emit-condition check failed (see log)"

# ── 10. ERROR-CODE parity: -5 (block not found), -8 (invalid count). ──────
# -5: a syntactically-valid but unknown blockhash.
ERR_BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(jpy "$(cc_rpc getchaintxstats "[10, \"$ERR_BAD_HASH\"]")" "d['error']['code']")
[[ "$E5" == "-5" ]] || fail "expected error -5 (Block not found) for unknown blockhash, got '$E5'"
# -8: a block count >= height.
BIG=$(( NBLOCKS + 10 ))
E8=$(jpy "$(cc_rpc getchaintxstats "[$BIG, \"$CC_TIP\"]")" "d['error']['code']")
[[ "$E8" == "-8" ]] || fail "expected error -8 (Invalid block count) for out-of-range nblocks, got '$E8'"
# -8: negative block count.
E8N=$(jpy "$(cc_rpc getchaintxstats "[-1, \"$CC_TIP\"]")" "d['error']['code']")
[[ "$E8N" == "-8" ]] || fail "expected error -8 (Invalid block count) for negative nblocks, got '$E8N'"

log "PASS: camlcoin getchaintxstats matches Core on count/height/shape + emit-conditions + error codes"
pass "$TXCOUNT_T" "$WINDOW_T" "$SHAPE_T" "$NBLOCKS0_T"
