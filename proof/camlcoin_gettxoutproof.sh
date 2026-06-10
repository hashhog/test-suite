#!/usr/bin/env bash
#
# camlcoin_gettxoutproof.sh — self-contained gettxoutproof/verifytxoutproof
#   Core-parity differential-regression test for camlcoin.
#
# gettxoutproof(["txid",...] (,"blockhash")) returns a SERIALIZED CMerkleBlock as
# HEX: an 80-byte block header + nTransactions(uint32 LE) + a varint hash count +
# the partial-merkle-tree hashes + a varint flag-byte count + the flag bytes.
# verifytxoutproof("hex") parses that proof, re-derives the merkle root from the
# partial tree, confirms the committed block is in the active chain, and returns a
# JSON ARRAY of the txids the proof commits to (empty array / RPC error when the
# proof is invalid or the block is not in the best chain).
#
# Because the proof is a deterministic function of (block, set-of-txids), the SAME
# tx in the SAME block yields a BYTE-IDENTICAL merkleblock across nodes. This cell
# proves camlcoin's gettxoutproof (lib/rpc.ml::handle_gettxoutproof) emits the
# byte-exact merkleblock Bitcoin Core emits, AND that camlcoin's verifytxoutproof
# (lib/rpc.ml::handle_verifytxoutproof) verifies BOTH camlcoin's own proof and
# Core's proof back to exactly the committed txid.
#
# Core ref: bitcoin-core/src/rpc/txoutproof.cpp
#   gettxoutproof:   :23-127  (CMerkleBlock(block, setTxids); ssMB << mb; HexStr)
#     -5 "Block not found"            when an explicit blockhash arg is unknown
#     -5 "Transaction not yet in block"  when the tx can't be located (no -txindex
#         AND no live UTXO AND no blockhash arg)
#   verifytxoutproof: :129-175 (ExtractMatches must equal header.hashMerkleRoot;
#     block must be in ActiveChain; returns [txid,...] or [] / -5 "Block not
#     found in chain").
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + OWN ports, launched -listen=0 (RPC-only; the sandbox
#   SIGKILLs any bitcoind that opens a P2P listener ~2s after load) and
#   -txindex=1 (so gettxoutproof can locate the tx with NO blockhash arg, the
#   exact path camlcoin uses via its always-on tx-index).
#
#   To make the proof byte-identical, both nodes must hold the IDENTICAL block.
#   Walletless (this bitcoind may be built without wallet): Core mines coinbases
#   to a deterministic P2WPKH address (key we hold), hand-builds + BIP-143-signs
#   a tx spending the height-1 matured coinbase to a SECOND deterministic address,
#   and mines it into a block via generateblock. We then replay every block to
#   camlcoin via submitblock and assert the tips are byte-identical before any
#   proof is generated. The non-coinbase SPEND tx (confirmed in a multi-tx block:
#   coinbase + spend) is the proof target — a real partial-merkle-tree, not the
#   degenerate single-tx case.
#
# DIFFERENTIAL TEST (gettxoutproof AND verifytxoutproof run on BOTH impl + Core):
#   (1) proof=ok        : camlcoin gettxoutproof([SPEND_TXID]) hex is
#                         BYTE-IDENTICAL to Core's gettxoutproof([SPEND_TXID]).
#   (2) verify-self=ok  : camlcoin verifytxoutproof(camlcoin_hex) == [SPEND_TXID].
#   (3) verify-cross=ok : camlcoin verifytxoutproof(core_hex)     == [SPEND_TXID]
#                         (Core's proof verifies on camlcoin).
#   (4) errors=ok       : gettxoutproof([unknown_txid]) -> RPC error on BOTH
#                         (Core: -5 'Transaction not yet in block'); and
#                         verifytxoutproof(garbage_hex) -> error OR [] on BOTH.
#   All four are GATED — none optional.
#
# Summary line (stdout, EXACTLY one):
#   PASS: GETTXOUTPROOF camlcoin: PASS proof=ok verify-self=ok verify-cross=ok errors=ok
#   FAIL: GETTXOUTPROOF camlcoin: FAIL <short reason>
#   SKIP (GAP_RE 'not found'/'not built'): GETTXOUTPROOF camlcoin: SKIP <reason>
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/scan/camlcoin_scantxoutset.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#   Run under: setsid -w bash camlcoin_gettxoutproof.sh
#
# Touches ONLY /tmp/txop-camlcoin/ + /tmp/txop-core-camlcoin/ and ports
#   22375/22395 (camlcoin RPC/P2P) + 22377/22397 (Core RPC/P2P).
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

CC_DATADIR="/tmp/txop-camlcoin"
CC_RPC=22375
CC_P2P=22395
CC_LOG="$CC_DATADIR/node.log"
CC_COOKIE=""
CC_PID=""

CORE_DATADIR="/tmp/txop-core-camlcoin"
CORE_RPC=22377
CORE_P2P=22397
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

NBLOCKS_PRE=110    # 110 coinbases (coinbase matures at 100), then 1 spend block.
# Final height = NBLOCKS_PRE + 1 (spend block) = 111. The spend tx is confirmed
# in the height-111 block, which contains [coinbase, spend] (2 txs) -> a real
# partial merkle tree of width 2 (not the single-tx degenerate case).

# A syntactically-valid but unknown/nonexistent 32-byte txid (display order).
UNKNOWN_TXID="00000000000000000000000000000000000000000000000000000000deadbeef"

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutproof:camlcoin] $*" >&2; }

# ── Cleanup: kill OWN nodes + free OWN ports + wipe scratch on any exit. ───
# NOTE: never `pkill -f bitcoind` / never broad kill by binary name — a live
# mainnet bitcoind may be running. Only our OWN datadir-scoped CLI stop + our
# OWN fixed ports + our OWN child PID.
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
pass() { echo "GETTXOUTPROOF camlcoin: PASS proof=$1 verify-self=$2 verify-cross=$3 errors=$4"; exit 0; }
fail() { echo "GETTXOUTPROOF camlcoin: FAIL $*"; exit 1; }
skip() { echo "GETTXOUTPROOF camlcoin: SKIP $*"; exit 0; }

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
# Retries up to 3x on a transient EMPTY response; a genuine JSON-RPC error body
# (carries "error") is returned immediately and never retried.
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
# jpy <json> <expr> — parse stdin JSON as `d`, print expr (bools lowercased).
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
cc_errcode() { jpy "$(cc_rpc "$1" "$2")" "d['error']['code']"; }
cc_errmsg()  { jpy "$(cc_rpc "$1" "$2")" "d['error']['message']"; }

# ── 2. Launch the Core regtest oracle (-listen=0 -txindex=1). ─────────────
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # RPC-only: -listen=0 alone survives the sandbox watchdog. -txindex=1 so
    # gettxoutproof can locate the tx with no blockhash arg (matches camlcoin's
    # always-on tx-index path), and so Core's own error paths behave like a
    # fully-indexed node.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle rpc=:$CORE_RPC -txindex=1 (attempt $attempt)"
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

# Early SKIP: if camlcoin has no gettxoutproof at all (method not found).
CC_PROBE=$(cc_errmsg gettxoutproof '[[]]')
case "$CC_PROBE" in
    *"Method not found"*|*"not found"*|*"Unknown method"*)
        # A genuine "no txids provided" / parameter error means the method IS
        # registered; only a method-not-found means it's truly absent.
        if echo "$CC_PROBE" | grep -qi "method"; then
            skip "camlcoin has no gettxoutproof RPC (not found; got: $CC_PROBE)"
        fi ;;
esac

# ── 4. Build the shared chain on Core (coinbases + a real SPEND tx). ───────
# Walletless: use Core's test_framework to mine $NBLOCKS_PRE coinbases to a
# deterministic P2WPKH funding address (key #1, we hold it), then hand-build +
# BIP-143-sign a tx spending the height-1 matured coinbase, paying a SECOND
# deterministic P2WPKH address (key #2), and mine it into a block via
# generateblock. The spend block has [coinbase, spend] -> a 2-tx partial merkle
# tree, the proof target. Core indexes every block; we replicate to camlcoin so
# both hold the IDENTICAL chain and the merkleblock proof compares byte-for-byte.
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
# Deterministic key #2 -> spend destination.
k2 = ECKey(); k2.set(bytes.fromhex('22'*31 + '23'), compressed=True)
dest_spk = key_to_p2wpkh_script(k2.get_pubkey().get_bytes())

rpc('generatetoaddress', [$NBLOCKS_PRE, fund_addr])

# Spend the height-1 coinbase output (matured after 100 blocks).
cb_tx = rpc('getblock', [rpc('getblockhash', [1]), 2])['tx'][0]
in_amount = int(round(cb_tx['vout'][0]['value'] * 100000000))
spend_value = in_amount - 1000   # 1000 sat fee
tx = CTransaction()
tx.vin.append(CTxIn(COutPoint(int(cb_tx['txid'], 16), 0), b'', 0xffffffff))
tx.vout.append(CTxOut(spend_value, dest_spk))
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
if len(sb['tx']) < 2:
    raise RuntimeError('spend block has %d txs, expected >=2 (coinbase+spend)' % len(sb['tx']))

print(json.dumps({
    'fund_addr': fund_addr, 'spend_txid': spend_txid, 'spend_value': spend_value,
    'spend_height': spend_height, 'spend_blockhash': spend_blockhash,
    'spend_block_ntx': len(sb['tx']), 'final_height': spend_height}))
" 2>&1) || fail "walletless chain build failed: $BUILD_OUT"

bget() { echo "$BUILD_OUT" | python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[-1])['$1'])" 2>/dev/null; }
FUND_ADDR=$(bget fund_addr)
SPEND_TXID=$(bget spend_txid)
SPEND_VALUE=$(bget spend_value)
SPEND_BLOCKHASH=$(bget spend_blockhash)
SPEND_BLOCK_NTX=$(bget spend_block_ntx)
CORE_HEIGHT=$(bget final_height)
[[ -n "$FUND_ADDR" && -n "$SPEND_TXID" && -n "$SPEND_VALUE" && -n "$SPEND_BLOCKHASH" && -n "$CORE_HEIGHT" ]] \
    || fail "could not parse walletless build output: $BUILD_OUT"
EXPECTED=$(( NBLOCKS_PRE + 1 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED (build output: $BUILD_OUT)"
[[ "$SPEND_BLOCK_NTX" -ge 2 ]] || fail "spend block has only $SPEND_BLOCK_NTX tx (need >=2 for a real merkle tree)"
log "chain built: fund=$FUND_ADDR spend=$SPEND_TXID (val=$SPEND_VALUE sat) in block $SPEND_BLOCKHASH (ntx=$SPEND_BLOCK_NTX) @h$CORE_HEIGHT"

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
[[ "$CORE_TIP" == "$SPEND_BLOCKHASH" ]] \
    || fail "tip $CORE_TIP != spend block $SPEND_BLOCKHASH (spend block is not the tip)"
log "chains identical at tip $CC_TIP (height $CORE_HEIGHT, spend block is tip)"

# ── proof helpers: gettxoutproof([txid]) on both sides. ────────────────────
# Core: -txindex=1 means NO blockhash arg is needed to locate the spend tx.
core_proof() {  # core_proof <txid> -> hex proof (or empty)
    core_cli_retry gettxoutproof "[\"$1\"]" 2>/dev/null
}
cc_proof() {    # cc_proof <txid> -> hex proof (or empty)
    local i env h
    for i in 1 2 3 4 5; do
        env=$(cc_rpc gettxoutproof "[[\"$1\"]]")
        if echo "$env" | grep -q '"result"'; then
            h=$(jpy "$env" "d['result']")
            [[ "$h" =~ ^[0-9a-f]+$ ]] && { echo "$h"; return 0; }
        fi
        sleep 1
    done
    echo ""   # caller surfaces the failure
}
# verify helpers: verifytxoutproof("hex") -> JSON array of txids (as JSON text).
core_verify() {  # core_verify <hex> -> JSON array string (or empty on RPC error)
    core_cli verifytxoutproof "$1" 2>/dev/null
}
cc_verify() {    # cc_verify <hex> -> JSON array string (compact), or empty on err
    jpy "$(cc_rpc verifytxoutproof "[\"$1\"]")" "json.dumps(d['result'])"
}

# ── 6. CHECK (1) proof=ok — byte-identical merkleblock hex. ───────────────
PROOF_T="ok"
log "gettxoutproof([SPEND_TXID]) on Core + camlcoin"
CORE_PROOF=$(core_proof "$SPEND_TXID")
CC_PROOF=$(cc_proof "$SPEND_TXID")
[[ "$CORE_PROOF" =~ ^[0-9a-f]+$ ]] || fail "Core gettxoutproof([SPEND_TXID]) returned no hex (resp empty; see $CORE_LOG)"
[[ "$CC_PROOF"   =~ ^[0-9a-f]+$ ]] || fail "camlcoin gettxoutproof([SPEND_TXID]) returned no hex (resp: $(cc_rpc gettxoutproof "[[\"$SPEND_TXID\"]]"))"

# Sanity: Core's proof must verify on Core back to exactly [SPEND_TXID] (oracle).
CORE_SELF=$(core_verify "$CORE_PROOF")
CORE_SELF_OK=$(python3 -c "
import sys, json
try:
    v = json.loads(sys.argv[1])
    print('yes' if v == ['$SPEND_TXID'] else 'no:%r' % v)
except Exception as e:
    print('no:parse(%s)' % e)
" "$CORE_SELF" 2>/dev/null)
[[ "$CORE_SELF_OK" == "yes" ]] || fail "ORACLE: Core verifytxoutproof(core_proof) != [SPEND_TXID]: $CORE_SELF_OK"

# The deterministic byte-for-byte assertion.
if [[ "$CC_PROOF" != "$CORE_PROOF" ]]; then
    PROOF_T="bad"
    log "PROOF HEX DIVERGES:"
    log "  core: $CORE_PROOF"
    log "  caml: $CC_PROOF"
    # Field-level diff to localize the divergence (header / nTx / hashes / flags).
    DIFF=$(python3 -c "
import sys
c = bytes.fromhex(sys.argv[1]); i = bytes.fromhex(sys.argv[2])
if len(c) != len(i):
    print('length core=%d impl=%d' % (len(c), len(i)))
else:
    for off in range(len(c)):
        if c[off] != i[off]:
            seg = ('header(0..79)' if off < 80 else
                   'nTx(80..83)' if off < 84 else 'hashes/flags(84..)')
            print('first byte diff @%d in %s: core=%02x impl=%02x' % (off, seg, c[off], i[off]))
            break
" "$CORE_PROOF" "$CC_PROOF" 2>/dev/null)
    log "  diff: $DIFF"
    fail "gettxoutproof hex diverges from Core: $DIFF"
fi
log "PROOF ok: camlcoin merkleblock hex is BYTE-IDENTICAL to Core ($(( ${#CC_PROOF} / 2 )) bytes)"

# ── 7. CHECK (2) verify-self=ok — camlcoin verifies its OWN proof. ────────
VSELF_T="ok"
log "verifytxoutproof(camlcoin_proof) on camlcoin"
CC_VSELF=""
for _ in 1 2 3 4 5; do
    CC_VSELF=$(cc_verify "$CC_PROOF")
    [[ -n "$CC_VSELF" && "$CC_VSELF" != "null" ]] && break
    sleep 1
done
VSELF_CHK=$(python3 -c "
import sys, json
try:
    v = json.loads(sys.argv[1])
    print('OK' if v == ['$SPEND_TXID'] else 'got %r expected [%r]' % (v, '$SPEND_TXID'))
except Exception as e:
    print('parse-fail(%s) on %r' % (e, sys.argv[1]))
" "$CC_VSELF" 2>/dev/null)
if [[ "$VSELF_CHK" != "OK" ]]; then
    VSELF_T="bad"
    log "verify-self failed: $VSELF_CHK (raw resp: $(cc_rpc verifytxoutproof "[\"$CC_PROOF\"]"))"
    fail "camlcoin verifytxoutproof(own proof) != [SPEND_TXID]: $VSELF_CHK"
fi
log "VERIFY-SELF ok: camlcoin verifytxoutproof(own proof) == [SPEND_TXID]"

# ── 8. CHECK (3) verify-cross=ok — camlcoin verifies CORE's proof. ────────
VCROSS_T="ok"
log "verifytxoutproof(core_proof) on camlcoin"
CC_VCROSS=""
for _ in 1 2 3 4 5; do
    CC_VCROSS=$(cc_verify "$CORE_PROOF")
    [[ -n "$CC_VCROSS" && "$CC_VCROSS" != "null" ]] && break
    sleep 1
done
VCROSS_CHK=$(python3 -c "
import sys, json
try:
    v = json.loads(sys.argv[1])
    print('OK' if v == ['$SPEND_TXID'] else 'got %r expected [%r]' % (v, '$SPEND_TXID'))
except Exception as e:
    print('parse-fail(%s) on %r' % (e, sys.argv[1]))
" "$CC_VCROSS" 2>/dev/null)
if [[ "$VCROSS_CHK" != "OK" ]]; then
    VCROSS_T="bad"
    log "verify-cross failed: $VCROSS_CHK (raw resp: $(cc_rpc verifytxoutproof "[\"$CORE_PROOF\"]"))"
    fail "camlcoin verifytxoutproof(Core proof) != [SPEND_TXID]: $VCROSS_CHK"
fi
log "VERIFY-CROSS ok: camlcoin verifytxoutproof(Core proof) == [SPEND_TXID]"

# ── 9. CHECK (4) errors=ok — bad gettxoutproof + garbage verifytxoutproof. ─
ERRORS_T="ok"

# 9a. gettxoutproof([UNKNOWN_TXID]) -> RPC error on BOTH.
#     Core (txindex on, tx never existed) -> -5 'Transaction not yet in block'.
log "gettxoutproof([UNKNOWN_TXID]) must error on Core + camlcoin"
CORE_BAD=$(core_cli gettxoutproof "[\"$UNKNOWN_TXID\"]" 2>&1)
CORE_BAD_CODE=$(echo "$CORE_BAD" | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
if echo "$CORE_BAD" | grep -q '^[0-9a-f]\{2,\}$'; then
    # Core unexpectedly RETURNED a proof for a nonexistent txid -> oracle anomaly.
    ERRORS_T="bad"; log "ORACLE: Core gettxoutproof(unknown) returned hex, expected error: $CORE_BAD"
fi
[[ "$CORE_BAD_CODE" == "-5" ]] || log "note: Core gettxoutproof(unknown) code was '$CORE_BAD_CODE' (expected -5): $CORE_BAD"

# camlcoin: must be an RPC error (carries an error object). Code parity to Core's
# -5 is preferred but NOT gated (camlcoin maps these to its misc-error code);
# the GATED requirement is "an error, not a proof".
CC_BAD_ENV=$(cc_rpc gettxoutproof "[[\"$UNKNOWN_TXID\"]]")
CC_BAD_HASERR=$(echo "$CC_BAD_ENV" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    has_err = d.get('error') is not None
    has_res = d.get('result') not in (None,)
    print('err' if has_err and not has_res else ('res:%s' % d.get('result')))
except Exception:
    print('parse-fail')
" 2>/dev/null)
if [[ "$CC_BAD_HASERR" != "err" ]]; then
    ERRORS_T="bad"
    log "camlcoin gettxoutproof(unknown) did NOT error: $CC_BAD_HASERR (raw: $CC_BAD_ENV)"
else
    CC_BAD_CODE=$(cc_errcode gettxoutproof "[[\"$UNKNOWN_TXID\"]]")
    CC_BAD_MSG=$(cc_errmsg gettxoutproof "[[\"$UNKNOWN_TXID\"]]")
    log "camlcoin gettxoutproof(unknown) errored ok (code=$CC_BAD_CODE msg='$CC_BAD_MSG'); Core code=$CORE_BAD_CODE"
fi

# 9b. verifytxoutproof(garbage_hex) -> error OR [] on BOTH (match Core behavior).
GARBAGE="deadbeefdeadbeefdeadbeef"   # too short / not a valid CMerkleBlock
log "verifytxoutproof(garbage) must be error-or-[] on Core + camlcoin"
CORE_G_RAW=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" verifytxoutproof "$GARBAGE" 2>&1)
CORE_G_OK=$(python3 -c "
import sys, json
s = sys.argv[1]
try:
    v = json.loads(s)
    print('empty-array' if v == [] else 'array:%r' % v)
except Exception:
    print('error')   # CLI printed an error string, not JSON
" "$CORE_G_RAW" 2>/dev/null)
case "$CORE_G_OK" in
    error|empty-array) log "Core verifytxoutproof(garbage) -> $CORE_G_OK (acceptable)" ;;
    *) ERRORS_T="bad"; log "ORACLE: Core verifytxoutproof(garbage) unexpected: $CORE_G_OK ($CORE_G_RAW)" ;;
esac

# camlcoin: must be an RPC error OR an empty array (NOT a non-empty txid list).
CC_G_ENV=$(cc_rpc verifytxoutproof "[\"$GARBAGE\"]")
CC_G_OK=$(echo "$CC_G_ENV" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    if d.get('error') is not None:
        print('error')
    else:
        r = d.get('result')
        if r == []: print('empty-array')
        elif isinstance(r, list): print('nonempty:%r' % r)
        else: print('result:%r' % r)
except Exception:
    print('parse-fail')
" 2>/dev/null)
case "$CC_G_OK" in
    error|empty-array)
        log "camlcoin verifytxoutproof(garbage) -> $CC_G_OK (matches Core's error-or-[])" ;;
    *)
        ERRORS_T="bad"
        log "camlcoin verifytxoutproof(garbage) returned a non-empty/invalid result: $CC_G_OK (raw: $CC_G_ENV)" ;;
esac

[[ "$ERRORS_T" == "ok" ]] || fail "error-handling parity failed (see log): gettxoutproof(unknown) must error; verifytxoutproof(garbage) must be error-or-[]"
log "ERRORS ok: gettxoutproof(unknown) errors on both; verifytxoutproof(garbage) is error-or-[] on both"

# ── 10. Done. ──────────────────────────────────────────────────────────────
log "PASS: camlcoin gettxoutproof/verifytxoutproof matches Core (byte-identical proof + self-verify + cross-verify + errors)"
pass "$PROOF_T" "$VSELF_T" "$VCROSS_T" "$ERRORS_T"
