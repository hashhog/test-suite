#!/usr/bin/env bash
#
# rustoshi_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity test.
#
# The DEEPEST indexing green-cell yet. gettxoutsetinfo returns statistics about
# the entire unspent-transaction-output (UTXO) set, INCLUDING a cryptographic
# HASH of that set. Matching that hash byte-for-byte against Bitcoin Core proves
# rustoshi's consensus STATE — its complete UTXO set — is byte-identical to
# Core's, not merely that an RPC has the right shape. The hash is a fingerprint
# of every unspent coin (txid, vout, height|coinbase, value, scriptPubKey).
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:1010+ (gettxoutsetinfo) +
#           src/kernel/coinstats.cpp (hash_serialized_3 / muhash kernels,
#           per-coin TxOutSer, GetBogoSize, total_amount accounting).
#   SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index ).
#              hash_type default "hash_serialized_3"; options
#              "hash_serialized_3" | "muhash" | "none".
#   OUTPUT (base, no coinstatsindex):
#     { height, bestblock, txouts, bogosize,
#       hash_serialized_3 (only when hash_type=hash_serialized_3),
#       muhash (only when hash_type=muhash),
#       transactions, disk_size, total_amount }
#   hash_serialized_3: SHA256d over the UTXO set serialized in COIN-CURSOR ORDER
#     (outpoint key = txid then vout), per-coin = (txid, vout, height<<1|coinbase,
#     txout) where txout = value(int64 LE) || CompactSize(spk_len) || spk.
#     Deterministic given the same UTXO set.
#   ERRORS:
#     hash_serialized_3 with a specific block/height -> -8 (RPC_INVALID_PARAMETER)
#       "hash_serialized_3 hash type cannot be queried for a specific block".
#     unrecognized hash_type -> error.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest instance +
#   OWN ports, launched -listen=0. Core is the SINGLE source of blocks: Core
#   mines ~110 blocks AND broadcasts at least one SPEND tx (so the UTXO set has
#   a spent output REMOVED and new outputs ADDED, not just coinbases), then
#   each block's raw hex is replayed into rustoshi via submitblock. After replay
#   both nodes hold the byte-identical chain, hence the byte-identical UTXO set,
#   so gettxoutsetinfo MUST agree — height, bestblock, txouts, total_amount,
#   AND the set hash.
#
# WHAT MUST MATCH CORE EXACTLY:
#   1. FIELDS+HASH: height, bestblock, txouts, total_amount ALL EXACT vs Core,
#      AND the set hash (hash_serialized_3) byte-EXACT vs Core. The hash match
#      is THE point — it proves the whole UTXO set is identical.
#   2. MUTATE: after mining ONE more block (changes the set), re-query ->
#      height+1, bestblock changed, the set hash changed on BOTH and still
#      matches between rustoshi and Core.
#   3. ERRORS: gettxoutsetinfo hash_serialized_3 <height> -> -8; gettxoutsetinfo
#      <bogus hash_type> -> error. bogosize/transactions/disk_size: assert
#      PRESENT + typed, NOT byte-equal (bogosize is "meaningless", disk_size is
#      impl-specific).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/blockfilter/rustoshi_getblockfilter.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO rustoshi: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO rustoshi: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO rustoshi: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-rustoshi/ + /tmp/gtxo-core/ and ports
#   22170/22190 (rustoshi RPC/P2P) + 22172/22192 (Core RPC; P2P unused, -listen=0).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Does NOT
#   broad-pkill bitcoind by name. Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

RS_DATADIR="/tmp/gtxo-rustoshi/$$"
RS_RPC=22170
RS_P2P=22190
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/gtxo-core/$$"
CORE_RPC=22172
CORE_P2P=22192   # declared but Core launched -listen=0 (no P2P listener)
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=110        # mine 110 empty blocks (matures the first coinbase at h=1)
TBASE=1700000000   # pin nTime so Core's blocks are deterministic

RS_PID=""
RS_COOKIE=""
CORE_BG=""
ADDR=""

log() { echo "[gettxoutsetinfo:rustoshi] $*" >&2; }

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
    echo "GETTXOUTSETINFO rustoshi: PASS fields=$1 hash=$2 mutate=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTSETINFO rustoshi: FAIL $*"
    exit 1
}
skip() {
    echo "GETTXOUTSETINFO rustoshi: SKIP $*"
    exit 0
}

# Poll until a TCP port is free (a just-killed node can hold the socket briefly).
wait_port_free() {
    local port="$1"
    for _ in $(seq 1 20); do
        if ! { exec 3<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null; then
            return 0
        fi
        exec 3>&- 2>/dev/null || true
        sleep 1
    done
    return 0
}

# ── 0. Idempotent reset (own ports + own PID scratch only). ───────────────
log "resetting scratch state (pid=$$)"
pkill -f "gtxo-rustoshi/$$" 2>/dev/null || true
if ss -tln 2>/dev/null | grep -qE ":(${RS_RPC}|${RS_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${RS_RPC}/${RS_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
wait_port_free "$RS_RPC"; wait_port_free "$RS_P2P"
wait_port_free "$CORE_RPC"; wait_port_free "$CORE_P2P"
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
core_cli_retry() {
    local out=""
    for _ in $(seq 1 15); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 2
    done
    return 1
}
rs_rpc() {
    curl -s --max-time 120 -u "$RS_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$RS_RPC/" 2>/dev/null
}
# Extract a python expression `$2` over JSON `$1` read from stdin (var: d).
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

# ── 3. Launch the Core regtest oracle (-listen=0). ────────────────────────
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
    wait_port_free "$CORE_RPC"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
        -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle (-listen=0) rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch rustoshi on regtest. ────────────────────────────────────────
log "launching rustoshi (regtest) rpc=:$RS_RPC p2p=:$RS_P2P -> $RS_LOG"
"$NODE_BIN" --network=regtest --datadir="$RS_DATADIR" \
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

# Capability probe: if rustoshi does not implement gettxoutsetinfo, SKIP.
PROBE=$(rs_rpc gettxoutsetinfo '[]')
PROBE_ECODE=$(jpy "$PROBE" "d.get('error',{}).get('code')")
if [[ "$PROBE_ECODE" == "-32601" ]]; then
    skip "no gettxoutsetinfo RPC (method not found)"
fi

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

# Build a SPEND with NO wallet (this bitcoind build has no wallet support):
# spend the matured coinbase at height 1 (paid to ADDR = p2wpkh of SECRET) via a
# RAW, locally-signed BIP-143 segwit tx, broadcast with sendrawtransaction, mine
# into block NBLOCKS+1. This REMOVES the coinbase-1 output from the UTXO set and
# ADDS a new p2wpkh output -> the UTXO set is no longer all coinbases, so the
# set hash genuinely exercises spent-then-recreated state.
DESTSECRET="2222222222222222222222222222222222222222222222222222222222222223"

CB_BLOCK1=$(core_cli_retry getblockhash 1)               || fail "getblockhash 1 failed"
CB1_TXID=$(core_cli_retry getblock "$CB_BLOCK1" 1 | python3 -c "import sys,json; print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ "$CB1_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not read coinbase txid at height 1: '$CB1_TXID'"
CB1_RAW=$(core_cli_retry getrawtransaction "$CB1_TXID" 0 "$CB_BLOCK1") || fail "getrawtransaction coinbase h1 failed"
[[ -n "$CB1_RAW" ]] || fail "empty coinbase raw at h1"
log "spending coinbase $CB1_TXID:0 (block 1) via raw BIP-143 segwit tx"

SPEND_RAW=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import SegwitV0SignatureHash, SIGHASH_ALL
from test_framework.script_util import key_to_p2wpkh_script, keyhash_to_p2pkh_script
from test_framework.key import ECKey
import io, hashlib

def hash160(b):
    return hashlib.new('ripemd160', hashlib.sha256(b).digest()).digest()

src = ECKey(); src.set(bytes.fromhex('$SECRET'), True)
src_pub = src.get_pubkey().get_bytes()
src_spk = key_to_p2wpkh_script(src_pub)

dst = ECKey(); dst.set(bytes.fromhex('$DESTSECRET'), True)
dst_spk = key_to_p2wpkh_script(dst.get_pubkey().get_bytes())

cb = CTransaction()
cb.deserialize(io.BytesIO(bytes.fromhex('$CB1_RAW')))
amount = cb.vout[0].nValue
assert bytes(cb.vout[0].scriptPubKey) == bytes(src_spk), 'coinbase vout0 spk != p2wpkh(SECRET)'

txid_internal = int.from_bytes(bytes.fromhex('$CB1_TXID')[::-1], 'little')

tx = CTransaction()
tx.vin.append(CTxIn(COutPoint(txid_internal, 0), b'', 0xffffffff))
fee = 1000
tx.vout.append(CTxOut(amount - fee, dst_spk))
tx.wit.vtxinwit.append(CTxInWitness())

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

core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || {
    sleep 1
    core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || fail "Core failed to mine the spend block"
}

CORE_HEIGHT=$(core_cli_retry getblockcount)
TOTAL=$(( NBLOCKS + 1 ))
[[ "$CORE_HEIGHT" == "$TOTAL" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $TOTAL"
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$CORE_HEIGHT")
core_cli_retry getblock "$SPEND_BLOCKHASH" 1 | grep -q "$SPEND_TXID" \
    || fail "spend tx $SPEND_TXID not found in block $SPEND_BLOCKHASH"
log "Core chain height = $CORE_HEIGHT (spend confirmed in block $CORE_HEIGHT)"

# ── 6. Replay ALL of Core's raw blocks into rustoshi via submitblock. ─────
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
CORE_TIP=$(core_cli_retry getbestblockhash)
RS_TIP=$(jpy "$(rs_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" == "$RS_TIP" ]] || fail "tip mismatch after replay: core=$CORE_TIP rust=$RS_TIP"
log "rustoshi replayed to height $RS_HEIGHT, tip identical ($RS_TIP) — UTXO sets must match"

# ── helpers for gettxoutsetinfo ───────────────────────────────────────────
# rs_gtxo <field> [hash_type]  -> field of rustoshi's gettxoutsetinfo
rs_gtxo() {
    local field="$1" ht="${2:-}"
    local params="[]"
    [[ -n "$ht" ]] && params="[\"$ht\"]"
    jpy "$(rs_rpc gettxoutsetinfo "$params")" "d['result'].get('$field')"
}
# co_gtxo <field> [hash_type]  -> field of Core's gettxoutsetinfo
co_gtxo() {
    local field="$1" ht="${2:-}"
    if [[ -n "$ht" ]]; then
        core_cli_retry gettxoutsetinfo "$ht" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$field'))" 2>/dev/null
    else
        core_cli_retry gettxoutsetinfo | python3 -c "import sys,json; print(json.load(sys.stdin).get('$field'))" 2>/dev/null
    fi
}
# Compare two BTC-decimal amounts at satoshi precision (Core emits up to 8
# decimals; rustoshi's f64 may differ in the LSB, so compare rounded sats).
amt_eq() {
    python3 -c "
a = round(float('$1') * 1e8); b = round(float('$2') * 1e8)
print('eq' if a == b else 'ne')
" 2>/dev/null
}

# ── 7. CHECK 1 — FIELDS + HASH (default hash_type = hash_serialized_3). ────
FIELDS_T="bad"; HASH_T="bad"

# Confirm rustoshi emits the default hash field at all (else SKIP — no set-hash
# machinery is the documented BLOCKED/SKIP path, not a fake PASS).
RS_HASHFIELD=$(rs_gtxo hash_serialized_3)
if [[ -z "$RS_HASHFIELD" || "$RS_HASHFIELD" == "None" ]]; then
    # maybe rustoshi's strong hash is muhash only; probe that before giving up.
    RS_MU=$(rs_gtxo muhash muhash)
    [[ -z "$RS_MU" || "$RS_MU" == "None" ]] && skip "rustoshi emits neither hash_serialized_3 nor muhash"
fi

RS_HEIGHT_F=$(rs_gtxo height);     CO_HEIGHT_F=$(co_gtxo height)
RS_BEST_F=$(rs_gtxo bestblock);    CO_BEST_F=$(co_gtxo bestblock)
RS_TXOUTS=$(rs_gtxo txouts);       CO_TXOUTS=$(co_gtxo txouts)
RS_TOTAL=$(rs_gtxo total_amount);  CO_TOTAL=$(co_gtxo total_amount)

[[ "$RS_HEIGHT_F" =~ ^[0-9]+$ ]] || fail "rustoshi height not int: '$RS_HEIGHT_F'"
[[ "$RS_TXOUTS"   =~ ^[0-9]+$ ]] || fail "rustoshi txouts not int: '$RS_TXOUTS'"
[[ "$RS_HEIGHT_F" == "$CO_HEIGHT_F" ]] || fail "height mismatch: rust=$RS_HEIGHT_F core=$CO_HEIGHT_F"
[[ "$RS_BEST_F"   == "$CO_BEST_F"   ]] || fail "bestblock mismatch: rust=$RS_BEST_F core=$CO_BEST_F"
[[ "$RS_TXOUTS"   == "$CO_TXOUTS"   ]] || fail "txouts mismatch: rust=$RS_TXOUTS core=$CO_TXOUTS"
[[ "$(amt_eq "$RS_TOTAL" "$CO_TOTAL")" == "eq" ]] \
    || fail "total_amount mismatch: rust=$RS_TOTAL core=$CO_TOTAL"
log "fields exact: height=$RS_HEIGHT_F bestblock=$RS_BEST_F txouts=$RS_TXOUTS total_amount=$RS_TOTAL"

# bogosize / transactions / disk_size: PRESENT + typed (NOT byte-equal).
RS_BOGO=$(rs_gtxo bogosize); RS_NTX=$(rs_gtxo transactions); RS_DISK=$(rs_gtxo disk_size)
[[ "$RS_BOGO" =~ ^[0-9]+$ ]] || fail "bogosize not present/typed: '$RS_BOGO'"
[[ "$RS_NTX"  =~ ^[0-9]+$ ]] || fail "transactions not present/typed: '$RS_NTX'"
[[ "$RS_DISK" =~ ^[0-9]+$ ]] || fail "disk_size not present/typed: '$RS_DISK'"
log "typed-present (not byte-equal): bogosize=$RS_BOGO transactions=$RS_NTX disk_size=$RS_DISK"
FIELDS_T="ok"

# THE POINT: the set hash, byte-EXACT vs Core, like-for-like hash_type.
# Prefer hash_serialized_3 (the default + Core-canonical). Fall back to muhash
# only if rustoshi does not emit hash_serialized_3.
HASH_KIND=""
if [[ -n "$RS_HASHFIELD" && "$RS_HASHFIELD" != "None" ]]; then
    HASH_KIND="hash_serialized_3"
    RS_SETHASH="$RS_HASHFIELD"
    CO_SETHASH=$(co_gtxo hash_serialized_3)
else
    HASH_KIND="muhash"
    RS_SETHASH=$(rs_gtxo muhash muhash)
    CO_SETHASH=$(co_gtxo muhash muhash)
fi
[[ "$RS_SETHASH" =~ ^[0-9a-f]{64}$ ]] || fail "rustoshi $HASH_KIND not 64-hex: '$RS_SETHASH'"
[[ "$CO_SETHASH" =~ ^[0-9a-f]{64}$ ]] || fail "Core $HASH_KIND not 64-hex: '$CO_SETHASH'"
if [[ "$RS_SETHASH" != "$CO_SETHASH" ]]; then
    fail "UTXO-set $HASH_KIND mismatch: rust=$RS_SETHASH core=$CO_SETHASH"
fi
log "UTXO-set $HASH_KIND byte-EXACT vs Core: $RS_SETHASH"
HASH_T="ok"

# ── 8. CHECK 2 — MUTATE: mine ONE more block, the set hash must change & match.
MUTATE_T="bad"
PRE_HEIGHT="$RS_HEIGHT_F"
PRE_BEST="$RS_BEST_F"
PRE_HASH="$RS_SETHASH"

core_cli setmocktime "$(( TBASE + NBLOCKS + 2 ))" >/dev/null 2>&1 || true
core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || {
    sleep 1
    core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || fail "Core failed to mine the mutate block"
}
NEW_HEIGHT=$(core_cli_retry getblockcount)
[[ "$NEW_HEIGHT" == "$(( PRE_HEIGHT + 1 ))" ]] || fail "Core height after mutate is $NEW_HEIGHT, expected $(( PRE_HEIGHT + 1 ))"
NEW_BH=$(core_cli_retry getblockhash "$NEW_HEIGHT")
NEW_RAW=$(core_cli_retry getblock "$NEW_BH" 0)
[[ -n "$NEW_RAW" ]] || fail "could not fetch mutate block raw"
sb=$(rs_rpc submitblock "[\"$NEW_RAW\"]")
sbres=$(jpy "$sb" "d.get('result')")
if [[ -n "$sbres" && "$sbres" != "None" && "$sbres" != "duplicate" && "$sbres" != "inconclusive" ]]; then
    fail "rustoshi submitblock rejected mutate block: result='$sbres' raw_resp=$sb"
fi
RS_NEW_HEIGHT=$(jpy "$(rs_rpc getblockcount '[]')" "d['result']")
[[ "$RS_NEW_HEIGHT" == "$NEW_HEIGHT" ]] || fail "rustoshi height after mutate is $RS_NEW_HEIGHT, expected $NEW_HEIGHT"

# Re-query both nodes with the SAME hash_kind.
if [[ "$HASH_KIND" == "muhash" ]]; then
    RS_POST_HASH=$(rs_gtxo muhash muhash); CO_POST_HASH=$(co_gtxo muhash muhash)
else
    RS_POST_HASH=$(rs_gtxo hash_serialized_3); CO_POST_HASH=$(co_gtxo hash_serialized_3)
fi
RS_POST_HEIGHT=$(rs_gtxo height); RS_POST_BEST=$(rs_gtxo bestblock)

[[ "$RS_POST_HEIGHT" == "$(( PRE_HEIGHT + 1 ))" ]] || fail "post-mutate height not +1: $RS_POST_HEIGHT (pre $PRE_HEIGHT)"
[[ "$RS_POST_BEST" != "$PRE_BEST" ]] || fail "post-mutate bestblock did NOT change: still $RS_POST_BEST"
[[ "$RS_POST_BEST" == "$NEW_BH"  ]] || fail "post-mutate bestblock != new tip: rust=$RS_POST_BEST tip=$NEW_BH"
[[ "$RS_POST_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "post-mutate $HASH_KIND not 64-hex: '$RS_POST_HASH'"
[[ "$RS_POST_HASH" != "$PRE_HASH" ]] || fail "post-mutate set $HASH_KIND did NOT change (set unchanged?): $RS_POST_HASH"
[[ "$RS_POST_HASH" == "$CO_POST_HASH" ]] || fail "post-mutate $HASH_KIND mismatch vs Core: rust=$RS_POST_HASH core=$CO_POST_HASH"
log "mutate ok: height $PRE_HEIGHT->$RS_POST_HEIGHT, $HASH_KIND changed $PRE_HASH -> $RS_POST_HASH (matches Core)"
MUTATE_T="ok"

# ── 9. CHECK 3 — ERRORS. ───────────────────────────────────────────────────
ERR_T="bad"
# (a) hash_serialized_3 with a specific block/height -> -8.
E1=$(rs_rpc gettxoutsetinfo "[\"hash_serialized_3\", $PRE_HEIGHT]")
E1_CODE=$(jpy "$E1" "d.get('error',{}).get('code')")
E1_MSG=$(jpy "$E1" "d.get('error',{}).get('message','')")
[[ "$E1_CODE" == "-8" ]] || fail "hash_serialized_3 <height>: expected -8, got '$E1_CODE' (resp=$E1)"
case "$E1_MSG" in
    *specific*block*) : ;;
    *) log "WARNING: -8 message not the canonical 'cannot be queried for a specific block': '$E1_MSG' (code -8 is the hard requirement)";;
esac
# Core agreement (Core also -8 for this case).
CE1=$(core_cli gettxoutsetinfo hash_serialized_3 "$PRE_HEIGHT" 2>&1 | grep -oE '\-8' | head -1)
[[ "$CE1" == "-8" ]] || log "WARNING: could not confirm Core returns -8 for hash_serialized_3 <height> (rustoshi is -8, which is the requirement)"

# (b) bogus hash_type -> error (any RPC error object).
E2=$(rs_rpc gettxoutsetinfo "[\"bogushashtype\"]")
E2_CODE=$(jpy "$E2" "d.get('error',{}).get('code')")
[[ -n "$E2_CODE" && "$E2_CODE" != "None" ]] || fail "bogus hash_type: expected an error, got none (resp=$E2)"
[[ "$E2_CODE" =~ ^-?[0-9]+$ ]] || fail "bogus hash_type: error code not numeric: '$E2_CODE' (resp=$E2)"
log "errors ok: hash_serialized_3 <height> -> -8 ; bogus hash_type -> error code $E2_CODE"
ERR_T="ok"

log "PASS: rustoshi gettxoutsetinfo matches Core on fields + UTXO-set hash + mutate + errors"
pass "$FIELDS_T" "$HASH_T" "$MUTATE_T" "$ERR_T"
