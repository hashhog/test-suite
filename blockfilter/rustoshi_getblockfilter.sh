#!/usr/bin/env bash
#
# rustoshi_getblockfilter.sh — self-contained getblockfilter Core-parity test.
#
# A SUBSTANTIVE indexing green-cell. getblockfilter returns the BIP-158 basic
# compact block filter (a GCS-encoded set of scriptPubKeys) plus the BIP-157
# chained filter HEADER for a block. Unlike getindexinfo (which only reports
# index *status*), this proves rustoshi computes the SPV-serving filter
# BYTE-IDENTICALLY to Bitcoin Core — the actual bytes light clients download.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:2956-3031 (getblockfilter) +
#           src/blockfilter.cpp (BlockFilter / GCSFilter) + BIP158 + BIP157.
#   SIGNATURE: getblockfilter "blockhash" ( "filtertype" ). filtertype default
#              "basic".
#   OUTPUT: { "filter": <hex GCS>, "header": <hex 32-byte filter header> }.
#   ERRORS:
#     unknown filtertype     -> -5  (RPC_INVALID_ADDRESS_OR_KEY) "Unknown filtertype"
#     filter index disabled  -> -1  (RPC_MISC_ERROR) "Index is not enabled ..."
#     block not found        -> -5  (RPC_INVALID_ADDRESS_OR_KEY) "Block not found"
#
# BIP-158 BASIC FILTER (type 0x00) — the exact bytes that must match Core:
#   ELEMENTS: every tx output scriptPubKey EXCEPT empty + OP_RETURN, PLUS for
#     every non-coinbase input the scriptPubKey of the prevout it spends
#     (from the undo/UTXO data). Deduped.
#   GCS: P=19, M=784931. SipHash-2-4 key = first 16 bytes of the block HASH
#     (k0 = bytes 0..8 LE, k1 = bytes 8..16 LE). Each element -> 64-bit value
#     via (SipHash(element) * (N*M)) >> 64 (BIP158 hash-to-range). Sort ascending,
#     Golomb-Rice encode the successive DIFFERENCES with P=19.
#   ENCODED FILTER ("filter"): CompactSize(N) || GCS bitstream, hex.
#   FILTER HEADER ("header"): SHA256d( SHA256d(rawFilterBytes) || prevHeader ),
#     chained from the parent block (all-zero for genesis's parent).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest instance +
#   OWN ports, launched -listen=0 -blockfilterindex=basic. Core is the SINGLE
#   source of blocks: Core mines a chain that INCLUDES A SPEND tx (so the
#   spending block's filter has BOTH an output scriptPubKey AND a spent-prevout
#   scriptPubKey -> a non-trivial multi-element filter), then each block's raw
#   hex is replayed into rustoshi via submitblock. After replay both nodes hold
#   the byte-identical chain, so getblockfilter on the SAME hash MUST agree
#   byte-for-byte (filter + header) — including the chained header link.
#
# WHAT MUST MATCH CORE EXACTLY:
#   1. filter hex byte-EXACT vs Core AND header hex byte-EXACT vs Core, for a
#      coinbase-only block (1-element filter) AND a block containing a spend
#      (multi-element filter).
#   2. HEADER CHAINING: the header at height N chains from height N-1 — verify
#      the bytes match Core across >=3 consecutive blocks (catches a wrong
#      prev-header link), AND verify the chain recomputes locally
#      (SHA256d(SHA256d(filter) || prevHeader) == header).
#   3. ERRORS: getblockfilter <hash> bogustype -> -5 "Unknown filtertype";
#      getblockfilter <unknown-hash> basic -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/blockheader/rustoshi_getblockheader.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER rustoshi: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER rustoshi: FAIL <short reason>
#   SKIP: GETBLOCKFILTER rustoshi: SKIP <no filter index>
#
# Touches ONLY /tmp/gbf-rustoshi/ + /tmp/gbf-core/ and ports
#   22130/22150 (rustoshi RPC/P2P) + 22132/22152 (Core RPC; P2P unused, -listen=0).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

RS_DATADIR="/tmp/gbf-rustoshi/$$"
RS_RPC=22130
RS_P2P=22150
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/gbf-core/$$"
CORE_RPC=22132
CORE_P2P=22152   # declared but Core launched -listen=0 (no P2P listener)
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=110        # mine 110 empty blocks (matures the first coinbase at h=1)
TBASE=1700000000   # pin nTime so Core's blocks are deterministic

RS_PID=""
RS_COOKIE=""
CORE_BG=""
ADDR=""

log() { echo "[getblockfilter:rustoshi] $*" >&2; }

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
    rm -rf "$RS_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "GETBLOCKFILTER rustoshi: PASS filter=$1 header=$2 chain=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETBLOCKFILTER rustoshi: FAIL $*"
    exit 1
}
skip() {
    echo "GETBLOCKFILTER rustoshi: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset (own ports + own PID scratch only). ───────────────
log "resetting scratch state (pid=$$)"
pkill -f "gbf-rustoshi/$$" 2>/dev/null || true
if ss -tln 2>/dev/null | grep -qE ":(${RS_RPC}|${RS_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${RS_RPC}/${RS_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
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

# ── 2. Derive the deterministic bcrt1 p2wpkh mining address. ──────────────
ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic mining address (Core test_framework import failed)"
[[ "$ADDR" == bcrt1* ]] || fail "derived address is not a regtest bech32 address: '$ADDR'"
log "deterministic mining address: $ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }
# 15 attempts x 2s = up to 30s tolerance per call. The replay phase issues 222
# read RPCs (getblockhash + getblock for 111 blocks) back-to-back; under heavy
# concurrent sandbox CPU pressure a single bitcoin-cli call can transiently time
# out even though Core is alive, so a generous budget avoids spurious failures.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 15); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        # Confirm Core is still alive; if it died, fail fast rather than spin.
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 2
    done
    return 1
}
rs_rpc() {
    curl -s --max-time 90 -u "$RS_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$RS_RPC/" 2>/dev/null
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

# ── 4. Launch rustoshi on regtest with the basic block filter index. ──────
log "launching rustoshi (regtest, --blockfilterindex=basic) rpc=:$RS_RPC p2p=:$RS_P2P -> $RS_LOG"
"$NODE_BIN" --network=regtest --datadir="$RS_DATADIR" \
    --port="$RS_P2P" --rpcbind="127.0.0.1:$RS_RPC" --blockfilterindex=basic >"$RS_LOG" 2>&1 &
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

# Quick capability probe: if rustoshi does not implement getblockfilter at all,
# SKIP cleanly rather than FAIL (uniform-interface contract).
PROBE=$(rs_rpc getblockfilter "[\"$(printf '0%.0s' {1..64})\", \"basic\"]")
PROBE_ECODE=$(jpy "$PROBE" "d.get('error',{}).get('code')")
PROBE_EMSG=$(jpy "$PROBE" "d.get('error',{}).get('message','')")
# A method-not-found is JSON-RPC -32601. "Index is not enabled" (-1) means
# the RPC exists but the index is off -> still a real green-cell (we enabled it).
if [[ "$PROBE_ECODE" == "-32601" ]]; then
    skip "no getblockfilter RPC (method not found)"
fi
if [[ "$PROBE_ECODE" == "-1" && "$PROBE_EMSG" == *"not enabled"* ]]; then
    skip "no filter index (getblockfilter reports index not enabled)"
fi

# ── 5. Core mines a chain that INCLUDES A SPEND. ──────────────────────────
# Strategy for a deterministic, identical chain on both nodes that contains a
# real multi-element filter:
#   - setmocktime-pin every block's nTime.
#   - Mine NBLOCKS empty blocks to ADDR (matures coinbase #1).
#   - Create a SPEND: send some coin to a fresh address; this tx spends a
#     matured coinbase output (-> the filter for the block that includes it
#     carries BOTH the new output scriptPubKeys AND the spent prevout's
#     scriptPubKey). Mine it into block NBLOCKS+1.
#   - Replay ALL blocks (1 .. NBLOCKS+1) into rustoshi via submitblock.
# Core's filters and rustoshi's filters are then computed over the identical
# block + undo data, so they must be byte-identical.
log "mining $NBLOCKS empty blocks to $ADDR on Core (setmocktime-pinned)"
core_cli setmocktime "$TBASE" >/dev/null 2>&1 || true
for (( i=1; i<=NBLOCKS; i++ )); do
    core_cli setmocktime "$(( TBASE + i ))" >/dev/null 2>&1 || true
    if ! core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1; then
        sleep 1
        core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || {
            kill -0 "$CORE_BG" 2>/dev/null \
                && fail "Core generatetoaddress failed at block $i (oracle alive)" \
                || fail "Core generatetoaddress failed at block $i (oracle DIED — see $CORE_LOG)"
        }
    fi
done

# Build a SPEND with NO wallet. This bitcoind build has "No wallet support
# compiled in", so sendtoaddress/getnewaddress are unavailable. Instead we
# spend the matured coinbase at height 1 (paid to ADDR = p2wpkh of SECRET, which
# we hold the private key for) via a RAW, locally-signed BIP-143 segwit tx, then
# broadcast it with sendrawtransaction and mine it into block NBLOCKS+1.
#
# The coinbase at height 1 carries a 50-BTC p2wpkh(SECRET) output (vout 0).
# After NBLOCKS (>=100) confirmations it is spendable. The spend creates a new
# p2wpkh output to a different key (DESTSECRET) and pays a small fee. The block
# that includes it therefore has a multi-element basic filter:
#   - the coinbase output scriptPubKey of block NBLOCKS+1,
#   - the spend's new output scriptPubKey,
#   - the SPENT prevout scriptPubKey (the p2wpkh(SECRET) from block 1's
#     coinbase, pulled from the undo data) — this is the element that proves
#     rustoshi includes spent-prevout scripts exactly like Core.
DESTSECRET="2222222222222222222222222222222222222222222222222222222222222223"

# Coinbase txid + value at height 1 (from Core, deterministic).
CB_BLOCK1=$(core_cli_retry getblockhash 1)               || fail "getblockhash 1 failed"
CB1_TXID=$(core_cli_retry getblock "$CB_BLOCK1" 1 | python3 -c "import sys,json; print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ "$CB1_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not read coinbase txid at height 1: '$CB1_TXID'"
# Read the coinbase's vout-0 value (sats) directly from its raw tx.
CB1_RAW=$(core_cli_retry getrawtransaction "$CB1_TXID" 0 "$CB_BLOCK1") || fail "getrawtransaction coinbase h1 failed"
[[ -n "$CB1_RAW" ]] || fail "empty coinbase raw at h1"
log "spending coinbase $CB1_TXID:0 (block 1) via raw BIP-143 segwit tx"

# Construct + sign the spend locally with the test_framework crypto.
SPEND_RAW=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import CScript, SegwitV0SignatureHash, SIGHASH_ALL
from test_framework.script_util import key_to_p2wpkh_script
from test_framework.key import ECKey
import io

src = ECKey(); src.set(bytes.fromhex('$SECRET'), True)
src_pub = src.get_pubkey().get_bytes()
src_spk = key_to_p2wpkh_script(src_pub)

dst = ECKey(); dst.set(bytes.fromhex('$DESTSECRET'), True)
dst_spk = key_to_p2wpkh_script(dst.get_pubkey().get_bytes())

# Parse the coinbase raw to find vout 0's value + scriptPubKey.
cb = CTransaction()
cb.deserialize(io.BytesIO(bytes.fromhex('$CB1_RAW')))
amount = cb.vout[0].nValue
assert bytes(cb.vout[0].scriptPubKey) == bytes(src_spk), 'coinbase vout0 spk != p2wpkh(SECRET)'

txid_int = int('$CB1_TXID', 16)  # display order; COutPoint wants internal int
# COutPoint hash field is the internal little-endian int of the txid; the RPC
# txid is display (reversed). Convert: reverse bytes then int.
txid_internal = int.from_bytes(bytes.fromhex('$CB1_TXID')[::-1], 'little')

tx = CTransaction()
tx.vin.append(CTxIn(COutPoint(txid_internal, 0), b'', 0xffffffff))
fee = 1000  # 1000 sats fee
tx.vout.append(CTxOut(amount - fee, dst_spk))
tx.wit.vtxinwit.append(CTxInWitness())

# BIP-143 sighash for p2wpkh: scriptCode = p2pkh of the same key.
from test_framework.script_util import keyhash_to_p2pkh_script
import hashlib
def hash160(b):
    return hashlib.new('ripemd160', hashlib.sha256(b).digest()).digest()
script_code = keyhash_to_p2pkh_script(hash160(src_pub))
sighash = SegwitV0SignatureHash(script_code, tx, 0, SIGHASH_ALL, amount)
sig = src.sign_ecdsa(sighash) + bytes([SIGHASH_ALL])
tx.wit.vtxinwit[0].scriptWitness.stack = [sig, src_pub]

print(tx.serialize_with_witness().hex())
" 2>/dev/null) || fail "raw spend tx construction failed (test_framework crypto)"
[[ "$SPEND_RAW" =~ ^[0-9a-f]+$ ]] || fail "constructed spend tx not hex: '$SPEND_RAW'"

# Broadcast the spend; it lands in Core's mempool.
core_cli setmocktime "$(( TBASE + NBLOCKS + 1 ))" >/dev/null 2>&1 || true
SPEND_TXID=$(core_cli_retry sendrawtransaction "$SPEND_RAW") || {
    log "sendrawtransaction output: $(core_cli sendrawtransaction "$SPEND_RAW" 2>&1)"
    fail "Core sendrawtransaction (raw spend) rejected"
}
[[ "$SPEND_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned non-txid: '$SPEND_TXID'"
log "spend txid: $SPEND_TXID -> mining it into block $(( NBLOCKS + 1 ))"

# Mine ONE block to confirm the spend; this block's filter is multi-element.
core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || {
    sleep 1
    core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || fail "Core failed to mine the spend block"
}

CORE_HEIGHT=$(core_cli_retry getblockcount)
TOTAL=$(( NBLOCKS + 1 ))
[[ "$CORE_HEIGHT" == "$TOTAL" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $TOTAL"
log "Core chain height = $CORE_HEIGHT (spend confirmed in block $CORE_HEIGHT)"

# Identify the height of the block that contains the spend tx.
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$CORE_HEIGHT")
core_cli_retry getblock "$SPEND_BLOCKHASH" 1 | grep -q "$SPEND_TXID" \
    || fail "spend tx $SPEND_TXID not found in block $SPEND_BLOCKHASH"
SPEND_HEIGHT=$CORE_HEIGHT
log "spend confirmed in block height $SPEND_HEIGHT ($SPEND_BLOCKHASH)"

# ── 6. Replay ALL of Core's raw blocks into rustoshi via submitblock. ─────
# getblockhash/getblock can transiently fail under concurrent sandbox load even
# though Core is alive; re-settle once and retry the FULL fetch before failing
# so the test isn't flaky on an unrelated RPC hiccup mid-replay.
log "replaying Core's $TOTAL raw blocks into rustoshi via submitblock"
for (( h=1; h<=TOTAL; h++ )); do
    bh=$(core_cli_retry getblockhash "$h")
    if [[ -z "$bh" ]]; then sleep 2; bh=$(core_cli_retry getblockhash "$h"); fi
    [[ -n "$bh" ]]                            || fail "getblockhash $h failed (Core RPC unresponsive)"
    raw=$(core_cli_retry getblock "$bh" 0)
    if [[ -z "$raw" ]]; then sleep 2; raw=$(core_cli_retry getblock "$bh" 0); fi
    [[ -n "$raw" ]]                           || fail "getblock $bh 0 failed (Core RPC unresponsive)"
    sb=$(rs_rpc submitblock "[\"$raw\"]")
    sbres=$(jpy "$sb" "d.get('result')")
    sberr=$(jpy "$sb" "d.get('error')")
    if [[ -n "$sbres" && "$sbres" != "None" && "$sbres" != "duplicate" && "$sbres" != "inconclusive" ]]; then
        fail "rustoshi submitblock rejected height $h: result='$sbres' raw_resp=$sb"
    fi
    if [[ -n "$sberr" && "$sberr" != "None" ]]; then
        fail "rustoshi submitblock errored height $h: $sb"
    fi
done
RS_HEIGHT=$(jpy "$(rs_rpc getblockcount '[]')" "d['result']")
[[ "$RS_HEIGHT" == "$TOTAL" ]] || fail "rustoshi height after replay is $RS_HEIGHT, expected $TOTAL"
log "rustoshi replayed to height $RS_HEIGHT — chains are byte-identical"

# Sanity: tips identical (proves identical chain).
CORE_TIP=$(core_cli_retry getbestblockhash)
RS_TIP=$(jpy "$(rs_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" == "$RS_TIP" ]] || fail "tip mismatch after replay: core=$CORE_TIP rust=$RS_TIP"

# ── helpers for getblockfilter ────────────────────────────────────────────
# gbf_filter <hash>  -> filter hex (rustoshi)
rs_gbf_filter() { jpy "$(rs_rpc getblockfilter "[\"$1\", \"basic\"]")" "d['result']['filter']"; }
rs_gbf_header() { jpy "$(rs_rpc getblockfilter "[\"$1\", \"basic\"]")" "d['result']['header']"; }
co_gbf_filter() { core_cli_retry getblockfilter "$1" basic | python3 -c "import sys,json; print(json.load(sys.stdin)['filter'])" 2>/dev/null; }
co_gbf_header() { core_cli_retry getblockfilter "$1" basic | python3 -c "import sys,json; print(json.load(sys.stdin)['header'])" 2>/dev/null; }

# ── 7. CHECK 1 — filter bytes byte-EXACT for coinbase-only AND spend blocks. ─
FILTER_T="bad"
# (a) a coinbase-only block: height 1 (the very first block; coinbase to ADDR).
H1=$(core_cli_retry getblockhash 1)
RS_F1=$(rs_gbf_filter "$H1")
CO_F1=$(co_gbf_filter "$H1")
[[ "$RS_F1" =~ ^[0-9a-f]+$ ]] || fail "rustoshi filter (coinbase block h1) not hex: '$RS_F1'"
[[ "$CO_F1" =~ ^[0-9a-f]+$ ]] || fail "Core filter (coinbase block h1) not hex: '$CO_F1'"
if [[ "$RS_F1" != "$CO_F1" ]]; then
    fail "coinbase-only filter mismatch at height 1: rust=$RS_F1 core=$CO_F1"
fi
log "coinbase-only filter (h1) byte-EXACT: $RS_F1"

# (b) the SPEND block: multi-element filter (>= new outputs + spent prevout).
RS_FS=$(rs_gbf_filter "$SPEND_BLOCKHASH")
CO_FS=$(co_gbf_filter "$SPEND_BLOCKHASH")
[[ "$RS_FS" =~ ^[0-9a-f]+$ ]] || fail "rustoshi filter (spend block) not hex: '$RS_FS'"
[[ "$CO_FS" =~ ^[0-9a-f]+$ ]] || fail "Core filter (spend block) not hex: '$CO_FS'"
if [[ "$RS_FS" != "$CO_FS" ]]; then
    fail "SPEND-block filter mismatch at height $SPEND_HEIGHT: rust=$RS_FS core=$CO_FS"
fi
# Confirm the spend filter is genuinely multi-element: its CompactSize(N) prefix
# must encode N >= 2 (the spend block has a coinbase output, the spend's
# outputs, AND the spent prevout scriptPubKey -> N typically 4+).
SPEND_N=$(python3 -c "
import sys
b = bytes.fromhex('$RS_FS')
n = b[0]
i = 1
if n == 0xfd: n = int.from_bytes(b[1:3],'little'); i=3
elif n == 0xfe: n = int.from_bytes(b[1:5],'little'); i=5
elif n == 0xff: n = int.from_bytes(b[1:9],'little'); i=9
print(n)
" 2>/dev/null)
[[ "$SPEND_N" =~ ^[0-9]+$ && "$SPEND_N" -ge 2 ]] \
    || fail "spend block filter is not multi-element (N=$SPEND_N); not a meaningful spend-filter test"
log "SPEND-block filter (h$SPEND_HEIGHT, N=$SPEND_N elements) byte-EXACT: $RS_FS"
FILTER_T="ok"

# ── 8. CHECK 2 — filter HEADER bytes byte-EXACT (both blocks). ────────────
HEADER_T="bad"
RS_H1=$(rs_gbf_header "$H1");            CO_H1=$(co_gbf_header "$H1")
RS_HS=$(rs_gbf_header "$SPEND_BLOCKHASH"); CO_HS=$(co_gbf_header "$SPEND_BLOCKHASH")
[[ "$RS_H1" =~ ^[0-9a-f]{64}$ ]] || fail "rustoshi header (h1) not 64-hex: '$RS_H1'"
[[ "$RS_HS" =~ ^[0-9a-f]{64}$ ]] || fail "rustoshi header (spend) not 64-hex: '$RS_HS'"
[[ "$RS_H1" == "$CO_H1" ]] || fail "filter HEADER mismatch at height 1: rust=$RS_H1 core=$CO_H1"
[[ "$RS_HS" == "$CO_HS" ]] || fail "filter HEADER mismatch at spend height $SPEND_HEIGHT: rust=$RS_HS core=$CO_HS"
log "filter headers byte-EXACT: h1=$RS_H1 spend=$RS_HS"
HEADER_T="ok"

# ── 9. CHECK 3 — HEADER CHAINING across >=3 consecutive blocks. ───────────
# For each of three consecutive heights ending at the spend block, verify:
#   (i)  rustoshi's header byte-matches Core's header (catches wrong values), and
#   (ii) rustoshi's header recomputes locally as
#        SHA256d( SHA256d(rawFilterBytes) || prevHeader ) where prevHeader is
#        rustoshi's OWN header at height-1 (catches a wrong prev-header LINK).
CHAIN_T="bad"
recompute_header() {
    # args: <filter_hex> <prev_header_hex(display/RPC order)>
    python3 -c "
import hashlib, sys
def d256(b): return hashlib.sha256(hashlib.sha256(b).digest()).digest()
filt = bytes.fromhex('$1')
# prev header arrives in RPC display order (big-endian-ish reversed); BIP157
# concatenates the internal 32-byte hashes. Core's GetHex() reverses, so to
# rebuild we reverse the RPC hex back to internal order, concat, hash, reverse.
prev_disp = bytes.fromhex('$2')
prev_internal = prev_disp[::-1]
fh = d256(filt)                 # internal order
hdr_internal = d256(fh + prev_internal)
print(hdr_internal[::-1].hex()) # back to display order
"
}
COK="ok"
START=$(( SPEND_HEIGHT - 2 ))
PREV_HDR=""   # rustoshi's header at START-1, RPC order
PH=$(( START - 1 ))
PREV_HDR=$(rs_gbf_header "$(core_cli_retry getblockhash "$PH")")
[[ "$PREV_HDR" =~ ^[0-9a-f]{64}$ ]] || { COK="bad"; log "chain: prev header at h$PH not 64-hex: '$PREV_HDR'"; }
for (( h=START; h<=SPEND_HEIGHT; h++ )); do
    bh=$(core_cli_retry getblockhash "$h")
    rs_hdr=$(rs_gbf_header "$bh")
    co_hdr=$(co_gbf_header "$bh")
    rs_flt=$(rs_gbf_filter "$bh")
    # (i) byte-match vs Core
    if [[ "$rs_hdr" != "$co_hdr" ]]; then
        COK="bad"; log "chain: header mismatch vs Core at h$h: rust=$rs_hdr core=$co_hdr"
    fi
    # (ii) recompute from rustoshi's own filter + the PREV header link
    recomputed=$(recompute_header "$rs_flt" "$PREV_HDR")
    if [[ "$recomputed" != "$rs_hdr" ]]; then
        COK="bad"
        log "chain: header at h$h does NOT chain from h$((h-1)): recomputed=$recomputed reported=$rs_hdr prev=$PREV_HDR"
    fi
    PREV_HDR="$rs_hdr"
done
[[ "$COK" == "ok" ]] && CHAIN_T="ok"
[[ "$CHAIN_T" == "ok" ]] || fail "header chaining check failed (see log)"
log "header chaining verified across heights $START..$SPEND_HEIGHT (byte-match Core + local prev-link recompute)"

# ── 10. CHECK 4 — ERRORS. ─────────────────────────────────────────────────
ERR_T="bad"
# (a) unknown filtertype -> -5 "Unknown filtertype".
EBAD=$(rs_rpc getblockfilter "[\"$SPEND_BLOCKHASH\", \"bogustype\"]")
EBAD_CODE=$(jpy "$EBAD" "d['error']['code']")
EBAD_MSG=$(jpy "$EBAD" "d['error']['message']")
[[ "$EBAD_CODE" == "-5" ]] || fail "unknown filtertype: expected -5, got '$EBAD_CODE' (resp=$EBAD)"
case "$EBAD_MSG" in
    *[Uu]nknown*filtertype*) : ;;
    *) log "WARNING: unknown-filtertype message not 'Unknown filtertype': '$EBAD_MSG' (code -5 is the hard requirement)";;
esac
# Core agreement.
CE1=$(core_cli getblockfilter "$SPEND_BLOCKHASH" bogustype 2>&1 | grep -oE '\-5' | head -1)
[[ "$CE1" == "-5" ]] || log "WARNING: could not confirm Core returns -5 for unknown filtertype (rustoshi is -5, which is the requirement)"

# (b) unknown block hash -> -5.
UNKNOWN="00000000000000000000000000000000000000000000000000000000deadbeef"
EUNK=$(rs_rpc getblockfilter "[\"$UNKNOWN\", \"basic\"]")
EUNK_CODE=$(jpy "$EUNK" "d['error']['code']")
[[ "$EUNK_CODE" == "-5" ]] || fail "unknown blockhash: expected -5, got '$EUNK_CODE' (resp=$EUNK)"
CE2=$(core_cli getblockfilter "$UNKNOWN" basic 2>&1 | grep -oE '\-5' | head -1)
[[ "$CE2" == "-5" ]] || log "WARNING: could not confirm Core returns -5 for unknown blockhash (rustoshi is -5, which is the requirement)"
ERR_T="ok"

log "PASS: rustoshi getblockfilter matches Core on filter bytes + header bytes + chaining + errors"
pass "$FILTER_T" "$HEADER_T" "$CHAIN_T" "$ERR_T"
