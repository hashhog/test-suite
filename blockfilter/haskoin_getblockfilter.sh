#!/usr/bin/env bash
#
# haskoin_getblockfilter.sh — self-contained getblockfilter Core-parity test.
#
# BIP-157/158 COMPACT BLOCK FILTERS — the highest-leverage SUBSTANTIVE indexing
# cell. This proves haskoin computes the BIP-158 basic block filter
# BYTE-IDENTICALLY to Bitcoin Core (not just that it reports index status):
# the GCS-encoded filter bytes AND the chained BIP-157 filter header must match
# Core for the SAME chain.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:2956-3030 (getblockfilter)
#   bitcoin-core/src/blockfilter.{h,cpp} (BlockFilter / GCSFilter, BIP158)
#   SIGNATURE: getblockfilter "blockhash" ( "filtertype" ). filtertype default "basic".
#   OUTPUT (object): { "filter": <hex GCS bytes>, "header": <hex 32-byte header> }.
#   ERRORS:
#     unknown filtertype       -> -5 (RPC_INVALID_ADDRESS_OR_KEY) "Unknown filtertype"
#     filter index not enabled -> -1 (RPC_MISC_ERROR) "Index is not enabled ..."
#     block not found          -> -5 (RPC_INVALID_ADDRESS_OR_KEY) "Block not found"
#
# BIP-158 basic filter (type 0x00) element set + encoding:
#   ELEMENTS: every output scriptPubKey EXCEPT empty + OP_RETURN; PLUS for every
#     non-coinbase input the prevout scriptPubKey (from undo data); deduped.
#   GCS: P=19, M=784931. SipHash-2-4 key = first 16 bytes of the block HASH
#     (k0 = bytes 0..8 LE, k1 = 8..16 LE). hash-to-range via (h*N*M)>>64. Sort
#     ascending, Golomb-Rice code the successive deltas (P=19). Encoded filter =
#     CompactSize(N) || GCS bitstream.
#   HEADER (BIP157): SHA256d( SHA256d(rawFilterBytes) || prevFilterHeader );
#     prevFilterHeader = parent block's basic-filter header (0..0 for genesis).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + OWN ports, launched -listen=0 -blockfilterindex=basic.
#   Core mines a chain that INCLUDES A SPEND tx (so a real multi-element filter
#   with BOTH an output scriptPubKey AND a spent-prevout scriptPubKey exists),
#   then we FEED Core's exact block bytes to haskoin via submitblock so BOTH
#   nodes hold the BYTE-IDENTICAL chain. haskoin runs --blockfilterindex.
#
# WHAT THE TEST ASSERTS (on BOTH nodes, same block hashes):
#   1. FILTER+HEADER byte-EXACT vs Core for:
#        - an empty/coinbase-only block (1-element filter), AND
#        - a block containing a spend (multi-element filter).
#   2. HEADER CHAINING: header at height N chains from N-1, bytes matching Core
#      across >=3 consecutive blocks (catches a wrong prev-header link).
#   3. ERRORS: getblockfilter <hash> bogustype -> -5 "Unknown filtertype";
#              getblockfilter <unknown-hash> basic -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/blockheader/haskoin_getblockheader.sh):
#   set -uo pipefail, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER haskoin: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER haskoin: FAIL <short reason>
#   SKIP: GETBLOCKFILTER haskoin: SKIP <no filter index>
#
# Touches ONLY /tmp/gbf-haskoin/ + /tmp/gbf-core/ and ports 22139/22159
#   (haskoin RPC/P2P) + 22141/22161 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node; never
#   broad-pkills bitcoind by name (a live mainnet bitcoind may be running).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
HK_DIR="$BASEDIR/haskoin"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

HK_BIN="$(find "$HK_DIR/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"

export LD_LIBRARY_PATH="/home/work/.local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}"

HK_DATADIR="/tmp/gbf-haskoin"
HK_RPC=22139
HK_P2P=22159
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""
HK_PID=""

CORE_DATADIR="/tmp/gbf-core"
CORE_RPC=22141
CORE_P2P=22161
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

export haskoin_datadir="$HK_DATADIR"

# Deterministic test secret -> one p2wpkh bcrt1 address Core mines to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=130        # >100 so coinbase outputs mature and are spendable.
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockfilter:haskoin] $*" >&2; }

# ── Cleanup: kill OUR nodes + wipe scratch on any exit (no broad pkill). ──
cleanup() {
    local ec=$?
    if [[ -n "$HK_PID" ]] && kill -0 "$HK_PID" 2>/dev/null; then
        kill "$HK_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HK_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HK_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$HK_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETBLOCKFILTER haskoin: PASS filter=$1 header=$2 chain=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETBLOCKFILTER haskoin: FAIL $*"
    exit 1
}
skip() {
    echo "GETBLOCKFILTER haskoin: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset (only OUR scratch markers + OUR ports). ───────────
log "resetting scratch state"
pkill -f "gbf-haskoin" >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HK_RPC}/${HK_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$HK_DATADIR" "$CORE_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -n "$HK_BIN" && -x "$HK_BIN" ]]   || fail "haskoin binary not found under $HK_DIR/dist-newstyle (build with: cabal build exe:haskoin)"
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

# ── RPC helpers ───────────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

hk_rpc() {
    curl -s --max-time 90 -u "$HK_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HK_RPC/" 2>/dev/null
}

# jpy <json> <expr>  (expr references parsed object as `d`); errors swallowed.
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

# ── 3. Launch the Core regtest oracle (RPC-only; -listen=0; index=basic). ──
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
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -blockfilterindex=basic -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch haskoin on regtest (RPC-only; --listen=False; filter index). ─
log "launching haskoin (regtest, --blockfilterindex) rpc=:$HK_RPC p2p=:$HK_P2P -> $HK_LOG"
"$HK_BIN" --network Regtest --datadir "$HK_DATADIR" \
    node --rpcport="$HK_RPC" --port="$HK_P2P" --listen=False --metricsport 0 \
    --blockfilterindex \
    >"$HK_LOG" 2>&1 &
HK_PID=$!
hk_deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        hk_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    kill -0 "$HK_PID" 2>/dev/null || { tail -n 20 "$HK_LOG" >&2 2>/dev/null || true; fail "haskoin exited during startup (see $HK_LOG)"; }
    sleep 2
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 180s"
hk_rpc getblockcount '[]' | grep -q '"result"' || fail "haskoin RPC never responded within 180s"
log "haskoin RPC ready"

# Confirm the basic block filter index is actually running; if not -> SKIP.
GII=$(hk_rpc getindexinfo '[]')
HAS_BFI=$(jpy "$GII" "'basic block filter index' in d.get('result', {})")
if [[ "$HAS_BFI" != "true" ]]; then
    log "getindexinfo did not report a basic block filter index: $GII"
    skip "no filter index"
fi
log "haskoin basic block filter index is running"

# ── 5. Build a chain on Core that INCLUDES A SPEND (no wallet needed). ─────
# This Core build is compiled WITHOUT wallet support, so we use Core's
# MiniWallet (RAW_P2PK, deterministic privkey k=1) to mine maturing coinbase
# outputs, create a real signed self-transfer, and mine ONE block (to the
# deterministic non-wallet address) confirming it. That spend block's filter
# then has BOTH an output scriptPubKey AND a spent-prevout scriptPubKey
# (multi-element). Helper drives Core over JSON-RPC (cookie auth).
log "building Core chain with a spend via MiniWallet (coinbase blocks=$NBLOCKS)"
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"
CHAIN_OUT=$(python3 "$(dirname "$0")/build_spend_chain.py" \
    "$TF_PATH" "$CORE_RPC" "$CORE_COOKIE_FILE" "$NBLOCKS" "$ADDR" 2>>"$CORE_LOG") \
    || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "build_spend_chain.py failed (see $CORE_LOG)"; }

TOTAL=$(awk '/^TOTAL /{print $2}'        <<<"$CHAIN_OUT")
SPEND_HEIGHT=$(awk '/^SPEND_HEIGHT /{print $2}' <<<"$CHAIN_OUT")
SPEND_HASH=$(awk '/^SPEND_HASH /{print $2}'     <<<"$CHAIN_OUT")
SPEND_TXID=$(awk '/^SPEND_TXID /{print $2}'     <<<"$CHAIN_OUT")
[[ -n "$TOTAL" && -n "$SPEND_HEIGHT" && -n "$SPEND_HASH" && -n "$SPEND_TXID" ]] \
    || fail "build_spend_chain.py did not return chain coordinates: $CHAIN_OUT"

# Confirm against Core directly (oracle): the spend block must contain the spend.
SB_JSON=$(core_cli_retry getblock "$SPEND_HASH" 1) || fail "Core getblock spend json failed"
SB_HAS_SPEND=$(jpy "$SB_JSON" "'$SPEND_TXID' in d.get('tx', [])")
[[ "$SB_HAS_SPEND" == "true" ]] || fail "spend tx not in expected spend block $SPEND_HASH"
log "Core chain built: height $TOTAL, spend tx $SPEND_TXID confirmed in block $SPEND_HASH (h$SPEND_HEIGHT)"

# ── 6. FEED Core's exact block bytes to haskoin via submitblock. ──────────
log "submitting $TOTAL Core blocks to haskoin via submitblock"
for h in $(seq 1 "$TOTAL"); do
    bh=$(core_cli_retry getblockhash "$h")  || fail "Core getblockhash $h failed"
    raw=$(core_cli_retry getblock "$bh" 0)  || fail "Core getblock $bh 0 failed"
    sb=$(hk_rpc submitblock "[\"$raw\"]")
    err=$(jpy "$sb" "d.get('error')")
    res=$(jpy "$sb" "d.get('result')")
    if [[ -n "$err" && "$err" != "None" ]]; then
        fail "haskoin submitblock rejected block $h (error): $sb"
    fi
    if [[ -n "$res" && "$res" != "None" ]]; then
        fail "haskoin submitblock rejected block $h (result '$res'): $sb"
    fi
done
HK_HEIGHT=$(jpy "$(hk_rpc getblockcount '[]')" "d['result']")
[[ "$HK_HEIGHT" == "$TOTAL" ]] || fail "haskoin height after submitblock is $HK_HEIGHT, expected $TOTAL (chain shape mismatch)"
log "both nodes at height $TOTAL with byte-identical chains"

# Give haskoin's filter index a moment to catch the just-connected blocks.
# (indexManagerConnectBlock runs inline on submitblock, but be generous.)
HK_BFI_HEIGHT=""
for _ in $(seq 1 30); do
    HK_BFI_HEIGHT=$(jpy "$(hk_rpc getindexinfo '["basic block filter index"]')" \
        "d['result']['basic block filter index']['best_block_height']")
    [[ "$HK_BFI_HEIGHT" == "$TOTAL" ]] && break
    sleep 2
done
log "haskoin filter index best_block_height=$HK_BFI_HEIGHT (target $TOTAL)"

# ── helper: fetch (filter, header) from a node for a block hash. ──────────
# Core:    getblockfilter <hash> basic -> {filter, header}
# haskoin: same JSON-RPC.
core_filter() { core_cli_retry getblockfilter "$1" basic; }
hk_filter()   { hk_rpc getblockfilter "[\"$1\", \"basic\"]"; }

cmp_block() {  # cmp_block <hash> <label> -> sets FILTER_T/HEADER_T to bad on mismatch
    local hash="$1" label="$2"
    local cv hv cf hf chf hhf
    cv=$(core_filter "$hash"); [[ -n "$cv" ]] || { FILTER_T=bad; log "$label: Core getblockfilter empty for $hash"; return; }
    hv=$(hk_filter "$hash")
    echo "$hv" | grep -q '"result"' || { FILTER_T=bad; HEADER_T=bad; log "$label: haskoin getblockfilter errored: $hv"; return; }
    cf=$(jpy "$cv" "d['filter']")
    hf=$(jpy "$hv" "d['result']['filter']")
    chf=$(jpy "$cv" "d['header']")
    hhf=$(jpy "$hv" "d['result']['header']")
    if [[ -z "$cf" || -z "$chf" ]]; then FILTER_T=bad; log "$label: Core filter/header empty"; return; fi
    if [[ "$hf" != "$cf" ]]; then
        FILTER_T=bad
        log "$label FILTER MISMATCH @ $hash:"
        log "  core=$cf"
        log "  hask=$hf"
    else
        log "$label filter byte-exact ($cf)"
    fi
    if [[ "$hhf" != "$chf" ]]; then
        HEADER_T=bad
        log "$label HEADER MISMATCH @ $hash:"
        log "  core=$chf"
        log "  hask=$hhf"
    else
        log "$label header byte-exact ($chf)"
    fi
}

# ── 7. FILTER + HEADER byte-exact: coinbase-only block + spend block. ─────
FILTER_T=ok
HEADER_T=ok

# A coinbase-only (1-element) block: any early matured block (e.g. height 5)
# is just a coinbase -> exactly one output scriptPubKey -> single-element filter.
CB_HEIGHT=5
CB_HASH=$(core_cli_retry getblockhash "$CB_HEIGHT") || fail "Core getblockhash $CB_HEIGHT failed"
cmp_block "$CB_HASH" "coinbase-only(h$CB_HEIGHT)"

# Sanity: confirm the coinbase-only block filter has exactly 1 element on Core
# (CompactSize N at the front of the filter bytes; for a coinbase-only block to
# a single p2wpkh-ish output, N should be 1). This guards against the test
# silently degenerating to an empty filter.
CB_FILTER=$(jpy "$(core_filter "$CB_HASH")" "d['filter']")
CB_N=$(python3 -c "print(int('$CB_FILTER'[0:2],16))" 2>/dev/null)
log "coinbase-only filter leading CompactSize N=$CB_N (expect 1)"

# The spend block: multi-element filter (>=1 output scriptPubKey AND the spent
# prevout scriptPubKey from undo data).
cmp_block "$SPEND_HASH" "spend(h$SPEND_HEIGHT)"
SPEND_FILTER=$(jpy "$(core_filter "$SPEND_HASH")" "d['filter']")
SPEND_N=$(python3 -c "print(int('$SPEND_FILTER'[0:2],16))" 2>/dev/null)
log "spend-block filter leading CompactSize N=$SPEND_N (expect >=2, multi-element)"
if [[ -n "$SPEND_N" ]] && (( SPEND_N < 2 )); then
    log "WARNING: spend-block filter has N=$SPEND_N (<2) — not the intended multi-element filter"
fi

[[ "$FILTER_T" == "ok" ]] || fail "filter bytes not byte-exact vs Core (see log)"
[[ "$HEADER_T" == "ok" ]] || fail "filter header not byte-exact vs Core (see log)"

# ── 8. HEADER CHAINING across >=3 consecutive blocks. ─────────────────────
# Check the spend block and its two predecessors (3 consecutive heights). Each
# header must (a) byte-match Core, AND (b) be locally consistent:
#   header(N) == SHA256d( SHA256d(filterBytes(N)) || header(N-1) ).
CHAIN_T=ok
declare -A HDR
declare -A FLT
chain_lo=$(( SPEND_HEIGHT - 2 ))
(( chain_lo < 1 )) && chain_lo=1
for h in $(seq "$chain_lo" "$SPEND_HEIGHT"); do
    hh=$(core_cli_retry getblockhash "$h") || fail "Core getblockhash $h failed"
    cv=$(core_filter "$hh")
    hv=$(hk_filter "$hh")
    echo "$hv" | grep -q '"result"' || { CHAIN_T=bad; log "chain: haskoin getblockfilter errored @ h$h"; break; }
    HDR[$h]=$(jpy "$hv" "d['result']['header']")
    FLT[$h]=$(jpy "$hv" "d['result']['filter']")
     chh=$(jpy "$cv" "d['header']")
    # (a) byte-match Core
    if [[ "${HDR[$h]}" != "$chh" ]]; then
        CHAIN_T=bad
        log "chain: header @ h$h mismatch vs Core: core=$chh hask=${HDR[$h]}"
    fi
done

# (b) local prev-header linkage: header(N) recomputed from filterBytes(N) +
#     haskoin's own header(N-1) must equal haskoin's header(N). This catches a
#     wrong prev-header link even if a single header happened to match Core.
for h in $(seq "$(( chain_lo + 1 ))" "$SPEND_HEIGHT"); do
    prev=$(( h - 1 ))
    recomputed=$(python3 -c "
import hashlib, sys
def d256(b): return hashlib.sha256(hashlib.sha256(b).digest()).digest()
flt = bytes.fromhex('${FLT[$h]}')
# headers are big-endian display hex; convert to internal LE for hashing
prev_hdr_le = bytes.fromhex('${HDR[$prev]}')[::-1]
fh = d256(flt)
hdr = d256(fh + prev_hdr_le)
print(hdr[::-1].hex())
" 2>/dev/null)
    if [[ -z "$recomputed" ]]; then
        CHAIN_T=bad; log "chain: recompute failed @ h$h"; continue
    fi
    if [[ "$recomputed" != "${HDR[$h]}" ]]; then
        CHAIN_T=bad
        log "chain: header @ h$h does NOT chain from h$prev: recomputed=$recomputed got=${HDR[$h]}"
    else
        log "chain: header @ h$h correctly chains from h$prev"
    fi
done

[[ "$CHAIN_T" == "ok" ]] || fail "header chaining check failed (see log)"
log "header chaining verified across >=3 consecutive blocks (matches Core + locally consistent)"

# ── 9. ERRORS. ────────────────────────────────────────────────────────────
ERRORS_T=ok

# 9a. bogus filtertype -> -5 "Unknown filtertype".
E_BOGUS=$(jpy "$(hk_rpc getblockfilter "[\"$SPEND_HASH\", \"bogustype\"]")" "d['error']['code']")
[[ "$E_BOGUS" == "-5" ]] || { ERRORS_T=bad; log "expected -5 for bogus filtertype, got '$E_BOGUS'"; }
# Confirm Core agrees (oracle).
CORE_EBOGUS=$(core_cli getblockfilter "$SPEND_HASH" bogustype 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_EBOGUS" == "-5" ]] || log "note: Core error code for bogus filtertype was '$CORE_EBOGUS' (expected -5)"

# 9b. unknown blockhash -> -5 "Block not found".
RAND_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E_UNK=$(jpy "$(hk_rpc getblockfilter "[\"$RAND_HASH\", \"basic\"]")" "d['error']['code']")
[[ "$E_UNK" == "-5" ]] || { ERRORS_T=bad; log "expected -5 for unknown blockhash, got '$E_UNK'"; }
CORE_EUNK=$(core_cli getblockfilter "$RAND_HASH" basic 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_EUNK" == "-5" ]] || log "note: Core error code for unknown blockhash was '$CORE_EUNK' (expected -5)"

[[ "$ERRORS_T" == "ok" ]] || fail "error-code check failed (see log)"
log "errors: bogus filtertype -> -5, unknown blockhash -> -5 (matches Core)"

# ── 10. All green. ────────────────────────────────────────────────────────
log "PASS: haskoin getblockfilter matches Core (filter bytes + header + chaining + errors)"
pass "$FILTER_T" "$HEADER_T" "$CHAIN_T" "$ERRORS_T"
