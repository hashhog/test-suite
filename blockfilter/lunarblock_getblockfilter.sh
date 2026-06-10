#!/usr/bin/env bash
#
# lunarblock_getblockfilter.sh — self-contained getblockfilter (BIP-157/158)
#   Core-parity differential test.
#
# This proves lunarblock computes BIP-158 BASIC compact block filters
# BYTE-IDENTICALLY to a REAL bitcoind (Bitcoin Core) — both the encoded GCS
# "filter" and the chained BIP-157 "header" — for the SAME chain, including a
# multi-element filter (a block containing a SPEND, which contributes BOTH an
# output scriptPubKey AND the spent-prevout scriptPubKey to the element set).
#
# Core refs:
#   bitcoin-core/src/rpc/blockchain.cpp:2956-3031  getblockfilter
#     SIGNATURE: getblockfilter "blockhash" ( "filtertype" ), filtertype "basic".
#     RESULT: { "filter": <hex GCS>, "header": <hex 32-byte filter header> }.
#     ERRORS: unknown filtertype -> -5 "Unknown filtertype";
#             filter index not enabled -> -1 "Index is not enabled ...";
#             block not found -> -5 "Block not found".
#   bitcoin-core/src/blockfilter.cpp  GCSFilter / BasicFilterElements
#     P=19, M=784931; SipHash-2-4 key = first 16 bytes of the block HASH
#     (k0=GetUint64(0), k1=GetUint64(1)); HashToRange via FastRange64; sort
#     ascending; Golomb-Rice code the successive deltas; encoded =
#     CompactSize(N) || GCS bitstream.  ELEMENTS: every output scriptPubKey
#     except empty / OP_RETURN, PLUS every non-coinbase input's spent-prevout
#     scriptPubKey; deduped.
#   bitcoin-core/src/blockfilter.cpp:253-256  ComputeHeader
#     header = SHA256d(SHA256d(rawFilterBytes) || prev_block_filter_header),
#     chained from genesis (prev = all-zero).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest instance +
#   OWN ports, launched with -blockfilterindex=basic. Core MINES the blocks
#   (coinbase to a bare OP_TRUE script via generateblock, so the coinbase
#   output is anyone-can-spend); lunarblock receives the BYTE-IDENTICAL blocks
#   via submitblock (getblock <h> 0 -> submitblock). Replaying Core's own
#   serialized blocks gives lunarblock the EXACT same chain, so every filter
#   and filter-header is computed over identical bytes and must match.
#   A SPEND of the matured OP_TRUE coinbase (empty scriptSig) is mined into one
#   block so its filter is a genuine multi-element (output spk + spent-prevout
#   spk) filter, not a trivial 1-element coinbase-only filter.
#
# ASSERTIONS (both nodes, same block hashes):
#   1. filter  : "filter" hex byte-EXACT vs Core for a coinbase-only block
#                (1-element filter) AND a block containing a spend
#                (multi-element filter); "header" hex byte-EXACT for both.
#   2. chain   : the filter "header" at height N chains from N-1 across >=3
#                consecutive blocks, byte-identical to Core (catches a wrong
#                prev-header link — e.g. forgetting the genesis filter).
#   3. errors  : getblockfilter <hash> bogustype -> -5 "Unknown filtertype";
#                getblockfilter <unknown-hash> basic -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors blockheader/lunarblock_getblockheader.sh):
#   set -uo pipefail, no required args, idempotent, trap cleanup, scratch /tmp
#   datadirs + unique ports, ONE clean summary line on stdout, all noise ->
#   stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER lunarblock: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER lunarblock: FAIL <short reason>
#   SKIP: GETBLOCKFILTER lunarblock: SKIP <no filter index>
#
# Touches ONLY /tmp/gbf-lunarblock + /tmp/gbf-core and ports
#   22138/22158 (lunarblock RPC/P2P) + 22136/22156 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Never
#   broad-pkills bitcoind; only frees its OWN fixed ports / scratch dir.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

LB_DATADIR="/tmp/gbf-lunarblock"
LB_RPC=22138
LB_P2P=22158
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/gbf-core"
CORE_RPC=22136
CORE_P2P=22156
CORE_LOG="$CORE_DATADIR/core.log"

# Chain shape: 1 OP_TRUE coinbase block, then 100 maturity blocks, then 1
# block with the SPEND. Total height 102.
MATURITY=100
# A fixed, well-formed regtest p2wpkh address used as the spend's output and as
# the maturity-blocks' coinbase recipient.
MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockfilter:lunarblock] $*" >&2; }

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
# pass <filter> <header> <chain> <errors>
pass() {
    echo "GETBLOCKFILTER lunarblock: PASS filter=$1 header=$2 chain=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETBLOCKFILTER lunarblock: FAIL $*"
    exit 1
}
skip() {
    echo "GETBLOCKFILTER lunarblock: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gbf-lunarblock" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${LB_RPC}/${LB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
command -v luajit  >/dev/null 2>&1 || fail "luajit not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]    || fail "lunarblock entrypoint not found at $LB_DIR/src/main.lua"
[[ -x "$CORE_BIN" ]]               || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || fail "bitcoin-cli not found at $CORE_CLI"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_rpc <method> <json-params-array> -> full JSON-RPC envelope on stdout.
# Direct curl JSON-RPC against Core using the regtest .cookie; re-reads the
# cookie fresh each call and retries on auth/empty so a daemon-restart cookie
# rotation is tolerated.
core_rpc() {
    local method="$1" params="$2" cookie out
    for _ in 1 2 3 4 5 6 7 8; do
        cookie=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null)
        if [[ -n "$cookie" ]]; then
            out=$(curl -s --max-time 90 -u "$cookie" \
                --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
                "http://127.0.0.1:$CORE_RPC/" 2>/dev/null)
            if [[ -n "$out" ]] && ! echo "$out" | grep -qi "incorrect password\|unauthorized"; then
                echo "$out"; return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# lb_rpc <method> <json-params-array> -> raw JSON-RPC envelope on stdout
# (lunarblock defaults to an EMPTY rpcpassword on regtest -> no auth header).
lb_rpc() {
    curl -s --max-time 90 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
}

# jres <json-rpc-envelope> <python-expr-on-`r`> -> value (errors swallowed).
# `r` is the parsed .result; for primitive results it is the value itself.
jres() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    r = d.get('result')
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# jerr <json-rpc-envelope> -> the .error.code (or empty)
jerr() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    e = d.get('error')
    if isinstance(e, dict): print(e.get('code',''))
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# jerrmsg <json-rpc-envelope> -> the .error.message (or empty)
jerrmsg() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    e = d.get('error')
    if isinstance(e, dict): print(e.get('message',''))
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# field <json-rpc-result-obj> <key> -> value from .result object (or __ABSENT__)
field() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    r = d.get('result')
    if not isinstance(r, dict):
        print('__NORESULT__'); sys.exit()
    v = r.get('$2')
    if v is None: print('__ABSENT__')
    else: print(v)
except Exception:
    print('__ERR__')
" <<<"$1" 2>/dev/null
}

# ── 2. Launch the Core regtest oracle (-blockfilterindex=basic, -listen=0). ─
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
        -listen=0 -blockfilterindex=basic -acceptnonstdtxn=1 -fallbackfee=0.0002 \
        >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then return 0; fi
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

# ── 3. Build the chain on Core: OP_TRUE coinbase block, maturity, then SPEND. ─
# 3a. Resolve the canonical "raw(51)#<checksum>" descriptor (bare OP_TRUE spk).
DESC=$(jres "$(core_rpc getdescriptorinfo '["raw(51)"]')" "r['descriptor']")
[[ -n "$DESC" ]] || fail "Core getdescriptorinfo raw(51) failed (see $CORE_LOG)"
log "OP_TRUE descriptor: $DESC"

# 3b. Mine block 1 with the coinbase paying to bare OP_TRUE (anyone-can-spend).
B1=$(jres "$(core_rpc generateblock "[\"$DESC\", []]")" "r['hash']")
[[ "$B1" =~ ^[0-9a-f]{64}$ ]] || fail "Core generateblock (OP_TRUE coinbase) failed: $B1 (see $CORE_LOG)"

# 3c. Mature the coinbase: $MATURITY blocks to a standard p2wpkh address.
GEN=$(core_rpc generatetoaddress "[$MATURITY, \"$MINE_ADDR\"]")
echo "$GEN" | grep -q '"result"' || fail "Core generatetoaddress (maturity) failed: $GEN"

# 3d. Build a raw tx spending the OP_TRUE coinbase (empty scriptSig) -> p2wpkh.
CBTXID=$(jres "$(core_rpc getblock "[\"$B1\", 1]")" "r['tx'][0]")
[[ "$CBTXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not resolve OP_TRUE coinbase txid: '$CBTXID'"
# value 49.99 (0.01 BTC fee; the OP_TRUE input requires no signature).
RAW=$(jres "$(core_rpc createrawtransaction "[[{\"txid\":\"$CBTXID\",\"vout\":0}], [{\"$MINE_ADDR\":49.99}]]")" "r")
[[ -n "$RAW" ]] || fail "Core createrawtransaction failed (see $CORE_LOG)"
# sendrawtransaction with maxfeerate=0 to bypass the high-feerate guard.
SPENDTXID=$(jres "$(core_rpc sendrawtransaction "[\"$RAW\", 0]")" "r")
[[ "$SPENDTXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction (OP_TRUE spend) failed: '$SPENDTXID' (see $CORE_LOG)"
log "spend txid: $SPENDTXID"

# 3e. Mine a block INCLUDING the spend (coinbase OP_TRUE + the spend tx).
BSPEND=$(jres "$(core_rpc generateblock "[\"$DESC\", [\"$SPENDTXID\"]]")" "r['hash']")
[[ "$BSPEND" =~ ^[0-9a-f]{64}$ ]] || fail "Core generateblock (spend block) failed: $BSPEND (see $CORE_LOG)"

CORE_H=$(jres "$(core_rpc getblockcount '[]')" "r")
EXPECT_H=$(( 1 + MATURITY + 1 ))
[[ "$CORE_H" == "$EXPECT_H" ]] || fail "Core height=$CORE_H expected $EXPECT_H"
log "Core chain built to height $CORE_H (spend block $BSPEND has a multi-element filter)"

# Confirm the spend block really has 2 transactions (coinbase + the spend).
SPEND_NTX=$(jres "$(core_rpc getblock "[\"$BSPEND\", 1]")" "len(r['tx'])")
[[ "$SPEND_NTX" == "2" ]] || fail "spend block ntx=$SPEND_NTX expected 2"

# ── 4. Fetch ALL raw serialized blocks 1..H from Core (batched). ──────────
RAW_FILE="$LB_DATADIR/core_raw_blocks.txt"
log "fetching Core's $CORE_H raw blocks (batched)"
python3 - "$CORE_DATADIR/regtest/.cookie" "$CORE_RPC" "$CORE_H" "$RAW_FILE" <<'PY' 2>/dev/null || fail "Core batched raw-block fetch failed (see $CORE_LOG)"
import sys, json, base64, time, urllib.request
cookie_path, rpc_port, nblocks, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
url = 'http://127.0.0.1:%s/' % rpc_port
def call(batch):
    for _ in range(8):
        try:
            cookie = open(cookie_path).read().strip()
            auth = base64.b64encode(cookie.encode()).decode()
            req = urllib.request.Request(url, data=json.dumps(batch).encode(),
                headers={'Authorization':'Basic '+auth,'Content-Type':'application/json'})
            resp = json.loads(urllib.request.urlopen(req, timeout=120).read())
            if isinstance(resp, list) and all('result' in r and r['result'] is not None for r in resp):
                return resp
        except Exception:
            pass
        time.sleep(1)
    raise SystemExit("batched RPC call failed after retries")
hb = call([{'jsonrpc':'1.0','id':h,'method':'getblockhash','params':[h]} for h in range(1, nblocks+1)])
hashes = {r['id']: r['result'] for r in hb}
bb = call([{'jsonrpc':'1.0','id':h,'method':'getblock','params':[hashes[h], 0]} for h in range(1, nblocks+1)])
raws = {r['id']: r['result'] for r in bb}
with open(out_path, 'w') as f:
    for h in range(1, nblocks+1):
        f.write(raws[h] + "\n")
PY
[[ -s "$RAW_FILE" ]] || fail "Core raw-block file empty: $RAW_FILE"
mapfile -t RAW_ARR <"$RAW_FILE"
[[ "${#RAW_ARR[@]}" == "$CORE_H" ]] || fail "expected $CORE_H raw blocks, got ${#RAW_ARR[@]}"

# ── 5. Launch lunarblock on regtest WITH --blockfilterindex. ──────────────
log "launching lunarblock (regtest, --blockfilterindex) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' --blockfilterindex --nov2transport" \
    >"$LB_LOG" 2>&1 &
LB_PID=$!
log "lunarblock pid=$LB_PID"
lb_deadline=$(( $(date +%s) + 120 ))
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
[[ "$lb_up" -eq 1 ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest within 120s"; }
log "lunarblock RPC ready"

# 5a. Confirm the basic block filter index is actually enabled on lunarblock.
IDXINFO=$(lb_rpc getindexinfo '[]')
echo "$IDXINFO" | grep -q "basic block filter index" \
    || skip "lunarblock did not report a basic block filter index (getindexinfo: $IDXINFO)"

# ── 6. Replay Core's blocks into lunarblock via submitblock. ──────────────
log "replaying Core's $CORE_H blocks into lunarblock via submitblock"
for ((h=1; h<=CORE_H; h++)); do
    raw="${RAW_ARR[$((h-1))]}"
    [[ -n "$raw" ]] || fail "empty raw block at height $h"
    sub=$(lb_rpc submitblock "[\"$raw\"]")
    res=$(jres "$sub" "r")
    if [[ -n "$res" && "$res" != "duplicate" ]]; then
        log "lunarblock submitblock rejected block $h: $sub"
        tail -n 40 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock submitblock failed at height $h: '$res'"
    fi
done

lb_h=$(jres "$(lb_rpc getblockcount '[]')" "r")
[[ "$lb_h" == "$CORE_H" ]] || { tail -n 40 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock height=$lb_h expected $CORE_H after replay"; }
log "both nodes at height $CORE_H (identical chain)"

# Sanity: tip hashes equal on both nodes (chain truly identical).
CORE_TIP=$(jres "$(core_rpc getbestblockhash '[]')" "r")
LB_TIP=$(jres "$(lb_rpc getbestblockhash '[]')" "r")
[[ "$CORE_TIP" == "$LB_TIP" && "$CORE_TIP" =~ ^[0-9a-f]{64}$ ]] \
    || fail "tip hash mismatch after replay: core=$CORE_TIP lb=$LB_TIP"

# ── 7. CHECK 1 — filter + header byte-EXACT for two block shapes. ─────────
# Compare on ONE node for a given block hash; assert lunarblock == Core for:
#   (a) a coinbase-only block (the OP_TRUE coinbase block B1, 1-element filter),
#   (b) the spend block BSPEND (multi-element filter).
FILTER_T="ok"; HEADER_T="ok"

compare_block() {
    local label="$1" bh="$2"
    local c l cflt lflt chdr lhdr
    c=$(core_rpc getblockfilter "[\"$bh\", \"basic\"]")
    l=$(lb_rpc getblockfilter "[\"$bh\", \"basic\"]")
    cflt=$(field "$c" filter); chdr=$(field "$c" header)
    lflt=$(field "$l" filter); lhdr=$(field "$l" header)
    if [[ ! "$cflt" =~ ^[0-9a-f]+$ ]]; then
        FILTER_T="bad"; log "$label: Core filter not hex: '$cflt' (env: $c)"; return
    fi
    if [[ "$lflt" != "$cflt" ]]; then
        FILTER_T="bad"
        log "$label: FILTER mismatch"
        log "  core = $cflt"
        log "  lb   = $lflt"
    else
        log "$label: filter OK ($cflt)"
    fi
    if [[ ! "$chdr" =~ ^[0-9a-f]{64}$ ]]; then
        HEADER_T="bad"; log "$label: Core header not 64-hex: '$chdr'"; return
    fi
    if [[ "$lhdr" != "$chdr" ]]; then
        HEADER_T="bad"
        log "$label: HEADER mismatch"
        log "  core = $chdr"
        log "  lb   = $lhdr"
    else
        log "$label: header OK ($chdr)"
    fi
}

compare_block "coinbase-only(B1)" "$B1"
compare_block "spend(BSPEND)"      "$BSPEND"

# Also verify the multi-element nature is real: the spend block's filter must
# decode to N>=2 (CompactSize first byte). A 1-element filter here would mean
# the spent-prevout scriptPubKey was dropped.
SPEND_FLT=$(field "$(lb_rpc getblockfilter "[\"$BSPEND\", \"basic\"]")" filter)
if [[ "$SPEND_FLT" =~ ^[0-9a-f]+$ ]]; then
    SPEND_N=$((16#${SPEND_FLT:0:2}))
    [[ "$SPEND_N" -ge 2 ]] || { FILTER_T="bad"; log "spend block filter N=$SPEND_N (<2): spent-prevout spk likely dropped: $SPEND_FLT"; }
else
    FILTER_T="bad"; log "spend block filter not hex on lunarblock: '$SPEND_FLT'"
fi

# Default filtertype (omitted arg) must behave as "basic".
LB_DEF=$(lb_rpc getblockfilter "[\"$BSPEND\"]")
LB_DEF_FLT=$(field "$LB_DEF" filter)
[[ "$LB_DEF_FLT" == "$SPEND_FLT" ]] || { FILTER_T="bad"; log "default filtertype != basic: '$LB_DEF_FLT' vs '$SPEND_FLT'"; }

[[ "$FILTER_T" == "ok" ]] || fail "filter bytes not byte-exact vs Core (see log)"
[[ "$HEADER_T" == "ok" ]] || fail "filter header bytes not byte-exact vs Core (see log)"

# ── 8. CHECK 2 — HEADER CHAINING across >=3 consecutive blocks. ───────────
# The header at height N must chain from N-1: assert lunarblock's header equals
# Core's for several consecutive heights (a wrong prev-header link — e.g. a
# missing genesis filter — would make ALL of these diverge while individual
# `filter` bytes still match).
CHAIN_T="ok"
CHAIN_HEIGHTS=( $((CORE_H-2)) $((CORE_H-1)) "$CORE_H" 1 0 )
for h in "${CHAIN_HEIGHTS[@]}"; do
    bh=$(jres "$(core_rpc getblockhash "[$h]")" "r")
    [[ "$bh" =~ ^[0-9a-f]{64}$ ]] || { CHAIN_T="bad"; log "chain: bad blockhash at height $h"; continue; }
    chdr=$(field "$(core_rpc getblockfilter "[\"$bh\", \"basic\"]")" header)
    lhdr=$(field "$(lb_rpc   getblockfilter "[\"$bh\", \"basic\"]")" header)
    if [[ "$lhdr" != "$chdr" || ! "$chdr" =~ ^[0-9a-f]{64}$ ]]; then
        CHAIN_T="bad"
        log "chain: header mismatch at height $h: core='$chdr' lb='$lhdr'"
    else
        log "chain: height $h header OK ($chdr)"
    fi
done
[[ "$CHAIN_T" == "ok" ]] || fail "filter-header chain not byte-identical to Core (see log)"

# ── 9. CHECK 3 — ERRORS. ──────────────────────────────────────────────────
ERRORS_T="ok"
# 9a. unknown filtertype -> -5 "Unknown filtertype".
EBT=$(lb_rpc getblockfilter "[\"$BSPEND\", \"bogustype\"]")
EBT_CODE=$(jerr "$EBT"); EBT_MSG=$(jerrmsg "$EBT")
[[ "$EBT_CODE" == "-5" ]] || { ERRORS_T="bad"; log "unknown filtertype: expected code -5, got '$EBT_CODE' ($EBT)"; }
echo "$EBT_MSG" | grep -qi "Unknown filtertype" || { ERRORS_T="bad"; log "unknown filtertype: message not 'Unknown filtertype': '$EBT_MSG'"; }

# 9b. unknown block hash + basic -> -5.
BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
EBH=$(lb_rpc getblockfilter "[\"$BAD_HASH\", \"basic\"]")
EBH_CODE=$(jerr "$EBH")
[[ "$EBH_CODE" == "-5" ]] || { ERRORS_T="bad"; log "unknown blockhash: expected code -5, got '$EBH_CODE' ($EBH)"; }

# Cross-check Core agrees on both error codes (oracle parity for the error path).
C_EBT_CODE=$(jerr "$(core_rpc getblockfilter "[\"$BSPEND\", \"bogustype\"]")")
[[ "$C_EBT_CODE" == "-5" ]] || { ERRORS_T="bad"; log "Core unknown-filtertype code != -5: '$C_EBT_CODE'"; }
C_EBH_CODE=$(jerr "$(core_rpc getblockfilter "[\"$BAD_HASH\", \"basic\"]")")
[[ "$C_EBH_CODE" == "-5" ]] || { ERRORS_T="bad"; log "Core unknown-blockhash code != -5: '$C_EBH_CODE'"; }

[[ "$ERRORS_T" == "ok" ]] || fail "error-code/message check failed (see log)"

# ── 10. All checks green. ─────────────────────────────────────────────────
log "PASS: lunarblock getblockfilter matches Core (filter bytes + header bytes + header chain + errors)"
pass "$FILTER_T" "$HEADER_T" "$CHAIN_T" "$ERRORS_T"
