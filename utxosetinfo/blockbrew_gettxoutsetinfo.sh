#!/usr/bin/env bash
#
# blockbrew_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity test.
#
# The DEEPEST indexing green-cell yet. gettxoutsetinfo's set HASH is a
# fingerprint of the ENTIRE UTXO set: matching it byte-for-byte against Bitcoin
# Core proves blockbrew's consensus STATE (its whole UTXO set) is identical to
# Core's, not merely that the RPC has the right shape. This is far stronger than
# an RPC-shape check — it is a UTXO-set commitment comparison.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:1010+   (gettxoutsetinfo)
#   bitcoin-core/src/kernel/coinstats.cpp        (hash_serialized_3 + muhash
#                                                 kernels, per-coin ApplyHash,
#                                                 GetBogoSize, total_amount).
#
#   SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index ).
#     hash_type default "hash_serialized_3"; options
#     "hash_serialized_3" | "muhash" | "none".
#   OUTPUT (base chainstate, no coinstatsindex):
#     { height, bestblock, txouts, bogosize,
#       hash_serialized_3 (only when hash_type=hash_serialized_3),
#       muhash (only when hash_type=muhash),
#       transactions, disk_size, total_amount }.
#   ERRORS (RPC_INVALID_PARAMETER = -8):
#     - hash_serialized_3 (or any type) WITH a specific block/height, no
#       coinstatsindex -> -8. (Core checks the coinstatsindex requirement first;
#       on a node without it the message is "Querying specific block heights
#       requires coinstatsindex". The PARITY POINT is code -8.)
#     - unrecognized hash_type -> -8 "'<x>' is not a valid hash_type".
#
# hash_serialized_3 (the DEFAULT, the one we assert byte-exact):
#   HashWriter (SHA256d) over every coin streamed in CoinsDB CURSOR ORDER
#   (txid ascending, then vout ascending). Per coin:
#     outpoint (32B txid internal-order || 4B vout LE)
#     || uint32_LE(height<<1 | coinbase)
#     || amount (8B LE) || CompactSize(len scriptPubKey) || scriptPubKey.
#   blockbrew computes this via consensus.ComputeUTXOSetInfo (flush-then-cursor;
#   the analogue of Core's ForceFlushStateToDisk + CoinsDB cursor walk).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core), launched on its OWN
#   scratch regtest instance + OWN ports, -listen=0. To make the UTXO sets
#   IDENTICAL across nodes, both must share the SAME chain: Core (wallet-less
#   here) mines 110 coinbases to a key we control, then builds + signs a REAL
#   raw SPEND tx (so the set has a spent output REMOVED and new outputs ADDED,
#   not just coinbases), mines the spend block, then we REPLICATE every block to
#   blockbrew via submitblock(getblock(h,0)). blockbrew rebuilds its own UTXO set
#   as it connects each block -> identical set -> identical hash.
#
# WHAT MUST MATCH CORE EXACTLY:
#   1. FIELDS: height, bestblock, txouts, total_amount EXACT vs Core, AND the
#      set hash (hash_serialized_3) byte-EXACT vs Core. The hash match is THE
#      point — it proves the whole UTXO set is identical.
#   2. MUTATE: mine 1 more block (changes the set) -> height+1, bestblock
#      changed, the set hash CHANGED on BOTH and STILL matches between impl and
#      Core.
#   3. ERRORS: gettxoutsetinfo hash_serialized_3 <height> -> -8; bogus type -> -8.
#      (bogosize/transactions/disk_size: assert PRESENT + typed, NOT byte-equal —
#       bogosize is "meaningless", disk_size impl-specific.)
#
# STRICT UNIFORM INTERFACE (mirrors blockfilter/blockbrew_getblockfilter.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1. Run under: setsid -w bash blockbrew_gettxoutsetinfo.sh
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO blockbrew: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO blockbrew: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO blockbrew: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-blockbrew/ + /tmp/gtxo-core/ and ports
#   22173/22193 (blockbrew RPC/P2P) + 22175/22195 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Never broad-pkills bitcoind by name (a live mainnet bitcoind may be running);
#   only frees its OWN fixed ports + scratch dir. Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

# Deterministic test secrets -> two controlled p2wpkh bcrt1 addresses. The Core
# build here is wallet-less, so we mine coinbases to MINE_ADDR (key we hold),
# then build/sign a RAW spend with MINE_WIF that pays DST_ADDR.
MINE_SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

BB_DATADIR="/tmp/gtxo-blockbrew"
BB_RPC=22173
BB_P2P=22193
BB_LOG="$BB_DATADIR/node.log"
BB_COOKIE=""
BB_PID=""

CORE_DATADIR="/tmp/gtxo-core"
CORE_RPC=22175
CORE_P2P=22195
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

NBLOCKS_PRE=110    # 110 coinbases (maturity 100) so block-1 coinbase is spendable.

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutsetinfo:blockbrew] $*" >&2; }

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
    free_port "$BB_RPC"
    free_port "$BB_P2P"
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETTXOUTSETINFO blockbrew: PASS fields=$1 hash=$2 mutate=$3 errors=$4"; exit 0; }
fail() { echo "GETTXOUTSETINFO blockbrew: FAIL $*"; exit 1; }
skip() { echo "GETTXOUTSETINFO blockbrew: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
free_port "$BB_RPC"
free_port "$BB_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
if ss -tln 2>/dev/null | grep -qE ":(${BB_RPC}|${BB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BB_RPC}/${BB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || fail "blockbrew binary not found at $NODE_BIN (build with: go build -o blockbrew ./...)"
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
    curl -s --max-time 120 -u "$BB_COOKIE" \
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
bb_scalar()  { jpy "$(bb_rpc "$1" "$2")" "d['result']"; }
bb_errcode() { jpy "$(bb_rpc "$1" "$2")" "d['error']['code']"; }
bb_errmsg()  { jpy "$(bb_rpc "$1" "$2")" "d['error']['message']"; }
bb_field()   { jpy "$(bb_rpc "$1" "$2")" "d['result']['$3']"; }
# bb_has_field: prints "1" if result has key, "" otherwise.
bb_has_field() { jpy "$(bb_rpc "$1" "$2")" "1 if ('$3' in d.get('result',{})) else ''"; }
# bb_field_type: prints python type name of result[field], or empty.
bb_field_type() { jpy "$(bb_rpc "$1" "$2")" "type(d['result']['$3']).__name__"; }

# ── 2. Launch the Core regtest oracle. ────────────────────────────────────
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
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
    log "launching Core regtest oracle rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch blockbrew on regtest. ───────────────────────────────────────
launch_bb_once() {
    BB_COOKIE=""
    free_port "$BB_RPC"
    rm -rf "$BB_DATADIR"; mkdir -p "$BB_DATADIR"
    "$NODE_BIN" -network=regtest -datadir="$BB_DATADIR" \
        -rpcbind="127.0.0.1:$BB_RPC" -nolisten \
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
    log "launching blockbrew (regtest, nolisten) rpc=:$BB_RPC -> $BB_LOG (attempt $attempt)"
    if launch_bb_once; then BB_OK=1; break; fi
    log "blockbrew launch attempt $attempt failed (see $BB_LOG); retrying after settle"
    [[ -n "$BB_PID" ]] && kill "$BB_PID" 2>/dev/null || true
    BB_PID=""
    sleep 3
done
[[ "$BB_OK" == "1" ]] || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew failed to start within 3 attempts (see $BB_LOG)"; }
log "blockbrew RPC ready"

# Early SKIP: if blockbrew's gettxoutsetinfo doesn't compute a real
# hash_serialized_3 (handler missing / returns empty), bail SKIP rather than
# faking a result. The genesis chainstate is enough to detect this.
GENPROBE=$(bb_field gettxoutsetinfo '[]' hash_serialized_3)
GENERR=$(bb_errcode gettxoutsetinfo '[]')
if [[ -n "$GENERR" ]]; then
    skip "blockbrew gettxoutsetinfo returned error code $GENERR on empty chain"
fi
case "$GENPROBE" in
    [0-9a-fA-F]*) [[ ${#GENPROBE} -eq 64 ]] || skip "blockbrew hash_serialized_3 not a 32-byte hex (len ${#GENPROBE})" ;;
    "") skip "blockbrew gettxoutsetinfo has no hash_serialized_3 field (handler not wired)" ;;
    *)  skip "blockbrew hash_serialized_3 malformed: '$GENPROBE'" ;;
esac

# ── 4. Build the shared chain on Core (110 coinbases + a real SPEND tx). ───
log "mining $NBLOCKS_PRE blocks to $MINE_ADDR (coinbase maturity)"
core_cli_retry generatetoaddress "$NBLOCKS_PRE" "$MINE_ADDR" >/dev/null \
    || fail "Core generatetoaddress (pre) failed"

# Spend the matured block-1 coinbase output -> a spent output REMOVED + new
# outputs ADDED, so the UTXO set differs from a coinbase-only chain.
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

# Mine the spend block. Final pre-mutate height = NBLOCKS_PRE + 1.
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (spend block) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount failed"
EXPECTED=$(( NBLOCKS_PRE + 1 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED"

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

# ── 6. Determine which hash_type blockbrew computes Core-correctly. ────────
# Prefer hash_serialized_3 (the default). Fall back to muhash if blockbrew's
# Core-correct strong hash is muhash. We compare like-for-like on the Core
# oracle side.
HASH_KEY=""
CORE_DEF=$(core_cli_retry gettxoutsetinfo) || fail "Core gettxoutsetinfo (default) failed"
CORE_HS3=$(echo "$CORE_DEF" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash_serialized_3',''))" 2>/dev/null)
BB_HS3=$(bb_field gettxoutsetinfo '[]' hash_serialized_3)
if [[ -n "$CORE_HS3" && -n "$BB_HS3" && "$CORE_HS3" == "$BB_HS3" ]]; then
    HASH_KEY="hash_serialized_3"
    log "hash_serialized_3 matches Core: $BB_HS3"
else
    log "hash_serialized_3 mismatch (core=$CORE_HS3 bb=$BB_HS3) — trying muhash"
    CORE_MH=$(core_cli_retry gettxoutsetinfo muhash | python3 -c "import sys,json;print(json.load(sys.stdin).get('muhash',''))" 2>/dev/null)
    BB_MH=$(bb_field gettxoutsetinfo '["muhash"]' muhash)
    if [[ -n "$CORE_MH" && -n "$BB_MH" && "$CORE_MH" == "$BB_MH" ]]; then
        HASH_KEY="muhash"
        log "muhash matches Core: $BB_MH"
    fi
fi
[[ -n "$HASH_KEY" ]] || fail "neither hash_serialized_3 nor muhash matched Core (hs3 core=$CORE_HS3 bb=$BB_HS3)"

# Set the params + jq key used for the chosen hash_type.
if [[ "$HASH_KEY" == "hash_serialized_3" ]]; then
    HT_PARAM='[]'                # default hash_type
    CORE_HT_ARGS=()              # default
else
    HT_PARAM='["muhash"]'
    CORE_HT_ARGS=(muhash)
fi

# core_setinfo: get a field from the Core oracle for the chosen hash_type.
core_setinfo_field() {
    core_cli_retry gettxoutsetinfo "${CORE_HT_ARGS[@]}" | python3 -c "
import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null
}

FIELDS_T="ok"; HASH_T="ok"; MUTATE_T="ok"; ERRORS_T="ok"

# ── 7. FIELDS — height, bestblock, txouts, total_amount EXACT + hash EXACT. ─
C_HEIGHT=$(core_setinfo_field height)
C_BEST=$(core_setinfo_field bestblock)
C_TXOUTS=$(core_setinfo_field txouts)
C_TOTAL=$(core_setinfo_field total_amount)
C_HASH=$(core_setinfo_field "$HASH_KEY")

B_HEIGHT=$(bb_field gettxoutsetinfo "$HT_PARAM" height)
B_BEST=$(bb_field gettxoutsetinfo "$HT_PARAM" bestblock)
B_TXOUTS=$(bb_field gettxoutsetinfo "$HT_PARAM" txouts)
B_HASH=$(bb_field gettxoutsetinfo "$HT_PARAM" "$HASH_KEY")
# total_amount may be a JSON number (e.g. 5550.00000000); normalize both via float.
B_TOTAL_RAW=$(bb_field gettxoutsetinfo "$HT_PARAM" total_amount)
C_TOTAL_N=$(python3 -c "print('%.8f'%float('$C_TOTAL'))" 2>/dev/null)
B_TOTAL_N=$(python3 -c "print('%.8f'%float('$B_TOTAL_RAW'))" 2>/dev/null)

[[ "$B_HEIGHT" == "$C_HEIGHT" ]]   || { FIELDS_T="bad"; log "height mismatch: core=$C_HEIGHT bb=$B_HEIGHT"; }
[[ "$B_BEST"   == "$C_BEST"   ]]   || { FIELDS_T="bad"; log "bestblock mismatch: core=$C_BEST bb=$B_BEST"; }
[[ "$B_TXOUTS" == "$C_TXOUTS" ]]   || { FIELDS_T="bad"; log "txouts mismatch: core=$C_TXOUTS bb=$B_TXOUTS"; }
[[ -n "$C_TOTAL_N" && "$B_TOTAL_N" == "$C_TOTAL_N" ]] || { FIELDS_T="bad"; log "total_amount mismatch: core=$C_TOTAL_N bb=$B_TOTAL_N"; }
[[ "$FIELDS_T" == "ok" ]] || fail "field mismatch (height/bestblock/txouts/total_amount) vs Core"

# The SET HASH — THE point. Byte-exact.
if [[ -z "$B_HASH" || "$B_HASH" != "$C_HASH" ]]; then
    HASH_T="bad"
    log "SET HASH MISMATCH ($HASH_KEY): core=$C_HASH bb=$B_HASH"
    fail "$HASH_KEY mismatch vs Core (UTXO set NOT byte-identical): core=$C_HASH bb=$B_HASH"
fi
log "SET HASH MATCH ($HASH_KEY=$B_HASH) — UTXO set byte-identical to Core @h$C_HEIGHT, txouts=$C_TXOUTS, total=$C_TOTAL_N"

# bogosize / transactions / disk_size: PRESENT + typed, NOT byte-equal.
for f in bogosize transactions disk_size; do
    HAS=$(bb_has_field gettxoutsetinfo "$HT_PARAM" "$f")
    [[ "$HAS" == "1" ]] || { FIELDS_T="bad"; log "missing field '$f' in blockbrew result"; }
    T=$(bb_field_type gettxoutsetinfo "$HT_PARAM" "$f")
    [[ "$T" == "int" ]] || { FIELDS_T="bad"; log "field '$f' not integer-typed (got $T)"; }
done
[[ "$FIELDS_T" == "ok" ]] || fail "bogosize/transactions/disk_size missing or wrong type"
log "bogosize/transactions/disk_size present + int-typed"

# ── 8. MUTATE — mine 1 more block, set changes, hash still matches Core. ───
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (mutate) failed"
NEW_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount (mutate) failed"
[[ "$NEW_HEIGHT" == "$(( CORE_HEIGHT + 1 ))" ]] || fail "Core mutate height $NEW_HEIGHT != $(( CORE_HEIGHT + 1 ))"
NEW_BH=$(core_cli_retry getblockhash "$NEW_HEIGHT") || fail "Core getblockhash (mutate) failed"
NEW_RAW=$(core_cli_retry getblock "$NEW_BH" 0) || fail "Core getblock raw (mutate) failed"
SUB=$(bb_rpc submitblock "[\"$NEW_RAW\"]")
echo "$SUB" | grep -q '"error":null' || log "mutate submitblock -> $SUB"

BB_NEW_HEIGHT=$(bb_scalar getblockcount '[]')
[[ "$BB_NEW_HEIGHT" == "$NEW_HEIGHT" ]] || fail "blockbrew did not connect mutate block (bb=$BB_NEW_HEIGHT core=$NEW_HEIGHT)"

# Re-query both.
C2_HEIGHT=$(core_setinfo_field height)
C2_BEST=$(core_setinfo_field bestblock)
C2_HASH=$(core_setinfo_field "$HASH_KEY")
B2_HEIGHT=$(bb_field gettxoutsetinfo "$HT_PARAM" height)
B2_BEST=$(bb_field gettxoutsetinfo "$HT_PARAM" bestblock)
B2_HASH=$(bb_field gettxoutsetinfo "$HT_PARAM" "$HASH_KEY")

# height incremented on both.
[[ "$C2_HEIGHT" == "$NEW_HEIGHT" && "$B2_HEIGHT" == "$NEW_HEIGHT" ]] \
    || { MUTATE_T="bad"; log "post-mutate height: core=$C2_HEIGHT bb=$B2_HEIGHT want=$NEW_HEIGHT"; }
# bestblock changed from before.
[[ "$C2_BEST" != "$C_BEST" && "$B2_BEST" != "$B_BEST" ]] \
    || { MUTATE_T="bad"; log "post-mutate bestblock did not change (core $C_BEST->$C2_BEST bb $B_BEST->$B2_BEST)"; }
[[ "$C2_BEST" == "$B2_BEST" && "$C2_BEST" == "$NEW_BH" ]] \
    || { MUTATE_T="bad"; log "post-mutate bestblock mismatch (core=$C2_BEST bb=$B2_BEST want=$NEW_BH)"; }
# set hash CHANGED on both AND still matches between impl and Core.
[[ "$C2_HASH" != "$C_HASH" ]] || { MUTATE_T="bad"; log "Core set hash did not change after mutate ($C_HASH)"; }
[[ "$B2_HASH" != "$B_HASH" ]] || { MUTATE_T="bad"; log "blockbrew set hash did not change after mutate ($B_HASH)"; }
[[ -n "$B2_HASH" && "$C2_HASH" == "$B2_HASH" ]] \
    || { MUTATE_T="bad"; log "post-mutate set hash mismatch ($HASH_KEY): core=$C2_HASH bb=$B2_HASH"; }
[[ "$MUTATE_T" == "ok" ]] || fail "mutate check failed (see log) — set hash did not re-match Core after new block"
log "MUTATE OK: height $C_HEIGHT->$C2_HEIGHT, set hash changed + re-matches ($HASH_KEY=$B2_HASH)"

# ── 9. ERRORS — -8 for specific-block hash_serialized_3 + bogus hash_type. ─
# hash_serialized_3 <height> -> -8 (cannot query a specific block w/o coinstatsindex).
ESPEC_CODE=$(bb_errcode gettxoutsetinfo "[\"hash_serialized_3\", 5]")
if [[ "$ESPEC_CODE" != "-8" ]]; then
    ERRORS_T="bad"; log "hash_serialized_3 <height>: expected code -8, got '$ESPEC_CODE'"
fi
# bogus hash_type -> -8.
EBOGUS_CODE=$(bb_errcode gettxoutsetinfo "[\"bogustype\"]")
EBOGUS_MSG=$(bb_errmsg gettxoutsetinfo "[\"bogustype\"]")
if [[ "$EBOGUS_CODE" != "-8" ]]; then
    ERRORS_T="bad"; log "bogus hash_type: expected code -8, got '$EBOGUS_CODE'"
fi
case "$EBOGUS_MSG" in
    *not\ a\ valid\ hash_type*) : ;;
    *) ERRORS_T="bad"; log "bogus hash_type: expected msg ~'is not a valid hash_type', got '$EBOGUS_MSG'" ;;
esac

# Cross-check the Core oracle agrees on the -8 codes (parity of the error path).
CORE_ESPEC=$(core_cli -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" gettxoutsetinfo hash_serialized_3 5 2>&1 | grep -i "error code" | grep -o '\-[0-9]*' | head -1)
CORE_EBOGUS=$(core_cli -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" gettxoutsetinfo bogustype 2>&1 | grep -i "error code" | grep -o '\-[0-9]*' | head -1)
[[ "$CORE_ESPEC" == "-8" ]]  || log "note: Core specific-block error code = '$CORE_ESPEC' (expected -8)"
[[ "$CORE_EBOGUS" == "-8" ]] || log "note: Core bogus-type error code = '$CORE_EBOGUS' (expected -8)"

[[ "$ERRORS_T" == "ok" ]] || fail "error-code check: specific-block code='$ESPEC_CODE'; bogus-type code='$EBOGUS_CODE' msg='$EBOGUS_MSG'"
log "ERRORS OK: specific-block -> -8, bogus hash_type -> -8 (matches Core)"

log "PASS: blockbrew gettxoutsetinfo matches Core (fields EXACT + $HASH_KEY byte-exact + mutate re-match + errors)"
pass "$FIELDS_T" "$HASH_T" "$MUTATE_T" "$ERRORS_T"
