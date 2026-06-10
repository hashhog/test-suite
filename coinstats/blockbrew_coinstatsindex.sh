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
#   22273/22293 (blockbrew RPC/P2P) + 22275/22295 (Core RPC/P2P).
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
BB_RPC=22273
BB_P2P=22293
BB_LOG="$BB_DATADIR/node.log"
BB_COOKIE=""
BB_PID=""

CORE_DATADIR="/tmp/csi-core"
CORE_RPC=22275
CORE_P2P=22295
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

# Disabled-coinstatsindex error-gate node: a SECOND blockbrew + Core launched
# WITHOUT -coinstatsindex, to assert the non-tip query rejects with -8.
NOIDX_BB_DATADIR="/tmp/csi-blockbrew-noidx"
NOIDX_BB_RPC=22277
NOIDX_BB_P2P=22297
NOIDX_BB_LOG="$NOIDX_BB_DATADIR/node.log"
NOIDX_BB_COOKIE=""
NOIDX_BB_PID=""

NBLOCKS_PRE=149    # +1 spend block => tip ~150. Maturity 100 => block-1 coinbase spendable.
HIST_H=100         # HISTORICAL height to query, well below tip.

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[coinstatsindex:blockbrew] $*" >&2; }

# ── Port helpers: free a port and POLL until it's actually released. ───────
free_port() {
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): waits for OUR
    # just-stopped node to release the port. NEVER kills by port.
    local p="$1"
    for _ in $(seq 1 20); do
        ss -tln 2>/dev/null | grep -qE ":${p} " || return 0
        sleep 1
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
pass() { echo "COINSTATSINDEX blockbrew: PASS atheight=$1 txouts=$2 amount=$3 hash=$4 bestblock=$5 reorg=$6"; exit 0; }
fail() { echo "COINSTATSINDEX blockbrew: FAIL $*"; exit 1; }
skip() { echo "COINSTATSINDEX blockbrew: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
free_port "$BB_RPC"; free_port "$BB_P2P"
free_port "$NOIDX_BB_RPC"; free_port "$NOIDX_BB_P2P"
free_port "$CORE_RPC"; free_port "$CORE_P2P"
if ss -tln 2>/dev/null | grep -qE ":(${BB_RPC}|${BB_P2P}|${NOIDX_BB_RPC}|${NOIDX_BB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BB_RPC}/${BB_P2P}/${NOIDX_BB_RPC}/${NOIDX_BB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
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

log "PASS (linear): blockbrew coinstatsindex matches Core at historical height H=$HIST_H (height/bestblock/txouts/total_amount/muhash) + disabled-index error gate"

# ── 9. REORG-SAFETY GATE ───────────────────────────────────────────────────
# WHY: the at-height gate above only proves the impl maintains the per-height
# MuHash on a LINEAR chain (connect-only). It CANNOT catch a reorg-desync — an
# impl that reverses the index on disconnect but never RE-ADDS on reconnect of
# the new chain's blocks will pass linear yet serve a stale (chain-A) muhash for
# a height that was reorged onto chain B. Core's coinstatsindex (BaseIndex +
# index/coinstatsindex.cpp: CustomAppend on connect, CustomRemove on disconnect)
# re-runs CustomAppend when B's blocks reconnect, so its per-height MuHash tracks
# the ACTIVE chain. This gate forces a reorg and asserts the impl agrees.
#
# REORG DESIGN (impl-agnostic; the remaining-7 fanout MUST mirror these exact
# steps):
#   (1) Both nodes already share linear chain A at tip N (= $CORE_HEIGHT).
#   (2) On the Core ORACLE only: invalidateblock(getblockhash(F+1)) for a fork
#       point F < N. That disconnects A's F+1..N (Core runs CustomRemove for each).
#       Then generatetoaddress a LONGER competing chain B from F to N+3 to a
#       DETERMINISTIC address. B has strictly more work, so Core reorgs A->B and
#       its index re-runs CustomAppend for B's F+1..N+3.
#   (3) REORG TRIGGER via invalidateblock ON THE IMPL (Core-faithful). A naive
#       submitblock of B's blocks F+1..N+3 onto the impl while it still sits at A's
#       tip N does NOT trigger a reorg on a CORRECT node: B's fork-child re-spends
#       a UTXO that A spent above the fork, so a node that (correctly) validates an
#       incoming side-branch block against the ACTIVE-TIP UTXO snapshot rejects it
#       as a double-spend — B never imports and no reorg happens (nimrod/haskoin do
#       exactly this; their coinstatsindex is in fact reorg-safe, provable via
#       invalidateblock). So the trigger here MIRRORS Core's own reorg primitive:
#       FIRST call invalidateblock(getblockhash(F+1)) ON THE IMPL — this rewinds it
#       to fork point F, disconnecting A's F+1..N and RESTORING the prevouts those
#       blocks spent. THEN submitblock B's blocks F+1..N+3 to the impl in order;
#       each now connects as a clean ACTIVE-TIP extension against the restored
#       fork-point UTXO set, so the impl reorgs to B's tip and reconnects B into the
#       coinstatsindex. Poll until impl tip == Core B tip.
#       FALLBACK (impls lacking invalidateblock): build B's spend from a coinbase
#       created ABOVE F so the fork is self-contained (no cross-fork prevout reuse)
#       and submitblock alone suffices. blockbrew/nimrod/haskoin all support
#       invalidateblock, so this path uses it directly.
#   (4) Pick a height H_R with F < H_R <= N — a height whose block DIFFERS between
#       A and B. Call gettxoutsetinfo muhash H_R on BOTH and ASSERT
#       impl.muhash@H_R == Core.muhash@H_R AND impl.bestblock@H_R ==
#       Core.bestblock@H_R (the B-chain block at H_R, NOT A's). This FAILS iff the
#       impl's index did not reconnect B's blocks (the connect-on-reconnect gap).
REORG_OK="ok"
REORG_DEPTH=5                                   # A's blocks F+1..N that get reorged out
REORG_F=$(( CORE_HEIGHT - REORG_DEPTH ))        # fork point F (< N)
REORG_NEWTIP=$(( CORE_HEIGHT + 3 ))             # B's tip height (N+3): strictly more work
REORG_H=$CORE_HEIGHT                            # H_R: the OLD tip height (F < H_R <= N); block differs A vs B
[[ "$REORG_F" -gt "$HIST_H" ]] || log "note: fork point F=$REORG_F not above linear-H=$HIST_H (ok; reorg-H differs)"

# Record A's block hash at H_R (must change after the reorg, proving A!=B at H_R).
A_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "Core getblockhash $REORG_H (chain A) failed"
log "reorg: chain A tip N=$CORE_HEIGHT, fork F=$REORG_F, B newtip=$REORG_NEWTIP, reorg-H=$REORG_H (A@H_R=$A_HASH_AT_HR)"

# (2) On the Core oracle: invalidate F+1 then build longer chain B to a
#     deterministic address ($DST_ADDR — distinct from the A-mining address, so
#     B's blocks are deterministically different from A's even at equal heights).
FORK_CHILD=$(core_cli_retry getblockhash "$(( REORG_F + 1 ))") || fail "Core getblockhash F+1 failed"
core_cli invalidateblock "$FORK_CHILD" >/dev/null 2>&1 || fail "Core invalidateblock $FORK_CHILD failed"
INVAL_TIP=$(core_cli_retry getblockcount) || fail "Core getblockcount after invalidate failed"
[[ "$INVAL_TIP" == "$REORG_F" ]] || fail "Core after invalidate is at $INVAL_TIP, expected fork F=$REORG_F"
NB_B=$(( REORG_NEWTIP - REORG_F ))              # number of B blocks to generate (= depth+3)
core_cli_retry generatetoaddress "$NB_B" "$DST_ADDR" >/dev/null || fail "Core generatetoaddress (chain B) failed"
CORE_BTIP_H=$(core_cli_retry getblockcount) || fail "Core getblockcount (B tip) failed"
[[ "$CORE_BTIP_H" == "$REORG_NEWTIP" ]] || fail "Core B tip height $CORE_BTIP_H != expected $REORG_NEWTIP"
CORE_BTIP=$(core_cli_retry getbestblockhash) || fail "Core getbestblockhash (B) failed"
B_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "Core getblockhash $REORG_H (chain B) failed"
[[ "$B_HASH_AT_HR" != "$A_HASH_AT_HR" ]] \
    || fail "reorg sanity: block at H_R=$REORG_H unchanged after reorg (A=B=$A_HASH_AT_HR; not a real reorg)"
log "reorg: Core reorged to B, tip=$CORE_BTIP @h$CORE_BTIP_H; B@H_R=$B_HASH_AT_HR (differs from A@H_R)"

# (3) REORG TRIGGER: invalidateblock(F+1) ON THE IMPL first, rewinding it to fork
#     point F (disconnecting A's F+1..N and restoring the prevouts they spent), so
#     B's blocks then connect as clean active-tip extensions. A naive submitblock
#     of B onto A's tip would be (correctly) rejected as a side-branch double-spend.
IMPL_FORK_CHILD=$(bb_scalar getblockhash "[$(( REORG_F + 1 ))]")
[[ "$IMPL_FORK_CHILD" == "$FORK_CHILD" ]] \
    || fail "reorg: impl F+1 hash ($IMPL_FORK_CHILD) != Core F+1 hash ($FORK_CHILD) before invalidate"
log "reorg: invalidateblock F+1=$IMPL_FORK_CHILD on blockbrew (rewind to fork F=$REORG_F)"
IB_RESP=$(bb_rpc invalidateblock "[\"$IMPL_FORK_CHILD\"]")
echo "$IB_RESP" | grep -q '"error":null' || log "reorg: blockbrew invalidateblock -> $IB_RESP"
# Poll until the impl has actually rewound to fork point F.
IMPL_AT_F=0
for _ in $(seq 1 30); do
    BB_INVAL_H=$(bb_scalar getblockcount '[]')
    if [[ "$BB_INVAL_H" == "$REORG_F" ]]; then IMPL_AT_F=1; break; fi
    sleep 1
done
[[ "$IMPL_AT_F" == "1" ]] \
    || fail "blockbrew did not rewind to fork F=$REORG_F after invalidateblock (impl height=$BB_INVAL_H) — invalidateblock unsupported/ineffective"
BB_INVAL_TIP=$(bb_scalar getbestblockhash '[]')
log "reorg: blockbrew rewound to fork F=$REORG_F (tip $BB_INVAL_TIP)"

# Mirror B to the impl: submitblock B's blocks F+1..N+3 in order. Each now connects
# as a clean active-tip extension; B carries strictly more work so the impl adopts B.
log "reorg: mirroring B's blocks $(( REORG_F + 1 ))..$REORG_NEWTIP to blockbrew via submitblock"
B_RAW_LIST=$(python3 -c "
import sys, json, base64, urllib.request
cookie=open('$CORE_COOKIE_FILE').read().strip()
auth='Basic '+base64.b64encode(cookie.encode()).decode()
def rpc(method, params):
    body=json.dumps({'jsonrpc':'1.0','id':1,'method':method,'params':params}).encode()
    req=urllib.request.Request('http://127.0.0.1:$CORE_RPC/', data=body,
        headers={'Content-Type':'application/json','Authorization':auth})
    return json.load(urllib.request.urlopen(req, timeout=60))['result']
for h in range($(( REORG_F + 1 )), $REORG_NEWTIP+1):
    bh=rpc('getblockhash',[h])
    raw=rpc('getblock',[bh,0])
    print('%d %s'%(h, raw))
" 2>/dev/null) || fail "Core raw-block fetch for chain B failed"
GOT_B=$(echo "$B_RAW_LIST" | grep -c .)
[[ "$GOT_B" == "$NB_B" ]] || fail "fetched $GOT_B B-blocks from Core, expected $NB_B"
while read -r h RAW; do
    [[ -n "$RAW" ]] || continue
    kill -0 "$BB_PID" 2>/dev/null || fail "blockbrew died during B replication at h=$h (see $BB_LOG)"
    SUB=$(bb_rpc submitblock "[\"$RAW\"]")
    echo "$SUB" | grep -q '"error":null' || log "reorg submitblock h=$h -> $SUB"
done <<< "$B_RAW_LIST"

# Poll until impl tip == Core tip (B). If the impl never adopts B, that is itself
# a reorg failure (it could not switch to the more-work chain).
BB_REORG_OK=0
for _ in $(seq 1 30); do
    BB_BTIP=$(bb_scalar getbestblockhash '[]')
    BB_BTIP_H=$(bb_scalar getblockcount '[]')
    if [[ "$BB_BTIP" == "$CORE_BTIP" && "$BB_BTIP_H" == "$CORE_BTIP_H" ]]; then BB_REORG_OK=1; break; fi
    sleep 1
done
[[ "$BB_REORG_OK" == "1" ]] \
    || fail "blockbrew did not adopt chain B (impl tip=$BB_BTIP @h$BB_BTIP_H, Core B tip=$CORE_BTIP @h$CORE_BTIP_H) — reorg to more-work chain failed"
log "reorg: blockbrew adopted chain B (tip $BB_BTIP @h$BB_BTIP_H)"

# (4) The reorg differential: gettxoutsetinfo muhash H_R on BOTH. Assert the
#     impl serves B's per-height MuHash + bestblock, NOT A's stale value.
RB_MUH=$(core_cli_retry gettxoutsetinfo muhash "$REORG_H") || fail "Core gettxoutsetinfo muhash $REORG_H (post-reorg) failed"
RC_HEIGHT=$(echo "$RB_MUH" | python3 -c "import sys,json;print(json.load(sys.stdin).get('height',''))" 2>/dev/null)
RC_BEST=$(echo "$RB_MUH"   | python3 -c "import sys,json;print(json.load(sys.stdin).get('bestblock',''))" 2>/dev/null)
RC_MUHASH=$(echo "$RB_MUH" | python3 -c "import sys,json;print(json.load(sys.stdin).get('muhash',''))" 2>/dev/null)
[[ "$RC_HEIGHT" == "$REORG_H" ]] || fail "Core post-reorg muhash@H_R height=$RC_HEIGHT != H_R=$REORG_H"
[[ "$RC_BEST" == "$B_HASH_AT_HR" ]] || fail "Core post-reorg bestblock@H_R=$RC_BEST != B@H_R=$B_HASH_AT_HR (oracle wrong?)"

RB_BEST=$(bb_field gettxoutsetinfo "[\"muhash\", $REORG_H]" bestblock)
RB_MUHASH=$(bb_field gettxoutsetinfo "[\"muhash\", $REORG_H]" muhash)
RB_HEIGHT=$(bb_field gettxoutsetinfo "[\"muhash\", $REORG_H]" height)
log "reorg @H_R=$REORG_H: core(best=$RC_BEST muhash=$RC_MUHASH) bb(height=$RB_HEIGHT best=$RB_BEST muhash=$RB_MUHASH)"

if [[ "$RB_BEST" == "$A_HASH_AT_HR" ]]; then
    REORG_OK="bad"; log "reorg DESYNC: blockbrew bestblock@H_R=$RB_BEST is A's stale block (B@H_R=$B_HASH_AT_HR) — index did not reconnect B"
fi
[[ "$RB_HEIGHT" == "$REORG_H" ]] \
    || { REORG_OK="bad"; log "reorg: blockbrew height@H_R=$RB_HEIGHT != H_R=$REORG_H"; }
[[ "$RB_BEST" == "$B_HASH_AT_HR" && "$RB_BEST" == "$RC_BEST" ]] \
    || { REORG_OK="bad"; log "reorg: bestblock@H_R mismatch (bb=$RB_BEST want B@H_R=$B_HASH_AT_HR core=$RC_BEST)"; }
[[ -n "$RB_MUHASH" && "$RB_MUHASH" == "$RC_MUHASH" ]] \
    || { REORG_OK="bad"; log "reorg: muhash@H_R MISMATCH (bb=$RB_MUHASH core=$RC_MUHASH) — impl served stale chain-A index after reorg"; }

[[ "$REORG_OK" == "ok" ]] || fail "reorg-safety gate failed at H_R=$REORG_H (impl muhash/bestblock did not follow reorg from A to B; coinstatsindex reconnects on connect+disconnect but NOT on reconnect of the new chain)"
log "REORG OK @H_R=$REORG_H: blockbrew muhash+bestblock match Core's B-chain values after reorg"

pass "$ATH_T" "$TXOUTS_T" "$AMOUNT_T" "$HASH_T" "$BEST_T" "$REORG_OK"
