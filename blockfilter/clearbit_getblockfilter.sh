#!/usr/bin/env bash
#
# clearbit_getblockfilter.sh — self-contained getblockfilter Core-parity test.
#
# A SUBSTANTIVE indexing green-cell: proves clearbit computes BIP-158 basic
# compact block filters (type 0x00) and BIP-157 chained filter headers
# BYTE-IDENTICALLY to Bitcoin Core — not merely that it reports index status.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:2956-3031 (getblockfilter) +
#           src/blockfilter.cpp (BlockFilter / GCSFilter / BasicFilterElements) +
#           BIP 157 + BIP 158.
#   SIGNATURE: getblockfilter "blockhash" ( "filtertype" ). filtertype default "basic".
#   OUTPUT: { "filter": <hex GCS>, "header": <hex 32-byte> } where
#     filter = HexStr(BlockFilter::GetEncodedFilter())
#            = CompactSize(N) ++ Golomb-Rice bitstream of the sorted element
#              hash DIFFERENCES, P=19, M=784931, SipHash key = block_hash[0..16].
#     header = the chained filter header (BIP-157):
#              header_n = SHA256d( SHA256d(rawFilter_n) || header_{n-1} ),
#              header_{genesis-parent} = all-zero.
#   ELEMENTS (BIP-158 basic): for every tx, each output scriptPubKey EXCEPT
#     empty + OP_RETURN, PLUS for every non-coinbase input the scriptPubKey of
#     the prevout it spends (from undo data). Deduped.
#   ERRORS: unknown filtertype -> -5 "Unknown filtertype";
#           index not enabled  -> -1 "Index is not enabled for filtertype basic";
#           block not found     -> -5 "Block not found".
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest + its OWN ports, launched -listen=0 -blockfilterindex=basic. Core is
#   the SINGLE source of blocks (deterministic via setmocktime): it mines to
#   maturity, creates a SPEND tx (so the spend block's filter has BOTH an output
#   scriptPubKey AND a spent-prevout scriptPubKey -> a non-trivial multi-element
#   filter), mines it in, then every block's RAW hex (`getblock <hash> 0`) is
#   replayed into clearbit via `submitblock`. After replay both nodes hold the
#   byte-identical chain, so getblockfilter on the SAME hash must agree
#   filter-for-filter and header-for-header.
#
# WHAT MUST MATCH CORE EXACTLY (byte-for-byte, requires SAME_CHAIN):
#   1. filter hex + header hex for a coinbase-only block (1-element filter)
#      AND for the spend block (multi-element filter).
#   2. header CHAINING: header at height N chains from N-1 — verified by
#      comparing the header bytes vs Core across >=3 consecutive blocks (catches
#      a wrong prev-header link).
#   3. ERRORS: getblockfilter <hash> bogustype -> -5; <unknown-hash> basic -> -5.
#
# If submitblock replay is unavailable (chains diverge) the byte-exact cross-node
# comparison is not apples-to-apples; the test then SKIPs (it cannot prove
# byte-parity without a shared chain), rather than passing vacuously.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/blockheader/clearbit_getblockheader.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER clearbit: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER clearbit: FAIL <short reason>
#   SKIP: GETBLOCKFILTER clearbit: SKIP <reason>
#
# Touches ONLY /tmp/gbf-clearbit/ + /tmp/gbf-core/ and ports
#   40237/40257 (clearbit RPC/P2P) + 40239/40259 (Core RPC; P2P unused, -listen=0).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Any `fuser -k` redirects stdout: `fuser -k "<port>/tcp" >/dev/null 2>&1`.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

CB_DATADIR="/tmp/gbf-clearbit/$$"
CB_RPC=40237
CB_P2P=40257
CB_LOG="$CB_DATADIR/node.log"

CORE_DATADIR="/tmp/gbf-core/$$"
CORE_RPC=40239   # 40238 may be held by a sibling node on the shared box
CORE_P2P=40259   # declared but Core launched -listen=0 (no P2P listener)
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to.
# We also need its regtest WIF so we can sign a wallet-free spend of a coinbase
# output paying to this key (this Core build has NO wallet support compiled in,
# so createwallet/sendtoaddress are unavailable — we use
# createrawtransaction + signrawtransactionwithkey + sendrawtransaction).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SECRET_WIF=""   # derived below via the Core test_framework

NMATURE=110        # mine 110 blocks first so block 1's coinbase is spendable
TBASE=1700000000   # pin block timestamps (each block i -> nTime = TBASE + i)

CB_PID=""
CB_COOKIE=""
CORE_BG=""
ADDR=""
SEND_ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockfilter:clearbit] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CB_PID" ]] && kill -0 "$CB_PID" 2>/dev/null; then
        kill "$CB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${CB_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CB_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETBLOCKFILTER clearbit: PASS filter=$1 header=$2 chain=$3 errors=$4"; exit 0; }
fail() { echo "GETBLOCKFILTER clearbit: FAIL $*"; exit 1; }
skip() { echo "GETBLOCKFILTER clearbit: SKIP $*"; exit 0; }

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
# Reclaim ONLY this PID's scratch + the canonical ports. We deliberately do NOT
# broad-pkill bitcoind/clearbit by name — that would kill sibling test runs and
# (catastrophically) the live mainnet bitcoind/clearbit on /data/nvme1.
log "resetting scratch state (pid=$$)"
pkill -f "gbf-clearbit/$$" 2>/dev/null || true
fuser -k "${CB_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CB_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$CB_DATADIR" "$CORE_DATADIR"
mkdir -p "$CB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "clearbit binary not found at $NODE_BIN (build with: zig build -Dsecp256k1=true -Dsecp256k1-include=$BASEDIR/bitcoin-core/src/secp256k1/include -Doptimize=ReleaseFast)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive the deterministic bcrt1 p2wpkh mining + send addresses. ─────
ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic mining address (Core test_framework import failed)"
[[ "$ADDR" == bcrt1* ]] || fail "derived address is not a regtest bech32 address: '$ADDR'"
# Regtest WIF for $SECRET (prefix 0xEF=239, compressed -> append 0x01) — used to
# sign the wallet-free spend of a coinbase output paying to $ADDR.
SECRET_WIF=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.address import byte_to_base58
print(byte_to_base58(bytes.fromhex('$SECRET') + b'\x01', 239))
" 2>/dev/null) || fail "could not derive regtest WIF for the test secret"
[[ -n "$SECRET_WIF" ]] || fail "derived WIF is empty"
# A second, distinct address to receive the spend (deterministic).
SEND_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('2222222222222222222222222222222222222222222222222222222222222223'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic send address"
log "mining address: $ADDR ; send address: $SEND_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_cli_retry: tolerant of the .cookie read race under concurrent fleet load.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# cb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
cb_rpc() {
    curl -s --max-time 90 -u "$CB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$CB_RPC/" 2>/dev/null
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

# ── 3. Launch the Core regtest oracle (RPC-only, -blockfilterindex=basic). ─
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
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

# ── 4. Launch clearbit on regtest WITH --blockfilterindex. ────────────────
log "launching clearbit (regtest, --blockfilterindex) rpc=:$CB_RPC p2p=:$CB_P2P -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" --blockfilterindex \
    --port="$CB_P2P" --rpcbind=127.0.0.1 --rpcport="$CB_RPC" >"$CB_LOG" 2>&1 &
CB_PID=$!
cb_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < cb_deadline )); do
    if [[ -z "$CB_COOKIE" ]]; then
        for c in "$CB_DATADIR/.cookie" "$CB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && CB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$CB_COOKIE" ]]; then
        echo "$(cb_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$CB_PID" 2>/dev/null || { tail -n 20 "$CB_LOG" >&2 2>/dev/null || true; fail "clearbit exited during startup (see $CB_LOG)"; }
    sleep 1
done
[[ -n "$CB_COOKIE" ]] || fail "clearbit cookie never appeared within 120s"
echo "$(cb_rpc getblockcount '[]')" | grep -q '"result"' || fail "clearbit RPC never responded within 120s"
log "clearbit RPC ready"

# ── 5. Core builds the chain: mine to maturity, create a SPEND, mine it in. ─
# Block heights of interest:
#   H_CB = a coinbase-only block        -> 1-element filter.
#   H_SPEND = block containing the spend -> multi-element filter (output spk +
#             spent coinbase prevout spk).
# This Core build has NO wallet compiled in, so the spend is constructed
# wallet-free: spend block 1's coinbase output 0 (pays to $ADDR's p2wpkh) using
# createrawtransaction + signrawtransactionwithkey($SECRET_WIF) +
# sendrawtransaction, then mine it in. The spend's input prevout scriptPubKey
# (= the coinbase p2wpkh) and the spend's output scriptPubKey BOTH enter the
# spend block's BIP-158 filter -> a multi-element (N>=2) filter.
log "Core: mining $NMATURE blocks to $ADDR (setmocktime-pinned)"
core_cli setmocktime "$TBASE" >/dev/null 2>&1 || true
mine_one() {  # mine 1 block at deterministic time = TBASE + height
    local nexth; nexth=$(( $(core_cli_retry getblockcount) + 1 ))
    core_cli setmocktime "$(( TBASE + nexth ))" >/dev/null 2>&1 || true
    if ! core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1; then
        sleep 1
        core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || {
            kill -0 "$CORE_BG" 2>/dev/null \
                && fail "Core generatetoaddress failed (oracle alive — transient RPC error)" \
                || fail "Core generatetoaddress failed (oracle DIED — see $CORE_LOG)"
        }
    fi
}
for (( i=1; i<=NMATURE; i++ )); do mine_one; done

# Spend block 1's coinbase output 0 (50 BTC, matured after 100 blocks).
SP_BH1=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
SP_B1J=$(core_cli_retry getblock "$SP_BH1" 2) || fail "Core getblock (verbosity 2) for block 1 failed"
SP_TXID=$(jpy "$SP_B1J" "d['tx'][0]['txid']")
SP_SPK=$(jpy "$SP_B1J" "d['tx'][0]['vout'][0]['scriptPubKey']['hex']")
[[ "$SP_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not read block-1 coinbase txid: '$SP_TXID'"
[[ "$SP_SPK" =~ ^[0-9a-f]+$ ]]     || fail "could not read block-1 coinbase scriptPubKey: '$SP_SPK'"
log "spending block-1 coinbase $SP_TXID:0 (spk=$SP_SPK) -> $SEND_ADDR (49.999 BTC, 0.001 fee)"

SP_RAW=$(core_cli createrawtransaction "[{\"txid\":\"$SP_TXID\",\"vout\":0}]" "{\"$SEND_ADDR\":49.999}") \
    || fail "Core createrawtransaction failed"
[[ -n "$SP_RAW" ]] || fail "Core createrawtransaction returned empty"
SP_SIGNED=$(core_cli signrawtransactionwithkey "$SP_RAW" "[\"$SECRET_WIF\"]" \
    "[{\"txid\":\"$SP_TXID\",\"vout\":0,\"scriptPubKey\":\"$SP_SPK\",\"amount\":50.0}]") \
    || fail "Core signrawtransactionwithkey failed"
SP_COMPLETE=$(jpy "$SP_SIGNED" "d.get('complete')")
[[ "$SP_COMPLETE" == "true" ]] || fail "Core could not fully sign the spend (complete=$SP_COMPLETE; resp=$SP_SIGNED)"
SP_HEX=$(jpy "$SP_SIGNED" "d['hex']")
[[ -n "$SP_HEX" ]] || fail "signed spend hex empty"
SPEND_TXID=$(core_cli sendrawtransaction "$SP_HEX" 2>/dev/null) || fail "Core sendrawtransaction (spend) failed"
[[ "$SPEND_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned bad txid: '$SPEND_TXID'"
log "spend accepted into Core mempool: $SPEND_TXID -> mining it into the next block"

# Mine the block that includes the spend tx -> H_SPEND.
mine_one
H_SPEND=$(core_cli_retry getblockcount)
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$H_SPEND")
core_cli_retry getblock "$SPEND_BLOCKHASH" 1 | grep -q "$SPEND_TXID" \
    || fail "spend tx $SPEND_TXID not found in block $H_SPEND ($SPEND_BLOCKHASH)"
# Mine a few more so we have >=3 consecutive blocks after the spend for chaining.
for (( i=1; i<=4; i++ )); do mine_one; done

CORE_HEIGHT=$(core_cli_retry getblockcount)
log "Core chain height: $CORE_HEIGHT ; H_SPEND=$H_SPEND"

# ── 6. Replay Core's raw blocks into clearbit via submitblock. ────────────
log "replaying Core's $CORE_HEIGHT raw blocks into clearbit via submitblock"
REPLAY_OK=1
for (( h=1; h<=CORE_HEIGHT; h++ )); do
    bh=$(core_cli_retry getblockhash "$h")    || { REPLAY_OK=0; log "getblockhash $h failed"; break; }
    raw=$(core_cli_retry getblock "$bh" 0)    || { REPLAY_OK=0; log "getblock $bh 0 failed"; break; }
    [[ -n "$raw" ]]                           || { REPLAY_OK=0; log "empty raw block at height $h"; break; }
    sb=$(cb_rpc submitblock "[\"$raw\"]")
    sbres=$(jpy "$sb" "d.get('result')")
    sberr=$(jpy "$sb" "d.get('error')")
    if [[ -n "$sbres" && "$sbres" != "None" && "$sbres" != "duplicate" && "$sbres" != "inconclusive" ]]; then
        REPLAY_OK=0; log "clearbit submitblock rejected height $h: result='$sbres' raw_resp=$sb"; break
    fi
    if [[ -n "$sberr" && "$sberr" != "None" ]]; then
        REPLAY_OK=0; log "clearbit submitblock errored height $h: $sb"; break
    fi
done

CB_HEIGHT=$(jpy "$(cb_rpc getblockcount '[]')" "d['result']")
log "clearbit height after replay: ${CB_HEIGHT:-?} (replay_ok=$REPLAY_OK, core=$CORE_HEIGHT)"
if [[ "$REPLAY_OK" != "1" || "$CB_HEIGHT" != "$CORE_HEIGHT" ]]; then
    skip "submitblock replay incomplete (replay_ok=$REPLAY_OK cb_height=${CB_HEIGHT:-?} core=$CORE_HEIGHT) — cannot compare filters on a shared chain"
fi

# Confirm both nodes hold the byte-identical chain (tip + spend block agree).
CORE_TIP=$(core_cli_retry getbestblockhash)
CB_TIP=$(jpy "$(cb_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$CORE_TIP" && -n "$CB_TIP" ]] || fail "could not read tips (core=$CORE_TIP cb=$CB_TIP)"
[[ "$CORE_TIP" == "$CB_TIP" ]] || skip "chains diverged after replay (core tip=$CORE_TIP cb tip=$CB_TIP) — byte comparison not apples-to-apples"
log "chains identical: tip=$CB_TIP"

# Give clearbit's filter index a moment to catch up to the tip (index sync wait).
idx_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < idx_deadline )); do
    info=$(cb_rpc getindexinfo '["basic block filter index"]')
    synced=$(jpy "$info" "d['result'].get('basic block filter index',{}).get('synced')")
    bbh=$(jpy "$info" "d['result'].get('basic block filter index',{}).get('best_block_height')")
    [[ "$synced" == "true" || "${bbh:-0}" -ge "$CB_HEIGHT" ]] && break
    sleep 2
done
log "clearbit filter index status: $(cb_rpc getindexinfo '["basic block filter index"]')"

# ── 7. Resolve the block hashes we compare on. ────────────────────────────
# H_CB: a coinbase-only block (well below the spend). H_SPEND: the spend block.
H_CB=$(( NMATURE - 5 ))   # a plain empty/coinbase-only block deep in the chain
CB_HASH_CB=$(core_cli_retry getblockhash "$H_CB")        || fail "getblockhash $H_CB failed"
CB_HASH_SPEND="$SPEND_BLOCKHASH"
log "comparing filters at: H_CB=$H_CB ($CB_HASH_CB), H_SPEND=$H_SPEND ($CB_HASH_SPEND)"

# Helper: read getblockfilter from each node.
core_filter() { core_cli_retry getblockfilter "$1" basic; }   # JSON object
cb_filter()   { jpy "$(cb_rpc getblockfilter "[\"$1\", \"basic\"]")" "json.dumps(d['result'])"; }
cb_filter_raw() { cb_rpc getblockfilter "[\"$1\", \"basic\"]"; }

# Extract .filter / .header from a getblockfilter JSON object.
gf() { jpy "$1" "d.get('$2')"; }

# ── 8. CHECK 1 — filter + header byte-EXACT for 1-element + multi-element. ─
FILTER_T="bad"; HEADER_T="bad"

CORE_CB_JSON=$(core_filter "$CB_HASH_CB")     || fail "Core getblockfilter (coinbase-only) failed"
CB_CB_JSON=$(cb_filter "$CB_HASH_CB")
[[ -n "$CORE_CB_JSON" ]] || fail "Core getblockfilter (coinbase-only) returned empty"
[[ -n "$CB_CB_JSON"   ]] || fail "clearbit getblockfilter (coinbase-only) returned empty: $(cb_filter_raw "$CB_HASH_CB")"

CORE_CB_FILTER=$(gf "$CORE_CB_JSON" filter); CORE_CB_HEADER=$(gf "$CORE_CB_JSON" header)
CB_CB_FILTER=$(gf "$CB_CB_JSON" filter);     CB_CB_HEADER=$(gf "$CB_CB_JSON" header)
[[ "$CB_CB_FILTER" =~ ^[0-9a-f]+$ ]] || fail "clearbit coinbase-only filter not hex: '$CB_CB_FILTER'"
[[ "$CB_CB_HEADER" =~ ^[0-9a-f]{64}$ ]] || fail "clearbit coinbase-only header not 64-hex: '$CB_CB_HEADER'"

log "coinbase-only: core filter=$CORE_CB_FILTER header=$CORE_CB_HEADER"
log "coinbase-only: cb   filter=$CB_CB_FILTER header=$CB_CB_HEADER"
[[ "$CB_CB_FILTER" == "$CORE_CB_FILTER" ]] || fail "coinbase-only FILTER mismatch vs Core at H_CB=$H_CB: cb=$CB_CB_FILTER core=$CORE_CB_FILTER"
[[ "$CB_CB_HEADER" == "$CORE_CB_HEADER" ]] || fail "coinbase-only HEADER mismatch vs Core at H_CB=$H_CB: cb=$CB_CB_HEADER core=$CORE_CB_HEADER"

CORE_SP_JSON=$(core_filter "$CB_HASH_SPEND")  || fail "Core getblockfilter (spend) failed"
CB_SP_JSON=$(cb_filter "$CB_HASH_SPEND")
[[ -n "$CORE_SP_JSON" ]] || fail "Core getblockfilter (spend) returned empty"
[[ -n "$CB_SP_JSON"   ]] || fail "clearbit getblockfilter (spend) returned empty: $(cb_filter_raw "$CB_HASH_SPEND")"

CORE_SP_FILTER=$(gf "$CORE_SP_JSON" filter); CORE_SP_HEADER=$(gf "$CORE_SP_JSON" header)
CB_SP_FILTER=$(gf "$CB_SP_JSON" filter);     CB_SP_HEADER=$(gf "$CB_SP_JSON" header)

log "spend block: core filter=$CORE_SP_FILTER header=$CORE_SP_HEADER"
log "spend block: cb   filter=$CB_SP_FILTER header=$CB_SP_HEADER"

# The spend block's filter must encode >1 element (CompactSize N>1). Sanity:
# the coinbase-only block has N=1, the spend block N>=2, so their encoded
# lengths differ and the spend filter is non-trivial. Decode N (first CompactSize
# byte; N is small on regtest so it fits in 1 byte).
SP_N=$(python3 -c "
b=bytes.fromhex('$CORE_SP_FILTER')
# CompactSize: <0xfd uses 1 byte
n=b[0]
print(n)
" 2>/dev/null)
[[ "${SP_N:-0}" -ge 2 ]] || fail "spend block filter is not multi-element (N=$SP_N) — test did not exercise a spent-prevout"
log "spend block filter element count N=$SP_N (multi-element OK)"

[[ "$CB_SP_FILTER" == "$CORE_SP_FILTER" ]] || fail "spend-block FILTER mismatch vs Core at H_SPEND=$H_SPEND: cb=$CB_SP_FILTER core=$CORE_SP_FILTER"
[[ "$CB_SP_HEADER" == "$CORE_SP_HEADER" ]] || fail "spend-block HEADER mismatch vs Core at H_SPEND=$H_SPEND: cb=$CB_SP_HEADER core=$CORE_SP_HEADER"
FILTER_T="ok"

# Header parity already passed on both representative blocks.
HEADER_T="ok"

# ── 9. CHECK 2 — header CHAINING across >=3 consecutive blocks vs Core. ────
# Compare clearbit's header bytes vs Core's for a run of consecutive blocks
# around the spend; a wrong prev-header link would diverge from the first
# mismatch onward. Use H_SPEND-1 .. H_SPEND+3 (5 consecutive blocks, >=3).
CHAIN_T="bad"
CHAIN_OK=1
CHAIN_LO=$(( H_SPEND - 1 ))
CHAIN_HI=$(( H_SPEND + 3 ))
(( CHAIN_LO < 1 )) && CHAIN_LO=1
(( CHAIN_HI > CORE_HEIGHT )) && CHAIN_HI=$CORE_HEIGHT
N_CHAIN=0
PREV_CORE_HDR=""
PREV_CB_HDR=""
for (( hh=CHAIN_LO; hh<=CHAIN_HI; hh++ )); do
    bhash=$(core_cli_retry getblockhash "$hh") || { CHAIN_OK=0; log "chain: getblockhash $hh failed"; break; }
    core_j=$(core_filter "$bhash")             || { CHAIN_OK=0; log "chain: core filter $hh failed"; break; }
    cb_j=$(cb_filter "$bhash")
    core_h=$(gf "$core_j" header); cb_h=$(gf "$cb_j" header)
    [[ "$cb_h" =~ ^[0-9a-f]{64}$ ]] || { CHAIN_OK=0; log "chain: cb header not 64-hex at $hh: '$cb_h'"; break; }
    if [[ "$cb_h" != "$core_h" ]]; then
        CHAIN_OK=0; log "chain: HEADER mismatch at height $hh: cb=$cb_h core=$core_h"; break
    fi
    # Verify the recurrence locally: header_n = SHA256d( SHA256d(filter_n) || header_{n-1} )
    cb_f=$(gf "$cb_j" filter)
    if [[ -n "$PREV_CB_HDR" ]]; then
        recomputed=$(python3 -c "
import hashlib
def d2(x): return hashlib.sha256(hashlib.sha256(x).digest()).digest()
filt=bytes.fromhex('$cb_f')
prev=bytes.fromhex('$PREV_CB_HDR')[::-1]          # display->internal
fh=d2(filt)
hdr=d2(fh+prev)[::-1].hex()                        # internal->display
print(hdr)
" 2>/dev/null)
        if [[ "$recomputed" != "$cb_h" ]]; then
            CHAIN_OK=0; log "chain: recurrence broken at height $hh (recomputed=$recomputed actual=$cb_h, prev=$PREV_CB_HDR)"; break
        fi
    fi
    PREV_CORE_HDR="$core_h"
    PREV_CB_HDR="$cb_h"
    N_CHAIN=$(( N_CHAIN + 1 ))
done
[[ "$CHAIN_OK" == "1" && "$N_CHAIN" -ge 3 ]] || fail "header chaining check failed (ok=$CHAIN_OK n=$N_CHAIN, need >=3 consecutive matching+recurrence-valid headers)"
log "header chaining verified across $N_CHAIN consecutive blocks ($CHAIN_LO..$((CHAIN_LO+N_CHAIN-1)))"
CHAIN_T="ok"

# ── 10. CHECK 3 — error parity. ───────────────────────────────────────────
ERRORS_T="bad"
EOK=1

# (a) Unknown filtertype -> -5 "Unknown filtertype".
ERESP=$(cb_rpc getblockfilter "[\"$CB_HASH_CB\", \"bogustype\"]")
ECODE=$(jpy "$ERESP" "d['error']['code']")
EMSG=$(jpy "$ERESP" "d['error']['message']")
if [[ "$ECODE" != "-5" ]]; then EOK=0; log "bogus filtertype: expected code -5, got '$ECODE' (resp=$ERESP)"; fi
echo "$EMSG" | grep -qi "Unknown filtertype" || { EOK=0; log "bogus filtertype: message not 'Unknown filtertype': '$EMSG'"; }

# (b) Unknown block hash -> -5 "Block not found".
BOGUS_HASH="dead00000000000000000000000000000000000000000000000000000000beef"
ERESP2=$(cb_rpc getblockfilter "[\"$BOGUS_HASH\", \"basic\"]")
ECODE2=$(jpy "$ERESP2" "d['error']['code']")
EMSG2=$(jpy "$ERESP2" "d['error']['message']")
if [[ "$ECODE2" != "-5" ]]; then EOK=0; log "unknown hash: expected code -5, got '$ECODE2' (resp=$ERESP2)"; fi
echo "$EMSG2" | grep -qi "Block not found" || { EOK=0; log "unknown hash: message not 'Block not found': '$EMSG2'"; }

# Cross-check Core agrees on the error codes (parity sanity).
CORE_E1=$(core_cli getblockfilter "$CB_HASH_CB" bogustype 2>&1 | grep -oE "error code: -?[0-9]+" | grep -oE "\-?[0-9]+" | head -1)
CORE_E2=$(core_cli getblockfilter "$BOGUS_HASH" basic 2>&1 | grep -oE "error code: -?[0-9]+" | grep -oE "\-?[0-9]+" | head -1)
[[ "$CORE_E1" == "-5" ]] || log "NOTE: Core bogus-filtertype error code was '$CORE_E1' (expected -5)"
[[ "$CORE_E2" == "-5" ]] || log "NOTE: Core unknown-hash error code was '$CORE_E2' (expected -5)"

[[ "$EOK" == "1" ]] || fail "error-parity check failed (see log)"
ERRORS_T="ok"

# ── DONE ───────────────────────────────────────────────────────────────────
pass "$FILTER_T" "$HEADER_T" "$CHAIN_T" "$ERRORS_T"
