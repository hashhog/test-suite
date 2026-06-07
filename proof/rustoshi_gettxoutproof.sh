#!/usr/bin/env bash
#
# rustoshi_gettxoutproof.sh — self-contained gettxoutproof/verifytxoutproof
# Core-parity differential-regression test.
#
# gettxoutproof(["txid",...] (,"blockhash")) returns a SERIALIZED merkleblock as
# HEX (CMerkleBlock = 80-byte header + nTransactions(4) + hash-count(varint) +
# hashes + flag-bytes). verifytxoutproof("hex") returns a JSON ARRAY of the
# txids the proof commits to that are in the active chain (empty/err if invalid).
# The SAME tx in the SAME block yields a DETERMINISTIC, byte-identical
# merkleblock across nodes, so impl vs Core hex must be byte-for-byte equal.
#
# Core ref: bitcoin-core/src/rpc/txoutproof.cpp
#   gettxoutproof:   serializes CMerkleBlock(block, setTxids) -> HexStr.
#     - locates the tx via the UTXO set (unspent output), -txindex, OR the
#       optional blockhash arg.
#     - unknown blockhash arg            -> RPC -5 "Block not found".
#     - tx not in any block / no output  -> RPC -5 "Transaction not yet in block".
#     - empty txids array                -> RPC -8 "Parameter 'txids' cannot be empty".
#   verifytxoutproof: deserializes the merkleblock, ExtractMatches, checks the
#     reproduced merkle root == header merkle root and the block is in the active
#     chain; returns [txid,...] or [] if the proof cannot be validated.
#     - non-hex / malformed garbage      -> RPC -8 "proof must be hexadecimal string".
#     - structurally valid but wrong root / foreign block -> [] (empty array).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports, launched -listen=0 (RPC only; the sandbox
#   SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener) AND -txindex=1.
#
#   To make the SAME tx exist byte-for-byte on BOTH nodes, Core mines the chain
#   to a deterministic p2wpkh address we hold the key for, and rustoshi is fed
#   every block via `submitblock` — so both nodes carry an IDENTICAL chain
#   (identical coinbases / UTXO set). A real spending tx is built+signed in
#   process with Core's test_framework, pushed into BOTH mempools, and confirmed
#   in a fresh block near the tip (so rustoshi's native no-blockhash 100-block
#   lookback window finds it). Every parity assertion therefore compares the
#   exact same tx in the exact same block on the two nodes.
#
# STRICT shared assertions (ALL gated; none optional):
#   (1) proof=ok        : gettxoutproof([txid]) on rustoshi returns hex
#                         BYTE-IDENTICAL to Core's gettxoutproof([txid]) for the
#                         same confirmed tx — tested both no-blockhash AND with
#                         the explicit blockhash arg.
#   (2) verify-self=ok  : verifytxoutproof(impl_hex) on rustoshi == EXACTLY [txid].
#   (3) verify-cross=ok : verifytxoutproof(core_hex) on rustoshi == EXACTLY [txid]
#                         (Core's proof verifies on the impl).
#   (4) errors=ok       : gettxoutproof for an unknown txid -> error (Core -5
#                         "Transaction not yet in block"); gettxoutproof with an
#                         unknown blockhash arg -> error (Core -5 "Block not
#                         found"); verifytxoutproof of garbage hex -> error or []
#                         matching Core's behavior.
#
# STRICT UNIFORM INTERFACE (mirrors scan/rustoshi_scantxoutset.sh &
#   rawtx/rustoshi_getrawtransaction.sh): no required args, idempotent, trap
#   cleanup, scratch /tmp datadirs + unique ports, ONE clean summary line on
#   stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTPROOF rustoshi: PASS proof=ok verify-self=ok verify-cross=ok errors=ok
#   FAIL: GETTXOUTPROOF rustoshi: FAIL <short reason>
#   SKIP: if the impl binary is missing the FAIL reason contains "not found"
#         (GAP_RE-compatible) so the runner downgrades to SKIP.
#
# Touches ONLY /tmp/proof-rustoshi/ + /tmp/proof-core/ and ports 40410/40430
#   (rustoshi RPC/P2P) + 40412/40432 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx/script)

# Deterministic test secrets. This Core build has NO wallet, so the spending tx
# is built + signed in-process with Core's test_framework. We mine to a p2wpkh
# address we hold the key for, then spend its matured coinbase to a SECOND
# p2wpkh address so the spend produces a non-coinbase tx to prove.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

RS_DATADIR="/tmp/proof-rustoshi"
RS_RPC=40410
RS_P2P=40430
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/proof-core"
CORE_RPC=40412
CORE_P2P=40432
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=101        # exactly enough so block-1's coinbase is matured + spendable.

RS_PID=""
RS_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutproof:rustoshi] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$RS_PID" ]] && kill -0 "$RS_PID" 2>/dev/null; then
        kill "$RS_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$RS_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$RS_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${RS_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${RS_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$RS_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <proof> <verify-self> <verify-cross> <errors>
pass() {
    echo "GETTXOUTPROOF rustoshi: PASS proof=$1 verify-self=$2 verify-cross=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTPROOF rustoshi: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "proof-rustoshi" 2>/dev/null || true
fuser -k "${RS_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${RS_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$RS_DATADIR" "$CORE_DATADIR"
mkdir -p "$RS_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "rustoshi binary not found at $NODE_BIN (build with: cargo build --release)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── Derive the deterministic p2wpkh mining + destination addresses. ───────
derive_p2wpkh() {
    python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$1'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null
}
MINE_ADDR=$(derive_p2wpkh "$SECRET")      || fail "could not derive mining address (test_framework import failed)"
[[ "$MINE_ADDR" == bcrt1* ]] || fail "mining address not regtest bech32: '$MINE_ADDR'"
DEST_ADDR=$(derive_p2wpkh "$DEST_SECRET") || fail "could not derive destination address"
[[ "$DEST_ADDR" == bcrt1* ]] || fail "destination address not regtest bech32: '$DEST_ADDR'"
log "mine addr=$MINE_ADDR dest addr=$DEST_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# Tolerant of the bitcoin-cli .cookie read race + heavy concurrent fleet load.
core_cli_retry() {
    local out="" rc=1
    for _ in $(seq 1 20); do
        out=$(core_cli "$@" 2>/dev/null); rc=$?
        [[ $rc -eq 0 && -n "$out" ]] && { echo "$out"; return 0; }
        [[ -n "$CORE_BG" ]] && ! kill -0 "$CORE_BG" 2>/dev/null && return 1   # daemon dead
        sleep 3
    done
    return 1
}

# rs_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
rs_rpc() {
    curl -s --max-time 90 -u "$RS_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$RS_RPC/" 2>/dev/null
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

# unq <json-string> -> value of a JSON string literal (quote-stripped).
unq() { python3 -c "import sys,json; print(json.loads(sys.stdin.read()))" <<<"$1" 2>/dev/null; }

# ── 2. Launch the Core regtest oracle (RPC-only, txindex on). ─────────────
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # -listen=0: RPC-only — the sandbox SIGKILLs a 0.0.0.0 P2P listener.
    # -txindex=1: Core can answer gettxoutproof with no blockhash arg.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
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
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -listen=0 -txindex=1 (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch rustoshi on regtest (txindex on so the native locator can resolve). ─
log "launching rustoshi (regtest) rpc=:$RS_RPC p2p=:$RS_P2P --txindex -> $RS_LOG"
"$NODE_BIN" --network=regtest --datadir="$RS_DATADIR" --txindex \
    --port="$RS_P2P" --rpcbind="127.0.0.1:$RS_RPC" >"$RS_LOG" 2>&1 &
RS_PID=$!
rs_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < rs_deadline )); do
    if [[ -z "$RS_COOKIE" ]]; then
        for c in "$RS_DATADIR/.cookie" "$RS_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && RS_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$RS_COOKIE" ]]; then
        echo "$(rs_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$RS_PID" 2>/dev/null || { tail -n 20 "$RS_LOG" >&2 2>/dev/null || true; fail "rustoshi exited during startup (see $RS_LOG)"; }
    sleep 1
done
[[ -n "$RS_COOKIE" ]] || fail "rustoshi cookie never appeared within 120s"
echo "$(rs_rpc getblockcount '[]')" | grep -q '"result"' || fail "rustoshi RPC never responded within 120s"
log "rustoshi RPC ready"

# ── 4. Mine the chain on Core, mirror it block-for-block into rustoshi. ───
log "mining $NBLOCKS blocks to $MINE_ADDR on Core"
core_cli_retry generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mirroring Core's $NBLOCKS blocks into rustoshi via submitblock"
BLK1_RAW=""
for ((h=1; h<=NBLOCKS; h++)); do
    BH=$(core_cli_retry getblockhash "$h")            || fail "Core getblockhash $h failed"
    RAW=$(core_cli_retry getblock "$BH" 0)            || fail "Core getblock $h (raw) failed"
    [[ "$h" == "1" ]] && BLK1_RAW="$RAW"              # keep block-1 bytes for coinbase parse
    SB=$(rs_rpc submitblock "[\"$RAW\"]")
    if echo "$SB" | grep -q '"error":{'; then
        ECODE=$(jpy "$SB" "d.get('error') and d['error'].get('code')")
        [[ -z "$ECODE" || "$ECODE" == "None" ]] || fail "rustoshi submitblock height=$h error: $SB"
    fi
done
RS_HEIGHT=$(jpy "$(rs_rpc getblockcount '[]')" "d['result']")
[[ "$RS_HEIGHT" == "$NBLOCKS" ]] || fail "rustoshi height $RS_HEIGHT != $NBLOCKS after mirror (submitblock did not connect chain)"

# Both chains must now share the SAME tip hash (identical blocks).
CORE_TIP=$(core_cli_retry getbestblockhash)
RS_TIP=$(jpy "$(rs_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" == "$RS_TIP" ]] || fail "tip mismatch after mirror: core=$CORE_TIP rust=$RS_TIP"
log "both nodes at identical tip $RS_TIP (height $NBLOCKS)"

# ── 5. Build + sign a real P2WPKH spend with the test_framework. ──────────
# Spend block-1's matured coinbase (vout 0, 50 BTC) to DEST_ADDR with a fee.
# The signed bytes are deterministic and IDENTICAL on both nodes. The block-1
# coinbase txid + value are parsed from the raw block bytes we already mirrored.
[[ -n "$BLK1_RAW" ]] || fail "block-1 raw bytes not captured during mirror"
read -r CB_TXID CB_VALUE < <(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
import io
from test_framework.messages import CBlock
b = CBlock()
b.deserialize(io.BytesIO(bytes.fromhex('$BLK1_RAW')))
cb = b.vtx[0]
print(cb.txid_hex, cb.vout[0].nValue)
" 2>"$RS_DATADIR/cb.err") || { cat "$RS_DATADIR/cb.err" >&2 2>/dev/null; fail "could not parse block-1 coinbase from raw bytes"; }
[[ "$CB_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not read block-1 coinbase txid: '$CB_TXID'"
[[ "$CB_VALUE" =~ ^[0-9]+$ ]]      || fail "could not read block-1 coinbase value: '$CB_VALUE'"
log "spending coinbase $CB_TXID:0 ($CB_VALUE sats) -> $DEST_ADDR"

CORE_HEX=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import sign_input_segwitv0
from test_framework.script_util import key_to_p2wpkh_script, keyhash_to_p2pkh_script
from test_framework.address import address_to_scriptpubkey
from test_framework.crypto.ripemd160 import ripemd160
import hashlib

src = ECKey(); src.set(bytes.fromhex('$SECRET'), compressed=True)
src_pub = src.get_pubkey().get_bytes()
spk_in = key_to_p2wpkh_script(src_pub)

tx = CTransaction()
tx.version = 2
prev_txid = int('$CB_TXID', 16)
in_amount = int('$CB_VALUE')
tx.vin = [CTxIn(COutPoint(prev_txid, 0), b'', 0xffffffff)]
out_value = in_amount - 10000
tx.vout = [CTxOut(out_value, address_to_scriptpubkey('$DEST_ADDR'))]
tx.wit.vtxinwit = [CTxInWitness()]
keyhash = ripemd160(hashlib.sha256(src_pub).digest())
script_code = keyhash_to_p2pkh_script(keyhash)
sign_input_segwitv0(tx, 0, script_code, in_amount, src)
tx.wit.vtxinwit[0].scriptWitness.stack.append(src_pub)
print(tx.serialize_with_witness().hex())
" 2>"$RS_DATADIR/sign.err") || { cat "$RS_DATADIR/sign.err" >&2 2>/dev/null; fail "in-process tx signing failed (see sign.err)"; }
[[ "$CORE_HEX" =~ ^[0-9a-f]+$ ]] || fail "signed tx hex malformed: '$CORE_HEX'"

# Push the SAME bytes into BOTH mempools.
CORE_SEND=$(core_cli_retry sendrawtransaction "$CORE_HEX") || fail "Core sendrawtransaction rejected the signed tx (see $CORE_LOG)"
TXID=$(echo "$CORE_SEND" | tr -d '[:space:]')
[[ "$TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned a non-txid: '$TXID'"
log "created + broadcast spending tx $TXID (Core mempool)"

RS_SEND=$(rs_rpc sendrawtransaction "[\"$CORE_HEX\"]")
echo "$RS_SEND" | grep -q '"result"' || fail "rustoshi sendrawtransaction rejected the Core tx: $RS_SEND"
RS_SENT_TXID=$(unq "$(jpy "$RS_SEND" "json.dumps(d['result'])")")
[[ "$RS_SENT_TXID" == "$TXID" ]] || fail "rustoshi sendrawtransaction txid $RS_SENT_TXID != Core $TXID"
log "identical tx now in BOTH mempools"

# ── 6. Confirm the tx in a FRESH block near the tip. ──────────────────────
# Mine 1 block on Core that confirms TXID, mirror it to rustoshi. The block is
# the new tip, so rustoshi's native no-blockhash 100-block lookback finds it.
CONF_HASH=$(core_cli_retry generatetoaddress 1 "$MINE_ADDR")
CONF_BLOCKHASH=$(jpy "$CONF_HASH" "d[0]" 2>/dev/null)
[[ "$CONF_BLOCKHASH" =~ ^[0-9a-f]{64}$ ]] || CONF_BLOCKHASH=$(core_cli_retry getbestblockhash)
[[ "$CONF_BLOCKHASH" =~ ^[0-9a-f]{64}$ ]] || fail "could not resolve confirming blockhash: '$CONF_BLOCKHASH'"
RAW_CONF=$(core_cli_retry getblock "$CONF_BLOCKHASH" 0) || fail "Core getblock (confirming) failed"
SB=$(rs_rpc submitblock "[\"$RAW_CONF\"]")
RS_TIP2=$(jpy "$(rs_rpc getbestblockhash '[]')" "d['result']")
[[ "$RS_TIP2" == "$CONF_BLOCKHASH" ]] || fail "rustoshi did not connect the confirming block (tip=$RS_TIP2 want=$CONF_BLOCKHASH)"
log "TXID confirmed in block $CONF_BLOCKHASH on both nodes"

# Sanity: the confirming block holds exactly [coinbase, TXID]. The spend's txid
# is what we prove; the coinbase is the only other tx.
core_cli_retry gettxoutproof "[\"$TXID\"]" "$CONF_BLOCKHASH" >/dev/null \
    || fail "Core gettxoutproof on the confirmed tx failed (oracle anomaly; see $CORE_LOG)"

# ════════════════════════════════════════════════════════════════════════
# CHECK 1 — proof: rustoshi gettxoutproof hex BYTE-IDENTICAL to Core's.
#   Tested both with the explicit blockhash arg AND with no blockhash arg.
# ════════════════════════════════════════════════════════════════════════
PROOF_T="ok"; VSELF_T="ok"; VCROSS_T="ok"; ERRORS_T="ok"

# Core's proof (authoritative). bitcoin-cli prints the bare hex string (no quotes).
CORE_PROOF_BH=$(core_cli_retry gettxoutproof "[\"$TXID\"]" "$CONF_BLOCKHASH" | tr -d '[:space:]') \
    || fail "Core gettxoutproof (with blockhash) failed (see $CORE_LOG)"
[[ "$CORE_PROOF_BH" =~ ^[0-9a-f]+$ ]] || fail "Core proof (blockhash) hex malformed: '$CORE_PROOF_BH'"
CORE_PROOF_NB=$(core_cli_retry gettxoutproof "[\"$TXID\"]" | tr -d '[:space:]') \
    || fail "Core gettxoutproof (no blockhash, via txindex) failed (see $CORE_LOG)"
[[ "$CORE_PROOF_NB" =~ ^[0-9a-f]+$ ]] || fail "Core proof (no blockhash) hex malformed: '$CORE_PROOF_NB'"
# Core must itself be deterministic: blockhash arg vs txindex resolution yield
# the SAME serialized merkleblock (same block, same txid set).
[[ "$CORE_PROOF_BH" == "$CORE_PROOF_NB" ]] || fail "Core's own proof differs blockhash-vs-txindex (oracle anomaly): bh=$CORE_PROOF_BH nb=$CORE_PROOF_NB"
log "Core proof hex (len $((${#CORE_PROOF_BH}/2)) bytes): $CORE_PROOF_BH"

# rustoshi proof WITH the explicit blockhash arg.
RS_PROOF_BH_RESP=$(rs_rpc gettxoutproof "[[\"$TXID\"], \"$CONF_BLOCKHASH\"]")
echo "$RS_PROOF_BH_RESP" | grep -q '"result"' || fail "rustoshi gettxoutproof (with blockhash) errored: $RS_PROOF_BH_RESP"
RS_PROOF_BH=$(unq "$(jpy "$RS_PROOF_BH_RESP" "json.dumps(d['result'])")")
[[ "$RS_PROOF_BH" =~ ^[0-9a-f]+$ ]] || { PROOF_T="bad"; log "rustoshi proof (blockhash) hex malformed: '$RS_PROOF_BH'"; }
[[ "$RS_PROOF_BH" == "$CORE_PROOF_BH" ]] || { PROOF_T="bad"; log "proof hex (blockhash) mismatch:\n  core=$CORE_PROOF_BH\n  rust=$RS_PROOF_BH"; }

# rustoshi proof WITHOUT the blockhash arg (native: txindex / UTXO / lookback).
RS_PROOF_NB_RESP=$(rs_rpc gettxoutproof "[[\"$TXID\"]]")
echo "$RS_PROOF_NB_RESP" | grep -q '"result"' || fail "rustoshi gettxoutproof (no blockhash) errored: $RS_PROOF_NB_RESP"
RS_PROOF_NB=$(unq "$(jpy "$RS_PROOF_NB_RESP" "json.dumps(d['result'])")")
[[ "$RS_PROOF_NB" =~ ^[0-9a-f]+$ ]] || { PROOF_T="bad"; log "rustoshi proof (no blockhash) hex malformed: '$RS_PROOF_NB'"; }
[[ "$RS_PROOF_NB" == "$CORE_PROOF_NB" ]] || { PROOF_T="bad"; log "proof hex (no blockhash) mismatch:\n  core=$CORE_PROOF_NB\n  rust=$RS_PROOF_NB"; }

# Structural sanity on Core's proof: header(80) + nTx(4) is the prefix; nTx>=1.
PROOF_NTX=$(python3 -c "
import sys
b=bytes.fromhex('$CORE_PROOF_BH')
import struct
print(struct.unpack_from('<I', b, 80)[0] if len(b)>=84 else -1)" 2>/dev/null)
[[ "$PROOF_NTX" =~ ^[0-9]+$ && "$PROOF_NTX" -ge 1 ]] || fail "Core proof structural check failed: nTx='$PROOF_NTX'"
log "proof nTransactions field = $PROOF_NTX (confirming block holds coinbase + spend)"

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — verify-self: verifytxoutproof(impl_hex) on impl == EXACTLY [txid].
# ════════════════════════════════════════════════════════════════════════
# Use rustoshi's OWN proof (must be == Core's by check 1, but verify against the
# impl's emitted bytes explicitly).
RS_VSELF_RESP=$(rs_rpc verifytxoutproof "[\"$RS_PROOF_BH\"]")
echo "$RS_VSELF_RESP" | grep -q '"result"' || fail "rustoshi verifytxoutproof(impl_hex) errored: $RS_VSELF_RESP"
RS_VSELF=$(jpy "$RS_VSELF_RESP" "json.dumps(d['result'])")
# Core's own self-verify for reference (must be [TXID]).
CORE_VSELF=$(core_cli_retry verifytxoutproof "$CORE_PROOF_BH")
CORE_VSELF_J=$(jpy "$CORE_VSELF" "json.dumps(d)" 2>/dev/null)
[[ -n "$CORE_VSELF_J" ]] || CORE_VSELF_J="$CORE_VSELF"
log "Core verify(core_hex)=$CORE_VSELF_J   rust verify(impl_hex)=$RS_VSELF"
EXPECT="[\"$TXID\"]"
RS_VSELF_NORM=$(python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" <<<"$RS_VSELF" 2>/dev/null)
[[ "$RS_VSELF_NORM" == "$EXPECT" ]] || { VSELF_T="bad"; log "verify-self != [txid]: got=$RS_VSELF want=$EXPECT"; }
# Core parity: Core's self-verify must also be exactly [TXID].
CORE_VSELF_NORM=$(python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" <<<"$CORE_VSELF_J" 2>/dev/null)
[[ "$CORE_VSELF_NORM" == "$EXPECT" ]] || fail "Core verify(core_hex) != [txid] (oracle anomaly): got=$CORE_VSELF_J want=$EXPECT"

# ════════════════════════════════════════════════════════════════════════
# CHECK 3 — verify-cross: verifytxoutproof(core_hex) on impl == EXACTLY [txid].
# ════════════════════════════════════════════════════════════════════════
RS_VCROSS_RESP=$(rs_rpc verifytxoutproof "[\"$CORE_PROOF_BH\"]")
echo "$RS_VCROSS_RESP" | grep -q '"result"' || fail "rustoshi verifytxoutproof(core_hex) errored: $RS_VCROSS_RESP"
RS_VCROSS=$(jpy "$RS_VCROSS_RESP" "json.dumps(d['result'])")
RS_VCROSS_NORM=$(python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" <<<"$RS_VCROSS" 2>/dev/null)
log "rust verify(core_hex)=$RS_VCROSS"
[[ "$RS_VCROSS_NORM" == "$EXPECT" ]] || { VCROSS_T="bad"; log "verify-cross != [txid]: got=$RS_VCROSS want=$EXPECT"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 4 — errors: unknown txid -> error; unknown blockhash -> error;
#           garbage-hex verify -> error or [] matching Core.
# ════════════════════════════════════════════════════════════════════════
# (4a) gettxoutproof for an unknown/nonexistent txid -> error.
UNKNOWN_TXID="00000000000000000000000000000000000000000000000000000000deadbeef"
RS_E_UNK=$(rs_rpc gettxoutproof "[[\"$UNKNOWN_TXID\"]]")
E_UNK_CODE=$(jpy "$RS_E_UNK" "d['error']['code']")
if [[ -z "$E_UNK_CODE" || "$E_UNK_CODE" == "None" ]]; then
    # Some impls might return an empty/'null' result instead of erroring — that is
    # NOT Core's contract. Core errors (-5). Treat a non-error as a divergence.
    RS_E_UNK_RES=$(jpy "$RS_E_UNK" "json.dumps(d.get('result'))")
    ERRORS_T="bad"; log "unknown-txid gettxoutproof did NOT error (Core errors -5); result=$RS_E_UNK_RES"
else
    log "unknown-txid gettxoutproof error code=$E_UNK_CODE (Core: -5)"
fi
# Core parity: Core returns -5 "Transaction not yet in block".
CORE_E_UNK=$(core_cli gettxoutproof "[\"$UNKNOWN_TXID\"]" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ -z "$CORE_E_UNK" || "$CORE_E_UNK" == "-5" ]] || { ERRORS_T="bad"; log "Core unknown-txid code != -5: '$CORE_E_UNK'"; }

# (4b) gettxoutproof with an unknown blockhash arg -> error (Core -5 "Block not found").
BAD_BLOCKHASH="00000000000000000000000000000000000000000000000000000000cafebabe"
RS_E_BBH=$(rs_rpc gettxoutproof "[[\"$TXID\"], \"$BAD_BLOCKHASH\"]")
E_BBH_CODE=$(jpy "$RS_E_BBH" "d['error']['code']")
if [[ -z "$E_BBH_CODE" || "$E_BBH_CODE" == "None" ]]; then
    RS_E_BBH_RES=$(jpy "$RS_E_BBH" "json.dumps(d.get('result'))")
    ERRORS_T="bad"; log "unknown-blockhash gettxoutproof did NOT error (Core errors -5); result=$RS_E_BBH_RES"
else
    log "unknown-blockhash gettxoutproof error code=$E_BBH_CODE (Core: -5)"
fi
CORE_E_BBH=$(core_cli gettxoutproof "[\"$TXID\"]" "$BAD_BLOCKHASH" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ -z "$CORE_E_BBH" || "$CORE_E_BBH" == "-5" ]] || { ERRORS_T="bad"; log "Core unknown-blockhash code != -5: '$CORE_E_BBH'"; }

# (4c) verifytxoutproof of garbage / malformed hex -> error or [] matching Core.
# Core: a NON-hex string -> RPC -8 "proof must be hexadecimal string".
GARBAGE="zzzznothex"
CORE_G=$(core_cli verifytxoutproof "$GARBAGE" 2>&1)
CORE_G_CODE=$(echo "$CORE_G" | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
log "Core garbage-hex verify: code='${CORE_G_CODE:-<none>}' ($CORE_G)"
RS_G=$(rs_rpc verifytxoutproof "[\"$GARBAGE\"]")
RS_G_CODE=$(jpy "$RS_G" "d['error']['code']")
RS_G_RES=$(jpy "$RS_G" "json.dumps(d.get('result'))")
# Accept either an error (any RPC error code) OR an empty-array result — both are
# Core-acceptable per the contract ("error or [] (match Core's behavior)").
if [[ -n "$RS_G_CODE" && "$RS_G_CODE" != "None" ]]; then
    log "rustoshi garbage-hex verify error code=$RS_G_CODE (Core: ${CORE_G_CODE:-error})"
elif [[ "$RS_G_RES" == "[]" ]]; then
    log "rustoshi garbage-hex verify returned [] (Core errors -8; [] also acceptable)"
else
    ERRORS_T="bad"; log "garbage-hex verify neither errored nor returned []: result=$RS_G_RES resp=$RS_G"
fi

# (4d) verifytxoutproof of a well-formed-hex-but-structurally-bogus proof: a
# byte-truncated copy of the real proof -> Core returns [] or errors. The impl
# must NOT return [txid] (that would be accepting a corrupt proof).
TRUNC_PROOF="${CORE_PROOF_BH:0:$(( ${#CORE_PROOF_BH} - 4 ))}"
RS_TR=$(rs_rpc verifytxoutproof "[\"$TRUNC_PROOF\"]")
RS_TR_CODE=$(jpy "$RS_TR" "d['error']['code']")
RS_TR_RES=$(jpy "$RS_TR" "json.dumps(d.get('result'))")
if [[ -n "$RS_TR_CODE" && "$RS_TR_CODE" != "None" ]]; then
    log "rustoshi truncated-proof verify errored code=$RS_TR_CODE (acceptable)"
elif [[ "$RS_TR_RES" == "[]" || "$RS_TR_RES" == "null" ]]; then
    log "rustoshi truncated-proof verify returned $RS_TR_RES (acceptable)"
elif echo "$RS_TR_RES" | grep -q "$TXID"; then
    ERRORS_T="bad"; log "truncated/corrupt proof verified as VALID [txid] (should not): $RS_TR_RES"
else
    log "rustoshi truncated-proof verify returned $RS_TR_RES (non-[txid]; acceptable)"
fi

# ── Verdict. ──────────────────────────────────────────────────────────────
if [[ "$PROOF_T" == "ok" && "$VSELF_T" == "ok" && "$VCROSS_T" == "ok" && "$ERRORS_T" == "ok" ]]; then
    log "PASS: rustoshi gettxoutproof/verifytxoutproof match Core on proof hex + self/cross verify + errors"
    pass "$PROOF_T" "$VSELF_T" "$VCROSS_T" "$ERRORS_T"
fi

REASON=""
[[ "$PROOF_T"  != "ok" ]] && REASON+="proof hex diverges from Core; "
[[ "$VSELF_T"  != "ok" ]] && REASON+="verify(impl_hex) != [txid]; "
[[ "$VCROSS_T" != "ok" ]] && REASON+="verify(core_hex) != [txid]; "
[[ "$ERRORS_T" != "ok" ]] && REASON+="error-handling diverges from Core; "
fail "${REASON% }"
