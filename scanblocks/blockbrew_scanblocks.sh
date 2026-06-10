#!/usr/bin/env bash
#
# blockbrew_scanblocks.sh — self-contained scanblocks Core-parity test.
#
# scanblocks drives the BIP-157 basic block filter index to find blocks whose
# GCS filter MATCHES any of the given scanobjects' scriptPubKeys, returning
#   { from_height, to_height, relevant_blocks:[blockhash...], completed }.
# It is the index-side counterpart to scantxoutset (which walks the UTXO set):
# scanblocks walks compact block filters, so it can locate the block a script
# was funded/spent in even after the coin is gone.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp scanblocks (action start/status/
#   abort). SIGNATURE: scanblocks "action" ( [scanobjects] start_height
#   stop_height "filtertype" options ). filtertype default "basic".
#   action=status -> null (no scan running); action=abort -> false; action=start
#   does real work.
#   ERRORS (Core):
#     unknown action      -> -8 (RPC_INVALID_PARAMETER) [impl-specific code OK]
#     unknown filtertype  -> -5 (RPC_INVALID_ADDRESS_OR_KEY) "Unknown filtertype"
#     index disabled      -> -1 (RPC_MISC_ERROR) "Index is not enabled ..."
#     bad start/stop hght -> -1 (RPC_MISC_ERROR) "Invalid start_height/stop_height"
#
# CENTRAL CAVEAT: block filters have FALSE POSITIVES (rate ~1/M, M=784931), so
# relevant_blocks may contain EXTRA blocks. Every assertion here is a
# MEMBERSHIP / SUPERSET assertion over a KNOWN-TRUE block set — NEVER list
# length or set equality. The single non-negotiable: the block that actually
# contains the funded/spent script MUST appear in relevant_blocks.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest instance +
#   OWN ports, launched -listen=0 -blockfilterindex=basic. Core is the SINGLE
#   source of blocks: Core mines NBLOCKS empty blocks to a DETERMINISTIC p2wpkh
#   addr (MINE_ADDR), then a RAW BIP-143 spend of coinbase#1 -> a fresh p2wpkh
#   (DST_ADDR), mined into the spend block. Each block's raw hex is replayed
#   into blockbrew via submitblock. After replay both nodes hold the
#   byte-identical chain, so scanblocks over the SAME needle MUST agree on every
#   TRUE-positive block (filters are byte-identical; only false positives may
#   diverge). This is the SAME chain-construction the blockbrew getblockfilter
#   harness uses (wallet-less Core: createrawtransaction +
#   signrawtransactionwithkey).
#
# KNOWN-TRUE block set for needle addr(MINE_ADDR):
#   - block 1 (coinbase paying MINE_ADDR — its scriptPubKey is an OUTPUT), and
#   - the spend block (MINE_ADDR's p2wpkh appears as the SPENT prevout, which
#     BIP-158 includes from undo data; the spend block's coinbase also pays
#     MINE_ADDR).
#
# WHAT MUST HOLD (mirrors rustoshi_scanblocks.sh gated assertions exactly):
#   A. SHAPE: object {from_height:int, to_height:int, relevant_blocks:[64hex...],
#      completed:bool}. from==start, to==stop, completed==true.
#   B. MEMBERSHIP: relevant_blocks ⊇ {block1, spendblock} for addr(MINE_ADDR).
#   C. CORE CROSS-CHECK: impl relevant_blocks ⊇ (Core relevant_blocks projected
#      to known-true set); both lists contain the known-true projection.
#   D. NEGATIVE NEEDLE: addr(<fresh-unfunded>) -> block1 and spendblock ABSENT.
#   E. RANGE BOUNDING: a 1-block window on the spend block returns from==to==
#      H_spend and the spend block present; a window strictly below the funded
#      heights does NOT contain the funded blocks.
#   F. ACTIONS: status -> null; abort -> false; bogus action -> error.
#   G. ERRORS: unknown filtertype -> -5; start>tip -> -1; stop<start -> -1.
#
# STRICT UNIFORM INTERFACE (mirrors blockfilter/blockbrew_getblockfilter.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS: SCANBLOCKS blockbrew: PASS scan=ok shape=ok range=ok errors=ok
#   FAIL: SCANBLOCKS blockbrew: FAIL <short reason>
#   SKIP: SCANBLOCKS blockbrew: SKIP <no scanblocks RPC | no filter index>
#
# Touches ONLY /tmp/sblk-blockbrew/$$ + /tmp/sblk-core/$$ and ports
#   22330/22350 (blockbrew RPC/P2P) + 22332/22352 (Core RPC; P2P unused, -listen=0).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Never broad-pkills bitcoind by name (a live mainnet bitcoind may be running);
#   only frees its OWN fixed ports + scratch dir.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

# Deterministic test secrets -> controlled p2wpkh bcrt1 addresses. The Core
# build here is wallet-less (createwallet -> -32601 Method not found), so we mine
# coinbases to MINE_ADDR (key we control), then build/sign a RAW spend tx with
# MINE_WIF that pays DST_ADDR. A fresh, never-funded secret -> negative needle.
MINE_SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"
NEG_SECRET="3333333333333333333333333333333333333333333333333333333333333334"

BB_DATADIR="/tmp/sblk-blockbrew/$$"
BB_RPC=22330
BB_P2P=22350
BB_LOG="$BB_DATADIR/node.log"
BB_COOKIE=""
BB_PID=""

CORE_DATADIR="/tmp/sblk-core/$$"
CORE_RPC=22332
CORE_P2P=22352   # declared but Core launched -listen=0 (no P2P listener)
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

NBLOCKS_PRE=110    # mine 110 blocks to MINE_ADDR (coinbase matures at 100).
# After NBLOCKS_PRE we send the raw spend then mine 1 block (the spend block),
# then 3 trailing blocks. Final height = NBLOCKS_PRE + 1 + 3 = 114.

MINE_ADDR=""
DST_ADDR=""
NEG_ADDR=""

log() { echo "[scanblocks:blockbrew] $*" >&2; }

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
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "SCANBLOCKS blockbrew: PASS scan=$1 shape=$2 range=$3 errors=$4"; exit 0; }
fail() { echo "SCANBLOCKS blockbrew: FAIL $*"; exit 1; }
skip() { echo "SCANBLOCKS blockbrew: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports + OWN PID scratch only). ───────────────
log "resetting scratch state (pid=$$)"
pkill -f "sblk-blockbrew/$$" 2>/dev/null || true
if ss -tln 2>/dev/null | grep -qE ":(${BB_RPC}|${BB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BB_RPC}/${BB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || skip "blockbrew binary not found at $NODE_BIN (build with: go build -o blockbrew ./cmd/blockbrew)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive deterministic bcrt1 p2wpkh addresses (funded + dst + negative). ─
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
print(one('$NEG_SECRET'))
print(bytes_to_wif(bytes.fromhex('$MINE_SECRET')))
" 2>/dev/null) || fail "could not derive deterministic addresses (Core test_framework import failed)"
MINE_ADDR=$(echo "$DERIVE" | sed -n '1p')
DST_ADDR=$(echo "$DERIVE" | sed -n '2p')
NEG_ADDR=$(echo "$DERIVE" | sed -n '3p')
MINE_WIF=$(echo "$DERIVE" | sed -n '4p')
[[ "$MINE_ADDR" == bcrt1* && "$DST_ADDR" == bcrt1* && "$NEG_ADDR" == bcrt1* && -n "$MINE_WIF" ]] \
    || fail "derived addresses/WIF malformed (mine='$MINE_ADDR' dst='$DST_ADDR' neg='$NEG_ADDR')"
[[ "$MINE_ADDR" != "$DST_ADDR" && "$MINE_ADDR" != "$NEG_ADDR" ]] || fail "address collision"
log "mine addr=$MINE_ADDR  dst addr=$DST_ADDR  neg needle=$NEG_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }
core_cli_retry() {
    local out=""
    for _ in $(seq 1 20); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        kill -0 "$CORE_BG" 2>/dev/null || return 1
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
    elif v is None: print('None')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}
bb_scalar()  { jpy "$(bb_rpc "$1" "$2")" "d['result']"; }
bb_errcode() { jpy "$(bb_rpc "$1" "$2")" "d['error']['code']"; }

# ── 3. Launch the Core regtest oracle (-listen=0 -blockfilterindex=basic). ─
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
    log "launching Core regtest oracle (-listen=0 -blockfilterindex=basic) rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch blockbrew on regtest WITH -blockfilterindex enabled. ────────
launch_bb_once() {
    BB_COOKIE=""
    # PID-scoped stop of OUR previous attempt (port-kill removed: 2026-06-10 fuser incident).
    if [[ -n "${BB_PID:-}" ]]; then
        kill "$BB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BB_PID" 2>/dev/null || true
    fi
    for __hp in "${BB_RPC}"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
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

# Capability probe: if scanblocks is unimplemented, SKIP; if the RPC exists but
# the index is off, SKIP. We pass a probe addr() needle over [0,0].
PROBE=$(bb_rpc scanblocks "[\"start\", [\"addr($MINE_ADDR)\"], 0, 0, \"basic\"]")
PROBE_ECODE=$(jpy "$PROBE" "d.get('error',{}).get('code')")
PROBE_EMSG=$(jpy "$PROBE" "d.get('error',{}).get('message','')")
if [[ "$PROBE_ECODE" == "-32601" ]]; then
    skip "no scanblocks RPC (method not found)"
fi
case "$PROBE_EMSG" in
    *[Nn]ot*enabled*) skip "no filter index (scanblocks reports index not enabled)" ;;
esac

# ── 5. Build the shared chain on Core (with a real SPEND tx). ─────────────
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
CB1_INFO=$(core_cli_retry getrawtransaction "$CB1_TXID" 2 "$CB1_BLOCKHASH" | python3 -c "
import sys,json
t=json.load(sys.stdin); o=t['vout'][0]
print('%s|%s'%(o['value'], o['scriptPubKey']['hex']))" 2>/dev/null)
CB1_VALUE="${CB1_INFO%%|*}"
CB1_SPK="${CB1_INFO##*|}"
[[ -n "$CB1_VALUE" && -n "$CB1_SPK" ]] || fail "could not read coinbase vout0 (value/spk)"

# Build the raw spend: input = (CB1_TXID, vout 0); output = DST_ADDR less fee.
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

# Mine the spend into a block (paid to MINE_ADDR so the spend block's coinbase
# also pays MINE_ADDR) -> a true match via BOTH a coinbase output AND a spent
# prevout. Then 3 trailing blocks.
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (spend block) failed"
SPEND_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount failed"
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
BLOCK1_HASH=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
log "known-true blocks: block1=$BLOCK1_HASH (h1, coinbase->MINE_ADDR) spend=$SPEND_BLOCKHASH (h$SPEND_HEIGHT)"

# ── 6. Replicate every Core block to blockbrew via submitblock. ───────────
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
TIP=$CORE_HEIGHT

# Give blockbrew's block filter index a moment to catch up to tip.
for _ in $(seq 1 90); do
    BB_TIPFILT=$(bb_errcode getblockfilter "[\"$BB_TIP\", \"basic\"]")
    [[ -z "$BB_TIPFILT" ]] && break   # no error => filter present
    sleep 1
done

# ── scanblocks helpers ────────────────────────────────────────────────────
# bb_scan <action> <scanobjects-json> <start> <stop>  -> raw JSON response
bb_scan() {
    bb_rpc scanblocks "[\"$1\", $2, $3, $4, \"basic\"]"
}
# return space-separated relevant_blocks list (blockbrew)
bb_scan_blocks() {
    jpy "$(bb_scan "$1" "$2" "$3" "$4")" "' '.join(d['result']['relevant_blocks'])"
}
co_scan_blocks() {
    # args: scanobjects-as-cli-json start stop
    core_cli_retry scanblocks start "$1" "$2" "$3" basic \
        | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin)['relevant_blocks']))" 2>/dev/null
}
in_list() {
    # in_list <hash> <space-separated-list>
    local needle="$1"; shift
    local item
    for item in $1; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

# ════════════════════════════════════════════════════════════════════════
# CHECK A+B — SHAPE + MEMBERSHIP (the load-bearing assertion).
# ════════════════════════════════════════════════════════════════════════
SCAN_T="bad"; SHAPE_T="bad"
NEEDLE="[\"addr($MINE_ADDR)\"]"
RESP=$(bb_scan "start" "$NEEDLE" 0 "$TIP")
FROM=$(jpy "$RESP" "d['result']['from_height']")
TO=$(jpy "$RESP" "d['result']['to_height']")
COMPLETED=$(jpy "$RESP" "d['result']['completed']")
RB_IS_ARR=$(jpy "$RESP" "isinstance(d['result']['relevant_blocks'], list)")
[[ "$FROM" == "0"    ]] || fail "from_height != 0 (got '$FROM'); resp=$RESP"
[[ "$TO"   == "$TIP" ]] || fail "to_height != tip $TIP (got '$TO'); resp=$RESP"
[[ "$COMPLETED" == "true" ]] || fail "completed != true (got '$COMPLETED'); resp=$RESP"
[[ "$RB_IS_ARR" == "true" ]] || fail "relevant_blocks is not an array; resp=$RESP"
# Every relevant block is a 64-hex string.
BADHEX=$(jpy "$RESP" "[x for x in d['result']['relevant_blocks'] if not (isinstance(x,str) and len(x)==64)]")
[[ "$BADHEX" == "[]" || -z "$BADHEX" ]] || fail "relevant_blocks contains non-64hex entries: $BADHEX"
SHAPE_T="ok"
log "shape ok: from=$FROM to=$TO completed=$COMPLETED"

RB=$(jpy "$RESP" "' '.join(d['result']['relevant_blocks'])")
# MEMBERSHIP: both known-true blocks MUST appear (false positives are extra-OK).
in_list "$BLOCK1_HASH" "$RB"      || fail "MEMBERSHIP: block1 ($BLOCK1_HASH, coinbase->MINE_ADDR) NOT in relevant_blocks: [$RB]"
in_list "$SPEND_BLOCKHASH" "$RB"  || fail "MEMBERSHIP: spend block ($SPEND_BLOCKHASH, h$SPEND_HEIGHT) NOT in relevant_blocks: [$RB]"
log "membership ok: block1 + spend block both present in relevant_blocks ($(echo "$RB" | wc -w) total)"

# ════════════════════════════════════════════════════════════════════════
# CHECK C — CORE CROSS-CHECK (superset-consistent on the known-true set).
# ════════════════════════════════════════════════════════════════════════
CORE_RB=$(co_scan_blocks "[\"addr($MINE_ADDR)\"]" 0 "$TIP")
[[ -n "$CORE_RB" ]] || fail "Core scanblocks returned empty/failed; CORE_RB='$CORE_RB'"
in_list "$BLOCK1_HASH" "$CORE_RB"     || fail "Core scanblocks missing block1 (oracle sanity); core=[$CORE_RB]"
in_list "$SPEND_BLOCKHASH" "$CORE_RB" || fail "Core scanblocks missing spend block (oracle sanity); core=[$CORE_RB]"
log "core cross-check ok: Core relevant_blocks ⊇ known-true set; impl ⊇ known-true set"
SCAN_T="ok"

# ════════════════════════════════════════════════════════════════════════
# CHECK D — NEGATIVE NEEDLE: fresh unfunded addr must NOT match the funded blocks.
# ════════════════════════════════════════════════════════════════════════
NEG_RB=$(bb_scan_blocks "start" "[\"addr($NEG_ADDR)\"]" 0 "$TIP")
if in_list "$BLOCK1_HASH" "$NEG_RB"; then
    fail "NEGATIVE: unfunded addr matched block1 ($BLOCK1_HASH) — needle ignored? neg=[$NEG_RB]"
fi
if in_list "$SPEND_BLOCKHASH" "$NEG_RB"; then
    fail "NEGATIVE: unfunded addr matched spend block ($SPEND_BLOCKHASH) — needle ignored? neg=[$NEG_RB]"
fi
log "negative needle ok: unfunded addr did NOT match either funded block ($(echo "$NEG_RB" | wc -w) stray fp)"

# ════════════════════════════════════════════════════════════════════════
# CHECK E — RANGE BOUNDING.
# ════════════════════════════════════════════════════════════════════════
RANGE_T="bad"
# (i) 1-block window on the spend block: from==to==H_spend, spend block present.
W1=$(bb_scan "start" "$NEEDLE" "$SPEND_HEIGHT" "$SPEND_HEIGHT")
W1_FROM=$(jpy "$W1" "d['result']['from_height']")
W1_TO=$(jpy "$W1" "d['result']['to_height']")
W1_RB=$(jpy "$W1" "' '.join(d['result']['relevant_blocks'])")
W1_N=$(jpy "$W1" "len(d['result']['relevant_blocks'])")
[[ "$W1_FROM" == "$SPEND_HEIGHT" ]] || fail "RANGE: 1-block window from_height != $SPEND_HEIGHT (got '$W1_FROM'); resp=$W1"
[[ "$W1_TO"   == "$SPEND_HEIGHT" ]] || fail "RANGE: 1-block window to_height != $SPEND_HEIGHT (got '$W1_TO'); resp=$W1"
in_list "$SPEND_BLOCKHASH" "$W1_RB"  || fail "RANGE: spend block missing from its own 1-block window; resp=$W1"
# relevant_blocks ⊆ that single block (at most 1 entry — only the spend block in range).
[[ "$W1_N" == "1" ]] || fail "RANGE: 1-block window returned $W1_N blocks, expected exactly 1 (the spend block); resp=$W1"
# (ii) a window strictly BELOW all funded heights (2..50) must NOT contain the
# funded blocks (block1 is at h1, below; spend at h$SPEND_HEIGHT, above). So a
# [2,50] window excludes BOTH funded blocks.
W2_RB=$(bb_scan_blocks "start" "$NEEDLE" 2 50)
if in_list "$BLOCK1_HASH" "$W2_RB"; then fail "RANGE: window [2,50] contains block1 (h1, out of range); w2=[$W2_RB]"; fi
if in_list "$SPEND_BLOCKHASH" "$W2_RB"; then fail "RANGE: window [2,50] contains spend block (h$SPEND_HEIGHT, out of range); w2=[$W2_RB]"; fi
RANGE_T="ok"
log "range bounding ok: 1-block spend window exact; [2,50] excludes both funded blocks"

# ════════════════════════════════════════════════════════════════════════
# CHECK F — ACTIONS: status->null ; abort->false ; bogus->error.
# ════════════════════════════════════════════════════════════════════════
ST=$(bb_rpc scanblocks "[\"status\"]")
ST_RES=$(jpy "$ST" "d['result']")
ST_HASERR=$(jpy "$ST" "'error' in d and d['error'] is not None")
[[ "$ST_HASERR" != "true" ]] || fail "ACTIONS: status returned an error: $ST"
[[ "$ST_RES" == "None" ]]    || fail "ACTIONS: status did not return null (got '$ST_RES'); resp=$ST"
AB=$(bb_rpc scanblocks "[\"abort\"]")
AB_RES=$(jpy "$AB" "d['result']")
[[ "$AB_RES" == "false" ]] || fail "ACTIONS: abort did not return false (got '$AB_RES'); resp=$AB"
BG=$(bb_rpc scanblocks "[\"bogusaction\"]")
BG_ECODE=$(jpy "$BG" "d.get('error',{}).get('code')")
[[ "$BG_ECODE" =~ ^-[0-9]+$ ]] || fail "ACTIONS: bogus action did not return an error code (got '$BG_ECODE'); resp=$BG"
log "actions ok: status=null abort=false bogus->error($BG_ECODE)"

# ════════════════════════════════════════════════════════════════════════
# CHECK G — ERRORS (codes are the hard requirement; message is soft).
# ════════════════════════════════════════════════════════════════════════
ERR_T="bad"
# (a) unknown filtertype -> -5.
EF=$(bb_rpc scanblocks "[\"start\", $NEEDLE, 0, $TIP, \"bogustype\"]")
EF_CODE=$(jpy "$EF" "d['error']['code']")
EF_MSG=$(jpy "$EF" "d['error']['message']")
[[ "$EF_CODE" == "-5" ]] || fail "ERRORS: unknown filtertype expected -5, got '$EF_CODE' (resp=$EF)"
case "$EF_MSG" in
    *[Uu]nknown*filtertype*) : ;;
    *) log "WARNING: unknown-filtertype message not 'Unknown filtertype': '$EF_MSG' (code -5 is the hard requirement)";;
esac
CEF=$(core_cli scanblocks start "$NEEDLE" 0 "$TIP" bogustype 2>&1 | grep -oE '\-5' | head -1)
[[ "$CEF" == "-5" ]] || log "WARNING: could not confirm Core returns -5 for unknown filtertype (blockbrew is -5)"
# (b) out-of-range start (tip+1) -> -1.
ES=$(bb_rpc scanblocks "[\"start\", $NEEDLE, $(( TIP + 1 )), $TIP, \"basic\"]")
ES_CODE=$(jpy "$ES" "d['error']['code']")
ES_MSG=$(jpy "$ES" "d['error']['message']")
[[ "$ES_CODE" == "-1" ]] || fail "ERRORS: start>tip expected -1, got '$ES_CODE' (resp=$ES)"
case "$ES_MSG" in
    *[Ii]nvalid*start*) : ;;
    *) log "WARNING: out-of-range start message not 'Invalid start_height': '$ES_MSG' (code -1 is the hard requirement)";;
esac
CES=$(core_cli scanblocks start "$NEEDLE" "$(( TIP + 1 ))" "$TIP" basic 2>&1 | grep -oE '\-1' | head -1)
[[ "$CES" == "-1" ]] || log "WARNING: could not confirm Core returns -1 for out-of-range start (blockbrew is -1)"
# (c) stop < start -> -1.
EE=$(bb_rpc scanblocks "[\"start\", $NEEDLE, 10, 5, \"basic\"]")
EE_CODE=$(jpy "$EE" "d['error']['code']")
EE_MSG=$(jpy "$EE" "d['error']['message']")
[[ "$EE_CODE" == "-1" ]] || fail "ERRORS: stop<start expected -1, got '$EE_CODE' (resp=$EE)"
case "$EE_MSG" in
    *[Ii]nvalid*stop*) : ;;
    *) log "WARNING: stop<start message not 'Invalid stop_height': '$EE_MSG' (code -1 is the hard requirement)";;
esac
CEE=$(core_cli scanblocks start "$NEEDLE" 10 5 basic 2>&1 | grep -oE '\-1' | head -1)
[[ "$CEE" == "-1" ]] || log "WARNING: could not confirm Core returns -1 for stop<start (blockbrew is -1)"
ERR_T="ok"
log "errors ok: filtertype=-5 start>tip=-1 stop<start=-1"

log "PASS: blockbrew scanblocks matches Core on membership + core-superset + negative + range + actions + errors"
pass "$SCAN_T" "$SHAPE_T" "$RANGE_T" "$ERR_T"
