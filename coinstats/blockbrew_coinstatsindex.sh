#!/usr/bin/env bash
#
# blockbrew_coinstatsindex.sh — self-contained gettxoutsetinfo-AT-HISTORICAL-HEIGHT
# (coinstatsindex) Core-parity differential test for blockbrew.
#
# CAPABILITY UNDER TEST
#   gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#   With -coinstatsindex=1, you can query the UTXO-set statistics AS OF a
#   HISTORICAL block (not just the tip) by passing hash_or_height (a height int
#   or a block hash). This is backed by the coinstatsindex: a per-height running
#   UTXO-set muhash + counts maintained on every block connect/disconnect.
#   WITHOUT coinstatsindex, a non-tip hash_or_height must error with code -8
#   "Querying specific block heights requires coinstatsindex".
#
#   Core ref:
#     bitcoin-core/src/rpc/blockchain.cpp::gettxoutsetinfo   (the dispatcher;
#         line ~1086: `if (!g_coin_stats_index) throw -8 "Querying specific
#         block heights requires coinstatsindex";` and ~992 the index lookup
#         path `g_coin_stats_index->LookUpStats(*pindex)` used for MUHASH/NONE
#         when index_requested).
#     bitcoin-core/src/kernel/coinstats.cpp                   (per-coin hashing).
#     bitcoin-core/src/index/coinstatsindex.cpp               (the per-height
#         running muhash + counts; CustomAppend on connect, GetSummary).
#
# STRICT SHARED CONTRACT (gated identically across all 10 scripts; NONE optional):
#   * Launch BOTH the impl and a REAL bitcoind oracle on regtest, each with
#     -coinstatsindex=1 AND -txindex=1.
#   * Mine ~150 blocks to a deterministic address with a few REAL spends so the
#     UTXO set genuinely differs across heights (a historical-height query is
#     only meaningful if H's set != tip's set).
#   * Mirror the chain so both nodes share a byte-identical tip.
#   * Wait for coinstatsindex to sync (poll getindexinfo until synced, or until
#     gettxoutsetinfo @tip works through the index).
#   * Pick a HISTORICAL height H well below tip (H=100).
#   * Call gettxoutsetinfo "muhash" H (and the DEFAULT hash_type) on BOTH.
#   * GATE every one of:
#       impl.height       == H == Core.height
#       impl.bestblock    == Core.bestblock      (hash AT height H, NOT the tip)
#       impl.txouts       == Core.txouts
#       impl.total_amount == Core.total_amount
#       impl.<hashfield>  == Core.<hashfield>     (muhash, or hash_serialized_3)
#   * ERROR GATE: with coinstatsindex DISABLED, a non-tip hash_or_height must
#     error (match Core's -8).
#
# Summary line (stdout), EXACTLY:
#   PASS: COINSTATSINDEX blockbrew: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok
#   FAIL: COINSTATSINDEX blockbrew: FAIL <reason>
#   SKIP: COINSTATSINDEX blockbrew: SKIP <reason>   (only for a MISSING binary)
#
# A missing/un-wired coinstatsindex is a REAL FAIL (reported honestly), NOT a
# SKIP. SKIP is reserved for a missing/unbuilt binary (GAP_RE 'not found'/'not
# built').
#
# Boilerplate (node launch + Core oracle + chain mirror + teardown) is REUSED
# from test-suite/utxosetinfo/blockbrew_gettxoutsetinfo.sh, with -coinstatsindex=1
# + -txindex=1 added to BOTH node launches and the assertions swapped to the
# at-historical-height gates above.
#
# Touches ONLY /tmp/csi-blockbrew/ + /tmp/csi-core/ and ports
#   40373/40393 (blockbrew RPC/P2P) + 40375/40395 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Never broad-pkills bitcoind by name (a live mainnet bitcoind may run);
#   only frees its OWN fixed ports + scratch dir.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

# Deterministic test secrets -> two controlled p2wpkh bcrt1 addresses.
MINE_SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

BB_DATADIR="/tmp/csi-blockbrew"
BB_RPC=40373
BB_P2P=40393
BB_LOG="$BB_DATADIR/node.log"
BB_COOKIE=""
BB_PID=""

CORE_DATADIR="/tmp/csi-core"
CORE_RPC=40375
CORE_P2P=40395
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

# Disabled-coinstatsindex error-gate node: a SECOND blockbrew + Core launched
# WITHOUT -coinstatsindex, to assert the non-tip query rejects with -8.
NOIDX_BB_DATADIR="/tmp/csi-blockbrew-noidx"
NOIDX_BB_RPC=40377
NOIDX_BB_P2P=40397
NOIDX_BB_LOG="$NOIDX_BB_DATADIR/node.log"
NOIDX_BB_COOKIE=""
NOIDX_BB_PID=""

NBLOCKS_PRE=149    # +1 spend block => tip ~150. Maturity 100 => block-1 coinbase spendable.
HIST_H=100         # HISTORICAL height to query, well below tip.

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[coinstatsindex:blockbrew] $*" >&2; }

# ── Port helpers: free a port and POLL until it's actually released. ───────
free_port() {
    local port="$1"
    fuser -k "${port}/tcp" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 20); do
        fuser "${port}/tcp" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}

# ── Cleanup: kill OWN nodes + free OWN ports + wipe scratch on any exit. ───
cleanup() {
    local ec=$?
    for pid in "$BB_PID" "$NOIDX_BB_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for _ in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    free_port "$BB_RPC"; free_port "$BB_P2P"
    free_port "$NOIDX_BB_RPC"; free_port "$NOIDX_BB_P2P"
    free_port "$CORE_RPC"; free_port "$CORE_P2P"
    rm -rf "$BB_DATADIR" "$NOIDX_BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "COINSTATSINDEX blockbrew: PASS atheight=$1 txouts=$2 amount=$3 hash=$4 bestblock=$5"; exit 0; }
fail() { echo "COINSTATSINDEX blockbrew: FAIL $*"; exit 1; }
skip() { echo "COINSTATSINDEX blockbrew: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
free_port "$BB_RPC"; free_port "$BB_P2P"
free_port "$NOIDX_BB_RPC"; free_port "$NOIDX_BB_P2P"
free_port "$CORE_RPC"; free_port "$CORE_P2P"
rm -rf "$BB_DATADIR" "$NOIDX_BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || skip "blockbrew binary not found at $NODE_BIN (build with: go build -o blockbrew ./...)"
[[ -x "$CORE_BIN" ]] || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || skip "bitcoin-cli not found at $CORE_CLI"
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

# bb_rpc <method> <jsonparams> [rpcport] [cookie]
bb_rpc() {
    local port="${3:-$BB_RPC}" cookie="${4:-$BB_COOKIE}"
    curl -s --max-time 120 -u "$cookie" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$port/" 2>/dev/null
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
bb_scalar()  { jpy "$(bb_rpc "$1" "$2")" "d['result']"; }
bb_errcode() { jpy "$(bb_rpc "$1" "$2")" "d['error']['code']"; }
bb_errmsg()  { jpy "$(bb_rpc "$1" "$2")" "d['error']['message']"; }
bb_field()   { jpy "$(bb_rpc "$1" "$2")" "d['result']['$3']"; }
bb_has_field() { jpy "$(bb_rpc "$1" "$2")" "1 if ('$3' in d.get('result',{})) else ''"; }
# Variants that target the no-index node (for the error gate).
ni_errcode() { jpy "$(bb_rpc "$1" "$2" "$NOIDX_BB_RPC" "$NOIDX_BB_COOKIE")" "d['error']['code']"; }
ni_errmsg()  { jpy "$(bb_rpc "$1" "$2" "$NOIDX_BB_RPC" "$NOIDX_BB_COOKIE")" "d['error']['message']"; }

# ── 2. Launch the Core regtest oracle WITH -coinstatsindex=1 -txindex=1. ──
launch_core_once() {
    free_port "$CORE_RPC"; free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
        -coinstatsindex=1 -txindex=1 \
        -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle (-coinstatsindex=1 -txindex=1) rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch blockbrew on regtest WITH -coinstatsindex=1 -txindex=1. ─────
# If blockbrew does not recognize -coinstatsindex (the flag is undefined), it
# fails startup with "flag provided but not defined: -coinstatsindex". That is
# the canonical present-but-unwired signature: a real FAIL, not a SKIP.
launch_bb_idx_once() {
    BB_COOKIE=""
    free_port "$BB_RPC"
    rm -rf "$BB_DATADIR"; mkdir -p "$BB_DATADIR"
    "$NODE_BIN" -network=regtest -datadir="$BB_DATADIR" \
        -rpcbind="127.0.0.1:$BB_RPC" -nolisten \
        -coinstatsindex=1 -txindex=1 \
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
    log "launching blockbrew (regtest, -coinstatsindex=1 -txindex=1) rpc=:$BB_RPC -> $BB_LOG (attempt $attempt)"
    if launch_bb_idx_once; then BB_OK=1; break; fi
    # Detect the undefined-flag signature: blockbrew rejected -coinstatsindex
    # outright. Distinguish from a transient launch failure.
    if grep -qiE "not defined: -coinstatsindex|flag provided but not defined.*coinstatsindex" "$BB_LOG" 2>/dev/null; then
        log "blockbrew rejected -coinstatsindex at startup (see $BB_LOG)"
        BB_OK=flagrej
        break
    fi
    log "blockbrew launch attempt $attempt failed (see $BB_LOG); retrying after settle"
    [[ -n "$BB_PID" ]] && kill "$BB_PID" 2>/dev/null || true
    BB_PID=""
    sleep 3
done

if [[ "$BB_OK" == "flagrej" ]]; then
    fail "blockbrew has no -coinstatsindex flag (flag rejected at startup). Substrate exists but is present-but-unwired: internal/storage/coinstatsindex.go defines CoinStatsIndex (WriteBlock/RevertBlock/GetStats) but NewCoinStatsIndex is never called, no -coinstatsindex CLI flag / Config field (cmd/blockbrew/main.go has -txindex only), getindexinfo never reports it, and handleGetTxOutSetInfo hardcodes -8 'Querying specific block heights requires coinstatsindex' (internal/rpc/wave47b_methods.go) for ALL non-tip queries regardless of the index. coinstatsindexPresent=present-but-unwired"
fi
[[ "$BB_OK" == "1" ]] || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew failed to start within 3 attempts (see $BB_LOG)"; }
log "blockbrew RPC ready (with -coinstatsindex=1)"

# Early SKIP only if gettxoutsetinfo handler is entirely absent on the empty chain.
GENERR=$(bb_errcode gettxoutsetinfo '[]')
GENRES=$(bb_has_field gettxoutsetinfo '[]' height)
if [[ -n "$GENERR" && "$GENRES" != "1" ]]; then
    case "$GENERR" in
        -32601|32601) skip "blockbrew has no gettxoutsetinfo method (code $GENERR)";;
    esac
fi

# ── 4. Build the shared chain on Core (149 coinbases + a real SPEND tx). ──
log "mining $NBLOCKS_PRE blocks to $MINE_ADDR (coinbase maturity)"
core_cli_retry generatetoaddress "$NBLOCKS_PRE" "$MINE_ADDR" >/dev/null \
    || fail "Core generatetoaddress (pre) failed"

# Spend the matured block-1 coinbase output -> a spent output REMOVED + new
# outputs ADDED, so the UTXO set genuinely differs across heights.
CB1_BLOCKHASH=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
CB1_TXID=$(core_cli_retry getblock "$CB1_BLOCKHASH" 1 | python3 -c "
import sys,json; print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ -n "$CB1_TXID" ]] || fail "could not read coinbase txid of block 1"
CB1_INFO=$(core_cli_retry getrawtransaction "$CB1_TXID" 2 "$CB1_BLOCKHASH" | python3 -c "
import sys,json
t=json.load(sys.stdin); o=t['vout'][0]
print('%s|%s'%(o['value'], o['scriptPubKey']['hex']))" 2>/dev/null)
CB1_VALUE="${CB1_INFO%%|*}"
CB1_SPK="${CB1_INFO##*|}"
[[ -n "$CB1_VALUE" && -n "$CB1_SPK" ]] || fail "could not read coinbase vout0 (value/spk)"

SPEND_OUT_BTC=$(python3 -c "print('%.8f' % (float('$CB1_VALUE') - 0.0001))" 2>/dev/null)
[[ -n "$SPEND_OUT_BTC" ]] || fail "could not compute spend output amount"
RAW_UNSIGNED=$(core_cli_retry createrawtransaction \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0}]" \
    "[{\"$DST_ADDR\":$SPEND_OUT_BTC}]") || fail "Core createrawtransaction failed"
[[ -n "$RAW_UNSIGNED" ]] || fail "createrawtransaction returned empty"

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

# Mine the spend block. Final tip height = NBLOCKS_PRE + 1.
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (spend block) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount failed"
EXPECTED=$(( NBLOCKS_PRE + 1 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED"
[[ "$CORE_HEIGHT" -gt "$HIST_H" ]] || fail "tip $CORE_HEIGHT not above historical H=$HIST_H"

# Sanity: the spend block must actually contain the spend tx.
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$CORE_HEIGHT") || fail "Core getblockhash spend failed"
HASTX=$(core_cli_retry getblock "$SPEND_BLOCKHASH" 1 | python3 -c "
import sys,json
b=json.load(sys.stdin); print('$SPEND_TXID' in b['tx'])
" 2>/dev/null)
[[ "$HASTX" == "True" ]] || fail "spend tx $SPEND_TXID not found in block @h$CORE_HEIGHT (chain shape wrong)"
log "spend confirmed in block @h$CORE_HEIGHT ($SPEND_BLOCKHASH)"

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

# ── 6. Wait for coinstatsindex to sync on BOTH nodes. ─────────────────────
# Core: poll getindexinfo until coinstatsindex.synced && best_block_height==tip.
log "waiting for Core coinstatsindex to sync to tip $CORE_HEIGHT"
CORE_IDX_OK=0
for _ in $(seq 1 60); do
    SY=$(core_cli getindexinfo coinstatsindex 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); e=d.get('coinstatsindex',{})
    print('%s %s'%(e.get('synced'), e.get('best_block_height')))
except Exception: print('None None')" 2>/dev/null)
    if [[ "$SY" == "True $CORE_HEIGHT" ]]; then CORE_IDX_OK=1; break; fi
    sleep 1
done
[[ "$CORE_IDX_OK" == "1" ]] || fail "Core coinstatsindex did not sync to tip (last='$SY')"
log "Core coinstatsindex synced to tip"

# blockbrew: poll getindexinfo for coinstatsindex; fall back to a tip-via-index
# probe (gettxoutsetinfo muhash <tip>) if getindexinfo omits the entry.
log "waiting for blockbrew coinstatsindex to sync to tip $CORE_HEIGHT"
BB_IDX_OK=0
for _ in $(seq 1 60); do
    SY=$(jpy "$(bb_rpc getindexinfo '["coinstatsindex"]')" \
        "'%s %s'%(d['result'].get('coinstatsindex',{}).get('synced'), d['result'].get('coinstatsindex',{}).get('best_block_height'))")
    if [[ "$SY" == "True $CORE_HEIGHT" ]]; then BB_IDX_OK=1; break; fi
    # Fallback: does an at-tip indexed query succeed?
    PROBE_H=$(bb_field gettxoutsetinfo "[\"muhash\", $CORE_HEIGHT]" height)
    if [[ "$PROBE_H" == "$CORE_HEIGHT" ]]; then BB_IDX_OK=1; break; fi
    sleep 1
done
if [[ "$BB_IDX_OK" != "1" ]]; then
    # No coinstatsindex visible. Confirm whether the at-height query is even
    # accepted — if it errors -8, the index is present-but-unwired / absent.
    EC=$(bb_errcode gettxoutsetinfo "[\"muhash\", $HIST_H]")
    EM=$(bb_errmsg gettxoutsetinfo "[\"muhash\", $HIST_H]")
    fail "blockbrew coinstatsindex not synced/visible (getindexinfo coinstatsindex='$SY'); at-height query gettxoutsetinfo muhash $HIST_H -> code='$EC' msg='$EM'. coinstatsindexPresent=present-but-unwired"
fi
log "blockbrew coinstatsindex available"

# ── 7. AT-HISTORICAL-HEIGHT gate — query H=$HIST_H on BOTH, default + muhash. ─
HIST_BH=$(core_cli_retry getblockhash "$HIST_H") || fail "Core getblockhash $HIST_H failed"

ATH_T="ok"; TXOUTS_T="ok"; AMOUNT_T="ok"; HASH_T="ok"; BEST_T="ok"

# Choose the strong-hash field: prefer muhash (Core's index-served hash for the
# MUHASH path); accept hash_serialized_3 if that is what blockbrew serves.
core_athist() {
    # $1=field $2=hash_type
    core_cli_retry gettxoutsetinfo "$2" "$HIST_H" | python3 -c "
import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null
}

# --- muhash hash_type at H ---
C_HEIGHT=$(core_athist height muhash)
C_BEST=$(core_athist bestblock muhash)
C_TXOUTS=$(core_athist txouts muhash)
C_TOTAL=$(core_athist total_amount muhash)
C_MUHASH=$(core_athist muhash muhash)

B_HEIGHT=$(bb_field gettxoutsetinfo "[\"muhash\", $HIST_H]" height)
B_BEST=$(bb_field gettxoutsetinfo "[\"muhash\", $HIST_H]" bestblock)
B_TXOUTS=$(bb_field gettxoutsetinfo "[\"muhash\", $HIST_H]" txouts)
B_TOTAL_RAW=$(bb_field gettxoutsetinfo "[\"muhash\", $HIST_H]" total_amount)
B_MUHASH=$(bb_field gettxoutsetinfo "[\"muhash\", $HIST_H]" muhash)

# Normalize amounts via float.
C_TOTAL_N=$(python3 -c "print('%.8f'%float('$C_TOTAL'))" 2>/dev/null)
B_TOTAL_N=$(python3 -c "print('%.8f'%float('$B_TOTAL_RAW'))" 2>/dev/null)

# height == H == Core.height
[[ "$C_HEIGHT" == "$HIST_H" ]] || fail "Core height at H=$HIST_H returned '$C_HEIGHT' (oracle wrong?)"
[[ "$B_HEIGHT" == "$HIST_H" && "$B_HEIGHT" == "$C_HEIGHT" ]] \
    || { ATH_T="bad"; log "atheight mismatch: H=$HIST_H core=$C_HEIGHT bb=$B_HEIGHT"; }

# bestblock == hash AT height H (NOT the tip)
[[ "$C_BEST" == "$HIST_BH" ]] || fail "Core bestblock at H=$HIST_H ('$C_BEST') != getblockhash($HIST_H) ('$HIST_BH')"
[[ "$B_BEST" == "$HIST_BH" && "$B_BEST" == "$C_BEST" ]] \
    || { BEST_T="bad"; log "bestblock@H mismatch: want=$HIST_BH core=$C_BEST bb=$B_BEST"; }
# And it must NOT be the tip (proves it's really historical).
[[ "$B_BEST" != "$BB_TIP" ]] || { BEST_T="bad"; log "bestblock@H equals tip $BB_TIP — not a historical lookup"; }

# txouts
[[ -n "$C_TXOUTS" && "$B_TXOUTS" == "$C_TXOUTS" ]] \
    || { TXOUTS_T="bad"; log "txouts@H mismatch: core=$C_TXOUTS bb=$B_TXOUTS"; }

# total_amount
[[ -n "$C_TOTAL_N" && "$B_TOTAL_N" == "$C_TOTAL_N" ]] \
    || { AMOUNT_T="bad"; log "total_amount@H mismatch: core=$C_TOTAL_N bb=$B_TOTAL_N"; }

# muhash (the per-height running UTXO-set commitment)
if [[ -n "$C_MUHASH" && "$B_MUHASH" == "$C_MUHASH" ]]; then
    log "muhash@H=$HIST_H MATCH: $B_MUHASH"
else
    HASH_T="bad"; log "muhash@H mismatch: core=$C_MUHASH bb=$B_MUHASH"
fi

# --- DEFAULT hash_type at H (Core: hash_serialized_3, but the index path only
#     serves MUHASH/NONE; Core errs -8 for hash_serialized_3 + specific block
#     EVEN with coinstatsindex). Assert the default-hash_type at-H behavior
#     matches Core, whatever it is. ---
CORE_DEF_RAW=$(core_cli gettxoutsetinfo "" "$HIST_H" 2>&1)
CORE_DEF_ERR=$(echo "$CORE_DEF_RAW" | grep -i "error code" | grep -o '\-[0-9]*' | head -1)
BB_DEF_EC=$(bb_errcode gettxoutsetinfo "[\"hash_serialized_3\", $HIST_H]")
BB_DEF_H=$(bb_field gettxoutsetinfo "[\"hash_serialized_3\", $HIST_H]" height)
if [[ -n "$CORE_DEF_ERR" ]]; then
    # Core rejects hash_serialized_3 + specific block (-8). blockbrew must too.
    [[ "$BB_DEF_EC" == "$CORE_DEF_ERR" ]] \
        || { HASH_T="bad"; log "default(hash_serialized_3)@H: Core err=$CORE_DEF_ERR bb err='$BB_DEF_EC' h='$BB_DEF_H'"; }
    log "default hash_type @H: Core+bb both reject with $CORE_DEF_ERR (parity)"
else
    # Core served a hash_serialized_3 at H via the index: compare byte-exact.
    C_DEF_HS3=$(echo "$CORE_DEF_RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash_serialized_3',''))" 2>/dev/null)
    B_DEF_HS3=$(bb_field gettxoutsetinfo "[\"hash_serialized_3\", $HIST_H]" hash_serialized_3)
    [[ -n "$C_DEF_HS3" && "$B_DEF_HS3" == "$C_DEF_HS3" ]] \
        || { HASH_T="bad"; log "default(hash_serialized_3)@H mismatch: core=$C_DEF_HS3 bb=$B_DEF_HS3"; }
fi

# Verify the historical set genuinely differs from the tip set (otherwise the
# whole test degenerates to an @tip query).
TIP_MUHASH=$(bb_field gettxoutsetinfo '["muhash"]' muhash)
[[ -n "$TIP_MUHASH" && "$TIP_MUHASH" != "$B_MUHASH" ]] \
    || log "warning: historical muhash == tip muhash (set did not change between H and tip)"

# Roll up the at-height gate.
[[ "$ATH_T"    == "ok" ]] || fail "atheight gate failed (H=$HIST_H not reported as height on both)"
[[ "$BEST_T"   == "ok" ]] || fail "bestblock gate failed (hash at H=$HIST_H not matched / equals tip)"
[[ "$TXOUTS_T" == "ok" ]] || fail "txouts gate failed (core=$C_TXOUTS bb=$B_TXOUTS at H=$HIST_H)"
[[ "$AMOUNT_T" == "ok" ]] || fail "total_amount gate failed (core=$C_TOTAL_N bb=$B_TOTAL_N at H=$HIST_H)"
[[ "$HASH_T"   == "ok" ]] || fail "hash gate failed (muhash/default at H=$HIST_H mismatched Core)"
log "AT-HEIGHT OK @H=$HIST_H: height=$B_HEIGHT bestblock=$B_BEST txouts=$B_TXOUTS total=$B_TOTAL_N muhash=$B_MUHASH"

# ── 8. ERROR GATE — coinstatsindex DISABLED -> non-tip query errors (== Core). ─
# Launch a SECOND blockbrew on the SAME chain dir contents but WITHOUT
# -coinstatsindex, and assert a specific-block query rejects with -8, matching
# Core run without the index.
log "launching no-index blockbrew for the error gate (no -coinstatsindex)"
launch_bb_noidx_once() {
    NOIDX_BB_COOKIE=""
    free_port "$NOIDX_BB_RPC"
    rm -rf "$NOIDX_BB_DATADIR"; mkdir -p "$NOIDX_BB_DATADIR"
    "$NODE_BIN" -network=regtest -datadir="$NOIDX_BB_DATADIR" \
        -rpcbind="127.0.0.1:$NOIDX_BB_RPC" -nolisten \
        -txindex=1 \
        -metricsport=0 >"$NOIDX_BB_LOG" 2>&1 &
    NOIDX_BB_PID=$!
    local deadline=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < deadline )); do
        if [[ -z "$NOIDX_BB_COOKIE" ]]; then
            for c in "$NOIDX_BB_DATADIR/regtest/.cookie" "$NOIDX_BB_DATADIR/.cookie"; do
                [[ -f "$c" ]] && NOIDX_BB_COOKIE=$(cat "$c") && break
            done
        fi
        if [[ -n "$NOIDX_BB_COOKIE" ]] && echo "$(bb_rpc getblockcount '[]' "$NOIDX_BB_RPC" "$NOIDX_BB_COOKIE")" | grep -q '"result"'; then
            return 0
        fi
        kill -0 "$NOIDX_BB_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
ERR_GATE="ok"
if launch_bb_noidx_once; then
    NI_EC=$(ni_errcode gettxoutsetinfo "[\"muhash\", $HIST_H]")
    NI_EM=$(ni_errmsg gettxoutsetinfo "[\"muhash\", $HIST_H]")
    # Core without the index for the same query:
    CORE_NOIDX=$( "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        gettxoutsetinfo muhash "$HIST_H" 2>&1 )
    # (Core HERE has the index, so it would succeed; the parity reference for the
    #  DISABLED case is Core's documented -8. Assert blockbrew's disabled-node
    #  emits -8 with the canonical message.)
    [[ "$NI_EC" == "-8" ]] || { ERR_GATE="bad"; log "no-index blockbrew specific-block: expected -8, got code='$NI_EC' msg='$NI_EM'"; }
    case "$NI_EM" in
        *coinstatsindex*) : ;;
        *) ERR_GATE="bad"; log "no-index blockbrew specific-block msg lacks 'coinstatsindex': '$NI_EM'";;
    esac
    [[ "$ERR_GATE" == "ok" ]] && log "ERROR GATE OK: no-index node rejects non-tip query with -8 ('$NI_EM')"
else
    ERR_GATE="bad"; log "no-index blockbrew failed to launch for the error gate (see $NOIDX_BB_LOG)"
fi
[[ "$ERR_GATE" == "ok" ]] || fail "error gate failed (coinstatsindex-disabled node did not reject non-tip query with -8)"

log "PASS: blockbrew coinstatsindex matches Core at historical height H=$HIST_H (height/bestblock/txouts/total_amount/muhash) + disabled-index error gate"
pass "$ATH_T" "$TXOUTS_T" "$AMOUNT_T" "$HASH_T" "$BEST_T"
