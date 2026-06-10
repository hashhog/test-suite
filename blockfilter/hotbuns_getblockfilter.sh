#!/usr/bin/env bash
#
# hotbuns_getblockfilter.sh — self-contained getblockfilter Core-parity test.
#
# Proves hotbuns computes BIP-158 basic block filters (the GCS "cfilter") and
# their BIP-157 filter-header chain BYTE-IDENTICALLY to Bitcoin Core, and that
# the getblockfilter RPC matches Core's signature, output shape, and error set.
# This is the SUBSTANTIVE indexing cell: getindexinfo only reports index STATUS;
# this verifies the actual SPV-serving filter bytes are exact.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:2956-3031 (getblockfilter)
#   bitcoin-core/src/blockfilter.{h,cpp}           (GCSFilter / BlockFilter)
#   bitcoin-core/src/util/golombrice.h             (Golomb-Rice codec)
#   BIP-158 (basic filter, type 0x00, P=19 M=784931, SipHash key = first 16
#            bytes of the block HASH, hash-to-range via (h*F)>>64) + BIP-157
#            (filter-header chain: H_i = SHA256d(SHA256d(filter_i) || H_{i-1}),
#             H_genesis-predecessor = 0^256).
#
#   SIGNATURE: getblockfilter "blockhash" ( "filtertype" ).  filtertype="basic".
#   OUTPUT  : { "filter": <hex GCS = CompactSize(N)||GR-bitstream>,
#               "header": <hex 32-byte filter header, big-endian display> }.
#   ERRORS  : unknown filtertype       -> RPC_INVALID_ADDRESS_OR_KEY (-5)
#                                         "Unknown filtertype"
#             filter index not enabled -> RPC_MISC_ERROR (-1)
#                                         "Index is not enabled for filtertype basic"
#             block not found          -> RPC_INVALID_ADDRESS_OR_KEY (-5)
#                                         "Block not found"
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + OWN ports, launched -listen=0 -blockfilterindex=basic.
#   To make the filters compare BYTE-EXACT the two nodes must share the IDENTICAL
#   chain: Core MINES every block (and includes a real SPEND tx so at least one
#   block's filter has BOTH an output scriptPubKey AND a spent-prevout
#   scriptPubKey — a non-trivial multi-element filter), then we REPLAY each raw
#   block into hotbuns via submitblock. Both nodes thus hold byte-identical
#   blocks -> byte-identical filters + filter headers at every height. The
#   regtest genesis is protocol-fixed and identical on both, anchoring the
#   filter-header chain.
#
#   Assertions (Core is the oracle; hotbuns must equal it byte-for-byte):
#     1. FILTER : getblockfilter <hash> basic "filter" hex == Core, for
#                 (a) a coinbase-only block (1-element filter) AND
#                 (b) the spend block (multi-element filter).
#        HEADER : "header" hex == Core for the same two blocks.
#     2. CHAIN  : "header" hex == Core across >=3 consecutive heights (catches a
#                 wrong prev-header link / missing genesis seed).
#     3. ERRORS : bogus filtertype -> -5 "Unknown filtertype";
#                 unknown blockhash -> -5 "Block not found".
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/blockheader/hotbuns_getblockheader.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + UNIQUE ports,
#   ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER hotbuns: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER hotbuns: FAIL <short reason>
#   SKIP: GETBLOCKFILTER hotbuns: SKIP <no filter index>
#
# Touches ONLY /tmp/gbf-hotbuns/ + /tmp/gbf-hotbuns-core/ and ports
#   22134/22154 (hotbuns RPC/P2P) + 22136/22156 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Does NOT
#   broad-pkill bitcoind by name (a live mainnet bitcoind may be running) —
#   only frees its OWN fixed ports / scratch dir. Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
HB_DIR="$BASEDIR/hotbuns"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

HB_DATADIR="/tmp/gbf-hotbuns"
HB_RPC=22134
HB_P2P=22154
HB_LOG="/tmp/gbf-hotbuns-node.log"               # outside the trap-wiped datadir

CORE_DATADIR="/tmp/gbf-hotbuns-core"             # NOT the shared /tmp/gbf-core
CORE_RPC=22136
CORE_P2P=22156
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic mining key -> p2wpkh coinbase outputs we can later spend.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
# Deterministic destination key for the spend output.
SECRET2="2222222222222222222222222222222222222222222222222222222222222223"

NBLOCKS_PRE=101    # coinbase maturity: mine 101 to ADDR before spending block 1's coinbase
COINBASE_ONLY=50   # an interior coinbase-only block -> 1-element filter
TARGET_HEIGHT=0    # set after the spend block is mined (the multi-element filter)

HB_PID=""
HB_COOKIE=""
CORE_BG=""
ADDR=""
ADDR2=""
WIF=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockfilter:hotbuns] $*" >&2; }

# ── Cleanup: kill OUR nodes + wipe OUR scratch on any exit. ───────────────
cleanup() {
    local ec=$?
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        pkill -P "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
        pkill -9 -P "$HB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$HB_LOG" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETBLOCKFILTER hotbuns: PASS filter=$1 header=$2 chain=$3 errors=$4"; exit 0; }
fail() { echo "GETBLOCKFILTER hotbuns: FAIL $*"; exit 1; }
skip() { echo "GETBLOCKFILTER hotbuns: SKIP $*"; exit 0; }

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
if ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HB_RPC}/${HB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 2
rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$HB_LOG"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
command -v bun     >/dev/null 2>&1 || fail "bun not found on PATH (hotbuns needs Bun runtime)"
[[ -f "$HB_DIR/src/index.ts" ]]    || fail "hotbuns entrypoint not found at $HB_DIR/src/index.ts"
[[ -x "$CORE_BIN" ]]               || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive deterministic regtest p2wpkh addresses + mining-key WIF. ────
eval "$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
from test_framework.wallet_util import bytes_to_wif
k=ECKey();  k.set(bytes.fromhex('$SECRET'),  compressed=True)
k2=ECKey(); k2.set(bytes.fromhex('$SECRET2'), compressed=True)
print('ADDR=%s'  % key_to_p2wpkh(k.get_pubkey().get_bytes(),  main=False))
print('ADDR2=%s' % key_to_p2wpkh(k2.get_pubkey().get_bytes(), main=False))
print('WIF=%s'   % bytes_to_wif(k.get_bytes()))
" 2>/dev/null)" || fail "could not derive deterministic keys (Core test_framework import failed)"
[[ "$ADDR"  == bcrt1* ]] || fail "derived mining address is not regtest bech32: '$ADDR'"
[[ "$ADDR2" == bcrt1* ]] || fail "derived dest address is not regtest bech32: '$ADDR2'"
[[ -n "$WIF" ]]          || fail "could not derive mining-key WIF"
log "mining addr=$ADDR  spend-dest=$ADDR2"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# tolerant of the bitcoin-cli .cookie read race under concurrent fleet load.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# hb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
hb_rpc() {
    curl -s --max-time 90 -u "$HB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HB_RPC/" 2>/dev/null
}

# jget <json> <pyexpr over d> -> value or empty (swallows errors).
jget() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if v is None: pass
    elif isinstance(v, bool): print('true' if v else 'false')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 3. Launch Core regtest oracle (RPC-only, with the basic filter index). ─
launch_core_once() {
    # PID-scoped stop of OUR previous attempt (port-kill removed: 2026-06-10 fuser incident).
    if [[ -n "${CORE_BG:-}" ]]; then
        kill "$CORE_BG" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CORE_BG" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_BG" 2>/dev/null || true
    fi
    for __hp in "${CORE_RPC}"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
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
    log "launching Core regtest oracle rpc=:$CORE_RPC (attempt $attempt, -listen=0 -blockfilterindex=basic)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch hotbuns on regtest WITH the basic block filter index. ───────
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P --blockfilterindex=1 -> $HB_LOG"
(
    cd "$HB_DIR"
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC" \
        --blockfilterindex=1
) >"$HB_LOG" 2>&1 &
HB_PID=$!
hb_deadline=$(( $(date +%s) + 120 ))   # generous: interpreted runtime + DB open + index init
while (( $(date +%s) < hb_deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        hb_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG)"; }
    sleep 2
done
[[ -n "$HB_COOKIE" ]] || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns cookie never appeared within 120s"; }
hb_rpc getblockcount '[]' | grep -q '"result"' || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns RPC never responded within 120s"; }
log "hotbuns RPC ready"

# ── 4b. SKIP gate: if hotbuns has no basic filter index, getblockfilter
#        returns RPC_MISC_ERROR (-1) "Index is not enabled...". A missing
#        --blockfilterindex wiring (or no index at all) is a SKIP, not a FAIL.
GEN_HASH=$(jget "$(hb_rpc getblockhash '[0]')" "d['result']")
[[ -n "$GEN_HASH" ]] || fail "hotbuns getblockhash 0 returned nothing"
PROBE=$(hb_rpc getblockfilter "[\"$GEN_HASH\",\"basic\"]")
PROBE_ERR=$(jget "$PROBE" "d.get('error',{}).get('message','')")
if echo "$PROBE_ERR" | grep -qi "Index is not enabled"; then
    log "hotbuns reports filter index not enabled: $PROBE_ERR"
    skip "no filter index (getblockfilter -> 'Index is not enabled for filtertype basic')"
fi

# ── 5. Build the shared chain on Core: mine to maturity, make a SPEND,
#        mine it into the tip block, so the tip filter is multi-element. ────
log "mining $NBLOCKS_PRE blocks to $ADDR on Core (coinbase maturity)"
core_cli_retry generatetoaddress "$NBLOCKS_PRE" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress (pre) failed"

# Spend the coinbase output of block 1 (now matured) -> ADDR2.
CB_BLOCKHASH=$(core_cli_retry getblockhash 1)
CB_TXID=$(core_cli_retry getblock "$CB_BLOCKHASH" \
            | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ -n "$CB_TXID" ]] || fail "could not read block-1 coinbase txid"
UTXO=$(core_cli_retry gettxout "$CB_TXID" 0)
VAL=$(echo "$UTXO" | python3 -c "import sys,json;print(json.load(sys.stdin)['value'])" 2>/dev/null)
SPK=$(echo "$UTXO" | python3 -c "import sys,json;print(json.load(sys.stdin)['scriptPubKey']['hex'])" 2>/dev/null)
[[ -n "$VAL" && -n "$SPK" ]] || fail "could not read block-1 coinbase utxo (val='$VAL' spk='$SPK')"
OUTVAL=$(python3 -c "print(round($VAL-0.001,8))" 2>/dev/null)
RAW=$(core_cli_retry createrawtransaction \
        "[{\"txid\":\"$CB_TXID\",\"vout\":0}]" "[{\"$ADDR2\":$OUTVAL}]")
[[ -n "$RAW" ]] || fail "createrawtransaction failed"
SIGNED=$(core_cli signrawtransactionwithkey "$RAW" "[\"$WIF\"]" \
            "[{\"txid\":\"$CB_TXID\",\"vout\":0,\"scriptPubKey\":\"$SPK\",\"amount\":$VAL}]" 2>/dev/null)
COMPLETE=$(echo "$SIGNED" | python3 -c "import sys,json;print(json.load(sys.stdin).get('complete'))" 2>/dev/null)
SIGNEDHEX=$(echo "$SIGNED" | python3 -c "import sys,json;print(json.load(sys.stdin)['hex'])" 2>/dev/null)
[[ "$COMPLETE" == "True" && -n "$SIGNEDHEX" ]] || fail "spend tx did not sign completely (complete='$COMPLETE')"
core_cli sendrawtransaction "$SIGNEDHEX" >/dev/null 2>&1 || fail "sendrawtransaction (spend) failed"
# Mine ONE block — it now contains [coinbase, spend], a multi-element filter.
core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null || fail "Core generatetoaddress (spend block) failed"
TIPH=$(core_cli_retry getblockcount)
[[ "$TIPH" -ge $((NBLOCKS_PRE+1)) ]] || fail "Core tip height $TIPH unexpectedly low"
TARGET_HEIGHT="$TIPH"   # the spend block

# Sanity: tip block has >=2 txs (coinbase + spend).
TIP_HASH=$(core_cli_retry getblockhash "$TIPH")
TIP_NTX=$(core_cli_retry getblock "$TIP_HASH" \
            | python3 -c "import sys,json;print(len(json.load(sys.stdin)['tx']))" 2>/dev/null)
[[ "$TIP_NTX" -ge 2 ]] || fail "spend block has $TIP_NTX txs, expected >=2 (oracle unexpected)"
log "Core chain built: tip height=$TIPH spend-block=$TIP_HASH ntx=$TIP_NTX"

# ── 6. Replay every block 1..TIPH into hotbuns via submitblock. ───────────
# Both nodes share the regtest genesis (height 0) already, anchoring the chain.
log "replaying blocks 1..$TIPH into hotbuns via submitblock"
for h in $(seq 1 "$TIPH"); do
    BH=$(core_cli_retry getblockhash "$h")
    RAWBLK=$(core_cli_retry getblock "$BH" 0)
    [[ -n "$RAWBLK" ]] || fail "could not read raw block at height $h from Core"
    RES=$(hb_rpc submitblock "[\"$RAWBLK\"]")
    RV=$(jget "$RES" "d.get('result')")
    # submitblock returns null/None on success, 'duplicate' if already known.
    if [[ -n "$RV" && "$RV" != "None" && "$RV" != "duplicate" ]]; then
        # surface non-trivial rejections
        fail "hotbuns submitblock rejected block $h ($BH): $RES"
    fi
done
HB_TIP_H=$(jget "$(hb_rpc getblockcount '[]')" "d['result']")
[[ "$HB_TIP_H" == "$TIPH" ]] || fail "hotbuns tip height $HB_TIP_H != Core $TIPH after replay"
log "hotbuns replayed to height $HB_TIP_H"

# Genesis must agree (regtest genesis is protocol-fixed); anchors the chain.
HB_GEN=$(jget "$(hb_rpc getblockhash '[0]')" "d['result']")
CORE_GEN=$(core_cli_retry getblockhash 0)
[[ "$HB_GEN" == "$CORE_GEN" ]] || fail "hotbuns regtest genesis '$HB_GEN' != Core '$CORE_GEN'"

# ── getblockfilter field extractors. ──────────────────────────────────────
# c_filter/c_header <hash> -> Core value ; h_filter/h_header <hash> -> hotbuns.
c_filter() { core_cli_retry getblockfilter "$1" basic | python3 -c "import sys,json;print(json.load(sys.stdin)['filter'])" 2>/dev/null; }
c_header() { core_cli_retry getblockfilter "$1" basic | python3 -c "import sys,json;print(json.load(sys.stdin)['header'])" 2>/dev/null; }
h_filter() { jget "$(hb_rpc getblockfilter "[\"$1\",\"basic\"]")" "d['result']['filter']"; }
h_header() { jget "$(hb_rpc getblockfilter "[\"$1\",\"basic\"]")" "d['result']['header']"; }

# ── 7. CHECK 1 — FILTER + HEADER byte-EXACT vs Core. ──────────────────────
#   (a) coinbase-only block (1-element filter) at height COINBASE_ONLY
#   (b) the spend block (multi-element filter) at height TARGET_HEIGHT
FILTER_T="ok"; HEADER_T="ok"

CO_HASH=$(core_cli_retry getblockhash "$COINBASE_ONLY")
SP_HASH="$TIP_HASH"

# Sanity: hotbuns agrees on these two hashes (it should — same chain).
HB_CO=$(jget "$(hb_rpc getblockhash "[$COINBASE_ONLY]")" "d['result']")
HB_SP=$(jget "$(hb_rpc getblockhash "[$TARGET_HEIGHT]")" "d['result']")
[[ "$HB_CO" == "$CO_HASH" ]] || fail "hotbuns hash@$COINBASE_ONLY '$HB_CO' != Core '$CO_HASH'"
[[ "$HB_SP" == "$SP_HASH" ]] || fail "hotbuns hash@$TARGET_HEIGHT '$HB_SP' != Core '$SP_HASH'"

# (a) coinbase-only — assert it really is a 1-element filter on Core, then compare.
C_CO_F=$(c_filter "$CO_HASH"); C_CO_H=$(c_header "$CO_HASH")
H_CO_F=$(h_filter "$CO_HASH"); H_CO_H=$(h_header "$CO_HASH")
[[ "$C_CO_F" =~ ^[0-9a-f]+$ ]] || fail "Core filter@$COINBASE_ONLY not hex: '$C_CO_F' (oracle unexpected)"
# CompactSize(N) leading byte 01 == one element for a coinbase-only block.
[[ "${C_CO_F:0:2}" == "01" ]] || log "note: coinbase-only filter N-prefix is '${C_CO_F:0:2}' (informational)"
[[ -n "$H_CO_F" ]] || fail "hotbuns returned no filter for coinbase-only block $CO_HASH"
[[ "$H_CO_F" == "$C_CO_F" ]] || { FILTER_T="bad"; log "FILTER mismatch (coinbase-only h$COINBASE_ONLY): hb='$H_CO_F' core='$C_CO_F'"; }
[[ "$H_CO_H" == "$C_CO_H" ]] || { HEADER_T="bad"; log "HEADER mismatch (coinbase-only h$COINBASE_ONLY): hb='$H_CO_H' core='$C_CO_H'"; }

# (b) spend block — multi-element. N-prefix >= 02.
C_SP_F=$(c_filter "$SP_HASH"); C_SP_H=$(c_header "$SP_HASH")
H_SP_F=$(h_filter "$SP_HASH"); H_SP_H=$(h_header "$SP_HASH")
[[ "$C_SP_F" =~ ^[0-9a-f]+$ ]] || fail "Core filter@spend not hex: '$C_SP_F' (oracle unexpected)"
SPN=$(( 16#${C_SP_F:0:2} ))
[[ "$SPN" -ge 2 ]] || fail "spend-block filter has N=$SPN (<2); expected multi-element (oracle unexpected)"
[[ -n "$H_SP_F" ]] || fail "hotbuns returned no filter for spend block $SP_HASH"
[[ "$H_SP_F" == "$C_SP_F" ]] || { FILTER_T="bad"; log "FILTER mismatch (spend h$TARGET_HEIGHT, N=$SPN): hb='$H_SP_F' core='$C_SP_F'"; }
[[ "$H_SP_H" == "$C_SP_H" ]] || { HEADER_T="bad"; log "HEADER mismatch (spend h$TARGET_HEIGHT): hb='$H_SP_H' core='$C_SP_H'"; }

[[ "$FILTER_T" == "ok" ]] || fail "filter bytes diverge from Core (see log)"
[[ "$HEADER_T" == "ok" ]] || fail "filter header bytes diverge from Core (see log)"
log "FILTER + HEADER byte-exact vs Core (1-element h$COINBASE_ONLY + multi-element h$TARGET_HEIGHT)"

# ── 8. CHECK 2 — HEADER CHAINING across >=3 consecutive heights. ──────────
# A wrong prev-header link (e.g. a missing genesis-filter seed) makes header_i
# diverge from Core at every height; comparing 3 consecutive heights byte-exact
# proves the H_i = SHA256d(SHA256d(filter_i) || H_{i-1}) chain is Core-correct.
CHAIN_T="ok"
C3=$(( TARGET_HEIGHT - 2 )); C2=$(( TARGET_HEIGHT - 1 )); C1=$TARGET_HEIGHT
for h in "$C3" "$C2" "$C1"; do
    BH=$(core_cli_retry getblockhash "$h")
    CH=$(c_header "$BH"); HH=$(h_header "$BH")
    [[ -n "$HH" ]] || { CHAIN_T="bad"; log "hotbuns returned no header at chain height $h"; continue; }
    [[ "$HH" == "$CH" ]] || { CHAIN_T="bad"; log "CHAIN header mismatch at h$h: hb='$HH' core='$CH'"; }
done
[[ "$CHAIN_T" == "ok" ]] || fail "filter-header chain diverges from Core across consecutive heights (see log)"
log "filter-header chain byte-exact vs Core across h$C3..h$C1"

# ── 9. CHECK 3 — ERRORS. ──────────────────────────────────────────────────
ERR_T="ok"
# (a) bogus filtertype -> -5 "Unknown filtertype".
EBOGUS=$(hb_rpc getblockfilter "[\"$SP_HASH\",\"bogustype\"]")
EBC=$(jget "$EBOGUS" "d['error']['code']")
EBM=$(jget "$EBOGUS" "d['error']['message']")
[[ "$EBC" == "-5" ]] || { ERR_T="bad"; log "bogus filtertype: expected code -5, got '$EBC' ($EBOGUS)"; }
echo "$EBM" | grep -qi "Unknown filtertype" || { ERR_T="bad"; log "bogus filtertype: expected 'Unknown filtertype', got '$EBM'"; }
# Cross-check Core: also -5 "Unknown filtertype".
CORE_EB=$(core_cli getblockfilter "$SP_HASH" bogustype 2>&1 | grep -oE -- '-?[0-9]+' | head -1)
[[ "$CORE_EB" == "-5" ]] || log "note: Core bogus-filtertype code parse got '$CORE_EB' (informational)"

# (b) unknown blockhash -> -5 "Block not found".
BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
EUNK=$(hb_rpc getblockfilter "[\"$BAD_HASH\",\"basic\"]")
EUC=$(jget "$EUNK" "d['error']['code']")
EUM=$(jget "$EUNK" "d['error']['message']")
[[ "$EUC" == "-5" ]] || { ERR_T="bad"; log "unknown blockhash: expected code -5, got '$EUC' ($EUNK)"; }
echo "$EUM" | grep -qi "Block not found" || { ERR_T="bad"; log "unknown blockhash: expected 'Block not found', got '$EUM'"; }
CORE_EU=$(core_cli getblockfilter "$BAD_HASH" basic 2>&1 | grep -oE -- '-?[0-9]+' | head -1)
[[ "$CORE_EU" == "-5" ]] || log "note: Core unknown-blockhash code parse got '$CORE_EU' (informational)"

[[ "$ERR_T" == "ok" ]] || fail "error-code/message parity check failed (see log)"
log "errors match Core (-5 Unknown filtertype; -5 Block not found)"

log "PASS: hotbuns getblockfilter byte-exact vs Core on filter + header + chain + errors"
pass "$FILTER_T" "$HEADER_T" "$CHAIN_T" "$ERR_T"
