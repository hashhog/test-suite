#!/usr/bin/env bash
#
# blockbrew_getblockfilter.sh — self-contained getblockfilter Core-parity test.
#
# A SUBSTANTIVE indexing green-cell. getblockfilter serves BIP-157/158 compact
# block filters to SPV clients. Unlike getindexinfo (which only reports index
# *status*), this proves blockbrew computes the BIP-158 BASIC filter (type 0x00)
# + the BIP-157 filter-header chain BYTE-IDENTICALLY to Bitcoin Core.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:2956-3031 (getblockfilter)
#   bitcoin-core/src/blockfilter.{h,cpp}            (BlockFilter / GCSFilter)
#   BIP-158 (basic filter element set + GCS encoding), BIP-157 (header chain).
#
#   SIGNATURE: getblockfilter "blockhash" ( "filtertype" ).  filtertype "basic".
#   OUTPUT: { "filter": <hex GCS>, "header": <hex 32-byte filter header> }.
#   ERRORS:
#     unknown filtertype       -> RPC_INVALID_ADDRESS_OR_KEY (-5) "Unknown filtertype"
#     filter index not enabled -> RPC_MISC_ERROR (-1) "Index is not enabled ..."
#     block not found          -> RPC_INVALID_ADDRESS_OR_KEY (-5) "Block not found"
#
# BIP-158 BASIC FILTER (must match Core byte-for-byte):
#   ELEMENTS: every output scriptPubKey EXCEPT empty + OP_RETURN; PLUS for every
#     non-coinbase input, the scriptPubKey of the prevout it spends (from undo
#     data). Dedup identical elements.
#   GCS: P=19, M=784931. SipHash-2-4 key = first 16 bytes of the block HASH
#     (k0=bytes0..8 LE, k1=bytes8..16 LE). element -> 64-bit value mapped into
#     [0,N*M) via (hash*range)>>64. Sort ascending, Golomb-Rice the diffs (P=19).
#   ENCODED FILTER: CompactSize(N) || GCS bitstream, hex-encoded.
#   HEADER: SHA256d( SHA256d(rawFilterBytes) || prevBlockFilterHeader ), chained;
#     prev for genesis's parent is all-zero.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core), launched on its OWN
#   scratch regtest instance + OWN ports, with -blockfilterindex=basic. To make
#   the filters/headers BYTE-EXACT across nodes, both nodes must share the
#   IDENTICAL chain: Core (which has a full wallet) mines the chain INCLUDING a
#   real SPEND tx (so the spend block's filter has BOTH an output scriptPubKey
#   AND a spent-prevout scriptPubKey — a genuine multi-element filter), then we
#   REPLICATE every block to blockbrew via submitblock(getblock(h,0)). blockbrew
#   rebuilds its own UTXO/undo set as it connects each block, so its spent-
#   prevout elements are populated identically. blockbrew runs with its own
#   -blockfilterindex enabled.
#
# WHAT MUST MATCH CORE EXACTLY:
#   1. filter hex byte-EXACT + header hex byte-EXACT for:
#        - a coinbase-only block (1-element filter)
#        - the spend block (multi-element filter: output spk + spent prevout spk)
#   2. HEADER CHAINING: header @N must chain from @N-1 across >=3 consecutive
#      blocks (byte-equal to Core each height — catches a wrong prev-header link).
#   3. ERRORS: bogus filtertype -> -5 "Unknown filtertype";
#              unknown blockhash -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors blockheader/blockbrew_getblockheader.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1. Run under: setsid -w bash blockbrew_getblockfilter.sh
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER blockbrew: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER blockbrew: FAIL <short reason>
#   SKIP: GETBLOCKFILTER blockbrew: SKIP <no filter index>
#
# Touches ONLY /tmp/gbf-blockbrew/ + /tmp/gbf-core/ and ports
#   40233/40253 (blockbrew RPC/P2P) + 40235/40255 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Never broad-pkills bitcoind by name (a live mainnet bitcoind may be running);
#   only frees its OWN fixed ports + scratch dir.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

# Deterministic test secrets -> two controlled p2wpkh bcrt1 addresses. The Core
# build here is wallet-less (createwallet -> -32601 Method not found), so we mine
# coinbases to MINE_ADDR (key we control), then build/sign a RAW spend tx with
# MINE_WIF that pays DST_ADDR. That gives the spend block both an output spk and
# a spent-prevout spk without needing the wallet RPCs.
MINE_SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

BB_DATADIR="/tmp/gbf-blockbrew"
BB_RPC=40233
BB_P2P=40253
BB_LOG="$BB_DATADIR/node.log"
BB_COOKIE=""
BB_PID=""

CORE_DATADIR="/tmp/gbf-core"
CORE_RPC=40235
CORE_P2P=40255
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

NBLOCKS_PRE=110    # mine 110 blocks to the wallet (coinbase matures at 100).
# After NBLOCKS_PRE we sendtoaddress (spend) then mine 1 block (the spend block),
# then 3 trailing blocks. Final height = NBLOCKS_PRE + 1 + 3 = 114.

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockfilter:blockbrew] $*" >&2; }

# ── Cleanup: kill OWN nodes + free OWN ports + wipe scratch on any exit. ───
# NOTE: never `pkill -f bitcoind` / never broad kill by binary name — a live
# mainnet bitcoind may be running. Only our OWN datadir-scoped CLI stop + our
# OWN fixed ports + our OWN child PID.
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
    fuser -k "${BB_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${BB_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETBLOCKFILTER blockbrew: PASS filter=$1 header=$2 chain=$3 errors=$4"; exit 0; }
fail() { echo "GETBLOCKFILTER blockbrew: FAIL $*"; exit 1; }
skip() { echo "GETBLOCKFILTER blockbrew: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
fuser -k "${BB_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${BB_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || fail "blockbrew binary not found at $NODE_BIN (build with: go build -o blockbrew ./cmd/blockbrew)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# Derive the two controlled addresses + the mining WIF from the test_framework.
DERIVE=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
from test_framework.wallet_util import bytes_to_wif
def one(hexsec):
    k=ECKey(); k.set(bytes.fromhex(hexsec),compressed=True)
    return key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False)
print(one('$MINE_SECRET'))
print(one('$DST_SECRET'))
print(bytes_to_wif(bytes.fromhex('$MINE_SECRET')))
" 2>/dev/null) || fail "could not derive deterministic addresses (Core test_framework import failed)"
MINE_ADDR=$(echo "$DERIVE" | sed -n '1p')
DST_ADDR=$(echo "$DERIVE" | sed -n '2p')
MINE_WIF=$(echo "$DERIVE" | sed -n '3p')
[[ "$MINE_ADDR" == bcrt1* && "$DST_ADDR" == bcrt1* && -n "$MINE_WIF" ]] \
    || fail "derived addresses/WIF malformed (mine='$MINE_ADDR' dst='$DST_ADDR')"
[[ "$MINE_ADDR" != "$DST_ADDR" ]] || fail "mine and dst addresses collided"
log "mine addr=$MINE_ADDR  dst addr=$DST_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }
core_cli_retry() {
    local out=""
    for _ in $(seq 1 20); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

bb_rpc() {
    curl -s --max-time 90 -u "$BB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$BB_RPC/" 2>/dev/null
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
bb_result() { jpy "$(bb_rpc "$1" "$2")" "json.dumps(d['result'])"; }
bb_scalar() { jpy "$(bb_rpc "$1" "$2")" "d['result']"; }
bb_errcode() { jpy "$(bb_rpc "$1" "$2")" "d['error']['code']"; }
bb_errmsg()  { jpy "$(bb_rpc "$1" "$2")" "d['error']['message']"; }
# bb_field <method> <params> <field> -> result[field] scalar (or empty).
bb_field() { jpy "$(bb_rpc "$1" "$2")" "d['result']['$3']"; }

# ── 2. Launch the Core regtest oracle with -blockfilterindex=basic. ───────
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
        -blockfilterindex=basic -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle (-blockfilterindex=basic) rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch blockbrew on regtest WITH -blockfilterindex enabled. ────────
launch_bb_once() {
    BB_COOKIE=""
    fuser -k "${BB_RPC}/tcp" >/dev/null 2>&1 || true
    rm -rf "$BB_DATADIR"; mkdir -p "$BB_DATADIR"
    "$NODE_BIN" -network=regtest -datadir="$BB_DATADIR" \
        -rpcbind="127.0.0.1:$BB_RPC" -nolisten -blockfilterindex \
        -metricsport=0 >"$BB_LOG" 2>&1 &
    BB_PID=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if [[ -z "$BB_COOKIE" ]]; then
            for c in "$BB_DATADIR/regtest/.cookie" "$BB_DATADIR/.cookie"; do
                [[ -f "$c" ]] && BB_COOKIE=$(cat "$c") && break
            done
        fi
        if [[ -n "$BB_COOKIE" ]] && echo "$(bb_rpc getblockcount '[]')" | grep -q '"result"'; then
            return 0
        fi
        kill -0 "$BB_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
BB_OK=0
for attempt in 1 2 3; do
    log "launching blockbrew (regtest, nolisten, -blockfilterindex) rpc=:$BB_RPC -> $BB_LOG (attempt $attempt)"
    if launch_bb_once; then BB_OK=1; break; fi
    log "blockbrew launch attempt $attempt failed (see $BB_LOG); retrying after settle"
    [[ -n "$BB_PID" ]] && kill "$BB_PID" 2>/dev/null || true
    BB_PID=""
    sleep 3
done
[[ "$BB_OK" == "1" ]] || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew failed to start within 3 attempts (see $BB_LOG)"; }
log "blockbrew RPC ready"

# Early SKIP: if blockbrew doesn't have a filter index wired, getblockfilter
# on the genesis hash returns the "Index is not enabled" RPC_MISC_ERROR (-1).
GEN_HASH=$(core_cli_retry getblockhash 0) || fail "Core getblockhash 0 failed"
BB_GEN_PROBE=$(bb_errcode getblockfilter "[\"$GEN_HASH\", \"basic\"]")
if [[ "$BB_GEN_PROBE" == "-1" ]]; then
    skip "blockbrew has no basic block filter index (getblockfilter -> -1 'Index is not enabled')"
fi

# ── 4. Build the shared chain on Core (with a real SPEND tx). ─────────────
# Wallet-less Core: mine coinbases to MINE_ADDR (we hold the key), mature them,
# then build + sign a RAW tx spending the height-1 coinbase output, send it to
# the mempool, and mine the spend block. Then 3 trailing blocks.
log "mining $NBLOCKS_PRE blocks to $MINE_ADDR (coinbase maturity)"
core_cli_retry generatetoaddress "$NBLOCKS_PRE" "$MINE_ADDR" >/dev/null \
    || fail "Core generatetoaddress (pre) failed"

# Grab the coinbase output of block 1 (matured: 110 confs >> 100) to spend.
CB1_BLOCKHASH=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
CB1_TXID=$(core_cli_retry getblock "$CB1_BLOCKHASH" 1 | python3 -c "
import sys,json; print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ -n "$CB1_TXID" ]] || fail "could not read coinbase txid of block 1"
# Coinbase output 0: value + scriptPubKey (the MINE_ADDR p2wpkh spk).
CB1_INFO=$(core_cli_retry getrawtransaction "$CB1_TXID" 2 "$CB1_BLOCKHASH" | python3 -c "
import sys,json
t=json.load(sys.stdin); o=t['vout'][0]
print('%s|%s'%(o['value'], o['scriptPubKey']['hex']))" 2>/dev/null)
CB1_VALUE="${CB1_INFO%%|*}"
CB1_SPK="${CB1_INFO##*|}"
[[ -n "$CB1_VALUE" && -n "$CB1_SPK" ]] || fail "could not read coinbase vout0 (value/spk)"

# Build the raw spend: input = (CB1_TXID, vout 0); output = DST_ADDR with a
# 0.0001 BTC fee deducted. createrawtransaction takes amounts in BTC.
SPEND_OUT_BTC=$(python3 -c "print('%.8f' % (float('$CB1_VALUE') - 0.0001))" 2>/dev/null)
[[ -n "$SPEND_OUT_BTC" ]] || fail "could not compute spend output amount"
RAW_UNSIGNED=$(core_cli_retry createrawtransaction \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0}]" \
    "[{\"$DST_ADDR\":$SPEND_OUT_BTC}]") || fail "Core createrawtransaction failed"
[[ -n "$RAW_UNSIGNED" ]] || fail "createrawtransaction returned empty"

# Sign with the mining WIF, supplying the prevout details (segwit needs amount).
SIGNED=$(core_cli_retry signrawtransactionwithkey "$RAW_UNSIGNED" \
    "[\"$MINE_WIF\"]" \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0,\"scriptPubKey\":\"$CB1_SPK\",\"amount\":$CB1_VALUE}]") \
    || fail "Core signrawtransactionwithkey failed"
SPEND_HEX=$(echo "$SIGNED" | python3 -c "
import sys,json
s=json.load(sys.stdin)
assert s.get('complete') is True, 'sign incomplete: %r'%s
print(s['hex'])" 2>/dev/null)
[[ -n "$SPEND_HEX" ]] || fail "raw spend did not sign to completion (see Core log)"

SPEND_TXID=$(core_cli_retry sendrawtransaction "$SPEND_HEX") || fail "Core sendrawtransaction failed"
[[ -n "$SPEND_TXID" ]] || fail "sendrawtransaction returned empty txid"
log "raw spend tx in mempool: $SPEND_TXID"

# Mine the spend into a block -> this is our multi-element filter block.
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (spend block) failed"
SPEND_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount failed"
# 3 trailing blocks so the spend block has descendants for chaining checks.
core_cli_retry generatetoaddress 3 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (tail) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount failed"
EXPECTED=$(( NBLOCKS_PRE + 1 + 3 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED"

# Sanity: the spend block must actually contain the spend tx.
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$SPEND_HEIGHT") || fail "Core getblockhash spend failed"
HASTX=$(core_cli_retry getblock "$SPEND_BLOCKHASH" 1 | python3 -c "
import sys,json
b=json.load(sys.stdin); print('$SPEND_TXID' in b['tx'])
" 2>/dev/null)
[[ "$HASTX" == "True" ]] || fail "spend tx $SPEND_TXID not found in block @h$SPEND_HEIGHT (chain shape wrong)"
log "spend confirmed in block @h$SPEND_HEIGHT ($SPEND_BLOCKHASH)"

# ── 5. Replicate every Core block to blockbrew via submitblock. ───────────
log "replicating $CORE_HEIGHT Core blocks to blockbrew via submitblock"
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"
RAW_LIST=$(python3 -c "
import sys, json, base64, urllib.request
cookie=open('$CORE_COOKIE_FILE').read().strip()
auth='Basic '+base64.b64encode(cookie.encode()).decode()
def rpc(method, params):
    body=json.dumps({'jsonrpc':'1.0','id':1,'method':method,'params':params}).encode()
    req=urllib.request.Request('http://127.0.0.1:$CORE_RPC/', data=body,
        headers={'Content-Type':'application/json','Authorization':auth})
    return json.load(urllib.request.urlopen(req, timeout=60))['result']
for h in range(1, $CORE_HEIGHT+1):
    bh=rpc('getblockhash',[h])
    raw=rpc('getblock',[bh,0])
    print('%d %s'%(h, raw))
" 2>/dev/null) || fail "Core raw-block fetch (python JSON-RPC) failed"
GOT=$(echo "$RAW_LIST" | grep -c .)
[[ "$GOT" == "$CORE_HEIGHT" ]] || fail "fetched $GOT raw blocks from Core, expected $CORE_HEIGHT"
while read -r h RAW; do
    [[ -n "$RAW" ]] || continue
    kill -0 "$BB_PID" 2>/dev/null || fail "blockbrew process died during replication at h=$h (see $BB_LOG)"
    SUB=$(bb_rpc submitblock "[\"$RAW\"]")
    echo "$SUB" | grep -q '"error":null' || { log "submitblock h=$h -> $SUB"; }
done <<< "$RAW_LIST"
BB_HEIGHT=$(bb_scalar getblockcount '[]')
[[ "$BB_HEIGHT" == "$CORE_HEIGHT" ]] || fail "blockbrew height $BB_HEIGHT != Core $CORE_HEIGHT (submitblock did not take)"

CORE_TIP=$(core_cli_retry getbestblockhash)
BB_TIP=$(bb_scalar getbestblockhash '[]')
[[ -n "$CORE_TIP" && "$CORE_TIP" == "$BB_TIP" ]] \
    || fail "tip hash mismatch after replicate (core=$CORE_TIP bb=$BB_TIP) — chains not identical"
log "chains identical at tip $BB_TIP (height $CORE_HEIGHT)"

# Give blockbrew's block filter index a moment to catch up to tip (it indexes
# on connect during submitblock, but allow ouroboros/haskoin-style settle).
for _ in $(seq 1 90); do
    BB_TIPFILT=$(bb_errcode getblockfilter "[\"$BB_TIP\", \"basic\"]")
    [[ -z "$BB_TIPFILT" ]] && break   # no error => filter present
    sleep 1
done

# ── 6. assert_block <height> <label> -> compares filter+header byte-exact. ─
# Sets global FAILREASON on mismatch (returns 1). Logs both sides on diff.
assert_block() {
    local h="$1" label="$2"
    local bh corF corH bbF bbH
    bh=$(core_cli_retry getblockhash "$h") || { FAILREASON="getblockhash $h failed"; return 1; }

    # Core side via its getblockfilter (the oracle).
    local CJSON
    CJSON=$(core_cli_retry getblockfilter "$bh" basic) || { FAILREASON="Core getblockfilter @h$h failed"; return 1; }
    corF=$(echo "$CJSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['filter'])" 2>/dev/null)
    corH=$(echo "$CJSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['header'])" 2>/dev/null)
    [[ -n "$corF" && -n "$corH" ]] || { FAILREASON="Core filter/header empty @h$h"; return 1; }

    # blockbrew side.
    bbF=$(bb_field getblockfilter "[\"$bh\", \"basic\"]" filter)
    bbH=$(bb_field getblockfilter "[\"$bh\", \"basic\"]" header)
    [[ -n "$bbF" && -n "$bbH" ]] || { FAILREASON="blockbrew filter/header empty @h$h ($label)"; return 1; }

    if [[ "$bbF" != "$corF" ]]; then
        log "FILTER MISMATCH @h$h ($label):"
        log "  core: $corF"
        log "  bb  : $bbF"
        FAILREASON="filter hex != Core @h$h ($label)"
        return 1
    fi
    if [[ "$bbH" != "$corH" ]]; then
        log "HEADER MISMATCH @h$h ($label):"
        log "  core: $corH"
        log "  bb  : $bbH"
        FAILREASON="filter header hex != Core @h$h ($label)"
        return 1
    fi
    log "MATCH @h$h ($label): filter(${#bbF} hex) + header byte-exact vs Core"
    return 0
}

FAILREASON=""
FILTER_T="ok"
HEADER_T="ok"

# ── 7a. TEST 0 — GENESIS block (height 0) byte-exact. ─────────────────────
# Core's BaseIndex indexes the genesis block; its filter header chains from the
# all-zero parent. blockbrew must index genesis too — otherwise height-1's
# header chains from all-zero instead of from the genesis filter header and
# every header diverges. This is the case the WriteGenesis fix closes.
assert_block 0 "genesis/all-zero-parent" || { FILTER_T="bad"; HEADER_T="bad"; fail "$FAILREASON"; }

# ── 7b. TEST 1 — coinbase-only block (1-element filter) byte-exact. ───────
# A block well before the spend has only the coinbase output (a single
# non-OP_RETURN scriptPubKey) -> a 1-element filter.
COINBASE_ONLY_H=50
assert_block "$COINBASE_ONLY_H" "coinbase-only/1-element" || { FILTER_T="bad"; HEADER_T="bad"; fail "$FAILREASON"; }

# ── 8. TEST 2 — spend block (multi-element filter) byte-exact. ────────────
# Must have BOTH an output scriptPubKey AND a spent-prevout scriptPubKey, so the
# element set is >1 and exercises the undo-data prevout-script path.
assert_block "$SPEND_HEIGHT" "spend/multi-element" || { FILTER_T="bad"; HEADER_T="bad"; fail "$FAILREASON"; }

# Cross-check: the spend block's filter really is multi-element (N>1). Decode the
# CompactSize element count from the leading byte(s) of the filter and assert >1.
SBH=$(core_cli_retry getblockhash "$SPEND_HEIGHT")
SPEND_FILTER=$(bb_field getblockfilter "[\"$SBH\", \"basic\"]" filter)
SPEND_N=$(python3 -c "
f=bytes.fromhex('$SPEND_FILTER')
# CompactSize decode (regtest filters are tiny; first byte suffices for N<253).
if not f: print(0)
else:
    b=f[0]
    if b<253: print(b)
    elif b==253: print(int.from_bytes(f[1:3],'little'))
    elif b==254: print(int.from_bytes(f[1:5],'little'))
    else: print(int.from_bytes(f[1:9],'little'))
" 2>/dev/null)
[[ -n "$SPEND_N" && "$SPEND_N" -gt 1 ]] \
    || fail "spend block filter is not multi-element (N=$SPEND_N) — spent-prevout spk likely missing"
log "spend block filter element count N=$SPEND_N (multi-element confirmed)"

# ── 9. TEST 3 — HEADER CHAINING across >=3 consecutive blocks. ───────────
# Verify the header bytes match Core for SPEND_HEIGHT-1, SPEND_HEIGHT,
# SPEND_HEIGHT+1, SPEND_HEIGHT+2 (4 consecutive). A wrong prev-header link would
# diverge from Core at the first chained block even if a single filter matched.
CHAIN_T="ok"
for h in $(seq $((SPEND_HEIGHT-1)) $((SPEND_HEIGHT+2))); do
    assert_block "$h" "chain" || { CHAIN_T="bad"; fail "$FAILREASON"; }
done

# Local-consistency cross-check: blockbrew's own header @N must equal
# SHA256d( SHA256d(filterBytes@N) || header@N-1 ) using blockbrew's own filter
# and parent header — catches a chain that matches Core but isn't internally
# self-consistent (e.g. a stored-but-not-recomputed header).
CH1=$(core_cli_retry getblockhash $((SPEND_HEIGHT)))
CH0=$(core_cli_retry getblockhash $((SPEND_HEIGHT-1)))
FILT_N=$(bb_field getblockfilter "[\"$CH1\", \"basic\"]" filter)
HDR_N=$(bb_field getblockfilter "[\"$CH1\", \"basic\"]" header)
HDR_PREV=$(bb_field getblockfilter "[\"$CH0\", \"basic\"]" header)
RECOMPUTED=$(python3 -c "
import hashlib
def d256(b): return hashlib.sha256(hashlib.sha256(b).digest()).digest()
filt=bytes.fromhex('$FILT_N')
# header field is displayed big-endian (Core's uint256.GetHex()); the raw
# 32-byte value used in the chain hash is little-endian (internal). Reverse.
prev=bytes.fromhex('$HDR_PREV')[::-1]
fh=d256(filt)
hdr=d256(fh+prev)
print(hdr[::-1].hex())
" 2>/dev/null)
[[ -n "$RECOMPUTED" && "$RECOMPUTED" == "$HDR_N" ]] \
    || fail "header self-consistency: recomputed=$RECOMPUTED stored=$HDR_N (chain link not SHA256d(SHA256d(filter)||prevHeader))"
log "header self-consistency @h$SPEND_HEIGHT OK (SHA256d(SHA256d(filter)||prevHeader))"

# ── 10. TEST 4 — ERROR cases. ────────────────────────────────────────────
ERRORS_T="ok"

# bogus filtertype -> -5 "Unknown filtertype"
EBOGUS_CODE=$(bb_errcode getblockfilter "[\"$BB_TIP\", \"bogustype\"]")
EBOGUS_MSG=$(bb_errmsg  getblockfilter "[\"$BB_TIP\", \"bogustype\"]")
if [[ "$EBOGUS_CODE" != "-5" ]]; then
    ERRORS_T="bad"; log "bogus filtertype: expected code -5, got '$EBOGUS_CODE'"
fi
case "$EBOGUS_MSG" in
    *Unknown\ filtertype*) : ;;
    *) ERRORS_T="bad"; log "bogus filtertype: expected msg ~'Unknown filtertype', got '$EBOGUS_MSG'" ;;
esac

# unknown blockhash -> -5
ERR_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
EUNK_CODE=$(bb_errcode getblockfilter "[\"$ERR_HASH\", \"basic\"]")
if [[ "$EUNK_CODE" != "-5" ]]; then
    ERRORS_T="bad"; log "unknown blockhash: expected code -5, got '$EUNK_CODE'"
fi
[[ "$ERRORS_T" == "ok" ]] || fail "error-code check: bogus-type code='$EBOGUS_CODE' msg='$EBOGUS_MSG'; unknown-hash code='$EUNK_CODE'"

log "PASS: blockbrew getblockfilter matches Core (filter+header byte-exact for 1-element + multi-element + 4-block chain + errors)"
pass "$FILTER_T" "$HEADER_T" "$CHAIN_T" "$ERRORS_T"
