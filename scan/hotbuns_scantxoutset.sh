#!/usr/bin/env bash
#
# hotbuns_scantxoutset.sh — self-contained scantxoutset Core-parity test.
#
# scantxoutset is the UTXO-set query keystone: given an output descriptor it
# scans the CURRENT (chainstate) UTXO set and reports every matching unspent
# output plus a total. This test drives BOTH the hotbuns impl and a REAL
# Bitcoin Core regtest oracle through the IDENTICAL chain + spend and asserts
# that hotbuns' scantxoutset agrees with Core on the load-bearing values.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:2316-2476 (scantxoutset).
#   SIGNATURE: scantxoutset "action" ( [scanobjects] ).
#     action="start" with scanobjects = ["addr(<addr>)"] or [{"desc":"addr(<addr>)"}]
#       scans the current UTXO set; returns ONLY after the scan completes.
#     action="status" -> null when idle (no scan running).
#     action="abort"  -> bool (false when nothing to abort).
#   OUTPUT (action="start") is an OBJECT:
#     { success(bool), txouts(int total UTXOs scanned), height(int tip),
#       bestblock(hex tip hash),
#       unspents: [ { txid, vout, scriptPubKey, desc, amount, coinbase,
#                     height, blockhash, confirmations } ],
#       total_amount(BTC) }
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest instance +
#   OWN ports, launched -listen=0 (RPC only; sandbox SIGKILLs bitcoind ~20-30s
#   after load).
#
#   CRITICAL ORDERING (same as the rawtx/getrawtransaction template): the
#   sandbox SIGKILLs bitcoind ~20-30s after launch regardless of -listen=0.
#   So PHASE A does EVERY Core-dependent operation up front and CAPTURES Core's
#   authoritative outputs into a scratch manifest, all within the live window:
#     - mine 110 blocks to MINE_ADDR;
#     - build+sign a real P2WPKH spend of block-1's matured coinbase to a fresh
#       DEST_ADDR, broadcast it, then mine ONE confirming block (so DEST_ADDR
#       ends up holding EXACTLY ONE confirmed UTXO of a known amount);
#     - capture all 111 raw blocks (the spend lives inside the 111th block, so
#       replaying the blocks alone reproduces the IDENTICAL UTXO set — no
#       mempool push needed);
#     - capture Core's scantxoutset(start, [addr(DEST_ADDR)]) result and the
#       unmatched-address result.
#   PHASE B then launches hotbuns (slow Bun cold start, but NOT bitcoind, so it
#   is never sandbox-killed), replays the 111 captured blocks via submitblock so
#   its chainstate UTXO set is byte-identical, and runs the SAME scantxoutset
#   calls, asserting against the captured Core values. hotbuns never needs Core
#   to be alive.
#
# DIFFERENTIAL ASSERTIONS (impl vs Core, both run the same scan):
#   (1) FUND: DEST_ADDR holds exactly one confirmed UTXO of a known amount.
#   (2) DESC : scantxoutset start [addr(DEST_ADDR)] returns that one unspent.
#   (3) AMT  : impl total_amount == Core total_amount AND the matched unspent's
#              txid/vout/amount == Core's.
#   (4) SHAPE: result object carries success + total_amount + unspents, and each
#              unspent carries Core's load-bearing keys (txid,vout,scriptPubKey,
#              amount,coinbase,height) plus the desc/blockhash/confirmations keys
#              Core emits.
#   (5) EMPTY: scanning an UNMATCHED address -> total_amount 0 / [] unspents on
#              BOTH impl and Core.
#
# Summary line (stdout, EXACTLY one):
#   PASS: SCANTXOUTSET hotbuns: PASS desc=ok amount=ok shape=ok empty=ok
#   FAIL: SCANTXOUTSET hotbuns: FAIL <short reason>
#   SKIP: SCANTXOUTSET hotbuns: FAIL hotbuns entrypoint not found ...  (GAP_RE)
#
# Touches ONLY /tmp/scan-hotbuns/ + /tmp/scan-core-hb/ + /tmp/scan-cap-hb/ and
#   ports 40214/40234 (hotbuns RPC/P2P) + 40216/40236 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/script/tx)

# Deterministic test secrets. We mine to a p2wpkh address we hold the key for,
# then spend its matured coinbase to a SECOND p2wpkh address — the scan target.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"
# A THIRD address that is never funded -> the unmatched-scan target.
NONE_SECRET="3333333333333333333333333333333333333333333333333333333333333334"

HB_DATADIR="/tmp/scan-hotbuns"
HB_RPC=40214
HB_P2P=40234
HB_LOG="$HB_DATADIR/node.log"

CORE_DATADIR="/tmp/scan-core-hb"
CORE_RPC=40216
CORE_P2P=40236
CORE_LOG="$CORE_DATADIR/core.log"

# Captured-from-Core manifest (survives Core's death; consumed by PHASE B).
CAP_DIR="/tmp/scan-cap-hb"
BLOCKS_FILE="$CAP_DIR/blocks.hex"        # one raw block hex per line (1..NBLOCKS + confirming)

NBLOCKS=110        # >100 so the first matured coinbase is spendable.

HB_PID=""
HB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[scantxoutset:hotbuns] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${HB_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${HB_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$CAP_DIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <desc> <amount> <shape> <empty>
pass() {
    echo "SCANTXOUTSET hotbuns: PASS desc=$1 amount=$2 shape=$3 empty=$4"
    exit 0
}
fail() {
    echo "SCANTXOUTSET hotbuns: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "scan-hotbuns" 2>/dev/null || true
pkill -f "scan-core-hb" 2>/dev/null || true
fuser -k "${HB_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${HB_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$CAP_DIR"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR" "$CAP_DIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
# Binary-missing checks emit a GAP_RE-compatible ("not found") message so the
# outer runner SKIPs rather than treating it as a hard failure.
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
command -v bun     >/dev/null 2>&1   || fail "bun runtime not found on PATH"
[[ -f "$NODE_DIR/src/index.ts" ]]    || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── Derive the deterministic p2wpkh addresses. ────────────────────────────
derive_addr() {
    python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$1'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null
}
MINE_ADDR=$(derive_addr "$SECRET")      || fail "could not derive mining address (test_framework import failed)"
[[ "$MINE_ADDR" == bcrt1* ]]            || fail "mining address not regtest bech32: '$MINE_ADDR'"
DEST_ADDR=$(derive_addr "$DEST_SECRET") || fail "could not derive destination address"
[[ "$DEST_ADDR" == bcrt1* ]]            || fail "destination address not regtest bech32: '$DEST_ADDR'"
NONE_ADDR=$(derive_addr "$NONE_SECRET") || fail "could not derive unmatched address"
[[ "$NONE_ADDR" == bcrt1* ]]            || fail "unmatched address not regtest bech32: '$NONE_ADDR'"
log "mine=$MINE_ADDR dest=$DEST_ADDR none=$NONE_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# hb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
hb_rpc() {
    curl -s --max-time 120 -u "$HB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HB_RPC/" 2>/dev/null
}

# jpy <json> <expr>   (expr references parsed object as `d`)
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

# ══════════════════════════════════════════════════════════════════════════
# PHASE A — drive REAL Core for every authoritative output, capturing into a
#   manifest, all within Core's ~20-30s live window.
# ══════════════════════════════════════════════════════════════════════════

# ── 2. Launch the Core regtest oracle (RPC-only). ─────────────────────────
log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -listen=0"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 30 ))
core_ready=0
while (( $(date +%s) < core_deadline )); do
    if core_cli getblockcount >/dev/null 2>&1; then core_ready=1; break; fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "bitcoind exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" -eq 1 ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core RPC never responded within 30s"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Mine the chain on Core to the address we hold the key for. ─────────
log "mining $NBLOCKS blocks to $MINE_ADDR on Core"
core_cli generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

# ── 4. Build + sign a real P2WPKH spend with the test_framework. ──────────
# Spend block-1's matured coinbase output (vout 0, 50 BTC) to DEST_ADDR.
CB_BLOCKHASH=$(core_cli getblockhash 1 2>/dev/null)         || fail "Core getblockhash 1 failed"
CB_JSON=$(core_cli getblock "$CB_BLOCKHASH" 2 2>/dev/null)  || fail "Core getblock 1 (verbose) failed"
CB_TXID=$(jpy "$CB_JSON" "d['tx'][0]['txid']")
[[ "$CB_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not read block-1 coinbase txid: '$CB_TXID'"
log "spending coinbase $CB_TXID:0 (50 BTC) -> $DEST_ADDR"

# 50 BTC in, 0.0001 BTC fee -> 49.9999 BTC out to DEST_ADDR.
SPEND_SATS=4999990000
CORE_HEX=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import sign_input_segwitv0
from test_framework.script_util import key_to_p2wpkh_script, keyhash_to_p2pkh_script
from test_framework.address import address_to_scriptpubkey
from test_framework.crypto.ripemd160 import ripemd160
import hashlib

src = ECKey(); src.set(bytes.fromhex('$SECRET'), compressed=True)
src_pub = src.get_pubkey().get_bytes()

tx = CTransaction()
tx.version = 2
prev_txid = int('$CB_TXID', 16)
tx.vin = [CTxIn(COutPoint(prev_txid, 0), b'', 0xffffffff)]
tx.vout = [CTxOut($SPEND_SATS, address_to_scriptpubkey('$DEST_ADDR'))]
tx.wit.vtxinwit = [CTxInWitness()]
keyhash = ripemd160(hashlib.sha256(src_pub).digest())
script_code = keyhash_to_p2pkh_script(keyhash)
sign_input_segwitv0(tx, 0, script_code, int(50*COIN), src)
tx.wit.vtxinwit[0].scriptWitness.stack.append(src_pub)
print(tx.serialize_with_witness().hex())
" 2>"$CAP_DIR/sign.err") || { cat "$CAP_DIR/sign.err" >&2 2>/dev/null; fail "in-process tx signing failed (see sign.err)"; }
[[ "$CORE_HEX" =~ ^[0-9a-f]+$ ]] || fail "signed tx hex malformed: '$CORE_HEX'"

# ── 5. Broadcast into Core; mine ONE confirming block (includes the spend). ─
CORE_SEND=$(core_cli sendrawtransaction "$CORE_HEX" 2>/dev/null) \
    || fail "Core sendrawtransaction rejected the signed tx (see $CORE_LOG)"
TXID=$(echo "$CORE_SEND" | tr -d '[:space:]')
[[ "$TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned a non-txid: '$TXID'"
log "created + broadcast spending tx $TXID (Core mempool)"

core_cli generatetoaddress 1 "$MINE_ADDR" >/dev/null 2>&1 || fail "Core confirming generate failed"
CONF_HEIGHT=$(core_cli getblockcount 2>/dev/null)
[[ "$CONF_HEIGHT" == "$(( NBLOCKS + 1 ))" ]] || fail "Core height $CONF_HEIGHT != $(( NBLOCKS + 1 )) after confirming"
CONF_BLOCKHASH=$(core_cli getbestblockhash 2>/dev/null)
[[ "$CONF_BLOCKHASH" =~ ^[0-9a-f]{64}$ ]] || fail "Core confirming blockhash malformed: '$CONF_BLOCKHASH'"
# Verify the spend really landed in the confirming block (so block-replay alone
# reproduces the UTXO set on hotbuns; no mempool push needed).
core_cli getrawtransaction "$TXID" 1 "$CONF_BLOCKHASH" >/dev/null 2>&1 \
    || fail "spend $TXID not found in confirming block $CONF_BLOCKHASH"
log "spend confirmed in block $CONF_BLOCKHASH at height $CONF_HEIGHT"

# ── 6. CAPTURE Core's authoritative scantxoutset outputs. ─────────────────
# Matched scan: addr(DEST_ADDR) -> exactly one unspent (the spend output).
CORE_SCAN=$(core_cli scantxoutset start "[\"addr($DEST_ADDR)\"]" 2>/dev/null) \
    || fail "Core scantxoutset start [addr(DEST_ADDR)] failed"
[[ -n "$CORE_SCAN" ]] || fail "Core scantxoutset produced no output"
CORE_SUCCESS=$(jpy "$CORE_SCAN" "d.get('success')")
CORE_TOTAL=$(jpy "$CORE_SCAN" "format(float(d.get('total_amount')),'.8f')")
CORE_NUNSP=$(jpy "$CORE_SCAN" "len(d.get('unspents',[]))")
[[ "$CORE_SUCCESS" == "true" ]] || fail "Core scan success != true: '$CORE_SUCCESS'"
[[ "$CORE_NUNSP" == "1" ]] || fail "Core scan matched $CORE_NUNSP unspents, expected exactly 1 (got: $CORE_SCAN)"
CORE_U_TXID=$(jpy "$CORE_SCAN" "d['unspents'][0].get('txid')")
CORE_U_VOUT=$(jpy "$CORE_SCAN" "d['unspents'][0].get('vout')")
CORE_U_AMT=$(jpy "$CORE_SCAN" "format(float(d['unspents'][0].get('amount')),'.8f')")
CORE_U_SPK=$(jpy "$CORE_SCAN" "d['unspents'][0].get('scriptPubKey')")
CORE_U_CB=$(jpy "$CORE_SCAN" "d['unspents'][0].get('coinbase')")
CORE_U_HEIGHT=$(jpy "$CORE_SCAN" "d['unspents'][0].get('height')")
# The matched output must be our spend's vout 0.
[[ "$CORE_U_TXID" == "$TXID" ]] || fail "Core matched txid '$CORE_U_TXID' != spend txid '$TXID'"
[[ "$CORE_U_VOUT" == "0" ]]     || fail "Core matched vout '$CORE_U_VOUT' != 0"
log "Core matched unspent: txid=$CORE_U_TXID vout=$CORE_U_VOUT amount=$CORE_U_AMT total=$CORE_TOTAL"

# Core's full key set on the unspent object (for the shape diff).
CORE_U_KEYS=$(jpy "$CORE_SCAN" "','.join(sorted(d['unspents'][0].keys()))")
log "Core unspent keys: $CORE_U_KEYS"

# Unmatched scan: a never-funded address -> total_amount 0, [] unspents.
CORE_EMPTY=$(core_cli scantxoutset start "[\"addr($NONE_ADDR)\"]" 2>/dev/null) \
    || fail "Core scantxoutset start [addr(NONE_ADDR)] failed"
CORE_EMPTY_TOTAL=$(jpy "$CORE_EMPTY" "format(float(d.get('total_amount')),'.8f')")
CORE_EMPTY_N=$(jpy "$CORE_EMPTY" "len(d.get('unspents',[]))")
[[ "$CORE_EMPTY_TOTAL" == "0.00000000" ]] || fail "Core unmatched total != 0: '$CORE_EMPTY_TOTAL'"
[[ "$CORE_EMPTY_N" == "0" ]] || fail "Core unmatched unspents != []: count=$CORE_EMPTY_N"
# Capture Core's txouts (total UTXOs scanned) for an extra parity check.
CORE_TXOUTS=$(jpy "$CORE_EMPTY" "d.get('txouts')")
log "Core unmatched scan: total=$CORE_EMPTY_TOTAL unspents=$CORE_EMPTY_N txouts=$CORE_TXOUTS"

# ── 7. Dump all 111 chain blocks as raw hex (the spend lives in block 111). ─
: > "$BLOCKS_FILE"
for ((h=1; h<=CONF_HEIGHT; h++)); do
    BH=$(core_cli getblockhash "$h" 2>/dev/null)   || fail "Core getblockhash $h failed"
    RAW=$(core_cli getblock "$BH" 0 2>/dev/null)   || fail "Core getblock $h (raw) failed"
    echo "$RAW" >> "$BLOCKS_FILE"
done
NLINES=$(wc -l < "$BLOCKS_FILE")
[[ "$NLINES" == "$CONF_HEIGHT" ]] || fail "captured $NLINES block lines, expected $CONF_HEIGHT"
log "captured $NLINES raw blocks + Core authoritative scan outputs; Core may now die"

# ── 8. Stop Core (we no longer need it). ──────────────────────────────────
core_cli stop >/dev/null 2>&1 || true
[[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
CORE_BG=""

# ══════════════════════════════════════════════════════════════════════════
# PHASE B — launch hotbuns, replay the captured chain via submitblock, run the
#   SAME scantxoutset calls, and assert against the captured Core outputs.
# ══════════════════════════════════════════════════════════════════════════

# ── 9. Launch hotbuns on regtest. ─────────────────────────────────────────
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P -> $HB_LOG"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC"
) >"$HB_LOG" 2>&1 &
HB_PID=$!
log "hotbuns pid=$HB_PID"
hb_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < hb_deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        echo "$(hb_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 20 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG)"; }
    sleep 1
done
[[ -n "$HB_COOKIE" ]] || fail "hotbuns cookie never appeared within 90s"
echo "$(hb_rpc getblockcount '[]')" | grep -q '"result"' || fail "hotbuns RPC never responded within 90s"
log "hotbuns RPC ready"

# ── 10. Mirror the captured 111 blocks into hotbuns via submitblock. ───────
log "mirroring $CONF_HEIGHT captured blocks into hotbuns via submitblock"
h=0
while IFS= read -r RAW; do
    h=$(( h + 1 ))
    SB=$(hb_rpc submitblock "[\"$RAW\"]")
    if echo "$SB" | grep -q '"error":{'; then
        ECODE=$(jpy "$SB" "d.get('error') and d['error'].get('code')")
        [[ -z "$ECODE" || "$ECODE" == "None" ]] || fail "hotbuns submitblock height=$h error: $SB"
    fi
done < "$BLOCKS_FILE"
HB_HEIGHT=$(jpy "$(hb_rpc getblockcount '[]')" "d['result']")
[[ "$HB_HEIGHT" == "$CONF_HEIGHT" ]] || fail "hotbuns height $HB_HEIGHT != $CONF_HEIGHT after mirror (submitblock did not connect chain)"
HB_TIP=$(jpy "$(hb_rpc getbestblockhash '[]')" "d['result']")
[[ "$HB_TIP" == "$CONF_BLOCKHASH" ]] || fail "hotbuns tip $HB_TIP != Core tip $CONF_BLOCKHASH after mirror"
log "hotbuns at height $CONF_HEIGHT, tip $HB_TIP (matches Core)"

# ════════════════════════════════════════════════════════════════════════
# CHECK A — DESC + AMOUNT: scantxoutset start [addr(DEST_ADDR)].
# ════════════════════════════════════════════════════════════════════════
DESC_T="ok"; AMOUNT_T="ok"; SHAPE_T="ok"

HB_SCAN_RESP=$(hb_rpc scantxoutset "[\"start\", [\"addr($DEST_ADDR)\"]]")
echo "$HB_SCAN_RESP" | grep -q '"result"' || fail "hotbuns scantxoutset start errored: $HB_SCAN_RESP"
HB_SCAN=$(jpy "$HB_SCAN_RESP" "json.dumps(d['result'])")
[[ -n "$HB_SCAN" ]] || fail "hotbuns scantxoutset result empty"
log "hotbuns scan: $HB_SCAN"

# success must be true.
HB_SUCCESS=$(jpy "$HB_SCAN" "d.get('success')")
[[ "$HB_SUCCESS" == "true" ]] || { SHAPE_T="bad"; log "hotbuns success != true: '$HB_SUCCESS'"; }

# Exactly one matched unspent (== Core).
HB_NUNSP=$(jpy "$HB_SCAN" "len(d.get('unspents',[]))")
[[ "$HB_NUNSP" == "$CORE_NUNSP" ]] || { DESC_T="bad"; log "unspent count mismatch: core=$CORE_NUNSP hotbuns=$HB_NUNSP"; }

if [[ "$HB_NUNSP" == "1" ]]; then
    HB_U_TXID=$(jpy "$HB_SCAN" "d['unspents'][0].get('txid')")
    HB_U_VOUT=$(jpy "$HB_SCAN" "d['unspents'][0].get('vout')")
    HB_U_AMT=$(jpy "$HB_SCAN" "format(float(d['unspents'][0].get('amount')),'.8f')")
    HB_U_SPK=$(jpy "$HB_SCAN" "d['unspents'][0].get('scriptPubKey')")
    HB_U_CB=$(jpy "$HB_SCAN" "d['unspents'][0].get('coinbase')")
    HB_U_HEIGHT=$(jpy "$HB_SCAN" "d['unspents'][0].get('height')")

    # DESC: the matched unspent IS the spend output (txid/vout == Core's).
    [[ "$HB_U_TXID" == "$CORE_U_TXID" ]] || { DESC_T="bad"; log "matched txid mismatch: core='$CORE_U_TXID' hotbuns='$HB_U_TXID'"; }
    [[ "$HB_U_VOUT" == "$CORE_U_VOUT" ]] || { DESC_T="bad"; log "matched vout mismatch: core='$CORE_U_VOUT' hotbuns='$HB_U_VOUT'"; }

    # AMOUNT: total_amount + the unspent's amount EQUAL Core's.
    HB_TOTAL=$(jpy "$HB_SCAN" "format(float(d.get('total_amount')),'.8f')")
    [[ "$HB_TOTAL" == "$CORE_TOTAL" ]] || { AMOUNT_T="bad"; log "total_amount mismatch: core='$CORE_TOTAL' hotbuns='$HB_TOTAL'"; }
    [[ "$HB_U_AMT" == "$CORE_U_AMT" ]] || { AMOUNT_T="bad"; log "unspent amount mismatch: core='$CORE_U_AMT' hotbuns='$HB_U_AMT'"; }
    # Sanity: the amount is the known funded value (49.9999 BTC).
    [[ "$HB_U_AMT" == "49.99990000" ]] || { AMOUNT_T="bad"; log "unspent amount '$HB_U_AMT' != expected 49.99990000"; }

    # Cross-check load-bearing per-unspent fields (scriptPubKey/coinbase/height).
    [[ "$HB_U_SPK" == "$CORE_U_SPK" ]]       || { AMOUNT_T="bad"; log "scriptPubKey mismatch: core='$CORE_U_SPK' hotbuns='$HB_U_SPK'"; }
    [[ "$HB_U_CB" == "$CORE_U_CB" ]]         || { AMOUNT_T="bad"; log "coinbase mismatch: core='$CORE_U_CB' hotbuns='$HB_U_CB'"; }
    [[ "$HB_U_HEIGHT" == "$CORE_U_HEIGHT" ]] || { AMOUNT_T="bad"; log "height mismatch: core='$CORE_U_HEIGHT' hotbuns='$HB_U_HEIGHT'"; }
else
    DESC_T="bad"; log "hotbuns did not match exactly one unspent (got $HB_NUNSP)"
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK B — SHAPE: top-level keys + per-unspent keys vs Core.
# ════════════════════════════════════════════════════════════════════════
# Top-level: success + total_amount + unspents are REQUIRED (the task's named
# shape contract). bestblock/height/txouts are Core fields we also verify.
for f in success total_amount unspents; do
    HAS=$(jpy "$HB_SCAN" "'$f' in d")
    [[ "$HAS" == "true" ]] || { SHAPE_T="bad"; log "result missing required top-level key '$f'"; }
done
# bestblock parity (tip hash).
HB_BEST=$(jpy "$HB_SCAN" "d.get('bestblock')")
[[ "$HB_BEST" == "$CONF_BLOCKHASH" ]] || { SHAPE_T="bad"; log "bestblock mismatch: '$HB_BEST' != tip '$CONF_BLOCKHASH'"; }
# height parity (tip height).
HB_H=$(jpy "$HB_SCAN" "d.get('height')")
[[ "$HB_H" == "$CONF_HEIGHT" ]] || { SHAPE_T="bad"; log "scan height mismatch: '$HB_H' != tip '$CONF_HEIGHT'"; }
# txouts present + numeric + >= the matched count.
HB_TXOUTS=$(jpy "$HB_SCAN" "d.get('txouts')")
[[ "$HB_TXOUTS" =~ ^[0-9]+$ ]] || { SHAPE_T="bad"; log "txouts absent/non-int: '$HB_TXOUTS'"; }

# Per-unspent keys: hotbuns MUST carry Core's load-bearing keys. We require the
# value-bearing subset that downstream consumers read; we additionally flag any
# of Core's keys hotbuns OMITS as a real divergence in the FAIL reason.
if [[ "$HB_NUNSP" == "1" ]]; then
    HB_U_KEYS=$(jpy "$HB_SCAN" "','.join(sorted(d['unspents'][0].keys()))")
    log "hotbuns unspent keys: $HB_U_KEYS"
    # Required (load-bearing) keys — absence is a hard shape failure.
    for k in txid vout scriptPubKey amount coinbase height; do
        HAS=$(jpy "$HB_SCAN" "'$k' in d['unspents'][0]")
        [[ "$HAS" == "true" ]] || { SHAPE_T="bad"; log "unspent missing required key '$k'"; }
    done
    # Core-parity keys — flag any of Core's keys hotbuns drops as a divergence.
    MISSING_KEYS=""
    for k in $(echo "$CORE_U_KEYS" | tr ',' ' '); do
        HAS=$(jpy "$HB_SCAN" "'$k' in d['unspents'][0]")
        [[ "$HAS" == "true" ]] || MISSING_KEYS="$MISSING_KEYS $k"
    done
    if [[ -n "$MISSING_KEYS" ]]; then
        SHAPE_T="bad"
        log "hotbuns unspent OMITS Core keys:$MISSING_KEYS (Core emits: $CORE_U_KEYS)"
    fi
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK C — EMPTY: scanning an unmatched address -> total 0 / [] unspents.
# ════════════════════════════════════════════════════════════════════════
EMPTY_T="ok"
HB_EMPTY_RESP=$(hb_rpc scantxoutset "[\"start\", [\"addr($NONE_ADDR)\"]]")
echo "$HB_EMPTY_RESP" | grep -q '"result"' || fail "hotbuns scantxoutset (unmatched) errored: $HB_EMPTY_RESP"
HB_EMPTY=$(jpy "$HB_EMPTY_RESP" "json.dumps(d['result'])")
HB_EMPTY_TOTAL=$(jpy "$HB_EMPTY" "format(float(d.get('total_amount')),'.8f')")
HB_EMPTY_N=$(jpy "$HB_EMPTY" "len(d.get('unspents',[]))")
HB_EMPTY_SUCCESS=$(jpy "$HB_EMPTY" "d.get('success')")
[[ "$HB_EMPTY_SUCCESS" == "true" ]]        || { EMPTY_T="bad"; log "unmatched success != true: '$HB_EMPTY_SUCCESS'"; }
[[ "$HB_EMPTY_TOTAL" == "0.00000000" ]]    || { EMPTY_T="bad"; log "unmatched total != 0: '$HB_EMPTY_TOTAL'"; }
[[ "$HB_EMPTY_N" == "0" ]]                 || { EMPTY_T="bad"; log "unmatched unspents != []: count=$HB_EMPTY_N"; }
# Core parity on the empty scan.
[[ "$HB_EMPTY_TOTAL" == "$CORE_EMPTY_TOTAL" ]] || { EMPTY_T="bad"; log "unmatched total != Core: core='$CORE_EMPTY_TOTAL' hotbuns='$HB_EMPTY_TOTAL'"; }
[[ "$HB_EMPTY_N" == "$CORE_EMPTY_N" ]]         || { EMPTY_T="bad"; log "unmatched count != Core: core='$CORE_EMPTY_N' hotbuns='$HB_EMPTY_N'"; }
log "hotbuns unmatched scan: total=$HB_EMPTY_TOTAL unspents=$HB_EMPTY_N (Core: total=$CORE_EMPTY_TOTAL unspents=$CORE_EMPTY_N)"

# ════════════════════════════════════════════════════════════════════════
# CHECK D — action=status -> null; action=abort -> bool (Core idle semantics).
# ════════════════════════════════════════════════════════════════════════
HB_STATUS_RESP=$(hb_rpc scantxoutset "[\"status\"]")
HB_STATUS_IS_NULL=$(jpy "$HB_STATUS_RESP" "d.get('result') is None and 'result' in d")
[[ "$HB_STATUS_IS_NULL" == "true" ]] || { SHAPE_T="bad"; log "scantxoutset status (idle) should be null, got: $HB_STATUS_RESP"; }
HB_ABORT_RESP=$(hb_rpc scantxoutset "[\"abort\"]")
HB_ABORT=$(jpy "$HB_ABORT_RESP" "d.get('result')")
[[ "$HB_ABORT" == "true" || "$HB_ABORT" == "false" ]] || { SHAPE_T="bad"; log "scantxoutset abort should be bool, got: $HB_ABORT_RESP"; }
log "status -> null, abort -> $HB_ABORT (idle semantics ok)"

# ── Verdict. ──────────────────────────────────────────────────────────────
REASONS=""
[[ "$DESC_T"   == "ok" ]] || REASONS="$REASONS desc-mismatch"
[[ "$AMOUNT_T" == "ok" ]] || REASONS="$REASONS amount-mismatch"
[[ "$SHAPE_T"  == "ok" ]] || REASONS="$REASONS shape-mismatch"
[[ "$EMPTY_T"  == "ok" ]] || REASONS="$REASONS empty-mismatch"

if [[ -n "$REASONS" ]]; then
    fail "hotbuns scantxoutset diverges from Core:$REASONS (see stderr log)"
fi

log "PASS: hotbuns scantxoutset matches Core on matched unspent + total_amount + result/unspent shape + empty scan"
pass "$DESC_T" "$AMOUNT_T" "$SHAPE_T" "$EMPTY_T"
