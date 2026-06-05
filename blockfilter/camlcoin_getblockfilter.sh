#!/usr/bin/env bash
#
# camlcoin_getblockfilter.sh — self-contained getblockfilter Core-parity test.
#
# A SUBSTANTIVE indexing green-cell. getblockfilter serves BIP-157/158 compact
# block filters to SPV clients. Unlike getindexinfo (which only reports index
# *status*), this proves camlcoin computes the BIP-158 BASIC filter (type 0x00)
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
#   REPLICATE every block to camlcoin via submitblock(getblock(h,0)). camlcoin
#   rebuilds its own UTXO/undo set as it connects each block, so its spent-
#   prevout elements are populated identically. camlcoin runs with
#   --blockfilterindex basic enabled.
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
# STRICT UNIFORM INTERFACE (mirrors blockfilter/blockbrew_getblockfilter.sh +
#   blockheader/camlcoin_getblockheader.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1. Run under: setsid -w bash camlcoin_getblockfilter.sh
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER camlcoin: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER camlcoin: FAIL <short reason>
#   SKIP: GETBLOCKFILTER camlcoin: SKIP <no filter index>
#
# Touches ONLY /tmp/gbf-camlcoin/ + /tmp/gbf-core-camlcoin/ and ports
#   40235/40255 (camlcoin RPC/P2P) + 40237/40257 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Never broad-pkills bitcoind by name (a live mainnet bitcoind may be running);
#   only frees its OWN fixed ports + scratch dir.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key + raw-tx builders)

CC_DATADIR="/tmp/gbf-camlcoin"
CC_RPC=40235
CC_P2P=40255
CC_LOG="$CC_DATADIR/node.log"
CC_COOKIE=""
CC_PID=""

CORE_DATADIR="/tmp/gbf-core-camlcoin"
CORE_RPC=40237
CORE_P2P=40257
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

NBLOCKS_PRE=110    # mine 110 blocks to the wallet (coinbase matures at 100).
# After NBLOCKS_PRE we sendtoaddress (spend) then mine 1 block (the spend block),
# then 3 trailing blocks. Final height = NBLOCKS_PRE + 1 + 3 = 114.

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockfilter:camlcoin] $*" >&2; }

# ── Cleanup: kill OWN nodes + free OWN ports + wipe scratch on any exit. ───
# NOTE: never `pkill -f bitcoind` / never broad kill by binary name — a live
# mainnet bitcoind may be running. Only our OWN datadir-scoped CLI stop + our
# OWN fixed ports + our OWN child PID.
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
    fuser -k "${CC_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CC_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETBLOCKFILTER camlcoin: PASS filter=$1 header=$2 chain=$3 errors=$4"; exit 0; }
fail() { echo "GETBLOCKFILTER camlcoin: FAIL $*"; exit 1; }
skip() { echo "GETBLOCKFILTER camlcoin: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
fuser -k "${CC_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CC_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$CC_DATADIR" "$CORE_DATADIR"
mkdir -p "$CC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || fail "camlcoin binary not found at $NODE_BIN (build with: dune build)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

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

# cc_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
# Retries up to 3x on a transient EMPTY response (dropped connection / RPC server
# momentarily not accepting): an empty body carries neither "result" nor "error",
# so a genuine JSON-RPC error response is returned immediately and never retried.
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
cc_result() { jpy "$(cc_rpc "$1" "$2")" "json.dumps(d['result'])"; }
cc_scalar() { jpy "$(cc_rpc "$1" "$2")" "d['result']"; }
cc_errcode() { jpy "$(cc_rpc "$1" "$2")" "d['error']['code']"; }
cc_errmsg()  { jpy "$(cc_rpc "$1" "$2")" "d['error']['message']"; }
# cc_field <method> <params> <field> -> result[field] scalar (or empty).
cc_field() { jpy "$(cc_rpc "$1" "$2")" "d['result']['$3']"; }

# ── 2. Launch the Core regtest oracle with -blockfilterindex=basic. ───────
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # NOTE: do NOT pass -port. Even with -listen=0, supplying an explicit P2P
    # -port makes the sandbox watchdog SIGKILL bitcoind a few seconds after
    # load. -listen=0 alone is RPC-only and survives (matches the passing
    # blockbrew_getblockfilter.sh launch).
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -blockfilterindex=basic -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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

# ── 3. Launch camlcoin on regtest WITH --blockfilterindex basic enabled. ──
# camlcoin binds its P2P listener on loopback by default; metricsport 0 avoids
# a 9332 collision with any other camlcoin instance.
launch_cc_once() {
    CC_COOKIE=""
    fuser -k "${CC_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CC_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CC_DATADIR"; mkdir -p "$CC_DATADIR"
    "$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
        --port "$CC_P2P" --rpcport "$CC_RPC" --metricsport 0 \
        --blockfilterindex basic >"$CC_LOG" 2>&1 &
    CC_PID=$!
    # Generous startup wait (ouroboros/haskoin-style settle margin honoured
    # fleet-wide); camlcoin opens RocksDB + the BIP-157 index on boot.
    local deadline=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < deadline )); do
        if [[ -z "$CC_COOKIE" && -f "$CC_DATADIR/.cookie" ]]; then
            CC_COOKIE=$(cat "$CC_DATADIR/.cookie")
        fi
        if [[ -n "$CC_COOKIE" ]] && echo "$(cc_rpc getblockcount '[]')" | grep -q '"result"'; then
            return 0
        fi
        kill -0 "$CC_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CC_OK=0
for attempt in 1 2 3; do
    log "launching camlcoin (regtest, --blockfilterindex basic) rpc=:$CC_RPC -> $CC_LOG (attempt $attempt)"
    if launch_cc_once; then CC_OK=1; break; fi
    log "camlcoin launch attempt $attempt failed (see $CC_LOG); retrying after settle"
    [[ -n "$CC_PID" ]] && { kill "$CC_PID" 2>/dev/null || true; for _ in $(seq 1 10); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done; kill -9 "$CC_PID" 2>/dev/null || true; }
    CC_PID=""
    sleep 3
done
[[ "$CC_OK" == "1" ]] || { tail -n 20 "$CC_LOG" >&2 2>/dev/null || true; fail "camlcoin failed to start within 3 attempts (see $CC_LOG)"; }
log "camlcoin RPC ready"

# Early SKIP: if camlcoin doesn't have a filter index wired (started without the
# flag honoured), getblockfilter on the genesis hash returns the
# "Index is not enabled" RPC_MISC_ERROR (-1).
GEN_HASH=$(core_cli_retry getblockhash 0) || fail "Core getblockhash 0 failed"
CC_GEN_PROBE=$(cc_errcode getblockfilter "[\"$GEN_HASH\", \"basic\"]")
if [[ "$CC_GEN_PROBE" == "-1" ]]; then
    skip "camlcoin has no basic block filter index (getblockfilter -> -1 'Index is not enabled')"
fi

# ── 4. Build the shared chain on Core (with a real SPEND tx). ─────────────
# This bitcoind build has NO wallet support (createwallet -> "Method not
# found"), so we build the chain WALLETLESS using Core's test_framework:
#   * mine $NBLOCKS_PRE coinbases to a deterministic P2WPKH address (we hold
#     the key), via generatetoaddress (no wallet needed);
#   * hand-build a raw tx that spends the height-1 (matured) coinbase output,
#     BIP-143-sign it with that key (segwit-v0 P2WPKH), and mine it into a
#     block via generateblock (no wallet needed) -> the multi-element filter
#     block (output spk + spent-prevout spk);
#   * mine 3 trailing blocks for the chaining checks.
# Core ingests + indexes every block; we then replicate the same blocks into
# camlcoin so both nodes hold the IDENTICAL chain and filters compare byte-exact.
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"
log "building walletless chain on Core: $NBLOCKS_PRE coinbases + 1 spend block + 3 tail"
BUILD_OUT=$(python3 -c "
import sys, json, base64, urllib.request, urllib.error
sys.path.insert(0, '$TF_PATH')
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import sign_input_segwitv0
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
from test_framework.script_util import key_to_p2wpkh_script, key_to_p2pkh_script

auth = 'Basic ' + base64.b64encode(open('$CORE_COOKIE_FILE').read().strip().encode()).decode()
def rpc(method, params=None):
    body = json.dumps({'jsonrpc':'1.0','id':1,'method':method,'params':params or []}).encode()
    req = urllib.request.Request('http://127.0.0.1:$CORE_RPC/', data=body,
        headers={'Content-Type':'application/json','Authorization':auth})
    try:
        r = json.load(urllib.request.urlopen(req, timeout=120))
    except urllib.error.HTTPError as e:
        r = json.loads(e.read().decode())
    if r.get('error'): raise RuntimeError('%s -> %s' % (method, r['error']))
    return r['result']

# Deterministic key #1 -> P2WPKH mined-to address; key #2 -> spend destination.
k = ECKey(); k.set(bytes.fromhex('11'*31 + '12'), compressed=True)
pub = k.get_pubkey().get_bytes()
addr = key_to_p2wpkh(pub, main=False)
scriptcode = key_to_p2pkh_script(pub)   # BIP-143 scriptCode for P2WPKH
k2 = ECKey(); k2.set(bytes.fromhex('22'*31 + '23'), compressed=True)
dst_spk = key_to_p2wpkh_script(k2.get_pubkey().get_bytes())

rpc('generatetoaddress', [$NBLOCKS_PRE, addr])

# Spend the height-1 coinbase output (matured after 100 blocks).
cb_tx = rpc('getblock', [rpc('getblockhash', [1]), 2])['tx'][0]
in_amount = int(round(cb_tx['vout'][0]['value'] * 100000000))
tx = CTransaction()
tx.vin.append(CTxIn(COutPoint(int(cb_tx['txid'], 16), 0), b'', 0xffffffff))
tx.vout.append(CTxOut(in_amount - 1000, dst_spk))   # 1000 sat fee
tx.wit.vtxinwit.append(CTxInWitness())
tx.wit.vtxinwit[0].scriptWitness.stack = [pub]      # pubkey; sig inserted at idx 0
sign_input_segwitv0(tx, 0, scriptcode, in_amount, k)
raw = tx.serialize().hex()
spend_txid = tx.txid_hex

acc = rpc('testmempoolaccept', [[raw]])[0]
if not acc.get('allowed'):
    raise RuntimeError('spend tx not accepted: %s' % acc.get('reject-reason'))

spend_blockhash = rpc('generateblock', [addr, [raw]])['hash']
spend_height = rpc('getblockcount')
rpc('generatetoaddress', [3, addr])   # 3 trailing blocks
final_height = rpc('getblockcount')

# Sanity: the spend tx is actually in the spend block.
sb = rpc('getblock', [spend_blockhash, 1])
if spend_txid not in sb['tx']:
    raise RuntimeError('spend tx not in spend block')

print(json.dumps({'spend_txid': spend_txid, 'spend_height': spend_height,
                  'spend_blockhash': spend_blockhash, 'final_height': final_height}))
" 2>&1) || fail "walletless chain build failed: $BUILD_OUT"

SPEND_TXID=$(echo "$BUILD_OUT"   | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['spend_txid'])" 2>/dev/null)
SPEND_HEIGHT=$(echo "$BUILD_OUT" | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['spend_height'])" 2>/dev/null)
SPEND_BLOCKHASH=$(echo "$BUILD_OUT" | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['spend_blockhash'])" 2>/dev/null)
CORE_HEIGHT=$(echo "$BUILD_OUT"  | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['final_height'])" 2>/dev/null)
[[ -n "$SPEND_TXID" && -n "$SPEND_HEIGHT" && -n "$CORE_HEIGHT" ]] \
    || fail "could not parse walletless build output: $BUILD_OUT"
EXPECTED=$(( NBLOCKS_PRE + 1 + 3 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED (build output: $BUILD_OUT)"
log "walletless chain built: spend $SPEND_TXID in block @h$SPEND_HEIGHT ($SPEND_BLOCKHASH), tip @h$CORE_HEIGHT"

# ── 5. Replicate every Core block to camlcoin via submitblock. ────────────
log "replicating $CORE_HEIGHT Core blocks to camlcoin via submitblock"
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
    kill -0 "$CC_PID" 2>/dev/null || fail "camlcoin process died during replication at h=$h (see $CC_LOG)"
    SUB=$(cc_rpc submitblock "[\"$RAW\"]")
    # submitblock returns result:null on accept; a non-null result string is a
    # BIP-22 reject reason (Core/camlcoin both return it in the result field).
    SBR=$(jpy "$SUB" "d.get('result')")
    if [[ -n "$SBR" && "$SBR" != "None" ]]; then
        fail "camlcoin submitblock rejected block at height $h: $SBR"
    fi
done <<< "$RAW_LIST"
CC_HEIGHT=$(cc_scalar getblockcount '[]')
[[ "$CC_HEIGHT" == "$CORE_HEIGHT" ]] || fail "camlcoin height $CC_HEIGHT != Core $CORE_HEIGHT (submitblock did not take)"

CORE_TIP=$(core_cli_retry getbestblockhash)
CC_TIP=$(cc_scalar getbestblockhash '[]')
[[ -n "$CORE_TIP" && "$CORE_TIP" == "$CC_TIP" ]] \
    || fail "tip hash mismatch after replicate (core=$CORE_TIP caml=$CC_TIP) — chains not identical"
log "chains identical at tip $CC_TIP (height $CORE_HEIGHT)"

# Give camlcoin's block filter index a moment to catch up to tip (it indexes
# on connect during submitblock, but allow a generous settle margin).
for _ in $(seq 1 90); do
    CC_TIPFILT=$(cc_errcode getblockfilter "[\"$CC_TIP\", \"basic\"]")
    [[ -z "$CC_TIPFILT" ]] && break   # no error => filter present
    sleep 1
done

# ── 6. assert_block <height> <label> -> compares filter+header byte-exact. ─
# Sets global FAILREASON on mismatch (returns 1). Logs both sides on diff.
assert_block() {
    local h="$1" label="$2"
    local bh corF corH ccF ccH
    bh=$(core_cli_retry getblockhash "$h") || { FAILREASON="getblockhash $h failed"; return 1; }

    # Core side via its getblockfilter (the oracle).
    local CJSON
    CJSON=$(core_cli_retry getblockfilter "$bh" basic) || { FAILREASON="Core getblockfilter @h$h failed"; return 1; }
    corF=$(echo "$CJSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['filter'])" 2>/dev/null)
    corH=$(echo "$CJSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['header'])" 2>/dev/null)
    [[ -n "$corF" && -n "$corH" ]] || { FAILREASON="Core filter/header empty @h$h"; return 1; }

    # camlcoin side.
    ccF=$(cc_field getblockfilter "[\"$bh\", \"basic\"]" filter)
    ccH=$(cc_field getblockfilter "[\"$bh\", \"basic\"]" header)
    [[ -n "$ccF" && -n "$ccH" ]] || { FAILREASON="camlcoin filter/header empty @h$h ($label)"; return 1; }

    if [[ "$ccF" != "$corF" ]]; then
        log "FILTER MISMATCH @h$h ($label):"
        log "  core: $corF"
        log "  caml: $ccF"
        FAILREASON="filter hex != Core @h$h ($label)"
        return 1
    fi
    if [[ "$ccH" != "$corH" ]]; then
        log "HEADER MISMATCH @h$h ($label):"
        log "  core: $corH"
        log "  caml: $ccH"
        FAILREASON="filter header hex != Core @h$h ($label)"
        return 1
    fi
    log "MATCH @h$h ($label): filter(${#ccF} hex) + header byte-exact vs Core"
    return 0
}

FAILREASON=""
FILTER_T="ok"
HEADER_T="ok"

# ── 7. TEST 1 — coinbase-only block (1-element filter) byte-exact. ────────
# A block well before the spend has only the coinbase output (a single
# non-OP_RETURN scriptPubKey) -> a 1-element filter.
COINBASE_ONLY_H=50
assert_block "$COINBASE_ONLY_H" "coinbase-only/1-element" || { FILTER_T="bad"; HEADER_T="bad"; fail "$FAILREASON"; }

# Cross-check: the coinbase-only block filter really is 1-element (N==1).
CBH=$(core_cli_retry getblockhash "$COINBASE_ONLY_H")
CB_FILTER=$(cc_field getblockfilter "[\"$CBH\", \"basic\"]" filter)
CB_N=$(python3 -c "
f=bytes.fromhex('$CB_FILTER')
if not f: print(0)
else:
    b=f[0]
    if b<253: print(b)
    elif b==253: print(int.from_bytes(f[1:3],'little'))
    elif b==254: print(int.from_bytes(f[1:5],'little'))
    else: print(int.from_bytes(f[1:9],'little'))
" 2>/dev/null)
[[ "$CB_N" == "1" ]] || fail "coinbase-only block filter N=$CB_N, expected 1 (element-set rule wrong)"
log "coinbase-only block filter element count N=$CB_N (1-element confirmed)"

# ── 8. TEST 2 — spend block (multi-element filter) byte-exact. ────────────
# Must have BOTH an output scriptPubKey AND a spent-prevout scriptPubKey, so the
# element set is >1 and exercises the undo-data prevout-script path.
assert_block "$SPEND_HEIGHT" "spend/multi-element" || { FILTER_T="bad"; HEADER_T="bad"; fail "$FAILREASON"; }

# Cross-check: the spend block's filter really is multi-element (N>1). Decode the
# CompactSize element count from the leading byte(s) of the filter and assert >1.
SBH=$(core_cli_retry getblockhash "$SPEND_HEIGHT")
SPEND_FILTER=$(cc_field getblockfilter "[\"$SBH\", \"basic\"]" filter)
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

# Local-consistency cross-check: camlcoin's own header @N must equal
# SHA256d( SHA256d(filterBytes@N) || header@N-1 ) using camlcoin's own filter
# and parent header — catches a chain that matches Core but isn't internally
# self-consistent (e.g. a stored-but-not-recomputed header).
CH1=$(core_cli_retry getblockhash $((SPEND_HEIGHT)))
CH0=$(core_cli_retry getblockhash $((SPEND_HEIGHT-1)))
FILT_N=$(cc_field getblockfilter "[\"$CH1\", \"basic\"]" filter)
HDR_N=$(cc_field getblockfilter "[\"$CH1\", \"basic\"]" header)
HDR_PREV=$(cc_field getblockfilter "[\"$CH0\", \"basic\"]" header)
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
EBOGUS_CODE=$(cc_errcode getblockfilter "[\"$CC_TIP\", \"bogustype\"]")
EBOGUS_MSG=$(cc_errmsg  getblockfilter "[\"$CC_TIP\", \"bogustype\"]")
if [[ "$EBOGUS_CODE" != "-5" ]]; then
    ERRORS_T="bad"; log "bogus filtertype: expected code -5, got '$EBOGUS_CODE'"
fi
case "$EBOGUS_MSG" in
    *Unknown\ filtertype*) : ;;
    *) ERRORS_T="bad"; log "bogus filtertype: expected msg ~'Unknown filtertype', got '$EBOGUS_MSG'" ;;
esac

# unknown blockhash -> -5
ERR_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
EUNK_CODE=$(cc_errcode getblockfilter "[\"$ERR_HASH\", \"basic\"]")
if [[ "$EUNK_CODE" != "-5" ]]; then
    ERRORS_T="bad"; log "unknown blockhash: expected code -5, got '$EUNK_CODE'"
fi
[[ "$ERRORS_T" == "ok" ]] || fail "error-code check: bogus-type code='$EBOGUS_CODE' msg='$EBOGUS_MSG'; unknown-hash code='$EUNK_CODE'"

log "PASS: camlcoin getblockfilter matches Core (filter+header byte-exact for 1-element + multi-element + 4-block chain + errors)"
pass "$FILTER_T" "$HEADER_T" "$CHAIN_T" "$ERRORS_T"
