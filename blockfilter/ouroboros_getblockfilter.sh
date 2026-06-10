#!/usr/bin/env bash
#
# ouroboros_getblockfilter.sh — self-contained getblockfilter Core-parity test.
#
# Proves ouroboros computes BIP 157/158 COMPACT BLOCK FILTERS (the
# getblockfilter RPC) BYTE-IDENTICALLY to a REAL bitcoind oracle — not just
# that it reports index status. This is the SUBSTANTIVE indexing cell: the
# basic filter (type 0x00) GCS encoding, the SipHash key derivation, the
# hash-to-range reduction, the Golomb-Rice bitstream, AND the BIP 157 filter
# header chaining must ALL match Core exactly.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:2956-3031 (getblockfilter) +
#           src/blockfilter.cpp + src/blockfilter.h (BlockFilter / GCSFilter).
#   SIGNATURE: getblockfilter "blockhash" ( "filtertype" ). filtertype
#     default "basic".
#   OUTPUT (object): { "filter": <hex GCS>, "header": <hex 32-byte> }.
#     - filter = CompactSize(N) + Golomb-Rice bitstream, P=19, M=784931,
#       SipHash-2-4 key = first 16 bytes of the block HASH (internal/LE),
#       element -> FastRange64(SipHash(element), N*M); sorted; deltas coded.
#       ELEMENTS: each output scriptPubKey (except empty + OP_RETURN) PLUS
#       each NON-coinbase spent-prevout scriptPubKey (except empty); deduped.
#     - header = dSHA256( dSHA256(rawFilterBytes) || prevBlockFilterHeader ),
#       chained off the PARENT block's basic-filter header (zero for the
#       genesis parent).
#   ERRORS: unknown filtertype -> RPC_INVALID_ADDRESS_OR_KEY (-5)
#             "Unknown filtertype";
#           filter index not enabled -> RPC_MISC_ERROR (-1)
#             "Index is not enabled for filtertype basic";
#           block not found -> -5 "Block not found".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest +
#   OWN ports, launched -listen=0 -blockfilterindex=basic. Core is the MINER:
#   it mines coinbase-only blocks AND a block containing a SPEND tx (so the
#   filter has both an output spk AND a spent-prevout spk -> a non-trivial
#   multi-element filter). ouroboros then REPLAYS Core's EXACT raw blocks via
#   submitblock, so the two chains are BYTE-IDENTICAL at every height and the
#   filters/headers compare byte-exact. ouroboros runs --blockfilterindex.
#
# ASSERTIONS (both nodes, same block hashes):
#   1. FILTER  : getblockfilter <hash> basic .filter hex byte-EXACT vs Core
#                for a coinbase-only block (1-element filter) AND a block
#                containing a spend (multi-element filter).
#      HEADER  : .header hex byte-EXACT vs Core for the same blocks.
#   2. CHAIN   : the header at height N chains from N-1, verified byte-exact
#                vs Core across >= 3 consecutive blocks (catches a wrong
#                prev-header link).
#   3. ERRORS  : getblockfilter <hash> bogustype -> -5 "Unknown filtertype";
#                getblockfilter <unknown-hash> basic -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors blockheader/ouroboros_getblockheader.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER ouroboros: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER ouroboros: FAIL <short reason>
#   SKIP: GETBLOCKFILTER ouroboros: SKIP <no filter index>
#
# Touches ONLY /tmp/gbf-ouroboros/ + /tmp/gbf-core/ and ports
#   22132/22152 (ouroboros RPC/P2P) + 22134/22154 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. A live
#   mainnet bitcoind may be running — this script frees ONLY its OWN fixed
#   ports / scratch dir, never broad-pkills bitcoind by name.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
OURO_DIR="$BASEDIR/ouroboros"
OURO_PY="$OURO_DIR/.venv/bin/python3"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/address)

OU_DATADIR="/tmp/gbf-ouroboros"
OU_RPC=22132
OU_P2P=22152
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/gbf-core"
CORE_RPC=22134
CORE_P2P=22154
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=101        # mature block-1's coinbase (matures at height 101) for the spend

# Three DISTINCT deterministic regtest p2wpkh keys, so the spend block's
# filter is a genuine MULTI-element set: coinbase output spk + spend output
# spk + spent-prevout spk are three DIFFERENT scriptPubKeys (had they shared
# an address, BIP 158 dedup would collapse them to N=1).
SECRET_MINE="1111111111111111111111111111111111111111111111111111111111111112"
SECRET_DEST="2222222222222222222222222222222222222222222222222222222222222223"
SECRET_CB2="3333333333333333333333333333333333333333333333333333333333333334"

OU_PID=""
OU_COOKIE=""
CORE_BG=""
MINE_ADDR=""; MINE_WIF=""; MINE_SPK=""
DEST_ADDR=""; DEST_SPK=""
CB2_ADDR=""
SPEND_HEIGHT=""    # height of the block that contains the spend tx

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockfilter:ouroboros] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
    fi
    pkill -f "gbf-ouroboros" 2>/dev/null || true
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETBLOCKFILTER ouroboros: PASS filter=$1 header=$2 chain=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETBLOCKFILTER ouroboros: FAIL $*"
    exit 1
}
skip() {
    echo "GETBLOCKFILTER ouroboros: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gbf-ouroboros" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${OU_RPC}/${OU_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$OU_DATADIR" "$CORE_DATADIR"
mkdir -p "$OU_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$OURO_PY" ]]                  || OURO_PY="python3"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros cli.py not found under $OURO_DIR"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 1b. Derive 3 deterministic regtest p2wpkh (addr, WIF, scriptPubKey). ──
# This bitcoind build has NO wallet support (createwallet -> -32601), so we
# derive keys via Core's test_framework and build/sign the spend ourselves.
derive_key() {  # <secret-hex> -> "addr wif scriptPubKey-hex"
    python3 -c "
import sys, hashlib
sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
from test_framework.wallet_util import bytes_to_wif
k=ECKey(); k.set(bytes.fromhex('$1'), compressed=True)
pk=k.get_pubkey().get_bytes()
h160=hashlib.new('ripemd160', hashlib.sha256(pk).digest()).digest()
print(key_to_p2wpkh(pk, main=False), bytes_to_wif(k.get_bytes(), compressed=True), '0014'+h160.hex())
" 2>/dev/null
}
read -r MINE_ADDR MINE_WIF MINE_SPK <<<"$(derive_key "$SECRET_MINE")"
read -r DEST_ADDR _DEST_WIF DEST_SPK <<<"$(derive_key "$SECRET_DEST")"
read -r CB2_ADDR _CB2_WIF _CB2_SPK   <<<"$(derive_key "$SECRET_CB2")"
[[ "$MINE_ADDR" == bcrt1* && "$DEST_ADDR" == bcrt1* && "$CB2_ADDR" == bcrt1* ]] \
    || fail "could not derive deterministic regtest addresses (test_framework import failed)"
log "mine=$MINE_ADDR dest=$DEST_ADDR cb2=$CB2_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_cli_retry: tolerant of the bitcoin-cli .cookie read race.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# core_first_tx <blockhash> -> the txid of the first (coinbase) tx in a block.
core_first_tx() {
    local blk
    blk=$(core_cli_retry getblock "$1" 1) || return 1
    jpy "$blk" "d['tx'][0]"
}

# ou_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
ou_rpc() {
    curl -s --max-time 90 -u "$OU_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$OU_RPC/" 2>/dev/null
}

# jpy <json> <expr>   (expr references parsed object as `d`); empty on error.
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 2. Launch the Core regtest oracle (-listen=0; RPC-only; filter index). ─
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
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -blockfilterindex=basic -fallbackfee=0.0002 \
        >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle rpc=:$CORE_RPC -listen=0 -blockfilterindex=basic (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch ouroboros on regtest (unique ports, --blockfilterindex). ────
log "launching ouroboros (regtest) rpc=:$OU_RPC p2p=:$OU_P2P --blockfilterindex -> $OU_LOG"
(
    cd "$OURO_DIR"
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$OU_DATADIR" \
        start --force --nolisten --nodnsseed --blockfilterindex \
        --rpc-port "$OU_RPC" --p2p-port "$OU_P2P"
) >"$OU_LOG" 2>&1 &
OU_PID=$!

# ouroboros (Python) — generous (>=90s) RPC-startup wait.
ou_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < ou_deadline )); do
    if [[ -z "$OU_COOKIE" ]]; then
        for c in "$OU_DATADIR/.cookie" "$OU_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && OU_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$OU_COOKIE" ]]; then
        echo "$(ou_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$OU_PID" 2>/dev/null || { tail -n 30 "$OU_LOG" >&2 2>/dev/null || true; fail "ouroboros exited during startup (see $OU_LOG)"; }
    sleep 2
done
[[ -n "$OU_COOKIE" ]] || fail "ouroboros cookie never appeared within 120s"
echo "$(ou_rpc getblockcount '[]')" | grep -q '"result"' || fail "ouroboros RPC never responded within 120s"
log "ouroboros RPC ready"

# ── 4b. Confirm ouroboros actually has the basic block filter index on. ───
# If --blockfilterindex silently no-op'd, getblockfilter must error -1; we
# detect that here and SKIP rather than emit confusing filter mismatches.
GII_ENV=$(ou_rpc getindexinfo '[]')
if echo "$GII_ENV" | grep -q '"result"'; then
    HAS_BFI=$(jpy "$GII_ENV" "'basic block filter index' in (d.get('result') or {})")
    if [[ "$HAS_BFI" != "true" ]]; then
        log "ouroboros getindexinfo does not report a basic block filter index"
        skip "no filter index (getindexinfo missing 'basic block filter index')"
    fi
fi

# ── 5. Mine NBLOCKS to mature coinbase; build+mine a SPEND block; REPLAY. ──
# No-wallet build: this bitcoind has wallet RPCs disabled, so we mine to a
# key WE control, then craft + sign the spend ourselves and mine it with
# generateblock (coinbase to a THIRD key, so coinbase-spk / spend-output-spk
# / spent-prevout-spk are three DISTINCT elements -> a genuine multi-element
# filter, not deduped to N=1).
log "mining $NBLOCKS blocks to $MINE_ADDR on Core (matures coinbase for a spend)"
core_cli_retry generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"

# The matured coinbase of block 1 (P2WPKH to MINE) is the spend's input.
CB_SPEND_HASH=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
CB_SPEND_TXID=$(core_first_tx "$CB_SPEND_HASH") || fail "Core could not read block-1 coinbase txid"
[[ -n "$CB_SPEND_TXID" ]] || fail "empty block-1 coinbase txid"

# Build raw tx: spend that coinbase (50 BTC) -> 49.999 to DEST (distinct spk).
SPEND_RAW=$(core_cli_retry createrawtransaction \
    "[{\"txid\":\"$CB_SPEND_TXID\",\"vout\":0}]" \
    "[{\"$DEST_ADDR\":49.999}]") || fail "Core createrawtransaction failed"
SPEND_SIGNED_ENV=$(core_cli_retry signrawtransactionwithkey "$SPEND_RAW" \
    "[\"$MINE_WIF\"]" \
    "[{\"txid\":\"$CB_SPEND_TXID\",\"vout\":0,\"scriptPubKey\":\"$MINE_SPK\",\"amount\":50.0}]") \
    || fail "Core signrawtransactionwithkey failed"
SPEND_COMPLETE=$(jpy "$SPEND_SIGNED_ENV" "d.get('complete')")
[[ "$SPEND_COMPLETE" == "true" ]] || fail "spend tx did not sign completely: $SPEND_SIGNED_ENV"
SPEND_TX=$(jpy "$SPEND_SIGNED_ENV" "d['hex']")
[[ -n "$SPEND_TX" ]] || fail "empty signed spend tx hex"

# Mine the spend into a block whose coinbase pays a THIRD distinct address.
log "mining the spend block (coinbase -> $CB2_ADDR, +1 spend tx) via generateblock"
GB_ENV=$(core_cli_retry generateblock "$CB2_ADDR" "[\"$SPEND_TX\"]") \
    || fail "Core generateblock (spend block) failed"
SPEND_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount failed"

# Mine a few trailing blocks so the spend block is not the tip (lets us probe
# a coinbase-only block AFTER the spend and exercise the header chain).
core_cli_retry generatetoaddress 3 "$MINE_ADDR" >/dev/null \
    || fail "Core generatetoaddress (trailing) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount failed"
log "Core height=$CORE_HEIGHT, spend at height=$SPEND_HEIGHT"

# Sanity: the spend block must actually contain >1 tx (coinbase + spend).
SPEND_HASH=$(core_cli_retry getblockhash "$SPEND_HEIGHT") || fail "Core getblockhash(spend) failed"
SPEND_BLK=$(core_cli_retry getblock "$SPEND_HASH" 1) || fail "Core getblock(spend) failed"
SPEND_NTX=$(jpy "$SPEND_BLK" "len(d['tx'])")
[[ "$SPEND_NTX" -ge 2 ]] || fail "spend block has nTx=$SPEND_NTX (<2); spend did not confirm there"
# Sanity: Core's own spend filter must be genuinely multi-element (N >= 2).
SPEND_FOBJ=$(core_cli_retry getblockfilter "$SPEND_HASH" basic) || fail "Core getblockfilter(spend) failed"
SPEND_N=$(jpy "$SPEND_FOBJ" "int(d['filter'][:2],16)")
[[ "${SPEND_N:-0}" -ge 2 ]] || fail "Core spend filter N=$SPEND_N (<2); elements collapsed (addresses not distinct?)"
log "spend block nTx=$SPEND_NTX, Core filter element count N=$SPEND_N"

log "replaying Core's $CORE_HEIGHT raw blocks into ouroboros via submitblock"
for ((h=1; h<=CORE_HEIGHT; h++)); do
    BH=$(core_cli_retry getblockhash "$h") || fail "Core getblockhash $h failed"
    RAW=$(core_cli_retry getblock "$BH" 0) || fail "Core getblock $BH 0 failed"
    [[ -n "$RAW" ]] || fail "Core returned empty raw block at height $h"
    SUB_ENV=$(ou_rpc submitblock "[\"$RAW\"]")
    echo "$SUB_ENV" | grep -q '"result"' || fail "ouroboros submitblock errored at height $h: $SUB_ENV"
    SUB_RES=$(jpy "$SUB_ENV" "d.get('result')")
    if [[ -n "$SUB_RES" && "$SUB_RES" != "None" ]]; then
        fail "ouroboros rejected Core block at height $h: '$SUB_RES'"
    fi
done
OU_HEIGHT=$(jpy "$(ou_rpc getblockcount '[]')" "d['result']")
[[ "$OU_HEIGHT" == "$CORE_HEIGHT" ]] || fail "ouroboros height after replay is $OU_HEIGHT, expected $CORE_HEIGHT"

# Give the Python filter index a moment to finish its off-thread add_block
# for the last connected block (block-connect hook is best-effort/async).
sleep 2

# Byte-identical chains => hash-at-height matches Core exactly.
CHECK_HASH=$(core_cli_retry getblockhash "$SPEND_HEIGHT")
OU_CHECK_HASH=$(jpy "$(ou_rpc getblockhash "[$SPEND_HEIGHT]")" "d['result']")
[[ "$OU_CHECK_HASH" == "$CHECK_HASH" ]] \
    || fail "spend-height hash mismatch ou=$OU_CHECK_HASH core=$CHECK_HASH (replay diverged)"

# ── 6. compare_at <height> <tag>  — byte-exact filter+header vs Core. ──────
# Returns 0 if both match, 1 otherwise; sets globals MATCH_FILTER/MATCH_HEADER.
compare_at() {
    local h="$1" tag="$2"
    local bh c_filter c_header o_env o_filter o_header
    bh=$(core_cli_retry getblockhash "$h") || { log "core getblockhash $h failed"; return 1; }

    # Core ground truth.
    local c_obj
    c_obj=$(core_cli_retry getblockfilter "$bh" basic) || { log "core getblockfilter $bh failed"; return 1; }
    c_filter=$(jpy "$c_obj" "d['filter']")
    c_header=$(jpy "$c_obj" "d['header']")
    [[ "$c_filter" =~ ^[0-9a-f]+$ ]] || { log "core filter not hex at h=$h ($tag): '$c_filter'"; return 1; }
    [[ "$c_header" =~ ^[0-9a-f]{64}$ ]] || { log "core header not 64-hex at h=$h ($tag): '$c_header'"; return 1; }

    # ouroboros.
    o_env=$(ou_rpc getblockfilter "[\"$bh\", \"basic\"]")
    echo "$o_env" | grep -q '"result"' || { log "ouroboros getblockfilter errored at h=$h ($tag): $o_env"; return 1; }
    o_filter=$(jpy "$o_env" "d['result']['filter']")
    o_header=$(jpy "$o_env" "d['result']['header']")

    local ok=0
    if [[ "$o_filter" != "$c_filter" ]]; then
        log "FILTER mismatch h=$h ($tag): core=$c_filter ouro=$o_filter"; ok=1
    fi
    if [[ "$o_header" != "$c_header" ]]; then
        log "HEADER mismatch h=$h ($tag): core=$c_header ouro=$o_header"; ok=1
    fi
    [[ "$ok" == "0" ]] && log "OK h=$h ($tag): filter+header byte-exact (filterlen=${#c_filter})"
    return $ok
}

FILTER_T="ok"
HEADER_T="ok"
CHAIN_T="ok"

# ── 7. CASE 1 — coinbase-only block (1-element filter) + spend block. ──────
# A coinbase-only block AFTER the spend (height = SPEND_HEIGHT+2 is coinbase
# only). Its filter has exactly the coinbase output spk (1 element).
CB_HEIGHT=$(( SPEND_HEIGHT + 2 ))
if ! compare_at "$CB_HEIGHT" "coinbase-only"; then
    FILTER_T="bad"; HEADER_T="bad"
fi

# The spend block: filter has the coinbase output spk + the spend output spk
# AND the spent-prevout spk -> a non-trivial MULTI-element filter (N=$SPEND_N
# confirmed above). This is the load-bearing case: byte-exactness here proves
# ouroboros includes spent-prevout scriptPubKeys looked up from undo/UTXO data.
if ! compare_at "$SPEND_HEIGHT" "spend(N=$SPEND_N multi-element)"; then
    FILTER_T="bad"; HEADER_T="bad"
fi

# ── 8. CASE 2 — HEADER CHAINING across >= 3 consecutive blocks. ───────────
# Compare the header byte-exact vs Core at SPEND_HEIGHT-1, SPEND_HEIGHT,
# SPEND_HEIGHT+1 — a wrong prev-header link breaks the chain from the spend
# block onward, which these consecutive checks catch.
for h in $(( SPEND_HEIGHT - 1 )) "$SPEND_HEIGHT" $(( SPEND_HEIGHT + 1 )); do
    bh=$(core_cli_retry getblockhash "$h") || { CHAIN_T="bad"; log "chain: core getblockhash $h failed"; continue; }
    c_hdr=$(jpy "$(core_cli_retry getblockfilter "$bh" basic)" "d['header']")
    o_hdr=$(jpy "$(ou_rpc getblockfilter "[\"$bh\", \"basic\"]")" "d['result']['header']")
    if [[ "$o_hdr" != "$c_hdr" ]]; then
        CHAIN_T="bad"; log "chain header mismatch at h=$h: core=$c_hdr ouro=$o_hdr"
    else
        log "chain OK h=$h: header byte-exact ($o_hdr)"
    fi
done

# Independent re-derivation: ouroboros header(N) MUST equal
# dSHA256( dSHA256(filter_N) || header_{N-1} ) using ouroboros's OWN bytes.
# This catches a header that happens to match Core by luck but is internally
# inconsistent with the node's own filter/prev-header.
#
# NOTE on byte order: getblockfilter returns the 32-byte filter header in
# DISPLAY (big-endian) order, matching Core's uint256::GetHex().  The BIP 157
# chaining rule operates on INTERNAL (little-endian) bytes, so we reverse the
# reported headers to internal order, chain, then reverse back to display
# order before comparing.  The GCS `filter` field is a raw byte vector and is
# NOT reversed.
CHAIN_DERIVE=$(python3 -c "
import sys, json, hashlib, urllib.request, base64
def d2(b): return hashlib.sha256(hashlib.sha256(b).digest()).digest()
cookie='$OU_COOKIE'; rpc='http://127.0.0.1:$OU_RPC/'
def call(method, params):
    body=json.dumps({'jsonrpc':'1.0','id':1,'method':method,'params':params}).encode()
    req=urllib.request.Request(rpc, data=body)
    req.add_header('Authorization','Basic '+base64.b64encode(cookie.encode()).decode())
    return json.load(urllib.request.urlopen(req, timeout=90))['result']
h=$SPEND_HEIGHT
bh   = call('getblockhash',[h])
bhm1 = call('getblockhash',[h-1])
gf   = call('getblockfilter',[bh,'basic'])
gfm1 = call('getblockfilter',[bhm1,'basic'])
filt   = bytes.fromhex(gf['filter'])                 # raw, forward
prev_i = bytes.fromhex(gfm1['header'])[::-1]         # display -> internal
derived_display = d2(d2(filt)+prev_i)[::-1].hex()    # internal -> display
print('MATCH' if derived_display==gf['header'] else 'MISMATCH derived=%s reported=%s'%(derived_display,gf['header']))
" 2>/dev/null)
if [[ "$CHAIN_DERIVE" != "MATCH" ]]; then
    CHAIN_T="bad"; log "self-consistent header derivation failed: $CHAIN_DERIVE"
else
    log "self-consistent header derivation OK (dSHA256(dSHA256(filter)||prev_header))"
fi

# ── 9. CASE 3 — ERRORS. ───────────────────────────────────────────────────
ERRORS_T="ok"

# 9a. bogus filtertype -> -5 "Unknown filtertype".
E_BOGUS=$(jpy "$(ou_rpc getblockfilter "[\"$SPEND_HASH\", \"bogustype\"]")" "d['error']['code']")
[[ "$E_BOGUS" == "-5" ]] || { ERRORS_T="bad"; log "bogus filtertype: expected -5, got '$E_BOGUS'"; }
E_BOGUS_MSG=$(jpy "$(ou_rpc getblockfilter "[\"$SPEND_HASH\", \"bogustype\"]")" "d['error']['message']")
echo "$E_BOGUS_MSG" | grep -qi "Unknown filtertype" || { ERRORS_T="bad"; log "bogus filtertype message not 'Unknown filtertype': '$E_BOGUS_MSG'"; }

# 9b. unknown blockhash -> -5 ("Block not found").
ERR_BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E_UNK=$(jpy "$(ou_rpc getblockfilter "[\"$ERR_BAD_HASH\", \"basic\"]")" "d['error']['code']")
[[ "$E_UNK" == "-5" ]] || { ERRORS_T="bad"; log "unknown blockhash: expected -5, got '$E_UNK'"; }

# Cross-check Core surfaces -5 on both error cases (oracle sanity).
CORE_E_BOGUS=$(core_cli getblockfilter "$SPEND_HASH" bogustype 2>&1 | grep -oE '\-5' | head -1)
[[ "$CORE_E_BOGUS" == "-5" ]] || log "(note) Core bogus-filtertype did not surface -5 via CLI text; relying on documented behaviour"
CORE_E_UNK=$(core_cli getblockfilter "$ERR_BAD_HASH" basic 2>&1 | grep -oE '\-5' | head -1)
[[ "$CORE_E_UNK" == "-5" ]] || log "(note) Core unknown-hash did not surface -5 via CLI text; relying on documented behaviour"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
[[ "$FILTER_T" == "ok" ]] || fail "filter bytes not byte-exact vs Core (see log)"
[[ "$HEADER_T" == "ok" ]] || fail "filter header not byte-exact vs Core (see log)"
[[ "$CHAIN_T"  == "ok" ]] || fail "header chaining not byte-exact vs Core (see log)"
[[ "$ERRORS_T" == "ok" ]] || fail "error-code parity check failed (see log)"

log "PASS: ouroboros getblockfilter matches Core (filter + header + chain + errors)"
pass "$FILTER_T" "$HEADER_T" "$CHAIN_T" "$ERRORS_T"
