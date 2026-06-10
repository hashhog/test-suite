#!/usr/bin/env bash
#
# camlcoin_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity test.
#
# The DEEPEST indexing cell yet. gettxoutsetinfo's set HASH is a fingerprint of
# the ENTIRE UTXO set: matching it byte-for-byte against a REAL bitcoind proves
# camlcoin's consensus STATE (its UTXO set) is identical to Core's — not just an
# RPC shape. A single missing / extra / wrong coin (wrong value, wrong height,
# wrong coinbase flag, wrong scriptPubKey, wrong outpoint, or a spent coin not
# removed) flips the hash.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:1010+ (gettxoutsetinfo)
#   bitcoin-core/src/kernel/coinstats.cpp     (hash_serialized_3 + muhash kernels,
#                                              per-coin ApplyHash, bogosize,
#                                              total_amount accounting)
#
#   SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#     hash_type default "hash_serialized_3"; opts hash_serialized_3|muhash|none.
#   OUTPUT (base, no coinstatsindex):
#     { height, bestblock, txouts, bogosize, hash_serialized_3 (when default),
#       muhash (when muhash), transactions, disk_size, total_amount }
#   hash_serialized_3: SHA256d over the UTXO set in COIN-CURSOR ORDER
#     (by outpoint key: txid then vout). per-coin = (txid, vout,
#     height<<1|coinbase, txout). Deterministic given the same UTXO set.
#   ERRORS:
#     hash_serialized_3 with a specific block/height -> -8
#       "hash_serialized_3 hash type cannot be queried for a specific block"
#     unrecognized hash_type -> error (Core: -8 "'X' is not a valid hash_type")
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + OWN ports, launched -listen=0. To make the UTXO sets
#   IDENTICAL, both nodes share ONE chain: Core mines ~110 coinbases AND a real
#   SPEND tx (so the set has a spent output REMOVED + new outputs ADDED, not
#   just coinbases), then we replay every block to camlcoin via submitblock and
#   assert tips equal before comparing.
#
# WHAT MUST MATCH CORE EXACTLY:
#   1. FIELDS: height, bestblock, txouts, total_amount EXACT vs Core, AND the
#      set hash (hash_serialized_3 default) byte-EXACT vs Core. The hash match
#      is THE point — it proves the whole UTXO set is identical.
#   2. MUTATE: mine ONE more block (changes the set) -> height+1, bestblock
#      changed, set hash CHANGED on both AND still matching between impl + Core.
#   3. ERRORS: hash_serialized_3 <height> -> -8; bogus hash_type -> error.
#      (bogosize/transactions/disk_size: PRESENT + typed, NOT byte-equal —
#      bogosize is "meaningless", disk_size is impl-specific.)
#
# STRICT UNIFORM INTERFACE (mirrors blockfilter/camlcoin_getblockfilter.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#   Run under: setsid -w bash camlcoin_gettxoutsetinfo.sh
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO camlcoin: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO camlcoin: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO camlcoin: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-camlcoin/ + /tmp/gtxo-core-camlcoin/ and ports
#   22175/22195 (camlcoin RPC/P2P) + 22177/22197 (Core RPC/P2P).
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

CC_DATADIR="/tmp/gtxo-camlcoin"
CC_RPC=22175
CC_P2P=22195
CC_LOG="$CC_DATADIR/node.log"
CC_COOKIE=""
CC_PID=""

CORE_DATADIR="/tmp/gtxo-core-camlcoin"
CORE_RPC=22177
CORE_P2P=22197
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

NBLOCKS_PRE=110    # 110 coinbases (coinbase matures at 100), then 1 spend block.
# Final pre-mutate height = NBLOCKS_PRE + 1 (spend block) = 111.

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutsetinfo:camlcoin] $*" >&2; }

# ── Cleanup: kill OWN nodes + free OWN ports + wipe scratch on any exit. ───
# NOTE: never `pkill -f bitcoind` / never broad kill by binary name — a live
# mainnet bitcoind may be running. Only our OWN datadir-scoped CLI stop + our
# OWN fixed ports + our OWN child PID. Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.
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
    free_port "$CC_RPC"
    free_port "$CC_P2P"
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETTXOUTSETINFO camlcoin: PASS fields=$1 hash=$2 mutate=$3 errors=$4"; exit 0; }
fail() { echo "GETTXOUTSETINFO camlcoin: FAIL $*"; exit 1; }
skip() { echo "GETTXOUTSETINFO camlcoin: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
free_port "$CC_RPC"
free_port "$CC_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
if ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${CC_RPC}/${CC_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
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
# cc_has_field <method> <params> <field> -> "1" if present (incl typed null), else "".
cc_has_field() { jpy "$(cc_rpc "$1" "$2")" "'1' if ('$3' in d.get('result',{})) else ''"; }
# cc_type_field <method> <params> <field> -> python type name of result[field].
cc_type_field() { jpy "$(cc_rpc "$1" "$2")" "type(d['result']['$3']).__name__"; }

# ── 2. Launch the Core regtest oracle. ────────────────────────────────────
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # NOTE: do NOT pass -port. -listen=0 alone is RPC-only and survives the
    # sandbox watchdog (matches the passing getblockfilter launch).
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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

# ── 3. Launch camlcoin on regtest. ────────────────────────────────────────
launch_cc_once() {
    CC_COOKIE=""
    free_port "$CC_RPC"
    free_port "$CC_P2P"
    rm -rf "$CC_DATADIR"; mkdir -p "$CC_DATADIR"
    "$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
        --port "$CC_P2P" --rpcport "$CC_RPC" --metricsport 0 >"$CC_LOG" 2>&1 &
    CC_PID=$!
    # Generous startup wait (ouroboros/haskoin-style settle margin honoured
    # fleet-wide); camlcoin opens RocksDB on boot.
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
    log "launching camlcoin (regtest) rpc=:$CC_RPC -> $CC_LOG (attempt $attempt)"
    if launch_cc_once; then CC_OK=1; break; fi
    log "camlcoin launch attempt $attempt failed (see $CC_LOG); retrying after settle"
    [[ -n "$CC_PID" ]] && { kill "$CC_PID" 2>/dev/null || true; for _ in $(seq 1 10); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done; kill -9 "$CC_PID" 2>/dev/null || true; }
    CC_PID=""
    sleep 3
done
[[ "$CC_OK" == "1" ]] || { tail -n 20 "$CC_LOG" >&2 2>/dev/null || true; fail "camlcoin failed to start within 3 attempts (see $CC_LOG)"; }
log "camlcoin RPC ready"

# Early SKIP: if camlcoin has no gettxoutsetinfo at all (method not found).
CC_PROBE=$(cc_errmsg gettxoutsetinfo '[]')
case "$CC_PROBE" in
    *not\ found*|*Method\ not\ found*|*Unknown\ method*)
        skip "camlcoin has no gettxoutsetinfo RPC (got: $CC_PROBE)" ;;
esac

# ── 4. Build the shared chain on Core (with a real SPEND tx). ─────────────
# Walletless (this bitcoind build has no wallet): use Core's test_framework to
# mine $NBLOCKS_PRE coinbases to a deterministic P2WPKH address (we hold the
# key), then hand-build + BIP-143-sign a tx spending the height-1 matured
# coinbase, and mine it into a block via generateblock. That REMOVES a UTXO
# (the spent coinbase) and ADDS new outputs (the spend output) — so the set is
# not just coinbases. Core indexes every block; we replicate to camlcoin so
# both hold the IDENTICAL chain and the UTXO sets compare byte-exact.
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"
log "building walletless chain on Core: $NBLOCKS_PRE coinbases + 1 spend block"
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

# Sanity: the spend tx is actually in the spend block.
sb = rpc('getblock', [spend_blockhash, 1])
if spend_txid not in sb['tx']:
    raise RuntimeError('spend tx not in spend block')

print(json.dumps({'spend_txid': spend_txid, 'spend_height': spend_height,
                  'spend_blockhash': spend_blockhash, 'final_height': spend_height}))
" 2>&1) || fail "walletless chain build failed: $BUILD_OUT"

SPEND_TXID=$(echo "$BUILD_OUT"   | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['spend_txid'])" 2>/dev/null)
SPEND_HEIGHT=$(echo "$BUILD_OUT" | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['spend_height'])" 2>/dev/null)
CORE_HEIGHT=$(echo "$BUILD_OUT"  | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['final_height'])" 2>/dev/null)
[[ -n "$SPEND_TXID" && -n "$SPEND_HEIGHT" && -n "$CORE_HEIGHT" ]] \
    || fail "could not parse walletless build output: $BUILD_OUT"
EXPECTED=$(( NBLOCKS_PRE + 1 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED (build output: $BUILD_OUT)"
log "walletless chain built: spend $SPEND_TXID in block @h$SPEND_HEIGHT, tip @h$CORE_HEIGHT"

# ── 5. Replicate every Core block to camlcoin via submitblock. ────────────
# camlcoin rebuilds its own UTXO set as it connects each block — including
# REMOVING the spent coinbase and ADDING the spend output — so the resulting
# set is identical to Core's, which is exactly what the hash certifies.
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

# ── 6. Decide which hash_type to compare on. ──────────────────────────────
# Prefer hash_serialized_3 (the default). If camlcoin emits a hash_serialized_3
# field, use it; else fall back to muhash if camlcoin emits that. We always
# query Core with the MATCHING hash_type so the comparison is like-for-like.
CC_DEFAULT=$(cc_result gettxoutsetinfo '[]')
[[ -n "$CC_DEFAULT" ]] || fail "camlcoin gettxoutsetinfo (default) returned no result"
HASH_TYPE=""
HASH_FIELD=""
if [[ -n "$(cc_has_field gettxoutsetinfo '[]' hash_serialized_3)" ]]; then
    HASH_TYPE="hash_serialized_3"; HASH_FIELD="hash_serialized_3"
elif [[ -n "$(cc_has_field gettxoutsetinfo '["muhash"]' muhash)" ]]; then
    HASH_TYPE="muhash"; HASH_FIELD="muhash"
else
    fail "camlcoin gettxoutsetinfo emits neither hash_serialized_3 nor muhash"
fi
log "comparing on hash_type=$HASH_TYPE (field $HASH_FIELD)"

# Build params array for the chosen hash_type.
if [[ "$HASH_TYPE" == "hash_serialized_3" ]]; then
    CC_PARAMS='[]'                 # default
    CORE_HT_ARG=""                 # core_cli default
else
    CC_PARAMS='["muhash"]'
    CORE_HT_ARG="muhash"
fi

# ── 7. TEST 1 — FIELDS + SET HASH byte-exact vs Core. ─────────────────────
FIELDS_T="ok"; HASH_T="ok"

# Core oracle side (real bitcoind).
if [[ -n "$CORE_HT_ARG" ]]; then
    CORE_JSON=$(core_cli_retry gettxoutsetinfo "$CORE_HT_ARG") || fail "Core gettxoutsetinfo ($CORE_HT_ARG) failed"
else
    CORE_JSON=$(core_cli_retry gettxoutsetinfo) || fail "Core gettxoutsetinfo failed"
fi
core_get() { echo "$CORE_JSON" | python3 -c "import sys,json;v=json.load(sys.stdin)['$1'];print('true' if isinstance(v,bool) else v)" 2>/dev/null; }

CORE_H=$(core_get height)
CORE_BB=$(core_get bestblock)
CORE_TXO=$(core_get txouts)
CORE_HASH=$(core_get "$HASH_FIELD")
# total_amount: Core emits BTC decimal. Compare in SATOSHIS to be robust to any
# decimal-rendering differences (e.g. "50.00000000" vs "50.0"): both -> int sats.
CORE_TA_SAT=$(echo "$CORE_JSON" | python3 -c "import sys,json,decimal;print(int((decimal.Decimal(str(json.load(sys.stdin)['total_amount']))*100000000).to_integral_value()))" 2>/dev/null)

# camlcoin side.
CC_H=$(cc_field    gettxoutsetinfo "$CC_PARAMS" height)
CC_BB=$(cc_field   gettxoutsetinfo "$CC_PARAMS" bestblock)
CC_TXO=$(cc_field  gettxoutsetinfo "$CC_PARAMS" txouts)
CC_HASH=$(cc_field gettxoutsetinfo "$CC_PARAMS" "$HASH_FIELD")
CC_TA_SAT=$(jpy "$(cc_rpc gettxoutsetinfo "$CC_PARAMS")" "int((__import__('decimal').Decimal(str(d['result']['total_amount']))*100000000).to_integral_value())")

[[ -n "$CORE_H" && -n "$CORE_BB" && -n "$CORE_TXO" && -n "$CORE_HASH" && -n "$CORE_TA_SAT" ]] \
    || fail "Core gettxoutsetinfo missing fields (json: $CORE_JSON)"
[[ -n "$CC_H" && -n "$CC_BB" && -n "$CC_TXO" && -n "$CC_HASH" && -n "$CC_TA_SAT" ]] \
    || fail "camlcoin gettxoutsetinfo missing fields (default: $CC_DEFAULT)"

[[ "$CC_H"      == "$CORE_H"      ]] || { FIELDS_T="bad"; log "height mismatch: core=$CORE_H caml=$CC_H"; }
[[ "$CC_BB"     == "$CORE_BB"     ]] || { FIELDS_T="bad"; log "bestblock mismatch: core=$CORE_BB caml=$CC_BB"; }
[[ "$CC_TXO"    == "$CORE_TXO"    ]] || { FIELDS_T="bad"; log "txouts mismatch: core=$CORE_TXO caml=$CC_TXO"; }
[[ "$CC_TA_SAT" == "$CORE_TA_SAT" ]] || { FIELDS_T="bad"; log "total_amount(sat) mismatch: core=$CORE_TA_SAT caml=$CC_TA_SAT"; }
[[ "$FIELDS_T" == "ok" ]] || fail "field mismatch vs Core (height/bestblock/txouts/total_amount)"
log "FIELDS match: height=$CC_H bestblock=$CC_BB txouts=$CC_TXO total_amount_sat=$CC_TA_SAT"

if [[ "$CC_HASH" != "$CORE_HASH" ]]; then
    log "SET-HASH MISMATCH ($HASH_TYPE):"
    log "  core: $CORE_HASH"
    log "  caml: $CC_HASH"
    HASH_T="bad"
    fail "$HASH_TYPE set hash != Core (UTXO set is NOT byte-identical)"
fi
log "SET HASH byte-exact vs Core ($HASH_TYPE = $CC_HASH) — UTXO set is identical"

# bogosize / transactions / disk_size: PRESENT + typed (NOT byte-equal).
for f in bogosize transactions disk_size; do
    [[ -n "$(cc_has_field gettxoutsetinfo "$CC_PARAMS" "$f")" ]] \
        || fail "camlcoin gettxoutsetinfo missing field '$f'"
    T=$(cc_type_field gettxoutsetinfo "$CC_PARAMS" "$f")
    [[ "$T" == "int" ]] || fail "camlcoin gettxoutsetinfo field '$f' is type '$T', expected int"
done
log "bogosize/transactions/disk_size present + int-typed (impl-specific values not compared)"

# ── 8. TEST 2 — MUTATE: mine 1 more block -> set + hash change, still match. ─
MUTATE_T="ok"
log "mutating: mining 1 more block on Core, replaying to camlcoin"
# Deterministic mine-to address (reuse key #1 from the build).
MUTATE_ADDR=$(python3 -c "
import sys
sys.path.insert(0, '$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('11'*31+'12'), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null)
[[ -n "$MUTATE_ADDR" ]] || fail "could not derive mutate mine-to address"
NEW_BH=$(core_cli_retry generatetoaddress 1 "$MUTATE_ADDR" | python3 -c "import sys,json;print(json.load(sys.stdin)[0])" 2>/dev/null)
[[ -n "$NEW_BH" ]] || fail "Core generatetoaddress (mutate) failed"
NEW_RAW=$(core_cli_retry getblock "$NEW_BH" 0) || fail "Core getblock (mutate) failed"
SUB=$(cc_rpc submitblock "[\"$NEW_RAW\"]")
SBR=$(jpy "$SUB" "d.get('result')")
[[ -z "$SBR" || "$SBR" == "None" ]] || fail "camlcoin submitblock rejected mutate block: $SBR"

NEW_TIP_CORE=$(core_cli_retry getbestblockhash)
NEW_TIP_CC=$(cc_scalar getbestblockhash '[]')
[[ "$NEW_TIP_CORE" == "$NEW_TIP_CC" ]] || fail "tip mismatch after mutate (core=$NEW_TIP_CORE caml=$NEW_TIP_CC)"

# Re-query both. height+1, bestblock changed, hash changed on BOTH and matches.
if [[ -n "$CORE_HT_ARG" ]]; then
    CORE_JSON2=$(core_cli_retry gettxoutsetinfo "$CORE_HT_ARG") || fail "Core gettxoutsetinfo (post-mutate) failed"
else
    CORE_JSON2=$(core_cli_retry gettxoutsetinfo) || fail "Core gettxoutsetinfo (post-mutate) failed"
fi
core_get2() { echo "$CORE_JSON2" | python3 -c "import sys,json;v=json.load(sys.stdin)['$1'];print('true' if isinstance(v,bool) else v)" 2>/dev/null; }
CORE_H2=$(core_get2 height)
CORE_BB2=$(core_get2 bestblock)
CORE_HASH2=$(core_get2 "$HASH_FIELD")

CC_H2=$(cc_field    gettxoutsetinfo "$CC_PARAMS" height)
CC_BB2=$(cc_field   gettxoutsetinfo "$CC_PARAMS" bestblock)
CC_HASH2=$(cc_field gettxoutsetinfo "$CC_PARAMS" "$HASH_FIELD")

EXP_H2=$(( CORE_H + 1 ))
[[ "$CC_H2" == "$EXP_H2" && "$CORE_H2" == "$EXP_H2" ]] \
    || { MUTATE_T="bad"; log "height did not advance to $EXP_H2 (core=$CORE_H2 caml=$CC_H2)"; }
[[ "$CC_BB2" != "$CC_BB" && "$CORE_BB2" != "$CORE_BB" ]] \
    || { MUTATE_T="bad"; log "bestblock did not change after mutate (caml: $CC_BB -> $CC_BB2)"; }
[[ "$CC_HASH2" != "$CC_HASH" && "$CORE_HASH2" != "$CORE_HASH" ]] \
    || { MUTATE_T="bad"; log "set hash did not change after mutate (caml: $CC_HASH -> $CC_HASH2)"; }
[[ "$CC_HASH2" == "$CORE_HASH2" ]] \
    || { MUTATE_T="bad"; log "post-mutate set hash mismatch: core=$CORE_HASH2 caml=$CC_HASH2"; }
[[ "$CC_BB2" == "$CORE_BB2" ]] \
    || { MUTATE_T="bad"; log "post-mutate bestblock mismatch: core=$CORE_BB2 caml=$CC_BB2"; }
[[ "$MUTATE_T" == "ok" ]] || fail "mutate check failed (height/bestblock/hash change + re-match)"
log "MUTATE: height $CORE_H -> $CC_H2, bestblock changed, set hash changed + still byte-exact vs Core"

# ── 9. TEST 3 — ERROR cases. ──────────────────────────────────────────────
ERRORS_T="ok"

# (a) hash_serialized_3 with a specific block/height -> -8.
ESPEC_CODE=$(cc_errcode gettxoutsetinfo "[\"hash_serialized_3\", $SPEND_HEIGHT]")
ESPEC_MSG=$(cc_errmsg   gettxoutsetinfo "[\"hash_serialized_3\", $SPEND_HEIGHT]")
if [[ "$ESPEC_CODE" != "-8" ]]; then
    ERRORS_T="bad"; log "hash_serialized_3 <height>: expected code -8, got '$ESPEC_CODE' (msg='$ESPEC_MSG')"
fi
case "$ESPEC_MSG" in
    *cannot\ be\ queried\ for\ a\ specific\ block*) : ;;
    *) log "hash_serialized_3 <height>: msg='$ESPEC_MSG' (code check is the gate; -8 is what matters)" ;;
esac

# (b) bogus hash_type -> error.
EBOGUS_CODE=$(cc_errcode gettxoutsetinfo '["bogustype"]')
EBOGUS_MSG=$(cc_errmsg   gettxoutsetinfo '["bogustype"]')
if [[ -z "$EBOGUS_CODE" ]]; then
    ERRORS_T="bad"; log "bogus hash_type: expected an error, got none (msg='$EBOGUS_MSG')"
fi
# Core uses -8 for an unrecognized hash_type; accept any negative error code so
# we only require "it errors", but log if it's not -8.
if [[ -n "$EBOGUS_CODE" && "$EBOGUS_CODE" != "-8" ]]; then
    log "bogus hash_type: errored with code '$EBOGUS_CODE' (Core uses -8; an error is the requirement)"
fi

[[ "$ERRORS_T" == "ok" ]] \
    || fail "error-case check: specific-block code='$ESPEC_CODE' msg='$ESPEC_MSG'; bogus-type code='$EBOGUS_CODE' msg='$EBOGUS_MSG'"
log "ERRORS: hash_serialized_3 <height> -> -8; bogus hash_type -> error"

log "PASS: camlcoin gettxoutsetinfo matches Core (fields + $HASH_TYPE set hash byte-exact + mutate + errors)"
pass "$FIELDS_T" "$HASH_T" "$MUTATE_T" "$ERRORS_T"
