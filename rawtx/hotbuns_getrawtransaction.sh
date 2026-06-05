#!/usr/bin/env bash
#
# hotbuns_getrawtransaction.sh — self-contained getrawtransaction Core-parity test.
#
# The next RPC-surface/indexing green-cell after getindexinfo ("txindex on but
# getrawtransaction fails"). getrawtransaction is the block-explorer keystone:
# raw-hex retrieval + a fully-decoded transaction object that must match Bitcoin
# Core EXACTLY on the load-bearing fields.
#
# Core ref: bitcoin-core/src/rpc/rawtransaction.cpp:216-374 (getrawtransaction),
#           :58-85 (TxToJSON envelope), src/core_io.cpp:430-533 (TxToUniv).
#   SIGNATURE: getrawtransaction "txid" ( verbosity "blockhash" ).
#     verbosity default 0; accepts bool (true=1,false=0) or int 0/1/2.
#   OUTPUT:
#     v0 -> the raw tx HEX string (EncodeHexTx)  — byte-exact serialization.
#     v1 -> a decoded OBJECT (TxToUniv include_hex=true) + the TxToJSON envelope:
#             txid, hash(=wtxid), version, size, vsize, weight, locktime,
#             vin[] {coinbase | txid,vout,scriptSig{asm,hex}, txinwitness?, sequence},
#             vout[] {value, n, scriptPubKey{asm,desc,hex,address?,type}}, hex,
#             and when confirmed in the active chain: blockhash, confirmations
#             (=1+tipH-txH), time, blocktime (both = block nTime); plus
#             in_active_chain when a blockhash ARG was given.
#   ERRORS (all -5 RPC_INVALID_ADDRESS_OR_KEY):
#     genesis-coinbase txid -> "...genesis block coinbase...cannot be retrieved";
#     unknown blockhash arg -> "Block hash not found";
#     tx not found          -> "No such mempool ... transaction" (category -5).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports, launched -listen=0 (RPC only; the sandbox
#   SIGKILLs any bitcoind ~20-30s after load) AND -txindex=1.
#
#   CRITICAL ORDERING: this sandbox SIGKILLs bitcoind ~20-30s after launch,
#   regardless of -listen=0. So PHASE A does EVERY Core-dependent operation up
#   front and CAPTURES Core's authoritative outputs (the 110 chain blocks + a
#   confirming block as raw hex; Core's v0 hex / v1 JSON for the spending tx;
#   Core's confirmed-via-blockhash v1; Core's error codes) into a scratch
#   manifest, all within the live window. PHASE B then launches hotbuns (slow
#   Bun cold start — but NOT bitcoind, so it is never sandbox-killed), replays
#   the captured blocks via submitblock, pushes the IDENTICAL signed tx, and
#   asserts hotbuns' getrawtransaction against the captured Core values. hotbuns
#   never needs Core to be alive.
#
#   To make the SAME transaction exist byte-for-byte on BOTH nodes, Core mines
#   the whole chain and hotbuns is fed each block via `submitblock` — so both
#   nodes carry an IDENTICAL chain (identical coinbases / UTXO set). The spend
#   tx is built+signed by Core's test_framework; the IDENTICAL signed hex is
#   pushed into BOTH mempools. Every parity assertion therefore compares the
#   exact same tx object on the two nodes.
#
# WHAT MUST MATCH CORE EXACTLY:
#   v0 hex              == Core's v0 hex   (byte-identical serialization)
#   v1 txid,hash,version,size,vsize,weight,locktime,hex   == Core
#   v1 vin[i] {txid,vout,sequence} + scriptSig.hex + txinwitness == Core
#   v1 vout[i] {value,n, scriptPubKey.hex,.type,.address} == Core
#   confirmed: blockhash == mined block; confirmations int >= 1 (== Core);
#              in_active_chain == true; time/blocktime present (== block nTime).
#   error codes: random txid -> -5; genesis-coinbase txid -> -5;
#                unknown blockhash arg -> -5 ("Block hash not found").
# PRESENT-NOT-BYTE-EQUAL (legitimately differ): scriptPubKey.asm, scriptSig.asm,
#   scriptPubKey.desc (InferDescriptor vs raw + asm whitespace can differ).
#
# txindex (sub-check 4): hotbuns ALWAYS writes a txindex entry for tip-connected
#   blocks (sync/blocks.ts Pattern C0; no user-facing --txindex flag is needed),
#   so getrawtransaction <txid> 1 with NO blockhash on a confirmed tx must
#   succeed and resolve the right blockhash.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/hotbuns_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETRAWTRANSACTION hotbuns: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   FAIL: GETRAWTRANSACTION hotbuns: FAIL <short reason>
#
# Touches ONLY /tmp/grt-hotbuns/ + /tmp/grt-core-hb/ and ports 40114/40134
#   (hotbuns RPC/P2P) + 40116/40136 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/script/tx)

# Deterministic test secrets. The spending tx is built + signed in-process with
# Core's test_framework. We mine to a p2wpkh address we hold the key for, then
# spend its matured coinbase to a SECOND p2wpkh address (decodes to bech32).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

HB_DATADIR="/tmp/grt-hotbuns"
HB_RPC=40114
HB_P2P=40134
HB_LOG="$HB_DATADIR/node.log"

CORE_DATADIR="/tmp/grt-core-hb"
CORE_RPC=40116
CORE_P2P=40136
CORE_LOG="$CORE_DATADIR/core.log"

# Captured-from-Core manifest (survives Core's death; consumed by PHASE B).
CAP_DIR="/tmp/grt-cap-hb"
BLOCKS_FILE="$CAP_DIR/blocks.hex"        # one raw block hex per line (1..NBLOCKS + confirming)

NBLOCKS=110        # >100 so the first matured coinbase is spendable.

HB_PID=""
HB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getrawtransaction:hotbuns] $*" >&2; }

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
# pass <hex> <decoded> <confirmed> <errors>
pass() {
    echo "GETRAWTRANSACTION hotbuns: PASS hex=$1 decoded=$2 confirmed=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION hotbuns: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "grt-hotbuns" 2>/dev/null || true
pkill -f "grt-core-hb" 2>/dev/null || true
fuser -k "${HB_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${HB_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$CAP_DIR"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR" "$CAP_DIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
command -v bun     >/dev/null 2>&1   || fail "bun runtime not found on PATH"
[[ -f "$NODE_DIR/src/index.ts" ]]    || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── Derive the deterministic p2wpkh mining + destination addresses. ───────
MINE_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null) \
    || fail "could not derive mining address (test_framework import failed)"
[[ "$MINE_ADDR" == bcrt1* ]] || fail "mining address not regtest bech32: '$MINE_ADDR'"
DEST_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$DEST_SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null) \
    || fail "could not derive destination address"
[[ "$DEST_ADDR" == bcrt1* ]] || fail "destination address not regtest bech32: '$DEST_ADDR'"
log "mine addr=$MINE_ADDR dest addr=$DEST_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# hb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
hb_rpc() {
    curl -s --max-time 90 -u "$HB_COOKIE" \
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

# unq <json-string> -> the value of a JSON string literal (quote-stripped).
unq() { python3 -c "import sys,json; print(json.loads(sys.stdin.read()))" <<<"$1" 2>/dev/null; }

# ══════════════════════════════════════════════════════════════════════════
# PHASE A — drive REAL Core for every authoritative output, capturing into a
#   manifest, all within Core's ~20-30s live window (sandbox SIGKILLs bitcoind
#   after that). hotbuns is NOT started yet (its slow Bun cold start would eat
#   into the window).
# ══════════════════════════════════════════════════════════════════════════

# ── 2. Launch the Core regtest oracle (RPC-only, txindex on). ─────────────
log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -listen=0 -txindex=1"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -listen=0 -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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

# Capture the genesis merkle root (== genesis coinbase txid) for the error test.
GEN_BLOCKHASH=$(core_cli getblockhash 0 2>/dev/null)
GEN_MROOT=$(jpy "$(core_cli getblockheader "$GEN_BLOCKHASH" 2>/dev/null)" "d.get('merkleroot')")
[[ "$GEN_MROOT" =~ ^[0-9a-f]{64}$ ]] || fail "could not read genesis merkleroot from Core: '$GEN_MROOT'"

# ── 4. Build + sign a real P2WPKH spend with the test_framework. ──────────
# Spend block-1's matured coinbase output (vout 0, 50 BTC) to DEST_ADDR.
CB_BLOCKHASH=$(core_cli getblockhash 1 2>/dev/null)         || fail "Core getblockhash 1 failed"
CB_JSON=$(core_cli getblock "$CB_BLOCKHASH" 2 2>/dev/null)  || fail "Core getblock 1 (verbose) failed"
CB_TXID=$(jpy "$CB_JSON" "d['tx'][0]['txid']")
[[ "$CB_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not read block-1 coinbase txid: '$CB_TXID'"
log "spending coinbase $CB_TXID:0 (50 BTC) -> $DEST_ADDR"

CORE_HEX=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import sign_input_segwitv0, CScript
from test_framework.script_util import key_to_p2wpkh_script
from test_framework.address import address_to_scriptpubkey

src = ECKey(); src.set(bytes.fromhex('$SECRET'), compressed=True)
src_pub = src.get_pubkey().get_bytes()
spk_in = key_to_p2wpkh_script(src_pub)          # P2WPKH scriptPubKey of the coinbase output

tx = CTransaction()
tx.version = 2
prev_txid = int('$CB_TXID', 16)
tx.vin = [CTxIn(COutPoint(prev_txid, 0), b'', 0xffffffff)]
# 50 BTC in, 0.0001 BTC fee -> 49.9999 BTC out to DEST_ADDR.
out_value = int(50 * COIN) - 10000
tx.vout = [CTxOut(out_value, address_to_scriptpubkey('$DEST_ADDR'))]
tx.wit.vtxinwit = [CTxInWitness()]
# BIP-143 scriptCode for P2WPKH is the corresponding P2PKH script.
from test_framework.script_util import keyhash_to_p2pkh_script
from test_framework.crypto.ripemd160 import ripemd160
import hashlib
keyhash = ripemd160(hashlib.sha256(src_pub).digest())
script_code = keyhash_to_p2pkh_script(keyhash)
sign_input_segwitv0(tx, 0, script_code, int(50*COIN), src)
tx.wit.vtxinwit[0].scriptWitness.stack.append(src_pub)   # pubkey on top of sig
print(tx.serialize_with_witness().hex())
" 2>"$CAP_DIR/sign.err") || { cat "$CAP_DIR/sign.err" >&2 2>/dev/null; fail "in-process tx signing failed (see sign.err)"; }
[[ "$CORE_HEX" =~ ^[0-9a-f]+$ ]] || fail "signed tx hex malformed: '$CORE_HEX'"

# ── 5. Broadcast into Core; capture Core's mempool v0 hex + v1 JSON. ──────
CORE_SEND=$(core_cli sendrawtransaction "$CORE_HEX" 2>/dev/null) \
    || fail "Core sendrawtransaction rejected the signed tx (see $CORE_LOG)"
TXID=$(echo "$CORE_SEND" | tr -d '[:space:]')
[[ "$TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned a non-txid: '$TXID'"
log "created + broadcast spending tx $TXID (Core mempool)"

CORE_V0=$(core_cli getrawtransaction "$TXID" 0 2>/dev/null)
CORE_V0=$(echo "$CORE_V0" | tr -d '[:space:]')
[[ "$CORE_V0" =~ ^[0-9a-f]+$ ]] || fail "Core getrawtransaction v0 malformed: '$CORE_V0'"
CORE_V1=$(core_cli getrawtransaction "$TXID" 1 2>/dev/null)
[[ -n "$CORE_V1" ]] || fail "Core getrawtransaction v1 produced no output"

# ── 6. Mine a confirming block on Core; capture it + Core confirmed v1. ───
core_cli generatetoaddress 1 "$MINE_ADDR" >/dev/null 2>&1 || fail "Core confirming generate failed"
CONF_BLOCKHASH=$(core_cli getbestblockhash 2>/dev/null)
[[ "$CONF_BLOCKHASH" =~ ^[0-9a-f]{64}$ ]] || fail "Core confirming blockhash malformed: '$CONF_BLOCKHASH'"
BLK_NTIME=$(jpy "$(core_cli getblockheader "$CONF_BLOCKHASH" 2>/dev/null)" "d.get('time')")
CORE_CONF_V1=$(core_cli getrawtransaction "$TXID" 1 "$CONF_BLOCKHASH" 2>/dev/null)
[[ -n "$CORE_CONF_V1" ]] || fail "Core confirmed v1 produced no output"
CORE_CONF_COUNT=$(jpy "$CORE_CONF_V1" "d.get('confirmations')")

# ── 7. Capture Core's error codes for parity. ─────────────────────────────
RAND_TXID="00000000000000000000000000000000000000000000000000000000deadbeef"
CORE_ERR_RAND=$(core_cli getrawtransaction "$RAND_TXID" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
CORE_ERR_GEN=$(core_cli getrawtransaction "$GEN_MROOT" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)

# ── 8. Dump all 110 chain blocks + the confirming block as raw hex. ───────
# A single CLI getblock per height (~9ms each here) finishes in ~1s — well
# inside Core's live window.
: > "$BLOCKS_FILE"
for ((h=1; h<=NBLOCKS; h++)); do
    BH=$(core_cli getblockhash "$h" 2>/dev/null)   || fail "Core getblockhash $h failed"
    RAW=$(core_cli getblock "$BH" 0 2>/dev/null)   || fail "Core getblock $h (raw) failed"
    echo "$RAW" >> "$BLOCKS_FILE"
done
RAW_CONF=$(core_cli getblock "$CONF_BLOCKHASH" 0 2>/dev/null) || fail "Core getblock (confirming) failed"
echo "$RAW_CONF" >> "$BLOCKS_FILE"
NLINES=$(wc -l < "$BLOCKS_FILE")
[[ "$NLINES" == "$(( NBLOCKS + 1 ))" ]] || fail "captured $NLINES block lines, expected $(( NBLOCKS + 1 ))"
log "captured $NLINES raw blocks + Core authoritative outputs; Core may now die"

# ── 9. Stop Core (we no longer need it). ──────────────────────────────────
core_cli stop >/dev/null 2>&1 || true
[[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
CORE_BG=""

# ══════════════════════════════════════════════════════════════════════════
# PHASE B — launch hotbuns (not bitcoind -> never sandbox-killed), replay the
#   captured chain via submitblock, push the IDENTICAL signed tx, and assert
#   hotbuns getrawtransaction against the captured Core outputs.
# ══════════════════════════════════════════════════════════════════════════

# ── 10. Launch hotbuns on regtest. ────────────────────────────────────────
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

# ── 11. Mirror the captured 110 chain blocks into hotbuns via submitblock. ─
log "mirroring $NBLOCKS captured blocks into hotbuns via submitblock"
h=0
while IFS= read -r RAW; do
    h=$(( h + 1 ))
    [[ "$h" -gt "$NBLOCKS" ]] && break   # the confirming block (last line) is replayed in CHECK 2
    SB=$(hb_rpc submitblock "[\"$RAW\"]")
    if echo "$SB" | grep -q '"error":{'; then
        ECODE=$(jpy "$SB" "d.get('error') and d['error'].get('code')")
        [[ -z "$ECODE" || "$ECODE" == "None" ]] || fail "hotbuns submitblock height=$h error: $SB"
    fi
done < "$BLOCKS_FILE"
HB_HEIGHT=$(jpy "$(hb_rpc getblockcount '[]')" "d['result']")
[[ "$HB_HEIGHT" == "$NBLOCKS" ]] || fail "hotbuns height $HB_HEIGHT != $NBLOCKS after mirror (submitblock did not connect chain)"
HB_TIP=$(jpy "$(hb_rpc getbestblockhash '[]')" "d['result']")
log "hotbuns at height $NBLOCKS, tip $HB_TIP"

# ── 12. Push the IDENTICAL signed tx into hotbuns' mempool. ───────────────
HB_SEND=$(hb_rpc sendrawtransaction "[\"$CORE_HEX\"]")
echo "$HB_SEND" | grep -q '"result"' || fail "hotbuns sendrawtransaction rejected the Core tx: $HB_SEND"
HB_SENT_TXID=$(unq "$(jpy "$HB_SEND" "json.dumps(d['result'])")")
[[ "$HB_SENT_TXID" == "$TXID" ]] || fail "hotbuns sendrawtransaction txid $HB_SENT_TXID != Core $TXID"
log "identical tx now in hotbuns mempool"

# ════════════════════════════════════════════════════════════════════════
# CHECK 1 — MEMPOOL: v0 hex byte-exact + v1 decoded fields exact (vs Core).
# ════════════════════════════════════════════════════════════════════════
HEX_T="ok"; DECODED_T="ok"

# v0 hex byte-EXACT (int 0).
HB_HEX=$(unq "$(jpy "$(hb_rpc getrawtransaction "[\"$TXID\", 0]")" "json.dumps(d['result'])")")
[[ "$HB_HEX" == "$CORE_V0" ]] || { HEX_T="bad"; log "v0 hex mismatch:\n  core=$CORE_V0\n  hotbuns=$HB_HEX"; }
# v0 hex == the original signed bytes too.
[[ "$HB_HEX" == "$CORE_HEX" ]] || { HEX_T="bad"; log "v0 hex != signed bytes: hotbuns=$HB_HEX"; }
# bool verbosity false == 0 (hex).
HB_HEX_BF=$(unq "$(jpy "$(hb_rpc getrawtransaction "[\"$TXID\", false]")" "json.dumps(d['result'])")")
[[ "$HB_HEX_BF" == "$CORE_V0" ]] || { HEX_T="bad"; log "v0 (bool false) hex mismatch: hotbuns=$HB_HEX_BF"; }
# default verbosity (omitted) == 0 (hex).
HB_HEX_DEF=$(unq "$(jpy "$(hb_rpc getrawtransaction "[\"$TXID\"]")" "json.dumps(d['result'])")")
[[ "$HB_HEX_DEF" == "$CORE_V0" ]] || { HEX_T="bad"; log "v0 (default omitted) hex mismatch: hotbuns=$HB_HEX_DEF"; }
[[ "$HEX_T" == "ok" ]] || fail "v0 hex parity failed (see log)"

# v1 decoded object. Core (CLI) returns the bare result object; hotbuns the
# JSON-RPC envelope (index d['result']). bool verbosity true == 1.
HB_V1_BT=$(hb_rpc getrawtransaction "[\"$TXID\", true]")
echo "$HB_V1_BT" | grep -q '"result"' || fail "hotbuns getrawtransaction v1 (bool true) errored: $HB_V1_BT"
HB_V1=$(jpy "$HB_V1_BT" "json.dumps(d['result'])")
[[ -n "$HB_V1" ]] || fail "hotbuns getrawtransaction v1 result empty"
log "Core v1: $CORE_V1"
log "hotb v1: $HB_V1"

# Top-level scalar fields that MUST be byte-equal.
for f in txid hash version size vsize weight locktime hex; do
    CV=$(jpy "$CORE_V1" "d.get('$f')")
    RV=$(jpy "$HB_V1"   "d.get('$f')")
    [[ -n "$CV" ]] || fail "Core v1 missing field '$f'"
    [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "v1 field '$f' mismatch: core='$CV' hotbuns='$RV'"; }
done

# vin parity: txid, vout, sequence, scriptSig.hex, txinwitness per input.
NVIN_C=$(jpy "$CORE_V1" "len(d.get('vin',[]))")
NVIN_R=$(jpy "$HB_V1"   "len(d.get('vin',[]))")
[[ "$NVIN_C" == "$NVIN_R" && -n "$NVIN_C" && "$NVIN_C" -ge 1 ]] || { DECODED_T="bad"; log "vin count mismatch: core=$NVIN_C hotbuns=$NVIN_R"; }
if [[ "$NVIN_C" == "$NVIN_R" ]]; then
    for ((i=0; i<NVIN_C; i++)); do
        for f in txid vout sequence; do
            CV=$(jpy "$CORE_V1" "d['vin'][$i].get('$f')")
            RV=$(jpy "$HB_V1"   "d['vin'][$i].get('$f')")
            [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vin[$i].$f mismatch: core='$CV' hotbuns='$RV'"; }
        done
        CV=$(jpy "$CORE_V1" "d['vin'][$i].get('scriptSig',{}).get('hex')")
        RV=$(jpy "$HB_V1"   "d['vin'][$i].get('scriptSig',{}).get('hex')")
        [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vin[$i].scriptSig.hex mismatch: core='$CV' hotbuns='$RV'"; }
        RA=$(jpy "$HB_V1" "'asm' in d['vin'][$i].get('scriptSig',{})")
        [[ "$RA" == "true" ]] || { DECODED_T="bad"; log "vin[$i].scriptSig.asm absent on hotbuns"; }
        # txinwitness (this is a segwit input): stack must match exactly.
        CW=$(jpy "$CORE_V1" "','.join(d['vin'][$i].get('txinwitness',[]))")
        RW=$(jpy "$HB_V1"   "','.join(d['vin'][$i].get('txinwitness',[]))")
        [[ "$CW" == "$RW" ]] || { DECODED_T="bad"; log "vin[$i].txinwitness mismatch: core='$CW' hotbuns='$RW'"; }
    done
fi

# vout parity: value, n, scriptPubKey.hex/.type/.address(if Core has it).
NVOUT_C=$(jpy "$CORE_V1" "len(d.get('vout',[]))")
NVOUT_R=$(jpy "$HB_V1"   "len(d.get('vout',[]))")
[[ "$NVOUT_C" == "$NVOUT_R" && -n "$NVOUT_C" && "$NVOUT_C" -ge 1 ]] || { DECODED_T="bad"; log "vout count mismatch: core=$NVOUT_C hotbuns=$NVOUT_R"; }
if [[ "$NVOUT_C" == "$NVOUT_R" ]]; then
    for ((i=0; i<NVOUT_C; i++)); do
        # value: compare numerically (8-dp) to avoid 1.00 vs 1 text diffs.
        CV=$(jpy "$CORE_V1" "format(float(d['vout'][$i]['value']),'.8f')")
        RV=$(jpy "$HB_V1"   "format(float(d['vout'][$i]['value']),'.8f')")
        [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vout[$i].value mismatch: core='$CV' hotbuns='$RV'"; }
        CV=$(jpy "$CORE_V1" "d['vout'][$i].get('n')")
        RV=$(jpy "$HB_V1"   "d['vout'][$i].get('n')")
        [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vout[$i].n mismatch: core='$CV' hotbuns='$RV'"; }
        for f in hex type; do
            CV=$(jpy "$CORE_V1" "d['vout'][$i]['scriptPubKey'].get('$f')")
            RV=$(jpy "$HB_V1"   "d['vout'][$i]['scriptPubKey'].get('$f')")
            [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vout[$i].scriptPubKey.$f mismatch: core='$CV' hotbuns='$RV'"; }
        done
        # address: required-equal ONLY when Core emits one (decodable scripts).
        CADDR=$(jpy "$CORE_V1" "d['vout'][$i]['scriptPubKey'].get('address')")
        if [[ -n "$CADDR" && "$CADDR" != "None" ]]; then
            RADDR=$(jpy "$HB_V1" "d['vout'][$i]['scriptPubKey'].get('address')")
            [[ "$RADDR" == "$CADDR" ]] || { DECODED_T="bad"; log "vout[$i].scriptPubKey.address mismatch: core='$CADDR' hotbuns='$RADDR'"; }
        fi
        # asm + desc present (not byte-equal).
        for f in asm desc; do
            RP=$(jpy "$HB_V1" "'$f' in d['vout'][$i]['scriptPubKey']")
            [[ "$RP" == "true" ]] || { DECODED_T="bad"; log "vout[$i].scriptPubKey.$f absent on hotbuns"; }
        done
    done
fi

# Mempool v1 must NOT carry block-context fields (Core only adds them when the
# tx is in a block — TxToJSON hashBlock null).
for f in blockhash confirmations time blocktime in_active_chain; do
    HAS=$(jpy "$HB_V1" "'$f' in d")
    [[ "$HAS" == "false" ]] || { DECODED_T="bad"; log "mempool v1 should OMIT '$f', but it is present"; }
done
[[ "$DECODED_T" == "ok" ]] || fail "v1 decoded parity failed (see log)"

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — CONFIRMED via blockhash arg.
# ════════════════════════════════════════════════════════════════════════
CONFIRMED_T="ok"

# Replay the captured confirming block (the last line of BLOCKS_FILE) into hotbuns.
RAW_CONF_HB=$(tail -n 1 "$BLOCKS_FILE")
[[ -n "$RAW_CONF_HB" ]] || fail "captured confirming block missing"
SB=$(hb_rpc submitblock "[\"$RAW_CONF_HB\"]")
HB_TIP2=$(jpy "$(hb_rpc getbestblockhash '[]')" "d['result']")
[[ "$HB_TIP2" == "$CONF_BLOCKHASH" ]] || fail "hotbuns did not connect the confirming block (tip=$HB_TIP2 want=$CONF_BLOCKHASH)"
log "TXID confirmed in block $CONF_BLOCKHASH on hotbuns"

# getrawtransaction <txid> 1 <blockhash> on hotbuns.
HB_CONF=$(hb_rpc getrawtransaction "[\"$TXID\", 1, \"$CONF_BLOCKHASH\"]")
echo "$HB_CONF" | grep -q '"result"' || fail "hotbuns getrawtransaction <txid> 1 <blockhash> errored: $HB_CONF"
HB_CONF_R=$(jpy "$HB_CONF" "json.dumps(d['result'])")

R_BH=$(jpy "$HB_CONF_R" "d.get('blockhash')")
[[ "$R_BH" == "$CONF_BLOCKHASH" ]] || { CONFIRMED_T="bad"; log "confirmed blockhash mismatch: got='$R_BH' want='$CONF_BLOCKHASH'"; }

R_CONF=$(jpy "$HB_CONF_R" "d.get('confirmations')")
if ! [[ "$R_CONF" =~ ^[0-9]+$ ]] || [[ "$R_CONF" -lt 1 ]]; then
    CONFIRMED_T="bad"; log "confirmations absent/not >=1: '$R_CONF'"
fi
# Core parity on confirmations (both at the same tip -> 1).
[[ -z "$CORE_CONF_COUNT" || "$CORE_CONF_COUNT" == "None" || "$CORE_CONF_COUNT" == "$R_CONF" ]] \
    || { CONFIRMED_T="bad"; log "confirmations mismatch: core='$CORE_CONF_COUNT' hotbuns='$R_CONF'"; }

R_IAC=$(jpy "$HB_CONF_R" "d.get('in_active_chain')")
[[ "$R_IAC" == "true" ]] || { CONFIRMED_T="bad"; log "in_active_chain != true (blockhash arg given): '$R_IAC'"; }

R_TIME=$(jpy "$HB_CONF_R" "d.get('time')")
R_BTIME=$(jpy "$HB_CONF_R" "d.get('blocktime')")
[[ "$R_TIME"  =~ ^[0-9]+$ ]] || { CONFIRMED_T="bad"; log "time absent/non-int: '$R_TIME'"; }
[[ "$R_BTIME" =~ ^[0-9]+$ ]] || { CONFIRMED_T="bad"; log "blocktime absent/non-int: '$R_BTIME'"; }
[[ "$R_TIME" == "$R_BTIME" ]] || { CONFIRMED_T="bad"; log "time != blocktime: '$R_TIME' vs '$R_BTIME'"; }
# blocktime must equal the actual block header nTime (captured from Core).
[[ -z "$BLK_NTIME" || "$R_BTIME" == "$BLK_NTIME" ]] || { CONFIRMED_T="bad"; log "blocktime '$R_BTIME' != block nTime '$BLK_NTIME'"; }

# Core parity on the confirmed envelope load-bearing fields (captured Core v1).
C_BH=$(jpy "$CORE_CONF_V1" "d.get('blockhash')")
[[ "$C_BH" == "$R_BH" ]] || { CONFIRMED_T="bad"; log "confirmed blockhash != Core: core='$C_BH' hotbuns='$R_BH'"; }
C_IAC=$(jpy "$CORE_CONF_V1" "d.get('in_active_chain')")
[[ "$C_IAC" == "$R_IAC" ]] || { CONFIRMED_T="bad"; log "in_active_chain != Core: core='$C_IAC' hotbuns='$R_IAC'"; }

[[ "$CONFIRMED_T" == "ok" ]] || fail "confirmed-via-blockhash parity failed (see log)"

# ── Sub-check 4: txindex (no blockhash) on a confirmed tx. hotbuns ALWAYS ──
# writes a txindex entry on tip-connect (Pattern C0), so this must succeed.
HB_TXI=$(hb_rpc getrawtransaction "[\"$TXID\", 1]")
if echo "$HB_TXI" | grep -q '"result"'; then
    HB_TXI_BH=$(jpy "$HB_TXI" "d['result'].get('blockhash')")
    [[ "$HB_TXI_BH" == "$CONF_BLOCKHASH" ]] || { CONFIRMED_T="bad"; log "txindex-resolved blockhash mismatch: '$HB_TXI_BH'"; }
    # No blockhash ARG given -> in_active_chain must be ABSENT (Core parity).
    HB_TXI_IAC=$(jpy "$HB_TXI" "'in_active_chain' in d['result']")
    [[ "$HB_TXI_IAC" == "false" ]] || { CONFIRMED_T="bad"; log "txindex path (no blockhash arg) must OMIT in_active_chain"; }
    log "txindex sub-check: getrawtransaction <txid> 1 (no blockhash) resolved via txindex -> $HB_TXI_BH"
else
    fail "hotbuns txindex enabled-by-default but getrawtransaction <txid> 1 (no blockhash) failed on a confirmed tx: $HB_TXI"
fi
[[ "$CONFIRMED_T" == "ok" ]] || fail "confirmed/txindex parity failed (see log)"

# ════════════════════════════════════════════════════════════════════════
# CHECK 3 — ERRORS: random txid -> -5; genesis-coinbase txid -> -5;
#                   unknown blockhash arg -> -5 ("Block hash not found").
# ════════════════════════════════════════════════════════════════════════
ERRORS_T="ok"

# random unknown txid -> -5 (and Core parity from the captured code).
E_RAND=$(jpy "$(hb_rpc getrawtransaction "[\"$RAND_TXID\"]")" "d['error']['code']")
[[ "$E_RAND" == "-5" ]] || { ERRORS_T="bad"; log "unknown txid: expected -5, got '$E_RAND'"; }
[[ -z "$CORE_ERR_RAND" || "$CORE_ERR_RAND" == "-5" ]] || { ERRORS_T="bad"; log "Core unknown-txid code != -5: '$CORE_ERR_RAND'"; }

# genesis-coinbase txid (== genesis merkle root) -> -5 + message mentions genesis.
E_GEN_RESP=$(hb_rpc getrawtransaction "[\"$GEN_MROOT\"]")
E_GEN=$(jpy "$E_GEN_RESP" "d['error']['code']")
[[ "$E_GEN" == "-5" ]] || { ERRORS_T="bad"; log "genesis-coinbase txid: expected -5, got '$E_GEN'"; }
E_GEN_MSG=$(jpy "$E_GEN_RESP" "d['error']['message']")
echo "$E_GEN_MSG" | grep -qi "genesis" || { ERRORS_T="bad"; log "genesis-coinbase error msg lacks 'genesis': '$E_GEN_MSG'"; }
[[ -z "$CORE_ERR_GEN" || "$CORE_ERR_GEN" == "-5" ]] || { ERRORS_T="bad"; log "Core genesis-coinbase code != -5: '$CORE_ERR_GEN'"; }

# unknown blockhash arg -> -5 ("Block hash not found").
BAD_BLOCKHASH="00000000000000000000000000000000000000000000000000000000cafebabe"
E_BBH_RESP=$(hb_rpc getrawtransaction "[\"$TXID\", 1, \"$BAD_BLOCKHASH\"]")
E_BBH=$(jpy "$E_BBH_RESP" "d['error']['code']")
[[ "$E_BBH" == "-5" ]] || { ERRORS_T="bad"; log "unknown blockhash arg: expected -5, got '$E_BBH'"; }
E_BBH_MSG=$(jpy "$E_BBH_RESP" "d['error']['message']")
echo "$E_BBH_MSG" | grep -qi "block hash not found" || { ERRORS_T="bad"; log "unknown blockhash msg lacks 'Block hash not found': '$E_BBH_MSG'"; }

[[ "$ERRORS_T" == "ok" ]] || fail "error-code parity failed (see log)"

log "PASS: hotbuns getrawtransaction matches Core on v0 hex + v1 decoded + confirmed envelope + error codes"
pass "$HEX_T" "$DECODED_T" "$CONFIRMED_T" "$ERRORS_T"
