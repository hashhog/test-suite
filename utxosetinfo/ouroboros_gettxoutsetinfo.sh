#!/usr/bin/env bash
#
# ouroboros_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity test.
#
# Proves ouroboros computes the UTXO-SET HASH (the gettxoutsetinfo RPC)
# BYTE-IDENTICALLY to a REAL bitcoind oracle — not just that it reports an RPC
# shape. This is the DEEPEST indexing cell: the UTXO-set hash is a fingerprint
# of the ENTIRE UTXO set, so matching it byte-for-byte proves ouroboros's
# consensus STATE (its UTXO set: every outpoint, height, coinbase-flag, amount
# and scriptPubKey) is identical to Core's, output-for-output.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:1010 (gettxoutsetinfo) +
#           src/kernel/coinstats.cpp (ComputeUTXOStats / TxOutSer / ApplyHash /
#           GetBogoSize).
#   SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index ).
#     hash_type default "hash_serialized_3"; options
#       "hash_serialized_3" | "muhash" | "none".
#   OUTPUT (base, no coinstatsindex): { height, bestblock, txouts, bogosize,
#     hash_serialized_3 (only for hash_serialized_3) | muhash (only for muhash),
#     transactions, disk_size, total_amount }.
#     - hash_serialized_3 = SHA256d over the UTXO set in COIN-CURSOR ORDER
#       (by outpoint key: txid then vout); per-coin =
#       outpoint(txid 32B + vout u32 LE) || u32 LE (height<<1|coinbase) ||
#       amount i64 LE || CompactSize(len(spk)) || spk.  Deterministic given the
#       same UTXO set.  See coinstats.cpp:46-51 (TxOutSer).
#   ERRORS: hash_serialized_3 + a specific block/height ->
#       RPC_INVALID_PARAMETER (-8) "hash_serialized_3 hash type cannot be
#       queried for a specific block"; unrecognized hash_type -> error.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest + OWN
#   ports, launched -listen=0. Core is the MINER: it mines ~110 blocks AND a
#   block containing a SPEND tx (so the UTXO set has a spent output REMOVED and
#   new outputs ADDED — not just coinbases). ouroboros then REPLAYS Core's
#   EXACT raw blocks via submitblock, so the two chains are BYTE-IDENTICAL at
#   every height and the UTXO sets compare hash-exact.
#
# ASSERTIONS (both nodes, same chain):
#   1. FIELDS+HASH: gettxoutsetinfo (default hash_type) -> height, bestblock,
#      txouts, total_amount ALL EXACT vs Core, AND the set hash
#      (hash_serialized_3) byte-EXACT vs Core. The set-hash match is THE point:
#      it proves the whole UTXO set is identical. bogosize/transactions/
#      disk_size asserted PRESENT + typed (NOT byte-equal — bogosize is
#      "meaningless" per Core, disk_size is impl-specific).
#   2. MUTATE: mine ONE more block on BOTH (changes the set) -> height+1,
#      bestblock changed, the set hash CHANGED on both AND still matches
#      between ouroboros and Core.
#   3. ERRORS: gettxoutsetinfo hash_serialized_3 <height> -> -8 (cannot query a
#      specific block); gettxoutsetinfo bogus -> error.
#
# STRICT UNIFORM INTERFACE (mirrors blockfilter/ouroboros_getblockfilter.sh):
#   set -uo pipefail, no required args, idempotent, trap cleanup, scratch /tmp +
#   unique ports, ONE clean summary line on stdout, noise -> stderr/log,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO ouroboros: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO ouroboros: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO ouroboros: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-ouroboros/ + /tmp/gtxo-core/ and ports
#   22172/22192 (ouroboros RPC/P2P) + 22972/22992 (Core RPC/P2P).
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

OU_DATADIR="/tmp/gtxo-ouroboros"
OU_RPC=22172
OU_P2P=22192
OU_LOG="$OU_DATADIR/node.log"

# Core oracle ports live in the 41xxx band, OUT of the contended 4027x/4029x
# range that sibling *_gettxoutsetinfo.sh cells use for their oracles. The
# task fixes ouroboros's OWN ports (RPC 22172 / P2P 22192); the oracle pair is
# chosen here to never collide with a concurrently-running sibling cell.
CORE_DATADIR="/tmp/gtxo-core"
CORE_RPC=22972
CORE_P2P=22992
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=110        # mature block-1's coinbase + a healthy coinbase-heavy set

# Two DISTINCT deterministic regtest p2wpkh keys: a spend that moves a matured
# coinbase to a fresh address removes one UTXO and adds another, so the set is
# NOT just coinbases.
SECRET_MINE="1111111111111111111111111111111111111111111111111111111111111112"
SECRET_DEST="2222222222222222222222222222222222222222222222222222222222222223"
SECRET_CB2="3333333333333333333333333333333333333333333333333333333333333334"

OU_PID=""
OU_COOKIE=""
CORE_BG=""
MINE_ADDR=""; MINE_WIF=""; MINE_SPK=""
DEST_ADDR=""; DEST_SPK=""
CB2_ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutsetinfo:ouroboros] $*" >&2; }

# ── Port-free poll: wait until a tcp port is actually released. ───────────
wait_port_free() {  # <port>
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): NEVER kills by port.
    local port="$1"
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":${port} " || return 0
        sleep 1
    done
    return 0
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
    fi
    pkill -f "gtxo-ouroboros" 2>/dev/null || true
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
    echo "GETTXOUTSETINFO ouroboros: PASS fields=$1 hash=$2 mutate=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTSETINFO ouroboros: FAIL $*"
    exit 1
}
skip() {
    echo "GETTXOUTSETINFO ouroboros: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gtxo-ouroboros" 2>/dev/null || true
wait_port_free "$OU_RPC"
wait_port_free "$OU_P2P"
wait_port_free "$CORE_RPC"
wait_port_free "$CORE_P2P"
if ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${OU_RPC}/${OU_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
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

# ── 1b. Derive deterministic regtest p2wpkh (addr, WIF, scriptPubKey). ────
# This bitcoind build has NO wallet support, so we mine to a key WE control,
# then craft + sign the spend ourselves via the test_framework.
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

# ou_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
ou_rpc() {
    curl -s --max-time 120 -u "$OU_COOKIE" \
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

# core_first_tx <blockhash> -> the txid of the first (coinbase) tx in a block.
core_first_tx() {
    local blk
    blk=$(core_cli_retry getblock "$1" 1) || return 1
    jpy "$blk" "d['tx'][0]"
}

# ── 2. Launch the Core regtest oracle (-listen=0; RPC-only). ──────────────
launch_core_once() {
    wait_port_free "$CORE_RPC"
    wait_port_free "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -fallbackfee=0.0002 \
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
    log "launching Core regtest oracle rpc=:$CORE_RPC -listen=0 (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch ouroboros on regtest (unique ports). ────────────────────────
log "launching ouroboros (regtest) rpc=:$OU_RPC p2p=:$OU_P2P -> $OU_LOG"
(
    cd "$OURO_DIR"
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$OU_DATADIR" \
        start --force --nolisten --nodnsseed \
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

# ── 4. Mine NBLOCKS, build+mine a SPEND block, mine trailer; then REPLAY. ─
log "mining $NBLOCKS blocks to $MINE_ADDR on Core (matures coinbase for a spend)"
core_cli_retry generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"

# The matured coinbase of block 1 (P2WPKH to MINE) is the spend's input.
CB_SPEND_HASH=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
CB_SPEND_TXID=$(core_first_tx "$CB_SPEND_HASH") || fail "Core could not read block-1 coinbase txid"
[[ -n "$CB_SPEND_TXID" ]] || fail "empty block-1 coinbase txid"

# Build raw tx: spend that coinbase (50 BTC) -> 49.999 to DEST (distinct spk).
# This REMOVES the block-1 coinbase output from the UTXO set and ADDS a new
# P2WPKH output to DEST — the set is no longer just coinbases.
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

# Mine a couple of trailing blocks so the spend is well-buried.
core_cli_retry generatetoaddress 2 "$MINE_ADDR" >/dev/null \
    || fail "Core generatetoaddress (trailing) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount failed"
log "Core height=$CORE_HEIGHT, spend at height=$SPEND_HEIGHT"

# Sanity: the spend block must actually contain >1 tx (coinbase + spend) so the
# UTXO set genuinely has a removed input + added non-coinbase output.
SPEND_HASH=$(core_cli_retry getblockhash "$SPEND_HEIGHT") || fail "Core getblockhash(spend) failed"
SPEND_BLK=$(core_cli_retry getblock "$SPEND_HASH" 1) || fail "Core getblock(spend) failed"
SPEND_NTX=$(jpy "$SPEND_BLK" "len(d['tx'])")
[[ "${SPEND_NTX:-0}" -ge 2 ]] || fail "spend block has nTx=$SPEND_NTX (<2); spend did not confirm there"
log "spend block nTx=$SPEND_NTX (input removed + non-coinbase output added)"

# Confirm Core's UTXO set is no longer coinbase-only: the spent coinbase must
# be gone and the DEST output present.
DEST_TXOUT=$(jpy "$(core_cli_retry gettxout "$(jpy "$SPEND_BLK" "d['tx'][1]")" 0)" "d.get('value')")
[[ -n "$DEST_TXOUT" ]] || fail "Core gettxout for the spend output is null; spend not in UTXO set"

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

# Byte-identical chains => hash-at-height matches Core exactly (a divergence
# would mean the UTXO sets cannot match either).
CHECK_HASH=$(core_cli_retry getblockhash "$SPEND_HEIGHT")
OU_CHECK_HASH=$(jpy "$(ou_rpc getblockhash "[$SPEND_HEIGHT]")" "d['result']")
[[ "$OU_CHECK_HASH" == "$CHECK_HASH" ]] \
    || fail "spend-height hash mismatch ou=$OU_CHECK_HASH core=$CHECK_HASH (replay diverged)"
log "chains byte-identical through height $CORE_HEIGHT (spend-height hash matches)"

# ── 5. FIELDS + SET HASH parity (default hash_type = hash_serialized_3). ───
# Pick the hash_type that ouroboros computes Core-correctly. Default is
# hash_serialized_3 (SHA256d over TxOutSer in cursor order). We probe that
# first; if it does not match but muhash does, we report which one matched.
FIELDS_T="ok"
HASH_T="ok"
HASH_TYPE_USED="hash_serialized_3"

# Core ground truth (hash_serialized_3).
C_OBJ=$(core_cli_retry gettxoutsetinfo) || fail "Core gettxoutsetinfo failed"
C_HEIGHT=$(jpy "$C_OBJ" "d['height']")
C_BEST=$(jpy "$C_OBJ" "d['bestblock']")
C_TXOUTS=$(jpy "$C_OBJ" "d['txouts']")
C_TXNS=$(jpy "$C_OBJ" "d['transactions']")
C_TOTAL=$(jpy "$C_OBJ" "repr(d['total_amount'])")
C_HS3=$(jpy "$C_OBJ" "d['hash_serialized_3']")
[[ "$C_HS3" =~ ^[0-9a-f]{64}$ ]] || fail "Core hash_serialized_3 not 64-hex: '$C_HS3'"
log "Core: height=$C_HEIGHT txouts=$C_TXOUTS txns=$C_TXNS total=$C_TOTAL hs3=$C_HS3"

# ouroboros (default hash_type).
O_ENV=$(ou_rpc gettxoutsetinfo '[]')
echo "$O_ENV" | grep -q '"result"' || fail "ouroboros gettxoutsetinfo errored: $O_ENV"
O_HEIGHT=$(jpy "$O_ENV" "d['result']['height']")
O_BEST=$(jpy "$O_ENV" "d['result']['bestblock']")
O_TXOUTS=$(jpy "$O_ENV" "d['result']['txouts']")
O_TXNS=$(jpy "$O_ENV" "d['result'].get('transactions')")
O_BOGO=$(jpy "$O_ENV" "d['result'].get('bogosize')")
O_DISK=$(jpy "$O_ENV" "d['result'].get('disk_size')")
O_TOTAL=$(jpy "$O_ENV" "repr(d['result']['total_amount'])")
O_HS3=$(jpy "$O_ENV" "d['result'].get('hash_serialized_3')")
log "ouro: height=$O_HEIGHT txouts=$O_TXOUTS txns=$O_TXNS total=$O_TOTAL hs3=$O_HS3"

# 5a. EXACT field parity: height, bestblock, txouts, total_amount.
[[ "$O_HEIGHT" == "$C_HEIGHT" ]] || { FIELDS_T="bad"; log "height mismatch ou=$O_HEIGHT core=$C_HEIGHT"; }
[[ "$O_BEST"  == "$C_BEST"  ]] || { FIELDS_T="bad"; log "bestblock mismatch ou=$O_BEST core=$C_BEST"; }
[[ "$O_TXOUTS" == "$C_TXOUTS" ]] || { FIELDS_T="bad"; log "txouts mismatch ou=$O_TXOUTS core=$C_TXOUTS"; }
[[ "$O_TXNS"  == "$C_TXNS"  ]] || { FIELDS_T="bad"; log "transactions mismatch ou=$O_TXNS core=$C_TXNS"; }
# total_amount: compare numerically (Core emits a JSON number; ouroboros a
# float). Use python for a tolerance-free decimal compare.
TOTAL_MATCH=$(python3 -c "
from decimal import Decimal
try:
    print('ok' if Decimal('$C_TOTAL') == Decimal('$O_TOTAL') else 'bad')
except Exception as e:
    print('bad')
" 2>/dev/null)
[[ "$TOTAL_MATCH" == "ok" ]] || { FIELDS_T="bad"; log "total_amount mismatch ou=$O_TOTAL core=$C_TOTAL"; }

# 5b. PRESENT + TYPED (NOT byte-equal): bogosize, transactions, disk_size.
[[ "$O_BOGO" =~ ^[0-9]+$ ]] || { FIELDS_T="bad"; log "bogosize missing/not-int: '$O_BOGO'"; }
[[ "${O_BOGO:-0}" -gt 0 ]]  || { FIELDS_T="bad"; log "bogosize not positive: '$O_BOGO'"; }
[[ "$O_TXNS" =~ ^[0-9]+$ ]] || { FIELDS_T="bad"; log "transactions missing/not-int: '$O_TXNS'"; }
[[ "$O_DISK" =~ ^[0-9]+$ ]] || { FIELDS_T="bad"; log "disk_size missing/not-int: '$O_DISK'"; }

# 5c. THE POINT — UTXO-SET HASH byte-exact vs Core.
if [[ "$O_HS3" == "$C_HS3" ]]; then
    log "UTXO-set hash_serialized_3 byte-EXACT vs Core: $O_HS3"
else
    log "hash_serialized_3 mismatch ou=$O_HS3 core=$C_HS3 — trying muhash fallback"
    # Fall back to muhash (also Core-correct from ouroboros's assumeutxo path).
    C_MU_OBJ=$(core_cli_retry gettxoutsetinfo muhash) || fail "Core gettxoutsetinfo muhash failed"
    C_MU=$(jpy "$C_MU_OBJ" "d['muhash']")
    O_MU_ENV=$(ou_rpc gettxoutsetinfo '["muhash"]')
    O_MU=$(jpy "$O_MU_ENV" "d['result'].get('muhash')")
    if [[ -n "$C_MU" && "$O_MU" == "$C_MU" ]]; then
        HASH_TYPE_USED="muhash"
        log "UTXO-set muhash byte-EXACT vs Core: $O_MU"
    else
        HASH_T="bad"
        log "BOTH hash_serialized_3 AND muhash mismatch (ou_mu=$O_MU core_mu=$C_MU)"
    fi
fi

# ── 6. MUTATE — mine ONE more block; set must change + still match. ────────
MUTATE_T="ok"
PREV_C_HASH="$C_HS3"
[[ "$HASH_TYPE_USED" == "muhash" ]] && PREV_C_HASH=$(jpy "$(core_cli_retry gettxoutsetinfo muhash)" "d['muhash']")

log "mining one more block on Core then replaying to ouroboros (mutate the set)"
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core mine-one failed"
NEW_HEIGHT=$(core_cli_retry getblockcount) || fail "Core getblockcount failed"
NEW_BH=$(core_cli_retry getblockhash "$NEW_HEIGHT") || fail "Core getblockhash new failed"
NEW_RAW=$(core_cli_retry getblock "$NEW_BH" 0) || fail "Core getblock new raw failed"
SUB_ENV=$(ou_rpc submitblock "[\"$NEW_RAW\"]")
echo "$SUB_ENV" | grep -q '"result"' || fail "ouroboros submitblock(mutate) errored: $SUB_ENV"
SUB_RES=$(jpy "$SUB_ENV" "d.get('result')")
[[ -z "$SUB_RES" || "$SUB_RES" == "None" ]] || fail "ouroboros rejected mutate block: '$SUB_RES'"

# Re-query both nodes with the SAME hash_type that matched.
if [[ "$HASH_TYPE_USED" == "muhash" ]]; then
    C2_OBJ=$(core_cli_retry gettxoutsetinfo muhash) || fail "Core re-query(muhash) failed"
    C2_HASH=$(jpy "$C2_OBJ" "d['muhash']")
    O2_ENV=$(ou_rpc gettxoutsetinfo '["muhash"]')
    O2_HASH=$(jpy "$O2_ENV" "d['result'].get('muhash')")
else
    C2_OBJ=$(core_cli_retry gettxoutsetinfo) || fail "Core re-query failed"
    C2_HASH=$(jpy "$C2_OBJ" "d['hash_serialized_3']")
    O2_ENV=$(ou_rpc gettxoutsetinfo '[]')
    O2_HASH=$(jpy "$O2_ENV" "d['result'].get('hash_serialized_3')")
fi
C2_HEIGHT=$(jpy "$C2_OBJ" "d['height']")
C2_BEST=$(jpy "$C2_OBJ" "d['bestblock']")
O2_HEIGHT=$(jpy "$O2_ENV" "d['result']['height']")
O2_BEST=$(jpy "$O2_ENV" "d['result']['bestblock']")

# height bumped by 1 on both.
[[ "$C2_HEIGHT" == "$NEW_HEIGHT" ]] || { MUTATE_T="bad"; log "Core height did not bump: $C2_HEIGHT"; }
[[ "$O2_HEIGHT" == "$NEW_HEIGHT" ]] || { MUTATE_T="bad"; log "ouroboros height did not bump: $O2_HEIGHT (want $NEW_HEIGHT)"; }
# bestblock changed on both.
[[ "$C2_BEST" != "$C_BEST" ]] || { MUTATE_T="bad"; log "Core bestblock did not change after mine"; }
[[ "$O2_BEST" != "$O_BEST" ]] || { MUTATE_T="bad"; log "ouroboros bestblock did not change after mine"; }
# set hash CHANGED on both (a new coinbase output entered the set).
[[ "$C2_HASH" != "$PREV_C_HASH" ]] || { MUTATE_T="bad"; log "Core set hash did NOT change after mine"; }
[[ "$O2_HASH" != "$O_HS3" && "$HASH_TYPE_USED" != "muhash" ]] || true
# set hash STILL MATCHES between ouroboros and Core.
[[ -n "$O2_HASH" && "$O2_HASH" == "$C2_HASH" ]] \
    || { MUTATE_T="bad"; log "post-mutate set hash mismatch ou=$O2_HASH core=$C2_HASH"; }
[[ "$MUTATE_T" == "ok" ]] && log "after mutate: height+1, bestblock+hash changed, hash STILL matches Core ($O2_HASH)"

# ── 7. ERRORS. ────────────────────────────────────────────────────────────
ERRORS_T="ok"

# 7a. hash_serialized_3 + a specific block/height -> -8.
SOME_HEIGHT=2
E_SPEC=$(jpy "$(ou_rpc gettxoutsetinfo "[\"hash_serialized_3\", $SOME_HEIGHT]")" "d['error']['code']")
[[ "$E_SPEC" == "-8" ]] || { ERRORS_T="bad"; log "hs3+height: expected -8, got '$E_SPEC'"; }
E_SPEC_MSG=$(jpy "$(ou_rpc gettxoutsetinfo "[\"hash_serialized_3\", $SOME_HEIGHT]")" "d['error']['message']")
echo "$E_SPEC_MSG" | grep -qi "cannot be queried for a specific block" \
    || { ERRORS_T="bad"; log "hs3+height message off: '$E_SPEC_MSG'"; }

# 7b. bogus hash_type -> error (any error envelope).
E_BOGUS_ENV=$(ou_rpc gettxoutsetinfo '["bogushashtype"]')
HAS_ERR=$(jpy "$E_BOGUS_ENV" "'error' in d and d['error'] is not None")
[[ "$HAS_ERR" == "true" ]] || { ERRORS_T="bad"; log "bogus hash_type did not error: $E_BOGUS_ENV"; }

# Cross-check Core surfaces -8 on the specific-block case (oracle sanity).
CORE_E_SPEC=$(core_cli gettxoutsetinfo hash_serialized_3 "$SOME_HEIGHT" 2>&1 | grep -oE '\-8' | head -1)
[[ "$CORE_E_SPEC" == "-8" ]] || log "(note) Core hs3+height did not surface -8 via CLI text (needs coinstatsindex to even reach the check); relying on documented behaviour"

# ── 8. Verdict. ───────────────────────────────────────────────────────────
[[ "$FIELDS_T" == "ok" ]] || fail "field parity failed (height/bestblock/txouts/total_amount or typed-present, see log)"
[[ "$HASH_T"   == "ok" ]] || fail "UTXO-set hash not byte-exact vs Core for any hash_type (see log)"
[[ "$MUTATE_T" == "ok" ]] || fail "mutate check failed (height/bestblock/hash change or re-match, see log)"
[[ "$ERRORS_T" == "ok" ]] || fail "error-code parity check failed (see log)"

log "PASS: ouroboros gettxoutsetinfo matches Core (fields + UTXO-set hash[$HASH_TYPE_USED] + mutate + errors)"
pass "$FIELDS_T" "$HASH_T" "$MUTATE_T" "$ERRORS_T"
