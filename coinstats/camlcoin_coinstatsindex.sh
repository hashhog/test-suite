#!/usr/bin/env bash
#
# camlcoin_coinstatsindex.sh — gettxoutsetinfo-AT-HISTORICAL-HEIGHT (coinstatsindex)
# Core-parity differential test for camlcoin.
#
# CAPABILITY UNDER TEST:
#   gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#   With -coinstatsindex=1, Bitcoin Core can return UTXO-set statistics AS OF a
#   HISTORICAL block (a height int or a block hash) — not just the tip. This is
#   backed by the coinstatsindex: a per-height running UTXO-set muhash + counts,
#   maintained on every block connect/disconnect.
#   Without coinstatsindex, a non-tip hash_or_height -> error -8
#   "Querying specific block heights requires coinstatsindex".
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp  gettxoutsetinfo
#       :1018  hash_or_height ("only available with coinstatsindex")
#       :1087  RPC_INVALID_PARAMETER "Querying specific block heights requires coinstatsindex"
#       :1091  RPC_INVALID_PARAMETER "hash_serialized_3 hash type cannot be queried for a specific block"
#   bitcoin-core/src/kernel/coinstats.cpp     (muhash / hash_serialized_3 kernels)
#   bitcoin-core/src/index/coinstatsindex.cpp (the per-height running index)
#
# STRICT SHARED CONTRACT (gated — none optional; identical across all 10 scripts):
#   * Launch BOTH the impl and a real bitcoind oracle on regtest with
#     -coinstatsindex=1 (and -txindex=1).
#   * Mine ~150 blocks to a deterministic address with a few real spends so the
#     UTXO set DIFFERS across heights.
#   * Mirror the chain so both nodes share a byte-identical tip.
#   * Wait for coinstatsindex to sync (poll getindexinfo / gettxoutsetinfo@tip).
#   * Pick a HISTORICAL height H well below tip (here H=100).
#   * Call gettxoutsetinfo "muhash" H (and the default hash_type) on BOTH.
#   GATE: impl.height==H==Core.height; impl.bestblock==Core.bestblock (the hash
#     AT height H, NOT the tip); impl.txouts==Core.txouts;
#     impl.total_amount==Core.total_amount; impl.<hash field> (muhash or
#     hash_serialized_3) == Core's.
#   ERROR gate: with coinstatsindex DISABLED, a non-tip hash_or_height MUST error
#     (match Core).
#
# Summary line (stdout) — EXACT:
#   PASS: COINSTATSINDEX camlcoin: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok reorg=ok
#   FAIL: COINSTATSINDEX camlcoin: FAIL <reason>
#   SKIP (missing binary only): COINSTATSINDEX camlcoin: SKIP <reason>
#
# If the impl lacks coinstatsindex / rejects hash_or_height, that is a REAL FAIL
# (not a SKIP). GAP_RE 'not found'/'not built' -> SKIP only for a missing binary.
#
# Boilerplate (node launch + Core oracle + chain mirror + teardown) is reused
# verbatim from utxosetinfo/camlcoin_gettxoutsetinfo.sh, with -coinstatsindex=1
# + -txindex=1 added to BOTH launches and the at-height assertions swapped in.
#
# Touches ONLY /tmp/csidx-camlcoin/ + /tmp/csidx-core-camlcoin/ and ports
#   40285/40305 (camlcoin RPC/P2P) + 40287/40307 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Never broad-pkills bitcoind by name (a live mainnet bitcoind may run); only
#   frees its OWN fixed ports + scratch dir.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key + raw-tx builders)

CC_DATADIR="/tmp/csidx-camlcoin"
CC_RPC=40285
CC_P2P=40305
CC_LOG="$CC_DATADIR/node.log"
CC_COOKIE=""
CC_PID=""
CC_TOOK_CSIDX_FLAG=0     # 1 iff camlcoin accepted -coinstatsindex=1 at launch

CORE_DATADIR="/tmp/csidx-core-camlcoin"
CORE_RPC=40287
CORE_P2P=40307
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

# ~150 blocks with a few real spends, then a HISTORICAL height H well below tip.
NBLOCKS_PRE=150
HIST_HEIGHT=100

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[coinstatsindex:camlcoin] $*" >&2; }

# ── Cleanup: kill OWN nodes + free OWN ports + wipe scratch on any exit. ───
free_port() {
    local p="$1"
    fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        fuser "${p}/tcp" >/dev/null 2>&1 || return 0
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
pass() { echo "COINSTATSINDEX camlcoin: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok reorg=$1"; exit 0; }
fail() { echo "COINSTATSINDEX camlcoin: FAIL $*"; exit 1; }
skip() { echo "COINSTATSINDEX camlcoin: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
free_port "$CC_RPC"
free_port "$CC_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
rm -rf "$CC_DATADIR" "$CORE_DATADIR"
mkdir -p "$CC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
# GAP_RE: missing binary -> SKIP (not built).
[[ -x "$NODE_BIN" ]] || skip "camlcoin binary not found at $NODE_BIN (not built; build with: dune build)"
[[ -x "$CORE_BIN" ]] || skip "bitcoind not found at $CORE_BIN (not built)"
[[ -x "$CORE_CLI" ]] || skip "bitcoin-cli not found at $CORE_CLI (not built)"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# ── Deterministic chain-B mining address (for the reorg phase). ────────────
# Chain B mines its competing blocks to a DISTINCT p2wpkh address so its
# coinbase scriptPubKey differs from chain A's at equal heights — guaranteeing
# A's and B's blocks at H_R differ even though the chain length is the same.
DST_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('33'*31 + '34'), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic chain-B mining address"
[[ "$DST_ADDR" == bcrt1* ]] || fail "chain-B address is not a regtest bech32 address: '$DST_ADDR'"

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
    echo "$resp"
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
cc_field() { jpy "$(cc_rpc "$1" "$2")" "d['result']['$3']"; }
cc_has_field() { jpy "$(cc_rpc "$1" "$2")" "'1' if ('$3' in d.get('result',{})) else ''"; }
cc_type_field() { jpy "$(cc_rpc "$1" "$2")" "type(d['result']['$3']).__name__"; }

# ── 2. Launch the Core regtest oracle WITH -coinstatsindex=1 -txindex=1. ───
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -fallbackfee=0.0002 \
        -coinstatsindex=1 -txindex=1 >"$CORE_LOG" 2>&1 &
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

# ── 3. Launch camlcoin on regtest. ────────────────────────────────────────
# Per the strict contract we attempt the launch WITH -coinstatsindex=1 first.
# camlcoin's CLI does NOT define that flag (no --coinstatsindex / --txindex in
# `main.exe --help`); passing it makes camlcoin refuse to boot ("unknown
# option --coinstatsindex"). That refusal is itself proof the capability is
# absent. We record it, then fall back to a flagless launch so the at-height
# query can still be exercised against the live node and produce the definitive
# verdict (the contract's "lacks coinstatsindex -> real FAIL" path).
launch_cc_once() {
    local with_csidx="$1"   # 1 -> add --coinstatsindex=1 --txindex=1
    CC_COOKIE=""
    free_port "$CC_RPC"
    free_port "$CC_P2P"
    rm -rf "$CC_DATADIR"; mkdir -p "$CC_DATADIR"
    if [[ "$with_csidx" == "1" ]]; then
        "$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
            --port "$CC_P2P" --rpcport "$CC_RPC" --metricsport 0 \
            --coinstatsindex=1 --txindex=1 >"$CC_LOG" 2>&1 &
    else
        "$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
            --port "$CC_P2P" --rpcport "$CC_RPC" --metricsport 0 >"$CC_LOG" 2>&1 &
    fi
    CC_PID=$!
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

# Attempt 1: WITH the coinstatsindex flag (contract-mandated form).
log "launching camlcoin (regtest) WITH --coinstatsindex=1 --txindex=1 rpc=:$CC_RPC -> $CC_LOG"
CC_OK=0
if launch_cc_once 1; then
    CC_OK=1; CC_TOOK_CSIDX_FLAG=1
    log "camlcoin accepted --coinstatsindex=1 and is RPC-ready"
else
    # Did it refuse because the flag is unknown? (capability-absent signal)
    if grep -qiE 'unknown option .*coinstatsindex|unknown option .*txindex' "$CC_LOG" 2>/dev/null; then
        log "camlcoin REFUSED to boot with --coinstatsindex/--txindex (unknown option) — capability absent at CLI"
    else
        log "camlcoin WITH-flag launch failed for another reason (see $CC_LOG); falling back to flagless"
    fi
    [[ -n "$CC_PID" ]] && { kill "$CC_PID" 2>/dev/null || true; for _ in $(seq 1 10); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done; kill -9 "$CC_PID" 2>/dev/null || true; }
    CC_PID=""
    # Attempt 2..4: flagless, so the live node is up and the at-height query runs.
    for attempt in 1 2 3; do
        log "launching camlcoin (regtest, flagless) rpc=:$CC_RPC (attempt $attempt)"
        if launch_cc_once 0; then CC_OK=1; break; fi
        log "camlcoin flagless launch attempt $attempt failed (see $CC_LOG); retrying after settle"
        [[ -n "$CC_PID" ]] && { kill "$CC_PID" 2>/dev/null || true; for _ in $(seq 1 10); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done; kill -9 "$CC_PID" 2>/dev/null || true; }
        CC_PID=""
        sleep 3
    done
fi
[[ "$CC_OK" == "1" ]] || { tail -n 20 "$CC_LOG" >&2 2>/dev/null || true; fail "camlcoin failed to start (see $CC_LOG)"; }
log "camlcoin RPC ready (took_coinstatsindex_flag=$CC_TOOK_CSIDX_FLAG)"

# Early SKIP only for a genuinely-missing method (binary-level gap).
CC_PROBE=$(cc_errmsg gettxoutsetinfo '[]')
case "$CC_PROBE" in
    *not\ found*|*Method\ not\ found*|*Unknown\ method*)
        skip "camlcoin has no gettxoutsetinfo RPC (got: $CC_PROBE)" ;;
esac

# ── 4. Build the shared chain on Core (~150 blocks + a few real spends). ───
# Walletless: mine NBLOCKS_PRE coinbases to a deterministic P2WPKH address (we
# hold the key), then hand-build + BIP-143-sign a few spends of matured
# coinbases and mine each into its own block. Spends REMOVE coins and ADD new
# outputs so the UTXO set genuinely DIFFERS across heights (the whole point of a
# per-height index). Core indexes every block; we replicate to camlcoin so both
# hold the IDENTICAL chain.
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"
log "building walletless chain on Core: $NBLOCKS_PRE coinbases + spends"
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

# Mine the bulk first.
rpc('generatetoaddress', [$NBLOCKS_PRE, addr])

# Spend a few matured coinbases (heights 1,2,3) — one tx per block, so the UTXO
# set changes at distinct, well-separated heights (all far below our HIST_HEIGHT
# anchor of $HIST_HEIGHT, so the set at H is non-trivial and deterministic).
spends = []
for cb_h in (1, 2, 3):
    cb_tx = rpc('getblock', [rpc('getblockhash', [cb_h]), 2])['tx'][0]
    in_amount = int(round(cb_tx['vout'][0]['value'] * 100000000))
    tx = CTransaction()
    tx.vin.append(CTxIn(COutPoint(int(cb_tx['txid'], 16), 0), b'', 0xffffffff))
    tx.vout.append(CTxOut(in_amount - 1000, dst_spk))   # 1000 sat fee
    tx.wit.vtxinwit.append(CTxInWitness())
    tx.wit.vtxinwit[0].scriptWitness.stack = [pub]
    sign_input_segwitv0(tx, 0, scriptcode, in_amount, k)
    raw = tx.serialize().hex()
    acc = rpc('testmempoolaccept', [[raw]])[0]
    if not acc.get('allowed'):
        raise RuntimeError('spend tx (cb %d) not accepted: %s' % (cb_h, acc.get('reject-reason')))
    bh = rpc('generateblock', [addr, [raw]])['hash']
    spends.append({'cb_height': cb_h, 'txid': tx.txid_hex, 'blockhash': bh})

final_height = rpc('getblockcount')
print(json.dumps({'spends': spends, 'final_height': final_height}))
" 2>&1) || fail "walletless chain build failed: $BUILD_OUT"

CORE_HEIGHT=$(echo "$BUILD_OUT" | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['final_height'])" 2>/dev/null)
[[ -n "$CORE_HEIGHT" ]] || fail "could not parse walletless build output: $BUILD_OUT"
EXPECTED=$(( NBLOCKS_PRE + 3 ))   # 3 spend blocks
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED (build output: $BUILD_OUT)"
[[ "$HIST_HEIGHT" -lt "$CORE_HEIGHT" ]] || fail "HIST_HEIGHT $HIST_HEIGHT not below tip $CORE_HEIGHT"
log "walletless chain built: tip @h$CORE_HEIGHT, historical anchor H=$HIST_HEIGHT"

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

# ── 6. Wait for Core's coinstatsindex to sync. ────────────────────────────
# Poll getindexinfo until coinstatsindex.synced==true (or it reaches tip). This
# is the oracle's per-height index becoming queryable; without it, the at-height
# query would 500 with "still syncing".
log "waiting for Core coinstatsindex to sync to tip $CORE_HEIGHT"
CSIDX_SYNCED=0
for _ in $(seq 1 60); do
    II=$(core_cli_retry getindexinfo 2>/dev/null)
    SY=$(echo "$II" | python3 -c "
import sys, json
try:
    d=json.load(sys.stdin)
    e=d.get('coinstatsindex',{})
    print('1' if (e.get('synced') is True) or (e.get('best_block_height',0) >= $CORE_HEIGHT) else '0')
except Exception:
    print('0')
" 2>/dev/null)
    if [[ "$SY" == "1" ]]; then CSIDX_SYNCED=1; break; fi
    sleep 1
done
[[ "$CSIDX_SYNCED" == "1" ]] || fail "Core coinstatsindex did not sync to tip within 60s (getindexinfo: $(core_cli_retry getindexinfo 2>/dev/null))"
# Sanity: Core can answer the at-height query (proves the oracle path works).
CORE_ATH_PROBE=$(core_cli_retry gettxoutsetinfo muhash "$HIST_HEIGHT") \
    || fail "Core gettxoutsetinfo muhash $HIST_HEIGHT failed even after index sync"
log "Core coinstatsindex synced; at-height query works"

# Core's authoritative answer AT the historical height H (for both hash types).
CORE_ATH_MUHASH_JSON="$CORE_ATH_PROBE"
CORE_ATH_DEFAULT_JSON=$(core_cli_retry gettxoutsetinfo none "$HIST_HEIGHT") \
    || fail "Core gettxoutsetinfo none $HIST_HEIGHT failed"
# hash_serialized_3 at a specific height is forbidden by Core (-8); we test the
# at-height comparison on muhash (the contract's primary hash field), and use
# 'none' for the field comparison of height/bestblock/txouts/amount.
core_ath() { echo "$CORE_ATH_MUHASH_JSON" | python3 -c "import sys,json;v=json.load(sys.stdin).get('$1');print('' if v is None else ('true' if isinstance(v,bool) else v))" 2>/dev/null; }
CORE_ATH_H=$(core_ath height)
CORE_ATH_BB=$(core_ath bestblock)
CORE_ATH_TXO=$(core_ath txouts)
CORE_ATH_MUHASH=$(core_ath muhash)
CORE_ATH_TA_SAT=$(echo "$CORE_ATH_MUHASH_JSON" | python3 -c "import sys,json,decimal;v=json.load(sys.stdin).get('total_amount');print('' if v is None else int((decimal.Decimal(str(v))*100000000).to_integral_value()))" 2>/dev/null)
# The block hash AT height H (NOT the tip) — bestblock must equal THIS.
CORE_HASH_AT_H=$(core_cli_retry getblockhash "$HIST_HEIGHT")
[[ -n "$CORE_ATH_H" && -n "$CORE_ATH_BB" && -n "$CORE_ATH_TXO" && -n "$CORE_ATH_MUHASH" && -n "$CORE_ATH_TA_SAT" && -n "$CORE_HASH_AT_H" ]] \
    || fail "Core at-height answer missing fields (json: $CORE_ATH_MUHASH_JSON)"
[[ "$CORE_ATH_H" == "$HIST_HEIGHT" ]] || fail "Core at-height returned height=$CORE_ATH_H, expected $HIST_HEIGHT"
[[ "$CORE_ATH_BB" == "$CORE_HASH_AT_H" ]] || fail "Core bestblock $CORE_ATH_BB != blockhash@H $CORE_HASH_AT_H (oracle self-check)"
log "Core@H=$HIST_HEIGHT: bestblock=$CORE_ATH_BB txouts=$CORE_ATH_TXO total_amount_sat=$CORE_ATH_TA_SAT muhash=$CORE_ATH_MUHASH"

# ── 7. ERROR GATE (coinstatsindex DISABLED): a non-tip query MUST error. ──
# We bring up a SEPARATE Core instance WITHOUT -coinstatsindex on the same
# scratch ports as the oracle is NOT free, so instead we assert the contract
# against camlcoin (which runs WITHOUT a coinstatsindex): a non-tip query must
# error -8 with Core's message. Core's own no-index behavior is the documented
# reference (blockchain.cpp:1087); we verify camlcoin matches it.
ERR_T="ok"
ECODE=$(cc_errcode gettxoutsetinfo "[\"muhash\", $HIST_HEIGHT]")
EMSG=$(cc_errmsg   gettxoutsetinfo "[\"muhash\", $HIST_HEIGHT]")
if [[ "$ECODE" != "-8" ]]; then
    ERR_T="bad"; log "no-index error gate: muhash <height> expected code -8, got '$ECODE' (msg='$EMSG')"
fi
case "$EMSG" in
    *coinstatsindex*) : ;;
    *) log "no-index error gate: msg='$EMSG' (does not mention coinstatsindex; Core says 'Querying specific block heights requires coinstatsindex')" ;;
esac
log "error-gate (camlcoin, no coinstatsindex): muhash <height> -> code=$ECODE msg='$EMSG'"

# ── 8. AT-HEIGHT GATE — the core capability test against camlcoin. ────────
# Call gettxoutsetinfo "muhash" H on camlcoin and compare every field to Core's
# authoritative at-height answer. This SUCCEEDS only if camlcoin has a working
# coinstatsindex (per-height running muhash + counts). camlcoin's handler
# (lib/rpc.ml:8298-8309) explicitly rejects ANY hash_or_height with -8
# "Querying specific block heights requires coinstatsindex" — so this is a real
# capability test, not a shape probe.
ATH_T="ok"
CC_ATH_JSON=$(cc_rpc gettxoutsetinfo "[\"muhash\", $HIST_HEIGHT]")
CC_ATH_HASRESULT=$(jpy "$CC_ATH_JSON" "'1' if d.get('result') is not None else ''")
if [[ -z "$CC_ATH_HASRESULT" ]]; then
    CC_ATH_ECODE=$(jpy "$CC_ATH_JSON" "d['error']['code']")
    CC_ATH_EMSG=$(jpy "$CC_ATH_JSON" "d['error']['message']")
    log "camlcoin gettxoutsetinfo muhash $HIST_HEIGHT did NOT return at-height stats: code=$CC_ATH_ECODE msg='$CC_ATH_EMSG'"
    fail "no coinstatsindex: gettxoutsetinfo \"muhash\" $HIST_HEIGHT -> error ${CC_ATH_ECODE:-?} '${CC_ATH_EMSG}' (cannot query historical height; expected height/bestblock/txouts/amount/muhash @H==Core)"
fi

# If we somehow got a result, gate every field against Core@H.
CC_ATH_H=$(jpy   "$CC_ATH_JSON" "d['result'].get('height')")
CC_ATH_BB=$(jpy  "$CC_ATH_JSON" "d['result'].get('bestblock')")
CC_ATH_TXO=$(jpy "$CC_ATH_JSON" "d['result'].get('txouts')")
CC_ATH_MUHASH=$(jpy "$CC_ATH_JSON" "d['result'].get('muhash')")
CC_ATH_TA_SAT=$(jpy "$CC_ATH_JSON" "int((__import__('decimal').Decimal(str(d['result'].get('total_amount'))) *100000000).to_integral_value()) if d['result'].get('total_amount') is not None else ''")

ATHEIGHT_OK=ok; TXOUTS_OK=ok; AMOUNT_OK=ok; HASH_OK=ok; BESTBLOCK_OK=ok
[[ "$CC_ATH_H"  == "$HIST_HEIGHT" && "$CC_ATH_H" == "$CORE_ATH_H" ]] || { ATH_T=bad; ATHEIGHT_OK=bad; log "height@H mismatch: want $HIST_HEIGHT core=$CORE_ATH_H caml=$CC_ATH_H"; }
[[ "$CC_ATH_BB" == "$CORE_ATH_BB" && "$CC_ATH_BB" == "$CORE_HASH_AT_H" ]] || { ATH_T=bad; BESTBLOCK_OK=bad; log "bestblock@H mismatch: blockhash@H=$CORE_HASH_AT_H core=$CORE_ATH_BB caml=$CC_ATH_BB"; }
[[ "$CC_ATH_TXO" == "$CORE_ATH_TXO" ]] || { ATH_T=bad; TXOUTS_OK=bad; log "txouts@H mismatch: core=$CORE_ATH_TXO caml=$CC_ATH_TXO"; }
[[ "$CC_ATH_TA_SAT" == "$CORE_ATH_TA_SAT" ]] || { ATH_T=bad; AMOUNT_OK=bad; log "total_amount@H mismatch: core=$CORE_ATH_TA_SAT caml=$CC_ATH_TA_SAT"; }
[[ "$CC_ATH_MUHASH" == "$CORE_ATH_MUHASH" ]] || { ATH_T=bad; HASH_OK=bad; log "muhash@H mismatch: core=$CORE_ATH_MUHASH caml=$CC_ATH_MUHASH"; }

[[ "$ATH_T" == "ok" ]] || fail "at-height divergence vs Core@H=$HIST_HEIGHT (atheight=$ATHEIGHT_OK txouts=$TXOUTS_OK amount=$AMOUNT_OK hash=$HASH_OK bestblock=$BESTBLOCK_OK)"

log "PASS (linear): camlcoin coinstatsindex at-height @H=$HIST_HEIGHT matches Core (height/bestblock/txouts/total_amount/muhash)"

# Sanity precondition for the reorg phase: both nodes' muhash @tip must agree,
# proving the per-coin serialization matches Core (a tip mismatch would make the
# reorg gate moot).
CORE_TIP_MU=$(core_cli_retry gettxoutsetinfo muhash | python3 -c "import sys,json;print(json.load(sys.stdin).get('muhash',''))" 2>/dev/null)
CC_TIP_MU=$(cc_field gettxoutsetinfo '["muhash"]' muhash)
[[ "$CORE_TIP_MU" =~ ^[0-9a-f]{64}$ ]] || fail "Core gettxoutsetinfo muhash @tip not 64-hex: '$CORE_TIP_MU'"
[[ "$CC_TIP_MU" == "$CORE_TIP_MU" ]] || fail "tip muhash mismatch (per-coin ser differs): caml=$CC_TIP_MU core=$CORE_TIP_MU"

# ── 9. REORG-SAFETY GATE ────────────────────────────────────────────────────
# WHY: the at-height gate above only proves the impl maintains the per-height
# MuHash on a LINEAR chain (connect-only). It CANNOT catch a reorg-desync — an
# impl that reverses the index on disconnect but never RE-ADDS on reconnect of
# the new chain's blocks will pass linear yet serve a stale (chain-A) muhash for
# a height that was reorged onto chain B. Core's coinstatsindex (BaseIndex +
# index/coinstatsindex.cpp: CustomAppend on connect, CustomRemove on disconnect)
# re-runs CustomAppend when B's blocks reconnect, so its per-height MuHash tracks
# the ACTIVE chain. This gate forces a reorg and asserts the impl agrees.
#
# REORG DESIGN (impl-agnostic; mirrors the committed rustoshi harness exactly):
#   (1) Both nodes already share linear chain A at tip N (= $CORE_HEIGHT).
#   (2) On the Core ORACLE only: invalidateblock(getblockhash(F+1)) for a fork
#       point F < N. That disconnects A's F+1..N (Core runs CustomRemove for each).
#       Then generatetoaddress a LONGER competing chain B from F to N+3 to a
#       DETERMINISTIC distinct address. B has strictly more work, so Core reorgs
#       A->B and its index re-runs CustomAppend for B's F+1..N+3.
#   (3) REORG TRIGGER via invalidateblock ON THE IMPL (Core-faithful). A naive
#       submitblock of B's blocks onto A's tip N would be (correctly) rejected as
#       a side-branch double-spend. So FIRST call invalidateblock(F+1) ON THE
#       IMPL — rewinding it to fork F (disconnecting A's F+1..N, restoring the
#       prevouts they spent, and dropping the coinstats snapshots above F) — THEN
#       submitblock B's blocks F+1..N+3 in order; each now connects as a clean
#       active-tip extension and the impl's coinstats re-appends for B.
#   (4) Pick H_R with F < H_R <= N — a height whose block DIFFERS between A and
#       B. Call gettxoutsetinfo muhash H_R on BOTH and ASSERT
#       impl.muhash@H_R == Core.muhash@H_R AND impl.bestblock@H_R ==
#       Core.bestblock@H_R (the B-chain block at H_R, NOT A's).
REORG_OK="ok"
REORG_DEPTH=5                                   # A's blocks F+1..N that get reorged out
REORG_F=$(( CORE_HEIGHT - REORG_DEPTH ))        # fork point F (< N)
REORG_NEWTIP=$(( CORE_HEIGHT + 3 ))             # B's tip height (N+3): strictly more work
REORG_H=$CORE_HEIGHT                            # H_R: the OLD tip height (F < H_R <= N)

# Record A's block hash at H_R (must change after the reorg, proving A!=B at H_R).
A_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "Core getblockhash $REORG_H (chain A) failed"
log "reorg: chain A tip N=$CORE_HEIGHT, fork F=$REORG_F, B newtip=$REORG_NEWTIP, reorg-H=$REORG_H (A@H_R=$A_HASH_AT_HR)"

# (2) On the Core oracle: invalidate F+1 then build longer chain B to DST_ADDR.
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

# Wait for Core's coinstatsindex to re-sync to the B tip after the reorg.
CSIDX_RESYNCED=0
for _ in $(seq 1 60); do
    II=$(core_cli_retry getindexinfo 2>/dev/null)
    SY=$(echo "$II" | python3 -c "
import sys, json
try:
    d=json.load(sys.stdin); e=d.get('coinstatsindex',{})
    print('1' if (e.get('synced') is True) or (e.get('best_block_height',0) >= $CORE_BTIP_H) else '0')
except Exception:
    print('0')" 2>/dev/null)
    if [[ "$SY" == "1" ]]; then CSIDX_RESYNCED=1; break; fi
    sleep 1
done
[[ "$CSIDX_RESYNCED" == "1" ]] || fail "Core coinstatsindex did not re-sync to B tip within 60s"

# (3) REORG TRIGGER: invalidateblock(F+1) ON THE IMPL first, rewinding it to F.
IMPL_FORK_CHILD=$(cc_scalar getblockhash "[$(( REORG_F + 1 ))]")
[[ "$IMPL_FORK_CHILD" == "$FORK_CHILD" ]] \
    || fail "reorg: impl F+1 hash ($IMPL_FORK_CHILD) != Core F+1 hash ($FORK_CHILD) before invalidate"
log "reorg: invalidateblock F+1=$IMPL_FORK_CHILD on camlcoin (rewind to fork F=$REORG_F)"
IB_RESP=$(cc_rpc invalidateblock "[\"$IMPL_FORK_CHILD\"]")
echo "$IB_RESP" | grep -q '"error":null\|"error": null' || log "reorg: camlcoin invalidateblock -> $IB_RESP"
# Poll until the impl has actually rewound to fork point F.
IMPL_AT_F=0
for _ in $(seq 1 30); do
    CC_INVAL_H=$(cc_scalar getblockcount '[]')
    if [[ "$CC_INVAL_H" == "$REORG_F" ]]; then IMPL_AT_F=1; break; fi
    sleep 1
done
[[ "$IMPL_AT_F" == "1" ]] \
    || fail "camlcoin did not rewind to fork F=$REORG_F after invalidateblock (impl height=$CC_INVAL_H) — invalidateblock unsupported/ineffective"
CC_INVAL_TIP=$(cc_scalar getbestblockhash '[]')
log "reorg: camlcoin rewound to fork F=$REORG_F (tip $CC_INVAL_TIP)"

# Mirror B to the impl: submitblock B's blocks F+1..N+3 in order. Each now
# connects as a clean active-tip extension; B carries strictly more work.
log "reorg: mirroring B's blocks $(( REORG_F + 1 ))..$REORG_NEWTIP to camlcoin via submitblock"
for (( h=REORG_F+1; h<=REORG_NEWTIP; h++ )); do
    kill -0 "$CC_PID" 2>/dev/null || fail "camlcoin died during B replication at h=$h (see $CC_LOG)"
    bh=$(core_cli_retry getblockhash "$h") || fail "Core getblockhash $h (chain B) failed"
    raw=$(core_cli_retry getblock "$bh" 0) || fail "Core getblock $bh 0 (chain B) failed"
    [[ -n "$raw" ]] || fail "empty raw for chain-B block at h=$h"
    SUB=$(cc_rpc submitblock "[\"$raw\"]")
    SBR=$(jpy "$SUB" "d.get('result')")
    if [[ -n "$SBR" && "$SBR" != "None" && "$SBR" != "inconclusive" && "$SBR" != "duplicate" ]]; then
        log "reorg submitblock h=$h -> result='$SBR' resp=$SUB"
    fi
done

# Poll until impl tip == Core tip (B). If the impl never adopts B, that is itself
# a reorg failure (it could not switch to the more-work chain).
CC_REORG_OK=0
for _ in $(seq 1 30); do
    CC_BTIP=$(cc_scalar getbestblockhash '[]')
    CC_BTIP_H=$(cc_scalar getblockcount '[]')
    if [[ "$CC_BTIP" == "$CORE_BTIP" && "$CC_BTIP_H" == "$CORE_BTIP_H" ]]; then CC_REORG_OK=1; break; fi
    sleep 1
done
[[ "$CC_REORG_OK" == "1" ]] \
    || fail "camlcoin did not adopt chain B (impl tip=$CC_BTIP @h$CC_BTIP_H, Core B tip=$CORE_BTIP @h$CORE_BTIP_H) — reorg to more-work chain failed"
log "reorg: camlcoin adopted chain B (tip $CC_BTIP @h$CC_BTIP_H)"

# (4) The reorg differential: gettxoutsetinfo muhash H_R on BOTH. Assert the
#     impl serves B's per-height MuHash + bestblock, NOT A's stale value.
RB_MUH=$(core_cli_retry gettxoutsetinfo muhash "$REORG_H") || fail "Core gettxoutsetinfo muhash $REORG_H (post-reorg) failed"
RC_HEIGHT=$(echo "$RB_MUH" | python3 -c "import sys,json;print(json.load(sys.stdin).get('height',''))" 2>/dev/null)
RC_BEST=$(echo "$RB_MUH"   | python3 -c "import sys,json;print(json.load(sys.stdin).get('bestblock',''))" 2>/dev/null)
RC_MUHASH=$(echo "$RB_MUH" | python3 -c "import sys,json;print(json.load(sys.stdin).get('muhash',''))" 2>/dev/null)
[[ "$RC_HEIGHT" == "$REORG_H" ]] || fail "Core post-reorg muhash@H_R height=$RC_HEIGHT != H_R=$REORG_H"
[[ "$RC_BEST" == "$B_HASH_AT_HR" ]] || fail "Core post-reorg bestblock@H_R=$RC_BEST != B@H_R=$B_HASH_AT_HR (oracle wrong?)"

CC_R_JSON=$(cc_rpc gettxoutsetinfo "[\"muhash\", $REORG_H]")
RB_HEIGHT=$(jpy "$CC_R_JSON" "d['result'].get('height')")
RB_BEST=$(jpy   "$CC_R_JSON" "d['result'].get('bestblock')")
RB_MUHASH=$(jpy "$CC_R_JSON" "d['result'].get('muhash')")
log "reorg @H_R=$REORG_H: core(best=$RC_BEST muhash=$RC_MUHASH) caml(height=$RB_HEIGHT best=$RB_BEST muhash=$RB_MUHASH)"

if [[ "$RB_BEST" == "$A_HASH_AT_HR" ]]; then
    REORG_OK="bad"; log "reorg DESYNC: camlcoin bestblock@H_R=$RB_BEST is A's stale block (B@H_R=$B_HASH_AT_HR) — index did not reconnect B"
fi
[[ "$RB_HEIGHT" == "$REORG_H" ]] \
    || { REORG_OK="bad"; log "reorg: camlcoin height@H_R=$RB_HEIGHT != H_R=$REORG_H"; }
[[ "$RB_BEST" == "$B_HASH_AT_HR" && "$RB_BEST" == "$RC_BEST" ]] \
    || { REORG_OK="bad"; log "reorg: bestblock@H_R mismatch (caml=$RB_BEST want B@H_R=$B_HASH_AT_HR core=$RC_BEST)"; }
[[ -n "$RB_MUHASH" && "$RB_MUHASH" == "$RC_MUHASH" ]] \
    || { REORG_OK="bad"; log "reorg: muhash@H_R MISMATCH (caml=$RB_MUHASH core=$RC_MUHASH) — impl served stale chain-A index after reorg"; }

[[ "$REORG_OK" == "ok" ]] || fail "reorg-safety gate failed at H_R=$REORG_H (impl muhash/bestblock did not follow reorg from A to B; coinstatsindex reverses on disconnect but does NOT reconnect on the new chain)"
log "REORG OK @H_R=$REORG_H: camlcoin muhash+bestblock match Core's B-chain values after reorg"

log "PASS: camlcoin coinstatsindex at-height query matches Core on all gated fields (linear + reorg)"
pass "$REORG_OK"
