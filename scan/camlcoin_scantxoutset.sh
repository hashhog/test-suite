#!/usr/bin/env bash
#
# camlcoin_scantxoutset.sh — self-contained scantxoutset Core-parity test.
#
# scantxoutset scans the CURRENT UTXO set for outputs matching one or more
# output descriptors and returns the matched coins. This cell proves that
# camlcoin's scantxoutset (lib/rpc.ml::handle_scantxoutset) returns the SAME
# matched coins, amounts, and result shape as a REAL bitcoind, against an
# IDENTICAL UTXO set.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:2316+ (scantxoutset 'action' [scanobjects])
#     action='start' with scanobjects=[{"desc":"addr(<addr>)"}] or
#       ["addr(<addr>)"] scans the live UTXO set for matching outputs.
#     Returns an OBJECT:
#       { success(bool), txouts(int total UTXOs scanned), height(int tip),
#         bestblock(hex), unspents(array of
#           {txid,vout,scriptPubKey,desc,amount,coinbase,height,blockhash?,
#            confirmations?}),
#         total_amount(BTC) }
#     unspents is iterated in coin-cursor (outpoint) order; we sort both sides
#     by (txid,vout) before comparing so order is not load-bearing.
#     action='status' -> null when idle; action='abort' -> bool.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + OWN ports, launched -listen=0 (RPC-only). To make the
#   UTXO sets IDENTICAL, both nodes share ONE chain: Core mines ~110 coinbases
#   to a deterministic P2WPKH funding address (we hold the key) AND a real SPEND
#   tx paying a second deterministic address (so the set has a non-coinbase,
#   single, known output to match crisply), then we replay every block to
#   camlcoin via submitblock and assert tips equal before scanning.
#
# DIFFERENTIAL TEST (run on BOTH impl and Core):
#   (1) fund known addresses (mine coinbases to FUND_ADDR; spend one matured
#       coinbase to MATCH_ADDR) and confirm.
#   (2) scantxoutset start [{"desc":"addr(MATCH_ADDR)"}].
#   (3) desc  : impl's matched unspent (txid/vout/amount) EQUALS Core's.
#       amount: impl's total_amount EQUALS Core's (compared in satoshis).
#   (4) shape : top-level has success + total_amount + unspents; each unspent
#       has EVERY key Core emits (txid,vout,scriptPubKey,desc,amount,coinbase,
#       height,blockhash,confirmations). blockhash+confirmations are GATED
#       (required, must equal Core's) — mirrors the strict shape check in
#       test-suite/scan/rustoshi_scantxoutset.sh.
#   (5) empty : an unmatched address -> total_amount 0 / empty unspents on BOTH.
#   Extra robustness: also scan addr(FUND_ADDR) (many coinbase coins) and assert
#   total_amount + the full matched-outpoint set EQUAL Core's.
#
# Summary line (stdout, EXACTLY one):
#   PASS: SCANTXOUTSET camlcoin: PASS desc=ok amount=ok shape=ok empty=ok
#   FAIL: SCANTXOUTSET camlcoin: FAIL <short reason>
#   SKIP (GAP_RE): SCANTXOUTSET camlcoin: SKIP <reason 'not found'/'not built'>
#
# STRICT UNIFORM INTERFACE (mirrors utxosetinfo/camlcoin_gettxoutsetinfo.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#   Run under: setsid -w bash camlcoin_scantxoutset.sh
#
# Touches ONLY /tmp/stxo-camlcoin/ + /tmp/stxo-core-camlcoin/ and ports
#   40375/40395 (camlcoin RPC/P2P) + 40377/40397 (Core RPC/P2P).
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

CC_DATADIR="/tmp/stxo-camlcoin"
CC_RPC=40375
CC_P2P=40395
CC_LOG="$CC_DATADIR/node.log"
CC_COOKIE=""
CC_PID=""

CORE_DATADIR="/tmp/stxo-core-camlcoin"
CORE_RPC=40377
CORE_P2P=40397
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

NBLOCKS_PRE=110    # 110 coinbases (coinbase matures at 100), then 1 spend block.
# Final pre-scan height = NBLOCKS_PRE + 1 (spend block) = 111.

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[scantxoutset:camlcoin] $*" >&2; }

# ── Cleanup: kill OWN nodes + free OWN ports + wipe scratch on any exit. ───
# NOTE: never `pkill -f bitcoind` / never broad kill by binary name — a live
# mainnet bitcoind may be running. Only our OWN datadir-scoped CLI stop + our
# OWN fixed ports + our OWN child PID. Every fuser -k redirects stdout.
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
pass() { echo "SCANTXOUTSET camlcoin: PASS desc=$1 amount=$2 shape=$3 empty=$4"; exit 0; }
fail() { echo "SCANTXOUTSET camlcoin: FAIL $*"; exit 1; }
skip() { echo "SCANTXOUTSET camlcoin: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
free_port "$CC_RPC"
free_port "$CC_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
rm -rf "$CC_DATADIR" "$CORE_DATADIR"
mkdir -p "$CC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions (GAP_RE-compatible skips for missing tooling). ────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || skip "camlcoin binary not found at $NODE_BIN (not built; build with: dune build)"
[[ -x "$CORE_BIN" ]] || skip "bitcoind not found at $CORE_BIN (not built)"
[[ -x "$CORE_CLI" ]] || skip "bitcoin-cli not found at $CORE_CLI (not built)"
[[ -d "$TF_PATH/test_framework" ]] || skip "Core test_framework not found at $TF_PATH (not found)"

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
cc_scalar()  { jpy "$(cc_rpc "$1" "$2")" "d['result']"; }
cc_errmsg()  { jpy "$(cc_rpc "$1" "$2")" "d['error']['message']"; }

# ── 2. Launch the Core regtest oracle. ────────────────────────────────────
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # NOTE: do NOT pass -port. -listen=0 alone is RPC-only and survives the
    # sandbox watchdog (matches the passing gettxoutsetinfo launch).
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

# Early SKIP: if camlcoin has no scantxoutset at all (method not found).
CC_PROBE=$(cc_errmsg scantxoutset '["status"]')
case "$CC_PROBE" in
    *not\ found*|*Method\ not\ found*|*Unknown\ method*)
        skip "camlcoin has no scantxoutset RPC (not found; got: $CC_PROBE)" ;;
esac

# ── 4. Build the shared chain on Core (coinbases + a real SPEND tx). ───────
# Walletless (this bitcoind build has no wallet): use Core's test_framework to
# mine $NBLOCKS_PRE coinbases to a deterministic P2WPKH funding address (key #1,
# we hold it), then hand-build + BIP-143-sign a tx spending the height-1 matured
# coinbase, paying a SECOND deterministic P2WPKH address (key #2, MATCH_ADDR),
# and mine it into a block via generateblock. This gives:
#   - FUND_ADDR: NBLOCKS_PRE coinbase coins MINUS the one we just spent.
#   - MATCH_ADDR: exactly ONE non-coinbase coin of a known amount (crisp match).
# Core indexes every block; we replicate to camlcoin so both hold the IDENTICAL
# chain and the UTXO sets compare exactly.
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

# Deterministic key #1 -> FUND_ADDR (mine coinbases here).
k = ECKey(); k.set(bytes.fromhex('11'*31 + '12'), compressed=True)
pub = k.get_pubkey().get_bytes()
fund_addr = key_to_p2wpkh(pub, main=False)
scriptcode = key_to_p2pkh_script(pub)   # BIP-143 scriptCode for P2WPKH
# Deterministic key #2 -> MATCH_ADDR (single spend destination).
k2 = ECKey(); k2.set(bytes.fromhex('22'*31 + '23'), compressed=True)
match_addr = key_to_p2wpkh(k2.get_pubkey().get_bytes(), main=False)
match_spk = key_to_p2wpkh_script(k2.get_pubkey().get_bytes())
# Deterministic key #3 -> NOMATCH_ADDR (never funded; empty-scan target).
k3 = ECKey(); k3.set(bytes.fromhex('33'*31 + '34'), compressed=True)
nomatch_addr = key_to_p2wpkh(k3.get_pubkey().get_bytes(), main=False)

rpc('generatetoaddress', [$NBLOCKS_PRE, fund_addr])

# Spend the height-1 coinbase output (matured after 100 blocks) -> MATCH_ADDR.
cb_tx = rpc('getblock', [rpc('getblockhash', [1]), 2])['tx'][0]
in_amount = int(round(cb_tx['vout'][0]['value'] * 100000000))
spend_value = in_amount - 1000   # 1000 sat fee
tx = CTransaction()
tx.vin.append(CTxIn(COutPoint(int(cb_tx['txid'], 16), 0), b'', 0xffffffff))
tx.vout.append(CTxOut(spend_value, match_spk))
tx.wit.vtxinwit.append(CTxInWitness())
tx.wit.vtxinwit[0].scriptWitness.stack = [pub]      # pubkey; sig inserted at idx 0
sign_input_segwitv0(tx, 0, scriptcode, in_amount, k)
raw = tx.serialize().hex()
spend_txid = tx.txid_hex

acc = rpc('testmempoolaccept', [[raw]])[0]
if not acc.get('allowed'):
    raise RuntimeError('spend tx not accepted: %s' % acc.get('reject-reason'))

spend_blockhash = rpc('generateblock', [fund_addr, [raw]])['hash']
spend_height = rpc('getblockcount')

sb = rpc('getblock', [spend_blockhash, 1])
if spend_txid not in sb['tx']:
    raise RuntimeError('spend tx not in spend block')

print(json.dumps({
    'fund_addr': fund_addr, 'match_addr': match_addr, 'nomatch_addr': nomatch_addr,
    'spend_txid': spend_txid, 'spend_value': spend_value,
    'spend_height': spend_height, 'spend_blockhash': spend_blockhash,
    'final_height': spend_height}))
" 2>&1) || fail "walletless chain build failed: $BUILD_OUT"

bget() { echo "$BUILD_OUT" | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['$1'])" 2>/dev/null; }
FUND_ADDR=$(bget fund_addr)
MATCH_ADDR=$(bget match_addr)
NOMATCH_ADDR=$(bget nomatch_addr)
SPEND_TXID=$(bget spend_txid)
SPEND_VALUE=$(bget spend_value)
CORE_HEIGHT=$(bget final_height)
[[ -n "$FUND_ADDR" && -n "$MATCH_ADDR" && -n "$NOMATCH_ADDR" && -n "$SPEND_TXID" && -n "$SPEND_VALUE" && -n "$CORE_HEIGHT" ]] \
    || fail "could not parse walletless build output: $BUILD_OUT"
EXPECTED=$(( NBLOCKS_PRE + 1 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED (build output: $BUILD_OUT)"
log "chain built: fund=$FUND_ADDR match=$MATCH_ADDR spend=$SPEND_TXID (val=$SPEND_VALUE sat) tip @h$CORE_HEIGHT"

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

# ── scan helpers: run scantxoutset start on both sides for an addr descriptor.
# Output of each is the full result JSON object (one line). The descriptor form
# is {"desc":"addr(<addr>)"} — exercises the object form Core + impl both take.
core_scan() {
    # $1 = address. Returns Core's scantxoutset result JSON on stdout (or empty).
    core_cli_retry scantxoutset start "[{\"desc\":\"addr($1)\"}]" 2>/dev/null
}
cc_scan() {
    # $1 = address. Returns camlcoin's scantxoutset result JSON on stdout.
    jpy "$(cc_rpc scantxoutset "[\"start\", [{\"desc\":\"addr($1)\"}]]")" "json.dumps(d['result'])"
}

# Compare two scantxoutset result objects: emit "OK" or a reason on stderr +
# nonzero. Compares total_amount (in sats) + the SORTED set of matched
# (txid,vout,amount_sat) tuples. Order-independent.
cmp_scan() {
    python3 -c "
import sys, json, decimal
core = json.loads(sys.argv[1]); impl = json.loads(sys.argv[2])
def sat(v): return int((decimal.Decimal(str(v))*100000000).to_integral_value())
def norm(o):
    ta = sat(o.get('total_amount', 0))
    us = sorted((u['txid'], int(u['vout']), sat(u['amount'])) for u in o.get('unspents', []))
    return ta, us
c_ta, c_us = norm(core); i_ta, i_us = norm(impl)
errs=[]
if c_ta != i_ta: errs.append('total_amount(sat) core=%d impl=%d' % (c_ta, i_ta))
if c_us != i_us: errs.append('unspents(txid,vout,amount) core=%r impl=%r' % (c_us, i_us))
print('OK' if not errs else '; '.join(errs))
sys.exit(0 if not errs else 1)
" "$1" "$2"
}

# ── 6. TEST desc + amount — scan MATCH_ADDR (one known non-coinbase coin). ─
DESC_T="ok"; AMOUNT_T="ok"
log "scanning addr(MATCH_ADDR) on Core + camlcoin"
CORE_M=$(core_scan "$MATCH_ADDR")
CC_M=$(cc_scan "$MATCH_ADDR")
[[ -n "$CORE_M" ]] || fail "Core scantxoutset(MATCH_ADDR) returned no result"
[[ -n "$CC_M"   ]] || fail "camlcoin scantxoutset(MATCH_ADDR) returned no result (resp: $(cc_rpc scantxoutset "[\"start\", [{\"desc\":\"addr($MATCH_ADDR)\"}]]"))"

# Sanity: Core itself should report exactly one matched coin = our spend.
CORE_M_N=$(echo "$CORE_M" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('unspents',[])))" 2>/dev/null)
[[ "$CORE_M_N" == "1" ]] || fail "Core matched $CORE_M_N coins for MATCH_ADDR, expected 1 (oracle setup wrong)"
CORE_M_TXID=$(echo "$CORE_M" | python3 -c "import sys,json;print(json.load(sys.stdin)['unspents'][0]['txid'])" 2>/dev/null)
[[ "$CORE_M_TXID" == "$SPEND_TXID" ]] || fail "Core matched txid $CORE_M_TXID != spend $SPEND_TXID (oracle setup wrong)"

CMP_M=$(cmp_scan "$CORE_M" "$CC_M") || { DESC_T="bad"; AMOUNT_T="bad"; }
if [[ "$DESC_T" != "ok" ]]; then
    log "MATCH_ADDR scan diverges from Core: $CMP_M"
    log "  core: $CORE_M"
    log "  caml: $CC_M"
    fail "scantxoutset(MATCH_ADDR) diverges from Core: $CMP_M"
fi
log "MATCH_ADDR scan matches Core: $CMP_M (txid=$SPEND_TXID amount_sat=$SPEND_VALUE)"

# ── 6b. Extra robustness — scan FUND_ADDR (many coinbase coins). ──────────
# This stresses the multi-coin path + coinbase flag + total_amount summation
# across ~109 coins (110 coinbases minus the one spent into MATCH_ADDR).
log "scanning addr(FUND_ADDR) on Core + camlcoin (multi-coin)"
CORE_F=$(core_scan "$FUND_ADDR")
CC_F=$(cc_scan "$FUND_ADDR")
[[ -n "$CORE_F" && -n "$CC_F" ]] || fail "scantxoutset(FUND_ADDR) returned no result (core/impl)"
CORE_F_N=$(echo "$CORE_F" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('unspents',[])))" 2>/dev/null)
log "Core matched $CORE_F_N coins for FUND_ADDR"
[[ "$CORE_F_N" -ge 1 ]] || fail "Core matched 0 coins for FUND_ADDR (oracle setup wrong)"
CMP_F=$(cmp_scan "$CORE_F" "$CC_F") || { DESC_T="bad"; AMOUNT_T="bad"; }
if [[ "$DESC_T" != "ok" ]]; then
    log "FUND_ADDR scan diverges from Core: $CMP_F"
    log "  core: $CORE_F"
    log "  caml: $CC_F"
    fail "scantxoutset(FUND_ADDR) diverges from Core: $CMP_F"
fi
log "FUND_ADDR scan matches Core: $CMP_F"

# ── 7. TEST shape — top-level + per-unspent keys (Core's required keys). ───
# STRICT (mirrors test-suite/scan/rustoshi_scantxoutset.sh): EVERY key Core
# emits per-unspent is REQUIRED and gated — including blockhash + confirmations.
# Core unspent keys (rpc/blockchain.cpp:2455-2466):
#   txid,vout,scriptPubKey,desc,amount,coinbase,height,blockhash,confirmations.
# A missing key is a real shape divergence — reported, never papered over.
SHAPE_T="ok"
SHAPE_OUT=$(python3 -c "
import sys, json
core = json.loads(sys.argv[1]); impl = json.loads(sys.argv[2])

# Top-level: impl must expose at least Core's headline keys for action=start.
top_required = ['success', 'txouts', 'height', 'bestblock', 'unspents', 'total_amount']
errs=[]
for k in top_required:
    if k not in impl: errs.append('missing top-level key %r' % k)

# Types on the headline keys.
if isinstance(impl.get('success'), bool) is False: errs.append('success not bool')
if not isinstance(impl.get('unspents'), list): errs.append('unspents not array')

# Per-unspent: every key Core emits MUST also be present on the impl. blockhash
# and confirmations are GATED (no longer optional): Core always emits them
# (rpc/blockchain.cpp:2455-2466), and the impl must too.
unspent_required = ['txid','vout','scriptPubKey','desc','amount','coinbase',
                    'height','blockhash','confirmations']
core_us = core.get('unspents', [])
imp_us = impl.get('unspents', [])
if core_us:
    # Cross-check: confirm Core really emits the keys we gate on (oracle sanity).
    cu = core_us[0]
    for k in ('blockhash','confirmations'):
        if k not in cu:
            errs.append('CORE unspent missing %r (oracle/Core version anomaly)' % k)
if imp_us:
    u = imp_us[0]
    for k in unspent_required:
        if k not in u: errs.append('unspent missing required key %r' % k)
    # desc must be a non-empty string (Core: a specialized/inferred descriptor).
    if not isinstance(u.get('desc'), str) or not u.get('desc'):
        errs.append('unspent desc not a non-empty string')
    if isinstance(u.get('coinbase'), bool) is False:
        errs.append('unspent coinbase not bool')
    # blockhash: 64-hex string. confirmations: int >= 1.
    bh = u.get('blockhash')
    if not isinstance(bh, str) or len(bh) != 64:
        errs.append('unspent blockhash not a 64-hex string: %r' % bh)
    cf = u.get('confirmations')
    if not isinstance(cf, int) or isinstance(cf, bool) or cf < 1:
        errs.append('unspent confirmations not a positive int: %r' % cf)
    # blockhash + confirmations must EQUAL Core's for the same matched coin.
    if core_us:
        cu = core_us[0]
        if 'blockhash' in cu and bh != cu.get('blockhash'):
            errs.append('blockhash core=%r impl=%r' % (cu.get('blockhash'), bh))
        if 'confirmations' in cu and cf != cu.get('confirmations'):
            errs.append('confirmations core=%r impl=%r' % (cu.get('confirmations'), cf))

print('OK' if not errs else '; '.join(errs))
sys.exit(0 if not errs else 1)
" "$CORE_M" "$CC_M" 2>>"$CC_LOG") || SHAPE_T="bad"
if [[ "$SHAPE_T" != "ok" ]]; then
    log "shape check failed: $SHAPE_OUT"
    log "  caml MATCH result: $CC_M"
    fail "scantxoutset result shape diverges from Core: $SHAPE_OUT"
fi
log "SHAPE ok: top-level success+txouts+height+bestblock+unspents+total_amount; unspent has ALL Core keys incl. blockhash+confirmations (gated)"

# ── 8. TEST empty — unmatched address -> total_amount 0 / empty unspents. ──
EMPTY_T="ok"
log "scanning addr(NOMATCH_ADDR) (never funded) on Core + camlcoin"
CORE_E=$(core_scan "$NOMATCH_ADDR")
CC_E=$(cc_scan "$NOMATCH_ADDR")
[[ -n "$CORE_E" && -n "$CC_E" ]] || fail "scantxoutset(NOMATCH_ADDR) returned no result (core/impl)"
EMPTY_OUT=$(python3 -c "
import sys, json, decimal
core=json.loads(sys.argv[1]); impl=json.loads(sys.argv[2])
def sat(v): return int((decimal.Decimal(str(v))*100000000).to_integral_value())
errs=[]
# Core itself must be empty here (oracle sanity).
if core.get('unspents'): errs.append('CORE unexpectedly matched %d coins (oracle wrong)' % len(core['unspents']))
if sat(core.get('total_amount',0)) != 0: errs.append('CORE total_amount != 0 (oracle wrong)')
# Impl must match: empty unspents + zero total.
if impl.get('unspents'): errs.append('impl matched %d coins, expected 0' % len(impl['unspents']))
if sat(impl.get('total_amount',0)) != 0: errs.append('impl total_amount=%d sat, expected 0' % sat(impl.get('total_amount',0)))
print('OK' if not errs else '; '.join(errs))
sys.exit(0 if not errs else 1)
" "$CORE_E" "$CC_E") || EMPTY_T="bad"
if [[ "$EMPTY_T" != "ok" ]]; then
    log "empty-scan check failed: $EMPTY_OUT"
    log "  core: $CORE_E"
    log "  caml: $CC_E"
    fail "scantxoutset(unmatched) diverges from Core (expected empty): $EMPTY_OUT"
fi
log "EMPTY ok: unmatched address -> total_amount 0 + empty unspents on both"

log "PASS: camlcoin scantxoutset matches Core (matched coins + amount + shape + empty)"
pass "$DESC_T" "$AMOUNT_T" "$SHAPE_T" "$EMPTY_T"
