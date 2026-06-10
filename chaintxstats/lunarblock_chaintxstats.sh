#!/usr/bin/env bash
#
# lunarblock_chaintxstats.sh — self-contained getchaintxstats DIFFERENTIAL test.
#
# The first RPC-surface green-cell after the wallet + mempool-policy chapters.
# getchaintxstats is READ-ONLY chain statistics (NOT consensus) but must be
# Core-EXACT: same output object shape, same field-emit conditions, same
# count/height arithmetic for the same chain shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp getchaintxstats (1809-1898).
#   getchaintxstats ( nblocks "blockhash" ) — both args optional.
#     time                      = the FINAL block's RAW header nTime (NOT MTP)
#     txcount                   = cumulative #txs genesis..pindex (m_chain_tx_count)
#     window_final_block_hash   = pindex block hash hex
#     window_final_block_height = pindex height
#     window_block_count        = resolved nblocks
#     window_interval (opt)     = MTP(pindex) - MTP(pindex-nblocks); only nblocks>0
#     window_tx_count (opt)     = txcount(pindex) - txcount(pindex-nblocks);
#                                 only nblocks>0 and both endpoints have a txcount
#     txrate (opt)              = window_tx_count / window_interval; only interval>0
#   Default nblocks = "one month" = 30*24*60*60 / nPowTargetSpacing (=4320 on the
#   600s networks incl regtest); on a short chain it clamps to
#   max(0, min(default, height-1)).
#   Errors: -5 (RPC_INVALID_ADDRESS_OR_KEY) "Block not found"; -8
#   (RPC_INVALID_PARAMETER) "Block is not in main chain" / "Invalid block count".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (own scratch datadir + ports). The SAME number of empty blocks
#   (NBLOCKS) is mined on BOTH lunarblock and Core, then getchaintxstats is
#   probed on both. Because every block is empty (exactly 1 coinbase tx), the
#   COUNT/height fields are fully deterministic for a chain of the same height:
#       txcount         = height + 1            (genesis coinbase + 1/block)
#       window_tx_count = nblocks               (1 coinbase per windowed block)
#       window_block_count = the resolved nblocks
#       window_final_block_height = height
#   Those are asserted EXACTLY equal to Core.
#
#   Time-dependent fields (time, window_interval, txrate) differ between the two
#   independent regtest nodes (their block timestamps are not synchronised), so
#   they are asserted PRESENT + correctly-typed + obeying the emit-condition
#   rules (e.g. nblocks=0 drops the 3 window extras; txrate present iff window
#   interval > 0), NOT for exact value equality.
#
# CHECKS (lunarblock vs Core, same NBLOCKS-high regtest chain):
#   txcount   : both emit txcount, and lunarblock == Core == height+1
#   window    : with nblocks=N (0<N<height): window_block_count==N (both),
#               window_tx_count==N (both), window_final_block_height==height (both)
#   shape     : window_final_block_hash is 64-hex (both); time present + int (both);
#               window_interval present + int >=0 when nblocks>0 (both);
#               txrate present + number iff window_interval>0 (both, matched)
#   nblocks0  : getchaintxstats 0 drops window_interval/window_tx_count/txrate on
#               BOTH; base fields still present.
#   Plus error parity: bogus blockhash -> -5 on both; a side/non-main hash and an
#   out-of-range nblocks -> -8 on both (best-effort; reported, not summary-gated).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/lunarblock_policy.sh): no
#   required args, idempotent, trap cleanup, scratch datadirs + unique ports, ONE
#   clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: CHAINTXSTATS lunarblock: PASS txcount=ok window=ok shape=ok nblocks0=ok
#   FAIL: CHAINTXSTATS lunarblock: FAIL <short reason> [txcount=.. window=.. ...]
#
# Touches ONLY /tmp/ctxstats-lunarblock + /tmp/ctxstats-core and ports
#   21898/21918 (lunarblock RPC/P2P), 21896/21916 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

LB_DATADIR="/tmp/ctxstats-lunarblock"
LB_RPC=21898
LB_P2P=21918
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/ctxstats-core"
CORE_RPC=21896
CORE_P2P=21916
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120          # mine the SAME number of empty blocks on both nodes
WIN=10               # a concrete window size 0<WIN<height for the window checks

# lunarblock defaults to an EMPTY rpcpassword on regtest -> RPC auth disabled.
LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[chaintxstats:lunarblock] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
        kill -TERM "-${LB_PID}" 2>/dev/null || kill -TERM "$LB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "-${LB_PID}" 2>/dev/null || kill -KILL "$LB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <txcount> <window> <shape> <nblocks0>
pass() {
    echo "CHAINTXSTATS lunarblock: PASS txcount=$1 window=$2 shape=$3 nblocks0=$4"
    exit 0
}
fail() {
    echo "CHAINTXSTATS lunarblock: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "ctxstats-lunarblock" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${LB_RPC}/${LB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v luajit  >/dev/null 2>&1 || fail "luajit not found on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]    || fail "lunarblock src/main.lua not found at $LB_DIR"
[[ -x "$CORE_BIN" ]]               || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || fail "bitcoin-cli not found at $CORE_CLI"

# ── Tiny JSON field extractor (no jq dependency; uses python3). ───────────
# jget <json> <field>  -> prints the value, or "__MISSING__" if absent,
# "__NULL__" if explicitly null. For nested .result objects pass the .result.
jget() {
    python3 - "$1" "$2" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("__PARSEERR__"); sys.exit(0)
k = sys.argv[2]
if k not in d:
    print("__MISSING__")
elif d[k] is None:
    print("__NULL__")
else:
    v = d[k]
    if isinstance(v, bool):
        print("true" if v else "false")
    else:
        print(v)
PY
}

# jtype <json> <field> -> "int" | "float" | "str" | "bool" | "missing" | "null"
jtype() {
    python3 - "$1" "$2" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("parseerr"); sys.exit(0)
k = sys.argv[2]
if k not in d:
    print("missing"); sys.exit(0)
v = d[k]
if v is None: print("null")
elif isinstance(v, bool): print("bool")
elif isinstance(v, int): print("int")
elif isinstance(v, float): print("float")
elif isinstance(v, str): print("str")
else: print("other")
PY
}

# jerr_code <json> -> the JSON-RPC error code, or "__NOERR__" if error is null.
jerr_code() {
    python3 - "$1" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("__PARSEERR__"); sys.exit(0)
e = d.get("error")
if e is None:
    print("__NOERR__")
elif isinstance(e, dict):
    print(e.get("code", "__NOCODE__"))
else:
    print("__BADERR__")
PY
}

# ── Core RPC wrapper (cookie auth via bitcoin-cli is simplest). ───────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ── lunarblock RPC over HTTP (empty rpcpassword -> no auth header). ────────
# lb_rpc <method> <json-params-array>  -> raw JSON-RPC envelope on stdout
lb_rpc() {
    curl -s --max-time 60 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
}
# lb_result <method> <params> -> the .result object as compact JSON (or empty)
lb_result() {
    lb_rpc "$1" "$2" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
r=d.get("result")
if r is not None: print(json.dumps(r))'
}
# core_result <method> <args...> -> the result as compact JSON
core_result() { core_cli "$@" 2>/dev/null; }

# ── 2. Launch the Core regtest oracle. ────────────────────────────────────
log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -fallbackfee=0.0002 -daemonwait=0 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 60 ))
core_up=0
while (( $(date +%s) < core_deadline )); do
    if core_cli getblockcount >/dev/null 2>&1; then core_up=1; break; fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_up" -eq 1 ]] || fail "Core oracle never came up within 60s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch lunarblock on regtest. ──────────────────────────────────────
log "launching lunarblock (regtest) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' --nov2transport" \
    >"$LB_LOG" 2>&1 &
LB_PID=$!
log "lunarblock pid=$LB_PID"
lb_deadline=$(( $(date +%s) + 90 ))
lb_up=0
while (( $(date +%s) < lb_deadline )); do
    if ! kill -0 "$LB_PID" 2>/dev/null; then
        tail -n 20 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock exited during startup (see $LB_LOG)"
    fi
    r=$(lb_rpc getblockchaininfo '[]')
    if echo "$r" | grep -q '"regtest"'; then lb_up=1; break; fi
    sleep 1
done
[[ "$lb_up" -eq 1 ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest within 90s"; }
log "lunarblock RPC ready"

# ── 4. Mine the SAME number of empty blocks on both nodes. ────────────────
# A fixed, well-formed regtest p2wpkh address (mainnet=false). Coinbase outputs
# go here; blocks stay empty (1 coinbase tx each) on both nodes.
MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

log "mining $NBLOCKS blocks on Core"
core_cli generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
core_h=$(core_cli getblockcount 2>/dev/null)
[[ "$core_h" == "$NBLOCKS" ]] || fail "Core height=$core_h expected $NBLOCKS"

log "mining $NBLOCKS blocks on lunarblock"
gen=$(lb_rpc generatetoaddress "[$NBLOCKS,\"$MINE_ADDR\"]")
echo "$gen" | grep -q '"result"' || { log "lunarblock generatetoaddress raw: $gen"; tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock generatetoaddress failed"; }
lb_h_env=$(lb_rpc getblockcount '[]')
lb_h=$(jget "$(echo "$lb_h_env" | python3 -c 'import sys,json; print(json.dumps({"result":json.load(sys.stdin).get("result")}))')" result)
[[ "$lb_h" == "$NBLOCKS" ]] || fail "lunarblock height=$lb_h expected $NBLOCKS"
log "both nodes at height $NBLOCKS"

HEIGHT="$NBLOCKS"
EXP_TXCOUNT=$(( HEIGHT + 1 ))      # genesis coinbase + 1 coinbase per block

# ── 5. Fetch getchaintxstats <WIN> from both (the main differential). ─────
log "querying getchaintxstats $WIN on both nodes"
LB_W=$(lb_result getchaintxstats "[$WIN]")
[[ -n "$LB_W" ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock getchaintxstats $WIN returned no result"; }
CORE_W=$(core_result getchaintxstats "$WIN")
[[ -n "$CORE_W" ]] || fail "Core getchaintxstats $WIN returned no result"
log "lunarblock[$WIN] = $LB_W"
log "Core[$WIN]       = $CORE_W"

# ── 6. txcount check (exact equality vs Core + vs derived height+1). ──────
TXCOUNT_T="ok"
lb_txc=$(jget "$LB_W" txcount)
core_txc=$(jget "$CORE_W" txcount)
if [[ "$lb_txc" == "__MISSING__" || "$lb_txc" == "__NULL__" ]]; then
    TXCOUNT_T="absent"
elif [[ "$lb_txc" != "$EXP_TXCOUNT" ]]; then
    TXCOUNT_T="bad:lb=$lb_txc!=$EXP_TXCOUNT"
elif [[ "$core_txc" != "$EXP_TXCOUNT" ]]; then
    TXCOUNT_T="oracle-anomaly:core=$core_txc"
elif [[ "$lb_txc" != "$core_txc" ]]; then
    TXCOUNT_T="ne-core:lb=$lb_txc,core=$core_txc"
fi
# Type must be integer.
[[ "$(jtype "$LB_W" txcount)" == "int" ]] || TXCOUNT_T="not-int"

# ── 7. window check (window_block_count, window_tx_count, final_height). ──
WINDOW_T="ok"
lb_wbc=$(jget "$LB_W" window_block_count)
core_wbc=$(jget "$CORE_W" window_block_count)
lb_wtc=$(jget "$LB_W" window_tx_count)
core_wtc=$(jget "$CORE_W" window_tx_count)
lb_wfh=$(jget "$LB_W" window_final_block_height)
core_wfh=$(jget "$CORE_W" window_final_block_height)
[[ "$lb_wbc"  == "$WIN"    ]] || WINDOW_T="block_count:lb=$lb_wbc!=$WIN"
[[ "$core_wbc" == "$WIN"   ]] || WINDOW_T="block_count-core:$core_wbc"
[[ "$lb_wtc"  == "$WIN"    ]] || WINDOW_T="tx_count:lb=$lb_wtc!=$WIN"
[[ "$core_wtc" == "$WIN"   ]] || WINDOW_T="tx_count-core:$core_wtc"
[[ "$lb_wfh"  == "$HEIGHT" ]] || WINDOW_T="final_height:lb=$lb_wfh!=$HEIGHT"
[[ "$core_wfh" == "$HEIGHT" ]] || WINDOW_T="final_height-core:$core_wfh"
[[ "$lb_wbc" == "$core_wbc" && "$lb_wtc" == "$core_wtc" && "$lb_wfh" == "$core_wfh" ]] \
    || WINDOW_T="${WINDOW_T}|ne-core(wbc:$lb_wbc/$core_wbc wtc:$lb_wtc/$core_wtc wfh:$lb_wfh/$core_wfh)"

# ── 8. shape check (time/hash/interval/txrate present + correctly typed). ─
SHAPE_T="ok"
# time present + int on both.
[[ "$(jtype "$LB_W" time)"   == "int" ]] || SHAPE_T="time-not-int:lb=$(jtype "$LB_W" time)"
[[ "$(jtype "$CORE_W" time)" == "int" ]] || SHAPE_T="time-not-int:core=$(jtype "$CORE_W" time)"
# time sane (positive unix seconds, this millennium-ish).
lb_time=$(jget "$LB_W" time)
[[ "$lb_time" =~ ^[0-9]+$ ]] && (( lb_time > 1000000000 )) || SHAPE_T="time-insane:$lb_time"
# window_final_block_hash is 64-hex on both, and equal (same chain shape => not
# guaranteed equal hashes since timestamps/nonce differ, so check shape only).
lb_hash=$(jget "$LB_W" window_final_block_hash)
core_hash=$(jget "$CORE_W" window_final_block_hash)
[[ "$lb_hash"   =~ ^[0-9a-f]{64}$ ]] || SHAPE_T="hash-shape:lb=$lb_hash"
[[ "$core_hash" =~ ^[0-9a-f]{64}$ ]] || SHAPE_T="hash-shape:core=$core_hash"
# window_interval present + int >= 0 when nblocks>0 (it is, WIN>0).
lb_wi=$(jget "$LB_W" window_interval)
lb_wi_t=$(jtype "$LB_W" window_interval)
core_wi_t=$(jtype "$CORE_W" window_interval)
[[ "$lb_wi_t"   == "int" ]] || SHAPE_T="interval-not-int:lb=$lb_wi_t"
[[ "$core_wi_t" == "int" ]] || SHAPE_T="interval-not-int:core=$core_wi_t"
[[ "$lb_wi" =~ ^-?[0-9]+$ ]] && (( lb_wi >= 0 )) || SHAPE_T="interval-negative:$lb_wi"
# txrate emit-condition parity: present IFF window_interval > 0. Match Core.
lb_txr_t=$(jtype "$LB_W" txrate)
core_txr_t=$(jtype "$CORE_W" txrate)
lb_has_txr=0;  [[ "$lb_txr_t"   == "int" || "$lb_txr_t"   == "float" ]] && lb_has_txr=1
core_has_txr=0; [[ "$core_txr_t" == "int" || "$core_txr_t" == "float" ]] && core_has_txr=1
# Expected: txrate present iff interval > 0.
exp_txr=0; [[ "$lb_wi" =~ ^[0-9]+$ ]] && (( lb_wi > 0 )) && exp_txr=1
[[ "$lb_has_txr" == "$exp_txr" ]] || SHAPE_T="txrate-emit-cond:has=$lb_has_txr exp=$exp_txr(interval=$lb_wi)"
# And lunarblock's txrate emit-decision must agree with Core's (both honour
# interval>0; on regtest interval is usually 0 so both omit txrate).
core_exp_txr=0
core_wi=$(jget "$CORE_W" window_interval)
[[ "$core_wi" =~ ^[0-9]+$ ]] && (( core_wi > 0 )) && core_exp_txr=1
[[ "$core_has_txr" == "$core_exp_txr" ]] || SHAPE_T="${SHAPE_T}|core-txrate-emit:has=$core_has_txr exp=$core_exp_txr"

# ── 9. nblocks0 check (getchaintxstats 0 drops the 3 window extras). ──────
NBLK0_T="ok"
LB_0=$(lb_result getchaintxstats "[0]")
CORE_0=$(core_result getchaintxstats 0)
[[ -n "$LB_0"   ]] || fail "lunarblock getchaintxstats 0 returned no result"
[[ -n "$CORE_0" ]] || fail "Core getchaintxstats 0 returned no result"
log "lunarblock[0] = $LB_0"
log "Core[0]       = $CORE_0"
# Base fields still present.
for f in time window_final_block_hash window_final_block_height window_block_count; do
    v=$(jget "$LB_0" "$f")
    [[ "$v" != "__MISSING__" && "$v" != "__NULL__" ]] || NBLK0_T="base-missing:$f"
done
# window_block_count must be 0.
[[ "$(jget "$LB_0" window_block_count)" == "0" ]] || NBLK0_T="wbc!=0:$(jget "$LB_0" window_block_count)"
# The 3 window extras must be ABSENT on both.
for f in window_interval window_tx_count txrate; do
    lv=$(jget "$LB_0" "$f")
    cv=$(jget "$CORE_0" "$f")
    [[ "$lv" == "__MISSING__" ]] || NBLK0_T="lb-emits-$f:$lv"
    [[ "$cv" == "__MISSING__" ]] || NBLK0_T="${NBLK0_T}|core-emits-$f:$cv"
done

# ── 10. Error-code parity (best-effort; reported, not summary-gated). ─────
# Bogus blockhash (64-hex that no block has) -> -5 on both.
BOGUS="00000000000000000000000000000000000000000000000000000000deadbeef"
lb_err=$(jerr_code "$(lb_rpc getchaintxstats "[1,\"$BOGUS\"]")")
core_err_raw=$(core_cli getchaintxstats 1 "$BOGUS" 2>&1 >/dev/null)
core_err=$(echo "$core_err_raw" | grep -oE 'code: -?[0-9]+' | grep -oE -- '-?[0-9]+' | head -1)
[[ -z "$core_err" ]] && core_err="?"
log "bogus-blockhash error: lunarblock=$lb_err core=$core_err (expect -5 on both)"
# Out-of-range nblocks (>= height) -> -8 on both.
big=$(( HEIGHT + 5 ))
lb_err2=$(jerr_code "$(lb_rpc getchaintxstats "[$big]")")
core_err2_raw=$(core_cli getchaintxstats "$big" 2>&1 >/dev/null)
core_err2=$(echo "$core_err2_raw" | grep -oE 'code: -?[0-9]+' | grep -oE -- '-?[0-9]+' | head -1)
[[ -z "$core_err2" ]] && core_err2="?"
log "out-of-range nblocks error: lunarblock=$lb_err2 core=$core_err2 (expect -8 on both)"

# ── 11. Verdict. ──────────────────────────────────────────────────────────
log "=== getchaintxstats DIFFERENTIAL (height=$HEIGHT, window=$WIN) ==="
log "  txcount=$TXCOUNT_T window=$WINDOW_T shape=$SHAPE_T nblocks0=$NBLK0_T"

FAILED=()
[[ "$TXCOUNT_T" == "ok" ]] || FAILED+=("txcount($TXCOUNT_T)")
[[ "$WINDOW_T"  == "ok" ]] || FAILED+=("window($WINDOW_T)")
[[ "$SHAPE_T"   == "ok" ]] || FAILED+=("shape($SHAPE_T)")
[[ "$NBLK0_T"   == "ok" ]] || FAILED+=("nblocks0($NBLK0_T)")

if [[ "${#FAILED[@]}" -gt 0 ]]; then
    fail "$(IFS=' '; echo "${FAILED[*]}") | txcount=$TXCOUNT_T window=$WINDOW_T shape=$SHAPE_T nblocks0=$NBLK0_T"
fi

log "PASS: count/height fields match Core exactly; time-dependent fields present+typed+emit-cond-correct"
pass ok ok ok ok
