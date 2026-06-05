#!/usr/bin/env bash
#
# nimrod_getblockfilter.sh — self-contained getblockfilter Core-parity test.
#
# This is a SUBSTANTIVE indexing cell: it proves nimrod computes BIP-158 basic
# compact block filters (the SPV-serving filter set) BYTE-IDENTICALLY to Bitcoin
# Core, plus the BIP-157 chained filter HEADER, exposed via the getblockfilter
# RPC.  Unlike getindexinfo (which only reports index status), this compares the
# actual filter + header bytes against a REAL bitcoind oracle.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:2956-3031 (getblockfilter) +
#   src/blockfilter.cpp (GCSFilter / BlockFilter — the BIP-158 basic filter) +
#   BIP 158 (the Golomb-coded set) + BIP 157 (the chained header).
#   SIGNATURE: getblockfilter "blockhash" ( "filtertype" ). filtertype default
#              "basic".
#   OUTPUT: { "filter": <hex GCS>, "header": <hex 32-byte> }
#     filter = HexStr(GetEncodedFilter())  — raw CompactSize(N)||GCS bytes, NOT
#              byte-reversed.
#     header = uint256::GetHex() of the BIP-157 chained filter header (reversed
#              big-endian display of the SHA256d).
#   ERRORS:
#     unknown filtertype       -> RPC -5  (RPC_INVALID_ADDRESS_OR_KEY) "Unknown filtertype"
#     filter index not enabled -> RPC -1  (RPC_MISC_ERROR) "Index is not enabled for filtertype basic"
#     block not found          -> RPC -5  "Block not found"
#
# BIP-158 BASIC FILTER (type 0x00) — the element set + encoding Core uses:
#   ELEMENTS: every output scriptPubKey (except empty + OP_RETURN) PLUS every
#     spent-prevout scriptPubKey (from undo) of non-coinbase inputs; deduped.
#   GCS: P=19, M=784931. SipHash-2-4 key = first 16 bytes of the block HASH
#     (k0 = bytes 0..8 LE, k1 = bytes 8..16 LE). Each element -> 64-bit value
#     mapped into [0, N*M) via (hash*range)>>64; sort; Golomb-Rice code the
#     successive deltas with P=19. Encoded = CompactSize(N) || GCS bitstream.
#   HEADER: SHA256d( SHA256d(rawFilterBytes) || prevBlockFilterHeader ), chained
#     from the parent's basic-filter header (all-zero for genesis's parent).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + OWN ports, launched -listen=0 -blockfilterindex=basic.
#   Core mines blocks INCLUDING a real SPEND tx (so at least one block's filter
#   has BOTH an output scriptPubKey AND a spent-prevout scriptPubKey — a
#   non-trivial multi-element filter). nimrod then IMPORTS the byte-identical
#   serialized blocks via submitblock with --blockfilterindex enabled, capturing
#   undo so the spent-prevout scripts enter the filter. The two nodes therefore
#   hold a bit-identical chain block-for-block, so getblockfilter on one MUST be
#   byte-EXACT against the other.
#
# WHAT MUST MATCH CORE EXACTLY:
#   1. FILTER + HEADER byte-exact for an EMPTY/coinbase-only block (1-element
#      filter) AND for a block containing a SPEND (multi-element filter).
#   2. HEADER CHAINING: header[N] chains from header[N-1] — verified byte-exact
#      vs Core across >=3 consecutive blocks (catches a wrong prev-header link).
#   3. ERRORS: bogus filtertype -> -5 "Unknown filtertype"; unknown block hash
#      -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/blockheader/nimrod_getblockheader.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + UNIQUE ports, ONE
#   clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER nimrod: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER nimrod: FAIL <short reason>
#   SKIP: GETBLOCKFILTER nimrod: SKIP <no filter index>
#
# Touches ONLY /tmp/gbf-nimrod/ + /tmp/gbf-core-nimrod/ and ports 40231/40251
#   (nimrod RPC/P2P) + 40233/40253 (Core RPC/P2P). NEVER touches /data/nvme1/
#   or testnet4-data/ or any live node. A live mainnet bitcoind may be running:
#   we NEVER pkill bitcoind by name — only free our OWN fixed ports / scratch.
#   Any `fuser -k` redirects stdout (`>/dev/null 2>&1`).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

# NOTE: this Core build has NO wallet support (createwallet -> Method not found),
# so the SPEND is built WITHOUT a wallet: mine to a known-key P2WPKH address,
# then createrawtransaction + signrawtransactionwithkey (WIF) + sendrawtransaction
# spending a matured coinbase output. All three RPCs are wallet-free.

NR_DATADIR="/tmp/gbf-nimrod"
NR_RPC=40231
NR_P2P=40251
NR_LOG="$NR_DATADIR/node.log"

# Node-unique Core datadir name (sibling getblockfilter harnesses for other
# impls may run concurrently — a shared name causes mutual rm -rf destruction).
CORE_DATADIR="/tmp/gbf-core-nimrod"
CORE_RPC=40233
CORE_P2P=40253
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=130        # mine enough to mature a coinbase (>100) so we can spend
NR_PID=""
NR_COOKIE=""
CORE_BG=""
ADDR=""
DEST_ADDR=""
SPK=""             # p2wpkh scriptPubKey of the mining address (hex)
WIF=""             # regtest WIF private key for signrawtransactionwithkey

# Deterministic test secrets -> one p2wpkh bcrt1 mining address + a destination.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockfilter:nimrod] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$NR_PID" ]] && kill -0 "$NR_PID" 2>/dev/null; then
        kill "$NR_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NR_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NR_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${NR_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${NR_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$NR_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETBLOCKFILTER nimrod: PASS filter=$1 header=$2 chain=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETBLOCKFILTER nimrod: FAIL $*"
    exit 1
}
skip() {
    echo "GETBLOCKFILTER nimrod: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
# NOTE: deliberately NOT `pkill -f bitcoind` — a live mainnet bitcoind may be
# running. Only free our OWN fixed ports + a nimrod proc on our OWN scratch dir.
pkill -f "gbf-nimrod" 2>/dev/null || true
fuser -k "${NR_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${NR_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$NR_DATADIR" "$CORE_DATADIR"
mkdir -p "$NR_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "nimrod binary not found at $NODE_BIN (build with: nimble build -d:release -y)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_cli_retry: tolerant of the bitcoin-cli .cookie read race under concurrent
# fleet load. Up to 8 attempts, 1s apart.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# nr_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
nr_rpc() {
    curl -s --max-time 90 -u "$NR_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$NR_RPC/" 2>/dev/null
}

# jpy <json> <expr>   (expr references parsed object as `d`) -> value or empty.
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

# ── 2. Launch the Core regtest oracle (RPC-only, -listen=0, +filter index). ─
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # -listen=0 (no P2P listener) + -rpcbind=127.0.0.1: the sandbox SIGKILLs any
    # bitcoind that binds a 0.0.0.0 P2P listener ~2s after load; an RPC-only,
    # loopback-bound oracle survives. -blockfilterindex=basic builds the BIP-158
    # index the getblockfilter RPC reads.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -rpcbind=127.0.0.1 -fallbackfee=0.0002 \
        -blockfilterindex=basic >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            if core_cli_retry getblockcount >/dev/null; then
                sleep 4
                kill -0 "$CORE_BG" 2>/dev/null && core_cli getblockcount >/dev/null 2>&1 && return 0
                return 1
            fi
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3 4 5 6; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 6 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Derive deterministic mining + destination keys / addresses / WIF. ──
# No wallet available -> derive everything from fixed secrets via test_framework.
DERIVE=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh, address_to_scriptpubkey, byte_to_base58
def info(secret):
    k=ECKey(); k.set(bytes.fromhex(secret),compressed=True)
    addr=key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False)
    spk=address_to_scriptpubkey(addr).hex()
    wif=byte_to_base58(bytes.fromhex(secret)+b'\x01', 0xEF)   # regtest WIF (compressed)
    return addr, spk, wif
ma, ms, mw = info('$SECRET')
da, ds, dw = info('$DEST_SECRET')
print(ma); print(ms); print(mw); print(da)
" 2>/dev/null) || fail "key derivation failed (Core test_framework import)"
ADDR=$(echo "$DERIVE"      | sed -n '1p')
SPK=$(echo "$DERIVE"       | sed -n '2p')
WIF=$(echo "$DERIVE"       | sed -n '3p')
DEST_ADDR=$(echo "$DERIVE" | sed -n '4p')
[[ "$ADDR" == bcrt1* && "$DEST_ADDR" == bcrt1* ]] || fail "derived addresses bad: mine='$ADDR' dest='$DEST_ADDR'"
[[ "$SPK" =~ ^0014[0-9a-f]{40}$ ]] || fail "derived p2wpkh scriptPubKey bad: '$SPK'"
[[ -n "$WIF" ]] || fail "derived WIF empty"
log "mining address $ADDR (spk=$SPK), dest $DEST_ADDR"

# ── 4. Launch nimrod on regtest WITH the basic block filter index. ────────
log "launching nimrod (regtest, --blockfilterindex) rpc=:$NR_RPC p2p=:$NR_P2P -> $NR_LOG"
"$NODE_BIN" --network=regtest --datadir="$NR_DATADIR" \
    --port="$NR_P2P" --rpcport="$NR_RPC" --blockfilterindex start >"$NR_LOG" 2>&1 &
NR_PID=$!
nr_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < nr_deadline )); do
    if [[ -z "$NR_COOKIE" ]]; then
        for c in "$NR_DATADIR/regtest/.cookie" "$NR_DATADIR/.cookie"; do
            [[ -f "$c" ]] && NR_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$NR_COOKIE" ]]; then
        echo "$(nr_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$NR_PID" 2>/dev/null || { tail -n 20 "$NR_LOG" >&2 2>/dev/null || true; fail "nimrod exited during startup (see $NR_LOG)"; }
    sleep 1
done
[[ -n "$NR_COOKIE" ]] || fail "nimrod cookie never appeared within 120s"
echo "$(nr_rpc getblockcount '[]')" | grep -q '"result"' || fail "nimrod RPC never responded within 120s"
log "nimrod RPC ready"

# If nimrod does not actually run a basic block filter index, getindexinfo will
# not list it — treat as SKIP (the cell is honestly "no filter index").
IDXINFO=$(nr_rpc getindexinfo '[]')
HAS_IDX=$(jpy "$IDXINFO" "'basic block filter index' in d['result']")
if [[ "$HAS_IDX" != "true" ]]; then
    skip "no filter index (getindexinfo: $IDXINFO)"
fi
log "nimrod reports a basic block filter index"

# ── 5. Mine NBLOCKS to the mining address on Core; build + send a SPEND. ──
log "mining $NBLOCKS blocks to $ADDR on Core (matures coinbase for a spend)"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"

# Build a real spend WITHOUT a wallet: spend the height-1 coinbase output (now
# matured, since NBLOCKS > 100) to a fresh address. The spending block's filter
# then includes BOTH the new output scriptPubKey AND the spent-prevout
# scriptPubKey (the coinbase's p2wpkh script).
CB1_HASH=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
CB1_TXID=$(jpy "$(core_cli_retry getblock "$CB1_HASH" 1)" "d['tx'][0]") \
    || fail "could not read height-1 coinbase txid"
[[ -n "$CB1_TXID" && "$CB1_TXID" != "None" ]] || fail "height-1 coinbase txid empty"
log "spending matured coinbase $CB1_TXID:0 (50 BTC) -> $DEST_ADDR"

# createrawtransaction: one input (the coinbase vout 0), one output (49.999 to
# dest, 0.001 fee). version/locktime default.
RAW_UNSIGNED=$(core_cli_retry createrawtransaction \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0}]" \
    "[{\"$DEST_ADDR\":49.999}]") || fail "Core createrawtransaction failed"
[[ -n "$RAW_UNSIGNED" ]] || fail "createrawtransaction returned empty"

# signrawtransactionwithkey: needs the prevout scriptPubKey + amount because the
# input is segwit (p2wpkh). Provide the matching WIF.
SIGN_RESP=$(core_cli_retry signrawtransactionwithkey "$RAW_UNSIGNED" \
    "[\"$WIF\"]" \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0,\"scriptPubKey\":\"$SPK\",\"amount\":50.0}]") \
    || fail "Core signrawtransactionwithkey failed"
SIGNED_OK=$(jpy "$SIGN_RESP" "d.get('complete')")
RAW_SIGNED=$(jpy "$SIGN_RESP" "d.get('hex')")
[[ "$SIGNED_OK" == "true" && -n "$RAW_SIGNED" ]] || fail "signing incomplete: $SIGN_RESP"

# Broadcast the spend (wallet-free sendrawtransaction).
SPEND_TXID=$(core_cli_retry sendrawtransaction "$RAW_SIGNED") \
    || fail "Core sendrawtransaction failed: $(core_cli sendrawtransaction "$RAW_SIGNED" 2>&1)"
[[ -n "$SPEND_TXID" ]] || fail "sendrawtransaction returned empty txid"
log "broadcast spend tx $SPEND_TXID"

# Mine ONE block confirming the spend. This block's filter is the multi-element
# one (output + spent-prevout scripts).
core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null \
    || fail "Core generatetoaddress (confirm spend) failed"
TOTAL=$(( NBLOCKS + 1 ))
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$TOTAL" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $TOTAL"

# The spend confirms in the last-mined block (height TOTAL).
SPEND_HEIGHT="$TOTAL"
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$SPEND_HEIGHT") \
    || fail "could not get spend block hash at height $SPEND_HEIGHT"
[[ -n "$SPEND_BLOCKHASH" ]] || fail "spend block hash empty"
# Verify the spend tx is actually in that block.
SPEND_NTX=$(jpy "$(core_cli_retry getblock "$SPEND_BLOCKHASH" 1)" "len(d.get('tx', []))")
SPEND_IN=$(jpy "$(core_cli_retry getblock "$SPEND_BLOCKHASH" 1)" "'$SPEND_TXID' in d.get('tx', [])")
[[ "$SPEND_IN" == "true" ]] || fail "spend tx $SPEND_TXID not in block $SPEND_BLOCKHASH"
[[ "$SPEND_NTX" =~ ^[0-9]+$ && "$SPEND_NTX" -ge 2 ]] || fail "spend block has only $SPEND_NTX tx (expected >=2)"
log "spend confirmed in block height $SPEND_HEIGHT ($SPEND_BLOCKHASH), nTx=$SPEND_NTX"

# ── 6. Capture EVERYTHING from Core up front (short oracle window). ────────
# The sandbox SIGKILLs bitcoind after a bounded lifetime, so we read every Core
# value we will ever need — raw blocks AND getblockfilter(filter+header) per
# height AND the bogus-filtertype error response — BEFORE the slow nimrod
# submitblock import loop. After this, Core may die; we only compare nimrod
# against the captured files.  Format: "height<TAB>blockhash<TAB>rawhex<TAB>filterhex<TAB>headerhex".
RAWFILE="$NR_DATADIR/core-blocks.tsv"
log "capturing $TOTAL raw blocks + Core getblockfilter results up front"
: > "$RAWFILE"
for ((h=1; h<=TOTAL; h++)); do
    CH=$(core_cli_retry getblockhash "$h")
    [[ -n "$CH" ]] || fail "Core getblockhash $h returned empty"
    RAW=$(core_cli_retry getblock "$CH" 0)
    [[ -n "$RAW" ]] || fail "Core getblock $CH 0 returned empty raw hex"
    GBF=$(core_cli_retry getblockfilter "$CH" basic) \
        || fail "Core getblockfilter $CH basic failed (h=$h)"
    CF=$(jpy "$GBF" "d['filter']")
    CHDR=$(jpy "$GBF" "d['header']")
    [[ -n "$CF" && -n "$CHDR" ]] || fail "Core getblockfilter $CH returned empty filter/header (h=$h)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$h" "$CH" "$RAW" "$CF" "$CHDR" >> "$RAWFILE"
done
[[ "$(wc -l < "$RAWFILE")" == "$TOTAL" ]] || fail "captured $(wc -l < "$RAWFILE") rows, expected $TOTAL"

# Capture Core's bogus-filtertype response too (for the error cross-check),
# while Core is still alive.
CB1_HASH_FOR_ERR=$(core_cli_retry getblockhash 1)
CORE_BOGUS_RESP=$(core_cli getblockfilter "$CB1_HASH_FOR_ERR" bogustype 2>&1 || true)
log "Core bogus-filtertype response: $CORE_BOGUS_RESP"

log "importing $TOTAL Core blocks into nimrod via submitblock (byte-identical chain)"
while IFS=$'\t' read -r h CH RAW CF CHDR; do
    SB=$(nr_rpc submitblock "[\"$RAW\"]")
    SB_RES=$(jpy "$SB" "d.get('result')")
    SB_ERR=$(jpy "$SB" "d.get('error')")
    if [[ -n "$SB_RES" && "$SB_RES" != "None" && "$SB_RES" != "duplicate" ]]; then
        fail "nimrod submitblock height $h rejected: result='$SB_RES' err='$SB_ERR'"
    fi
    if [[ -n "$SB_ERR" && "$SB_ERR" != "None" ]]; then
        fail "nimrod submitblock height $h errored: '$SB_ERR'"
    fi
done < "$RAWFILE"
NR_HEIGHT=$(jpy "$(nr_rpc getblockcount '[]')" "d['result']")
[[ "$NR_HEIGHT" == "$TOTAL" ]] || fail "nimrod height after import is $NR_HEIGHT, expected $TOTAL"

# Confirm the chains are bit-identical at the spend height (import succeeded).
NR_SPEND_HASH=$(jpy "$(nr_rpc getblockhash "[$SPEND_HEIGHT]")" "d['result']")
[[ "$NR_SPEND_HASH" == "$SPEND_BLOCKHASH" ]] || \
    fail "chains diverge at spend height $SPEND_HEIGHT (core=$SPEND_BLOCKHASH nimrod=$NR_SPEND_HASH)"

# Give nimrod's filter index a moment to catch the tip (it indexes on connect,
# but allow generous settle for the heaviest impls / under fleet load).
for _ in $(seq 1 30); do
    NR_II=$(nr_rpc getindexinfo '[]')
    SY=$(jpy "$NR_II" "d['result'].get('basic block filter index', {}).get('synced')")
    BH=$(jpy "$NR_II" "d['result'].get('basic block filter index', {}).get('best_block_height')")
    [[ "$SY" == "true" || "$BH" == "$TOTAL" ]] && break
    sleep 2
done
log "nimrod filter index status: $(nr_rpc getindexinfo '[]')"

# ── Comparison helpers. ────────────────────────────────────────────────────
# nr_gbf <hash> -> "<filterhex>|<headerhex>" from nimrod, or empty on error.
nr_gbf() {
    local resp; resp=$(nr_rpc getblockfilter "[\"$1\", \"basic\"]")
    echo "$resp" | grep -q '"result"' || { echo ""; return 1; }
    local f hdr
    f=$(jpy "$resp" "d['result']['filter']")
    hdr=$(jpy "$resp" "d['result']['header']")
    echo "${f}|${hdr}"
}
# core_row <height> -> the captured TSV row fields via awk (Core is now dead).
# Prints "blockhash<TAB>filter<TAB>header" for the height, or empty.
core_row() { awk -F'\t' -v h="$1" '$1==h{print $2"\t"$4"\t"$5}' "$RAWFILE"; }
core_filter_at() { core_row "$1" | cut -f2; }
core_header_at() { core_row "$1" | cut -f3; }
core_hash_at()   { core_row "$1" | cut -f1; }

# ── 7. TEST 1 — FILTER + HEADER byte-exact: coinbase-only AND spend block. ─
FILTER_T="ok"; HEADER_T="ok"

# (a) Coinbase-only block (1-element filter): height 1 (first mined block).
COINBASE_HEIGHT=1
CB_HASH=$(core_hash_at "$COINBASE_HEIGHT")
CORE_CB_F=$(core_filter_at "$COINBASE_HEIGHT")
CORE_CB_H=$(core_header_at "$COINBASE_HEIGHT")
NR_CB=$(nr_gbf "$CB_HASH") || fail "nimrod getblockfilter(coinbase block) errored: $(nr_rpc getblockfilter "[\"$CB_HASH\", \"basic\"]")"
NR_CB_F="${NR_CB%%|*}";     NR_CB_H="${NR_CB##*|}"
[[ "$CORE_CB_F" =~ ^[0-9a-f]+$ ]] || fail "Core coinbase-block filter not hex: '$CORE_CB_F'"
[[ "$CORE_CB_H" =~ ^[0-9a-f]{64}$ ]] || fail "Core coinbase-block header not 64-hex: '$CORE_CB_H'"
if [[ "$NR_CB_F" != "$CORE_CB_F" ]]; then
    FILTER_T="bad"; log "coinbase-block FILTER mismatch: nimrod='$NR_CB_F' core='$CORE_CB_F'"
fi
if [[ "$NR_CB_H" != "$CORE_CB_H" ]]; then
    HEADER_T="bad"; log "coinbase-block HEADER mismatch: nimrod='$NR_CB_H' core='$CORE_CB_H'"
fi
log "coinbase-block (h=$COINBASE_HEIGHT) filter nimrod=$NR_CB_F core=$CORE_CB_F"

# (b) Spend block (multi-element filter): includes output + spent-prevout scripts.
CORE_SP_F=$(core_filter_at "$SPEND_HEIGHT")
CORE_SP_H=$(core_header_at "$SPEND_HEIGHT")
NR_SP=$(nr_gbf "$SPEND_BLOCKHASH") || fail "nimrod getblockfilter(spend block) errored: $(nr_rpc getblockfilter "[\"$SPEND_BLOCKHASH\", \"basic\"]")"
NR_SP_F="${NR_SP%%|*}";     NR_SP_H="${NR_SP##*|}"
[[ "$CORE_SP_F" =~ ^[0-9a-f]+$ ]] || fail "Core spend-block filter not hex: '$CORE_SP_F'"
if [[ "$NR_SP_F" != "$CORE_SP_F" ]]; then
    FILTER_T="bad"; log "spend-block FILTER mismatch: nimrod='$NR_SP_F' core='$CORE_SP_F'"
fi
if [[ "$NR_SP_H" != "$CORE_SP_H" ]]; then
    HEADER_T="bad"; log "spend-block HEADER mismatch: nimrod='$NR_SP_H' core='$CORE_SP_H'"
fi
log "spend-block (h=$SPEND_HEIGHT) filter nimrod=$NR_SP_F core=$CORE_SP_F"

# The spend block's filter MUST decode to >1 element (CompactSize N > 1) — proves
# it is genuinely multi-element (output + spent-prevout), not a degenerate cell.
SP_N=$(python3 -c "
b=bytes.fromhex('$CORE_SP_F')
n=b[0]                       # CompactSize: first byte < 0xfd is N directly
print(n if n < 0xfd else 'multi')
" 2>/dev/null)
[[ "$SP_N" == "multi" || ( "$SP_N" =~ ^[0-9]+$ && "$SP_N" -ge 2 ) ]] || \
    fail "spend block filter only has N=$SP_N elements (expected >=2 — output + spent prevout)"
log "spend-block filter element count N=$SP_N (multi-element, non-trivial)"

[[ "$FILTER_T" == "ok" ]] || fail "filter byte-parity failed (see log)"
[[ "$HEADER_T" == "ok" ]] || fail "header byte-parity failed (see log)"

# ── 8. TEST 2 — HEADER CHAINING across >=3 consecutive blocks. ────────────
# Verify each nimrod header byte-matches Core AND chains from its predecessor.
# We also independently recompute the chain locally: header[N] =
# SHA256d(SHA256d(filterN) || header[N-1]) — proving nimrod's chaining link is
# the real BIP-157 one (catches a wrong prev-header LINK even if one header
# happened to match).
CHAIN_T="ok"
CHAIN_START=$(( SPEND_HEIGHT - 1 ))
[[ "$CHAIN_START" -ge 1 ]] || CHAIN_START=1
CHAIN_END=$(( CHAIN_START + 2 ))   # 3 consecutive: start, start+1, start+2
[[ "$CHAIN_END" -le "$TOTAL" ]] || { CHAIN_END="$TOTAL"; CHAIN_START=$(( TOTAL - 2 )); }

# Seed the recompute chain with the parent's (CHAIN_START-1) Core header.
PREV_HDR=""
if [[ "$CHAIN_START" -gt 1 ]]; then
    PREV_HDR=$(core_header_at "$(( CHAIN_START - 1 ))")
fi

for ((h=CHAIN_START; h<=CHAIN_END; h++)); do
    HH=$(core_hash_at "$h")
    CHDR=$(core_header_at "$h")
    NG=$(nr_gbf "$HH")   || { CHAIN_T="bad"; log "chain: nimrod gbf failed at h=$h"; break; }
    NF="${NG%%|*}"; NHDR="${NG##*|}"
    # nimrod header must byte-match Core at every height.
    if [[ "$NHDR" != "$CHDR" ]]; then
        CHAIN_T="bad"; log "chain: header mismatch vs Core at h=$h: nimrod='$NHDR' core='$CHDR'"
    fi
    # Independently recompute the BIP-157 chained header from nimrod's filter
    # bytes and the previous header.
    if [[ -n "$PREV_HDR" ]]; then
        EXP_HDR=$(python3 -c "
import hashlib
def d256(b): return hashlib.sha256(hashlib.sha256(b).digest()).digest()
filt=bytes.fromhex('$NF')
prev=bytes.fromhex('$PREV_HDR')[::-1]      # display(BE)->internal(LE)
fh=d256(filt)
hdr=d256(fh+prev)
print(hdr[::-1].hex())                       # internal(LE)->display(BE)
" 2>/dev/null)
        if [[ -n "$EXP_HDR" && "$EXP_HDR" != "$NHDR" ]]; then
            CHAIN_T="bad"
            log "chain: recomputed header != nimrod at h=$h: recomputed='$EXP_HDR' nimrod='$NHDR' (prev='$PREV_HDR')"
        fi
    fi
    PREV_HDR="$NHDR"
done
[[ "$CHAIN_T" == "ok" ]] || fail "header chaining check failed across h=$CHAIN_START..$CHAIN_END (see log)"
log "header chaining byte-exact + locally-recomputed across h=$CHAIN_START..$CHAIN_END"

# ── 9. TEST 3 — ERROR parity. ─────────────────────────────────────────────
ERRORS_T="ok"

# (a) bogus filtertype -> -5 "Unknown filtertype".
BOGUS=$(nr_rpc getblockfilter "[\"$CB_HASH\", \"bogustype\"]")
BCODE=$(jpy "$BOGUS" "d.get('error', {}).get('code')")
BMSG=$(jpy "$BOGUS" "d.get('error', {}).get('message')")
if [[ "$BCODE" != "-5" ]]; then
    ERRORS_T="bad"; log "bogus filtertype: code='$BCODE' (want -5), msg='$BMSG'"
fi
if [[ "$BMSG" != *"Unknown filtertype"* ]]; then
    ERRORS_T="bad"; log "bogus filtertype message != 'Unknown filtertype': '$BMSG'"
fi
# Cross-check the Core response captured up front agrees (-5 / "Unknown filtertype").
[[ "$CORE_BOGUS_RESP" == *"Unknown filtertype"* ]] || \
    log "WARN: Core bogus-filtertype response did not mention 'Unknown filtertype': $CORE_BOGUS_RESP"

# (b) unknown block hash -> -5.
UNKHASH="00000000000000000000000000000000000000000000000000000000deadbeef"
UNK=$(nr_rpc getblockfilter "[\"$UNKHASH\", \"basic\"]")
UCODE=$(jpy "$UNK" "d.get('error', {}).get('code')")
UMSG=$(jpy "$UNK" "d.get('error', {}).get('message')")
if [[ "$UCODE" != "-5" ]]; then
    ERRORS_T="bad"; log "unknown blockhash: code='$UCODE' (want -5), msg='$UMSG'"
fi
[[ "$ERRORS_T" == "ok" ]] || fail "error-parity check failed (see log)"
log "error parity OK (bogus filtertype -> -5 'Unknown filtertype'; unknown hash -> -5)"

# ── 10. All checks passed. ────────────────────────────────────────────────
pass "ok" "ok" "ok" "ok"
