#!/usr/bin/env bash
#
# lunarblock_scanblocks.sh — self-contained scanblocks Core-parity test.
#
# scanblocks drives the BIP-157 basic block filter index to find blocks whose
# GCS filter MATCHES any of the given scanobjects' scriptPubKeys, returning
#   { from_height, to_height, relevant_blocks:[blockhash...], completed }.
# It is the index-side counterpart to scantxoutset (which walks the UTXO set):
# scanblocks walks compact block filters, so it can locate the block a script
# was funded/spent in even after the coin is gone.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp scanblocks.
#   SIGNATURE: scanblocks "action" ( [scanobjects] start_height stop_height
#              "filtertype" options ). filtertype default "basic".
#   action=status -> null (no scan running); action=abort -> false; action=start
#   does real work.
#   ERRORS (Core):
#     unknown action      -> -8 (RPC_INVALID_PARAMETER) [impl-specific code OK]
#     unknown filtertype  -> -5 (RPC_INVALID_ADDRESS_OR_KEY) "Unknown filtertype"
#     index disabled      -> -1 (RPC_MISC_ERROR) "Index is not enabled ..."
#     bad start/stop hght -> -1 (RPC_MISC_ERROR) "Invalid start_height/stop_height"
#
# CENTRAL CAVEAT: block filters have FALSE POSITIVES (rate ~1/M, M=784931), so
# relevant_blocks may contain EXTRA blocks. Every assertion here is a
# MEMBERSHIP / SUPERSET assertion over a KNOWN-TRUE block set — NEVER list
# length or set equality. The single non-negotiable: the block that actually
# contains the funded/spent script MUST appear in relevant_blocks.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest instance +
#   OWN ports, launched -listen=0 -blockfilterindex=basic. Core is the SINGLE
#   source of blocks: Core mines NBLOCKS empty blocks to a DETERMINISTIC p2wpkh
#   addr (ADDR), then a RAW BIP-143 spend of coinbase#1 -> a fresh p2wpkh
#   (DESTADDR), mined into block NBLOCKS+1. Each block's raw hex is replayed
#   into lunarblock via submitblock. After replay both nodes hold the
#   byte-identical chain, so scanblocks over the SAME needle MUST agree on every
#   TRUE-positive block (filters are byte-identical; only false positives may
#   diverge).
#
# KNOWN-TRUE block set for needle addr(ADDR):
#   - block 1 (coinbase paying ADDR — ADDR's scriptPubKey is an OUTPUT), and
#   - block NBLOCKS+1 (the spend — ADDR's p2wpkh appears as the SPENT prevout,
#     which BIP-158 includes from undo data).
#
# WHAT MUST HOLD (per the strict fan-out contract — same gates as
#   scanblocks/rustoshi_scanblocks.sh):
#   A. SHAPE: object {from_height:int, to_height:int, relevant_blocks:[64hex...],
#      completed:bool}. from==start, to==stop, completed==true.
#   B. MEMBERSHIP: relevant_blocks ⊇ {block1, spendblock} for addr(ADDR).
#   C. CORE CROSS-CHECK: impl relevant_blocks ⊇ (Core relevant_blocks projected
#      to known-true set); both lists equal on the known-true projection.
#   D. NEGATIVE NEEDLE: addr(<fresh-unfunded>) -> block1 and spendblock ABSENT.
#   E. RANGE BOUNDING: a 1-block window on the spend block returns from==to==
#      H_spend and the spend block present; a window strictly below the funded
#      heights does NOT contain the funded blocks.
#   F. ACTIONS: status -> null; abort -> false; bogus action -> error.
#   G. ERRORS: unknown filtertype -> -5; start>tip -> -1; stop<start -> -1.
#
# STRICT UNIFORM INTERFACE (mirrors blockfilter/lunarblock_getblockfilter.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS: SCANBLOCKS lunarblock: PASS scan=ok shape=ok range=ok errors=ok
#   FAIL: SCANBLOCKS lunarblock: FAIL <short reason>
#   SKIP: SCANBLOCKS lunarblock: SKIP <no scanblocks RPC | no filter index>
#
# Touches ONLY /tmp/sblk-lunarblock + /tmp/sblk-lb-core and ports
#   22338/22358 (lunarblock RPC/P2P) + 22336/22356 (Core RPC; P2P unused,
#   -listen=0). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

LB_DATADIR="/tmp/sblk-lunarblock"
LB_RPC=22338
LB_P2P=22358
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/sblk-lb-core"
CORE_RPC=22336
CORE_P2P=22356   # declared but Core launched -listen=0 (no P2P listener)
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DESTSECRET="2222222222222222222222222222222222222222222222222222222222222223"
# A fresh, never-funded secret -> negative-needle address.
NEGSECRET="3333333333333333333333333333333333333333333333333333333333333334"

NBLOCKS=110        # mine 110 empty blocks (matures the first coinbase at h=1)
TBASE=1700000000   # pin nTime so Core's blocks are deterministic

LB_PID=""
CORE_BG=""
ADDR=""
NEGADDR=""

log() { echo "[scanblocks:lunarblock] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
        kill -TERM "-${LB_PID}" 2>/dev/null || kill -TERM "$LB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "-${LB_PID}" 2>/dev/null || kill -KILL "$LB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "SCANBLOCKS lunarblock: PASS scan=$1 shape=$2 range=$3 errors=$4"
    exit 0
}
fail() {
    echo "SCANBLOCKS lunarblock: FAIL $*"
    exit 1
}
skip() {
    echo "SCANBLOCKS lunarblock: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset (own ports + own scratch only). ───────────────────
log "resetting scratch state"
pkill -f "sblk-lunarblock" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${LB_RPC}/${LB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
command -v luajit  >/dev/null 2>&1   || fail "luajit not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]      || fail "lunarblock entrypoint not found at $LB_DIR/src/main.lua"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive deterministic bcrt1 p2wpkh addresses (funded + negative). ───
derive_addr() {
    python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$1'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null
}
ADDR=$(derive_addr "$SECRET")       || fail "could not derive funded mining address"
NEGADDR=$(derive_addr "$NEGSECRET") || fail "could not derive negative-needle address"
[[ "$ADDR" == bcrt1*    ]] || fail "funded address is not a regtest bech32 address: '$ADDR'"
[[ "$NEGADDR" == bcrt1* ]] || fail "negative address is not a regtest bech32 address: '$NEGADDR'"
[[ "$ADDR" != "$NEGADDR" ]] || fail "funded and negative addresses collide"
log "funded mining address: $ADDR ; negative needle: $NEGADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }
core_cli_retry() {
    local out=""
    for _ in $(seq 1 15); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 2
    done
    return 1
}
# lunarblock defaults to an EMPTY rpcpassword on regtest -> no auth header.
lb_rpc() {
    curl -s --max-time 90 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
}
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('None')
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

# ── 4. Launch lunarblock on regtest with the basic block filter index. ────
log "launching lunarblock (regtest, --blockfilterindex) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' --blockfilterindex --nov2transport" \
    >"$LB_LOG" 2>&1 &
LB_PID=$!
log "lunarblock pid=$LB_PID"
lb_deadline=$(( $(date +%s) + 120 ))
lb_up=0
while (( $(date +%s) < lb_deadline )); do
    if ! kill -0 "$LB_PID" 2>/dev/null; then
        tail -n 20 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock exited during startup (see $LB_LOG)"
    fi
    r=$(lb_rpc getblockchaininfo '[]')
    if echo "$r" | grep -q '"regtest"'; then lb_up=1; break; fi
    sleep 1
done
[[ "$lb_up" -eq 1 ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest within 120s"; }
log "lunarblock RPC ready"

# Capability probe: if scanblocks is unimplemented, SKIP; if the RPC exists but
# the index is off, SKIP. We pass a probe addr() needle over [0,0].
PROBE=$(lb_rpc scanblocks "[\"start\", [\"addr($ADDR)\"], 0, 0, \"basic\"]")
PROBE_ECODE=$(jpy "$PROBE" "d.get('error',{}).get('code')")
PROBE_EMSG=$(jpy "$PROBE" "d.get('error',{}).get('message','')")
if [[ "$PROBE_ECODE" == "-32601" ]]; then
    skip "no scanblocks RPC (method not found)"
fi
case "$PROBE_EMSG" in
    *[Nn]ot*enabled*) skip "no filter index (scanblocks reports index not enabled)" ;;
esac

# Confirm the basic block filter index is actually enabled on lunarblock.
IDXINFO=$(lb_rpc getindexinfo '[]')
echo "$IDXINFO" | grep -q "basic block filter index" \
    || skip "lunarblock did not report a basic block filter index (getindexinfo: $IDXINFO)"

# ── 5. Core mines a chain that INCLUDES A SPEND. ──────────────────────────
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

# Build a RAW BIP-143 spend of coinbase#1 (paid to ADDR=p2wpkh(SECRET)) to a
# fresh p2wpkh(DESTSECRET). The block including it carries ADDR's scriptPubKey
# as a SPENT prevout (undo data) -> the spend block is a TRUE match for ADDR.
CB_BLOCK1=$(core_cli_retry getblockhash 1)               || fail "getblockhash 1 failed"
CB1_TXID=$(core_cli_retry getblock "$CB_BLOCK1" 1 | python3 -c "import sys,json; print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ "$CB1_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not read coinbase txid at height 1: '$CB1_TXID'"
CB1_RAW=$(core_cli_retry getrawtransaction "$CB1_TXID" 0 "$CB_BLOCK1") || fail "getrawtransaction coinbase h1 failed"
[[ -n "$CB1_RAW" ]] || fail "empty coinbase raw at h1"
log "spending coinbase $CB1_TXID:0 (block 1) via raw BIP-143 segwit tx"

SPEND_RAW=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import CScript, SegwitV0SignatureHash, SIGHASH_ALL
from test_framework.script_util import key_to_p2wpkh_script, keyhash_to_p2pkh_script
from test_framework.key import ECKey
import io, hashlib

src = ECKey(); src.set(bytes.fromhex('$SECRET'), True)
src_pub = src.get_pubkey().get_bytes()
src_spk = key_to_p2wpkh_script(src_pub)
dst = ECKey(); dst.set(bytes.fromhex('$DESTSECRET'), True)
dst_spk = key_to_p2wpkh_script(dst.get_pubkey().get_bytes())

cb = CTransaction(); cb.deserialize(io.BytesIO(bytes.fromhex('$CB1_RAW')))
amount = cb.vout[0].nValue
assert bytes(cb.vout[0].scriptPubKey) == bytes(src_spk), 'coinbase vout0 spk != p2wpkh(SECRET)'

txid_internal = int.from_bytes(bytes.fromhex('$CB1_TXID')[::-1], 'little')
tx = CTransaction()
tx.vin.append(CTxIn(COutPoint(txid_internal, 0), b'', 0xffffffff))
fee = 1000
tx.vout.append(CTxOut(amount - fee, dst_spk))
tx.wit.vtxinwit.append(CTxInWitness())
def hash160(b): return hashlib.new('ripemd160', hashlib.sha256(b).digest()).digest()
script_code = keyhash_to_p2pkh_script(hash160(src_pub))
sighash = SegwitV0SignatureHash(script_code, tx, 0, SIGHASH_ALL, amount)
sig = src.sign_ecdsa(sighash) + bytes([SIGHASH_ALL])
tx.wit.vtxinwit[0].scriptWitness.stack = [sig, src_pub]
print(tx.serialize_with_witness().hex())
" 2>/dev/null) || fail "raw spend tx construction failed (test_framework crypto)"
[[ "$SPEND_RAW" =~ ^[0-9a-f]+$ ]] || fail "constructed spend tx not hex: '$SPEND_RAW'"

core_cli setmocktime "$(( TBASE + NBLOCKS + 1 ))" >/dev/null 2>&1 || true
SPEND_TXID=$(core_cli_retry sendrawtransaction "$SPEND_RAW") || {
    log "sendrawtransaction output: $(core_cli sendrawtransaction "$SPEND_RAW" 2>&1)"
    fail "Core sendrawtransaction (raw spend) rejected"
}
[[ "$SPEND_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned non-txid: '$SPEND_TXID'"
log "spend txid: $SPEND_TXID -> mining it into block $(( NBLOCKS + 1 ))"

# Mine ONE block to confirm the spend (mine to ADDR so the coinbase output also
# pays ADDR; the spend block is then a true match for ADDR via BOTH a coinbase
# output AND the spent prevout).
core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || {
    sleep 1
    core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || fail "Core failed to mine the spend block"
}

CORE_HEIGHT=$(core_cli_retry getblockcount)
TOTAL=$(( NBLOCKS + 1 ))
[[ "$CORE_HEIGHT" == "$TOTAL" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $TOTAL"
log "Core chain height = $CORE_HEIGHT (spend confirmed in block $CORE_HEIGHT)"

SPEND_HEIGHT=$CORE_HEIGHT
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$SPEND_HEIGHT")
core_cli_retry getblock "$SPEND_BLOCKHASH" 1 | grep -q "$SPEND_TXID" \
    || fail "spend tx $SPEND_TXID not found in block $SPEND_BLOCKHASH"
BLOCK1_HASH=$(core_cli_retry getblockhash 1)
log "known-true blocks: block1=$BLOCK1_HASH (h1, coinbase->ADDR) spend=$SPEND_BLOCKHASH (h$SPEND_HEIGHT)"

# ── 6. Replay ALL of Core's raw blocks into lunarblock via submitblock. ───
log "replaying Core's $TOTAL raw blocks into lunarblock via submitblock"
for (( h=1; h<=TOTAL; h++ )); do
    bh=$(core_cli_retry getblockhash "$h")
    if [[ -z "$bh" ]]; then sleep 2; bh=$(core_cli_retry getblockhash "$h"); fi
    [[ -n "$bh" ]]                            || fail "getblockhash $h failed (Core RPC unresponsive)"
    raw=$(core_cli_retry getblock "$bh" 0)
    if [[ -z "$raw" ]]; then sleep 2; raw=$(core_cli_retry getblock "$bh" 0); fi
    [[ -n "$raw" ]]                           || fail "getblock $bh 0 failed (Core RPC unresponsive)"
    sb=$(lb_rpc submitblock "[\"$raw\"]")
    sbres=$(jpy "$sb" "d.get('result')")
    sberr=$(jpy "$sb" "d.get('error')")
    if [[ -n "$sbres" && "$sbres" != "None" && "$sbres" != "duplicate" && "$sbres" != "inconclusive" ]]; then
        tail -n 40 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock submitblock rejected height $h: result='$sbres' raw_resp=$sb"
    fi
    if [[ -n "$sberr" && "$sberr" != "None" ]]; then
        fail "lunarblock submitblock errored height $h: $sb"
    fi
done
LB_HEIGHT=$(jpy "$(lb_rpc getblockcount '[]')" "d['result']")
[[ "$LB_HEIGHT" == "$TOTAL" ]] || { tail -n 40 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock height after replay is $LB_HEIGHT, expected $TOTAL"; }
CORE_TIP=$(core_cli_retry getbestblockhash)
LB_TIP=$(jpy "$(lb_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" == "$LB_TIP" ]] || fail "tip mismatch after replay: core=$CORE_TIP lb=$LB_TIP"
log "lunarblock replayed to height $LB_HEIGHT — chains are byte-identical (tip $LB_TIP)"
TIP=$TOTAL

# ── scanblocks helpers ────────────────────────────────────────────────────
lb_scan() {
    # args: action scanobjects start stop  -> raw JSON response
    lb_rpc scanblocks "[\"$1\", $2, $3, $4, \"basic\"]"
}
lb_scan_blocks() {
    jpy "$(lb_scan "$1" "$2" "$3" "$4")" "' '.join(d['result']['relevant_blocks'])"
}
co_scan_blocks() {
    # args: scanobjects-as-cli-json start stop
    core_cli_retry scanblocks start "$1" "$2" "$3" basic \
        | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin)['relevant_blocks']))" 2>/dev/null
}
in_list() {
    # in_list <hash> <space-separated-list>
    local needle="$1"; shift
    local item
    for item in $1; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

# ════════════════════════════════════════════════════════════════════════
# CHECK A+B — SHAPE + MEMBERSHIP (the load-bearing assertion).
# ════════════════════════════════════════════════════════════════════════
SCAN_T="bad"; SHAPE_T="bad"
NEEDLE="[\"addr($ADDR)\"]"
RESP=$(lb_scan "start" "$NEEDLE" 0 "$TIP")
# Shape: from_height/to_height/completed/relevant_blocks
FROM=$(jpy "$RESP" "d['result']['from_height']")
TO=$(jpy "$RESP" "d['result']['to_height']")
COMPLETED=$(jpy "$RESP" "d['result']['completed']")
RB_IS_ARR=$(jpy "$RESP" "isinstance(d['result']['relevant_blocks'], list)")
[[ "$FROM" == "0"    ]] || fail "from_height != 0 (got '$FROM'); resp=$RESP"
[[ "$TO"   == "$TIP" ]] || fail "to_height != tip $TIP (got '$TO'); resp=$RESP"
[[ "$COMPLETED" == "true" ]] || fail "completed != true (got '$COMPLETED'); resp=$RESP"
[[ "$RB_IS_ARR" == "true" ]] || fail "relevant_blocks is not an array; resp=$RESP"
# Every relevant block is a 64-hex string.
BADHEX=$(jpy "$RESP" "[x for x in d['result']['relevant_blocks'] if not (isinstance(x,str) and len(x)==64)]")
[[ "$BADHEX" == "[]" || -z "$BADHEX" ]] || fail "relevant_blocks contains non-64hex entries: $BADHEX"
SHAPE_T="ok"
log "shape ok: from=$FROM to=$TO completed=$COMPLETED"

RB=$(jpy "$RESP" "' '.join(d['result']['relevant_blocks'])")
# MEMBERSHIP: both known-true blocks MUST appear (false positives are extra-OK).
in_list "$BLOCK1_HASH" "$RB"      || fail "MEMBERSHIP: block1 ($BLOCK1_HASH, coinbase->ADDR) NOT in relevant_blocks: [$RB]"
in_list "$SPEND_BLOCKHASH" "$RB"  || fail "MEMBERSHIP: spend block ($SPEND_BLOCKHASH, h$SPEND_HEIGHT) NOT in relevant_blocks: [$RB]"
log "membership ok: block1 + spend block both present in relevant_blocks ($(echo "$RB" | wc -w) total)"

# ════════════════════════════════════════════════════════════════════════
# CHECK C — CORE CROSS-CHECK (superset-consistent on the known-true set).
# ════════════════════════════════════════════════════════════════════════
CORE_RB=$(co_scan_blocks "[\"addr($ADDR)\"]" 0 "$TIP")
[[ -n "$CORE_RB" ]] || fail "Core scanblocks returned empty/failed; CORE_RB='$CORE_RB'"
# Core MUST also report both known-true blocks (proves the oracle agrees).
in_list "$BLOCK1_HASH" "$CORE_RB"     || fail "Core scanblocks missing block1 (oracle sanity); core=[$CORE_RB]"
in_list "$SPEND_BLOCKHASH" "$CORE_RB" || fail "Core scanblocks missing spend block (oracle sanity); core=[$CORE_RB]"
# Projection equality on the known-true set: each known-true block is in BOTH.
log "core cross-check ok: Core relevant_blocks ⊇ known-true set; impl ⊇ known-true set"
SCAN_T="ok"

# ════════════════════════════════════════════════════════════════════════
# CHECK D — NEGATIVE NEEDLE: fresh unfunded addr must NOT match the funded blocks.
# ════════════════════════════════════════════════════════════════════════
NEG_RB=$(lb_scan_blocks "start" "[\"addr($NEGADDR)\"]" 0 "$TIP")
if in_list "$BLOCK1_HASH" "$NEG_RB"; then
    fail "NEGATIVE: unfunded addr matched block1 ($BLOCK1_HASH) — needle ignored? neg=[$NEG_RB]"
fi
if in_list "$SPEND_BLOCKHASH" "$NEG_RB"; then
    fail "NEGATIVE: unfunded addr matched spend block ($SPEND_BLOCKHASH) — needle ignored? neg=[$NEG_RB]"
fi
log "negative needle ok: unfunded addr did NOT match either funded block ($(echo "$NEG_RB" | wc -w) stray fp)"

# ════════════════════════════════════════════════════════════════════════
# CHECK E — RANGE BOUNDING.
# ════════════════════════════════════════════════════════════════════════
RANGE_T="bad"
# (i) 1-block window on the spend block: from==to==H_spend, spend block present.
W1=$(lb_scan "start" "$NEEDLE" "$SPEND_HEIGHT" "$SPEND_HEIGHT")
W1_FROM=$(jpy "$W1" "d['result']['from_height']")
W1_TO=$(jpy "$W1" "d['result']['to_height']")
W1_RB=$(jpy "$W1" "' '.join(d['result']['relevant_blocks'])")
W1_N=$(jpy "$W1" "len(d['result']['relevant_blocks'])")
[[ "$W1_FROM" == "$SPEND_HEIGHT" ]] || fail "RANGE: 1-block window from_height != $SPEND_HEIGHT (got '$W1_FROM'); resp=$W1"
[[ "$W1_TO"   == "$SPEND_HEIGHT" ]] || fail "RANGE: 1-block window to_height != $SPEND_HEIGHT (got '$W1_TO'); resp=$W1"
in_list "$SPEND_BLOCKHASH" "$W1_RB"  || fail "RANGE: spend block missing from its own 1-block window; resp=$W1"
# relevant_blocks ⊆ that single block (at most 1 entry — only the spend block in range).
[[ "$W1_N" == "1" ]] || fail "RANGE: 1-block window returned $W1_N blocks, expected exactly 1 (the spend block); resp=$W1"
# (ii) a window strictly BELOW all funded heights (2..50) must NOT contain the
# funded blocks (block1 is at h1, below; spend at TIP, above). So a [2,50]
# window excludes BOTH funded blocks.
W2_RB=$(lb_scan_blocks "start" "$NEEDLE" 2 50)
if in_list "$BLOCK1_HASH" "$W2_RB"; then fail "RANGE: window [2,50] contains block1 (h1, out of range); w2=[$W2_RB]"; fi
if in_list "$SPEND_BLOCKHASH" "$W2_RB"; then fail "RANGE: window [2,50] contains spend block (h$SPEND_HEIGHT, out of range); w2=[$W2_RB]"; fi
RANGE_T="ok"
log "range bounding ok: 1-block spend window exact; [2,50] excludes both funded blocks"

# ════════════════════════════════════════════════════════════════════════
# CHECK F — ACTIONS: status->null ; abort->false ; bogus->error.
# ════════════════════════════════════════════════════════════════════════
ST=$(lb_rpc scanblocks "[\"status\"]")
ST_RES=$(jpy "$ST" "d['result']")
ST_HASERR=$(jpy "$ST" "'error' in d and d['error'] is not None")
# status must be JSON null (result present and null, no error).
[[ "$ST_HASERR" != "true" ]] || fail "ACTIONS: status returned an error: $ST"
[[ "$ST_RES" == "None" ]]    || fail "ACTIONS: status did not return null (got '$ST_RES'); resp=$ST"
AB=$(lb_rpc scanblocks "[\"abort\"]")
AB_RES=$(jpy "$AB" "d['result']")
[[ "$AB_RES" == "false" ]] || fail "ACTIONS: abort did not return false (got '$AB_RES'); resp=$AB"
BG=$(lb_rpc scanblocks "[\"bogusaction\"]")
BG_ECODE=$(jpy "$BG" "d.get('error',{}).get('code')")
[[ "$BG_ECODE" =~ ^-[0-9]+$ ]] || fail "ACTIONS: bogus action did not return an error code (got '$BG_ECODE'); resp=$BG"
log "actions ok: status=null abort=false bogus->error($BG_ECODE)"

# ════════════════════════════════════════════════════════════════════════
# CHECK G — ERRORS (codes are the hard requirement; message is soft).
# ════════════════════════════════════════════════════════════════════════
ERR_T="bad"
# (a) unknown filtertype -> -5.
EF=$(lb_rpc scanblocks "[\"start\", $NEEDLE, 0, $TIP, \"bogustype\"]")
EF_CODE=$(jpy "$EF" "d['error']['code']")
EF_MSG=$(jpy "$EF" "d['error']['message']")
[[ "$EF_CODE" == "-5" ]] || fail "ERRORS: unknown filtertype expected -5, got '$EF_CODE' (resp=$EF)"
case "$EF_MSG" in
    *[Uu]nknown*filtertype*) : ;;
    *) log "WARNING: unknown-filtertype message not 'Unknown filtertype': '$EF_MSG' (code -5 is the hard requirement)";;
esac
# Core agreement (soft).
CEF=$(core_cli scanblocks start "$NEEDLE" 0 "$TIP" bogustype 2>&1 | grep -oE '\-5' | head -1)
[[ "$CEF" == "-5" ]] || log "WARNING: could not confirm Core returns -5 for unknown filtertype (lunarblock is -5)"
# (b) out-of-range start (tip+1) -> -1.
ES=$(lb_rpc scanblocks "[\"start\", $NEEDLE, $(( TIP + 1 )), $TIP, \"basic\"]")
ES_CODE=$(jpy "$ES" "d['error']['code']")
ES_MSG=$(jpy "$ES" "d['error']['message']")
[[ "$ES_CODE" == "-1" ]] || fail "ERRORS: start>tip expected -1, got '$ES_CODE' (resp=$ES)"
case "$ES_MSG" in
    *[Ii]nvalid*start*) : ;;
    *) log "WARNING: out-of-range start message not 'Invalid start_height': '$ES_MSG' (code -1 is the hard requirement)";;
esac
CES=$(core_cli scanblocks start "$NEEDLE" "$(( TIP + 1 ))" "$TIP" basic 2>&1 | grep -oE '\-1' | head -1)
[[ "$CES" == "-1" ]] || log "WARNING: could not confirm Core returns -1 for out-of-range start (lunarblock is -1)"
# (c) stop < start -> -1.
EE=$(lb_rpc scanblocks "[\"start\", $NEEDLE, 10, 5, \"basic\"]")
EE_CODE=$(jpy "$EE" "d['error']['code']")
EE_MSG=$(jpy "$EE" "d['error']['message']")
[[ "$EE_CODE" == "-1" ]] || fail "ERRORS: stop<start expected -1, got '$EE_CODE' (resp=$EE)"
case "$EE_MSG" in
    *[Ii]nvalid*stop*) : ;;
    *) log "WARNING: stop<start message not 'Invalid stop_height': '$EE_MSG' (code -1 is the hard requirement)";;
esac
CEE=$(core_cli scanblocks start "$NEEDLE" 10 5 basic 2>&1 | grep -oE '\-1' | head -1)
[[ "$CEE" == "-1" ]] || log "WARNING: could not confirm Core returns -1 for stop<start (lunarblock is -1)"
ERR_T="ok"
log "errors ok: filtertype=-5 start>tip=-1 stop<start=-1"

log "PASS: lunarblock scanblocks matches Core on membership + core-superset + negative + range + actions + errors"
pass "$SCAN_T" "$SHAPE_T" "$RANGE_T" "$ERR_T"
