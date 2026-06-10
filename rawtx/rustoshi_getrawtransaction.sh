#!/usr/bin/env bash
#
# rustoshi_getrawtransaction.sh — self-contained getrawtransaction Core-parity test.
#
# The next RPC-surface/indexing green-cell after getindexinfo ("txindex on but
# getrawtransaction fails"). getrawtransaction is the block-explorer keystone:
# raw-hex retrieval + a fully-decoded transaction object that must match Bitcoin
# Core EXACTLY on the load-bearing fields.
#
# Core ref: bitcoin-core/src/rpc/rawtransaction.cpp:216-374 (getrawtransaction),
#           :58-85 (TxToJSON envelope), src/core_io.cpp:430-533 (TxToUniv).
#   SIGNATURE: getrawtransaction "txid" ( verbosity "blockhash" ).
#     verbosity default 0; accepts bool (true=1,false=0) or int 0/1/2.
#   OUTPUT:
#     v0 -> the raw tx HEX string (EncodeHexTx)  — byte-exact serialization.
#     v1 -> a decoded OBJECT (TxToUniv include_hex=true) + the TxToJSON envelope:
#             txid, hash(=wtxid), version, size, vsize, weight, locktime,
#             vin[] {coinbase | txid,vout,scriptSig{asm,hex}, txinwitness?, sequence},
#             vout[] {value, n, scriptPubKey{asm,desc,hex,address?,type}}, hex,
#             and when confirmed in the active chain: blockhash, confirmations
#             (=1+tipH-txH), time, blocktime (both = block nTime); plus
#             in_active_chain when a blockhash ARG was given.
#   ERRORS (all -5 RPC_INVALID_ADDRESS_OR_KEY):
#     genesis-coinbase txid -> "...genesis block coinbase...cannot be retrieved";
#     unknown blockhash arg -> "Block hash not found";
#     tx not found          -> "No such mempool ... transaction" (category -5).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports, launched -listen=0 (RPC only; the sandbox
#   SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener) AND -txindex=1.
#
#   To make the SAME transaction exist byte-for-byte on BOTH nodes, Core mines
#   the whole chain and rustoshi is fed each block via `submitblock` — so both
#   nodes carry an IDENTICAL chain (identical coinbases / UTXO set). A real
#   spending tx is then built+signed by Core's wallet and the IDENTICAL signed
#   hex is pushed into BOTH mempools with `sendrawtransaction`. Every parity
#   assertion therefore compares the exact same tx object on the two nodes.
#
# WHAT MUST MATCH CORE EXACTLY:
#   v0 hex              == Core's v0 hex   (byte-identical serialization)
#   v1 txid,hash,version,size,vsize,weight,locktime,hex   == Core
#   v1 vin[i] {txid,vout,sequence} + scriptSig.hex        == Core
#   v1 vout[i] {value,n, scriptPubKey.hex,.type,.address} == Core
#   confirmed: blockhash == mined block; confirmations int >= 1;
#              in_active_chain == true; time/blocktime present.
#   error codes: random txid -> -5; genesis-coinbase txid -> -5.
# PRESENT-NOT-BYTE-EQUAL (legitimately differ): scriptPubKey.asm, scriptSig.asm,
#   scriptPubKey.desc (InferDescriptor vs raw + asm whitespace can differ).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETRAWTRANSACTION rustoshi: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   FAIL: GETRAWTRANSACTION rustoshi: FAIL <short reason>
#
# Touches ONLY /tmp/grt-rustoshi/ + /tmp/grt-core/ and ports 22010/22030
#   (rustoshi RPC/P2P) + 22012/22032 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/script/tx)

# Deterministic test secrets. This Core build has NO wallet, so the spending tx
# is built + signed in-process with Core's test_framework. We mine to a p2wpkh
# address we hold the key for, then spend its matured coinbase to a SECOND
# p2wpkh address (so the output decodes to a checkable bech32 address).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

RS_DATADIR="/tmp/grt-rustoshi"
RS_RPC=22010
RS_P2P=22030
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/grt-core"
CORE_RPC=22012
CORE_P2P=22032
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=101        # exactly enough so block-1's coinbase is matured + spendable.

RS_PID=""
RS_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getrawtransaction:rustoshi] $*" >&2; }

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
    rm -rf "$RS_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <decoded> <confirmed> <errors>
pass() {
    echo "GETRAWTRANSACTION rustoshi: PASS hex=$1 decoded=$2 confirmed=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION rustoshi: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "grt-rustoshi" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${RS_RPC}|${RS_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
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

# ── Derive the deterministic p2wpkh mining + destination addresses. ───────
MINE_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null) \
    || fail "could not derive mining address (test_framework import failed)"
[[ "$MINE_ADDR" == bcrt1* ]] || fail "mining address not regtest bech32: '$MINE_ADDR'"
DEST_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$DEST_SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null) \
    || fail "could not derive destination address"
[[ "$DEST_ADDR" == bcrt1* ]] || fail "destination address not regtest bech32: '$DEST_ADDR'"
log "mine addr=$MINE_ADDR dest addr=$DEST_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# Tolerant of the bitcoin-cli .cookie read race + heavy concurrent fleet load.
# Very generous (20 attempts x 3s = up to 60s) because this box runs many
# sibling regtest harnesses and Core can stall for tens of seconds under CPU
# contention; a transient blip must not fail the whole cell. If the daemon is
# genuinely gone (process dead) we bail immediately.
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

# jstr_eq <json-string> -> the value of a JSON string literal (quote-stripped).
# Core CLI returns a bare quoted string for getrawtransaction <txid> 0 etc.
unq() { python3 -c "import sys,json; print(json.loads(sys.stdin.read()))" <<<"$1" 2>/dev/null; }

# ── 2. Launch the Core regtest oracle (RPC-only, txindex on). ─────────────
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
    # -listen=0: RPC-only — the sandbox SIGKILLs a 0.0.0.0 P2P listener.
    # -txindex=1: Core can answer getrawtransaction with no blockhash arg.
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

# ── 3. Launch rustoshi on regtest (txindex on for sub-check #4). ──────────
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
# Mine to the p2wpkh address we hold the key for so its coinbase is spendable.
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
    # submitblock returns null on success, "duplicate" if already known.
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
# Spend block-1's matured coinbase output (vout 0, 50 BTC) to DEST_ADDR, with a
# fee. The signed bytes are deterministic and IDENTICAL on both nodes. The
# block-1 coinbase txid + value are parsed straight from the raw block bytes we
# already mirrored (no extra Core round-trips under heavy fleet load).
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
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import sign_input_segwitv0, CScript
from test_framework.script_util import key_to_p2wpkh_script
from test_framework.address import address_to_scriptpubkey

src = ECKey(); src.set(bytes.fromhex('$SECRET'), compressed=True)
src_pub = src.get_pubkey().get_bytes()
spk_in = key_to_p2wpkh_script(src_pub)          # P2WPKH scriptPubKey of the coinbase output

tx = CTransaction()
tx.version = 2
prev_txid = int('$CB_TXID', 16)
in_amount = int('$CB_VALUE')
tx.vin = [CTxIn(COutPoint(prev_txid, 0), b'', 0xffffffff)]
# spend the full coinbase value minus a 0.0001 BTC fee, to DEST_ADDR.
out_value = in_amount - 10000
tx.vout = [CTxOut(out_value, address_to_scriptpubkey('$DEST_ADDR'))]
tx.wit.vtxinwit = [CTxInWitness()]
# BIP-143 scriptCode for P2WPKH is the corresponding P2PKH script.
from test_framework.script_util import keyhash_to_p2pkh_script
from test_framework.crypto.ripemd160 import ripemd160
import hashlib
keyhash = ripemd160(hashlib.sha256(src_pub).digest())
script_code = keyhash_to_p2pkh_script(keyhash)
sign_input_segwitv0(tx, 0, script_code, in_amount, src)
tx.wit.vtxinwit[0].scriptWitness.stack.append(src_pub)   # pubkey on top of sig
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

# ════════════════════════════════════════════════════════════════════════
# CHECK 1 — MEMPOOL: v0 hex byte-exact + v1 decoded fields exact.
# ════════════════════════════════════════════════════════════════════════
HEX_T="ok"; DECODED_T="ok"

# v0 hex byte-EXACT: rustoshi vs Core (cross-node), and both vs the signed bytes.
# bitcoin-cli prints a string result RAW (no surrounding quotes) — do not unq it.
CORE_HEX_V0=$(core_cli_retry getrawtransaction "$TXID" 0 | tr -d '[:space:]')
[[ "$CORE_HEX_V0" == "$CORE_HEX" ]] || fail "Core v0 hex != broadcast bytes (oracle anomaly): '$CORE_HEX_V0'"
RS_HEX=$(unq "$(jpy "$(rs_rpc getrawtransaction "[\"$TXID\", 0]")" "json.dumps(d['result'])")")
[[ "$RS_HEX" == "$CORE_HEX_V0" ]] || { HEX_T="bad"; log "v0 hex mismatch:\n  core=$CORE_HEX_V0\n  rust=$RS_HEX"; }

# default verbosity (omitted) == 0 (hex).
RS_HEX_DEF=$(unq "$(jpy "$(rs_rpc getrawtransaction "[\"$TXID\"]")" "json.dumps(d['result'])")")
[[ "$RS_HEX_DEF" == "$CORE_HEX_V0" ]] || { HEX_T="bad"; log "v0 (default verbosity) hex mismatch: rust=$RS_HEX_DEF"; }

# bool verbosity false == 0 (hex).
RS_HEX_BF=$(unq "$(jpy "$(rs_rpc getrawtransaction "[\"$TXID\", false]")" "json.dumps(d['result'])")")
[[ "$RS_HEX_BF" == "$CORE_HEX_V0" ]] || { HEX_T="bad"; log "v0 (bool false) hex mismatch: rust=$RS_HEX_BF"; }

[[ "$HEX_T" == "ok" ]] || fail "v0 hex parity failed (see log)"

# v1 decoded object. Core via CLI returns the bare result object; rustoshi via
# the JSON-RPC envelope (index d['result']). Compare the load-bearing fields.
CORE_V1=$(core_cli_retry getrawtransaction "$TXID" 1)
[[ -n "$CORE_V1" ]] || fail "Core getrawtransaction v1 produced no output"
# bool verbosity true == 1 (decoded) on rustoshi.
RS_V1_BT=$(rs_rpc getrawtransaction "[\"$TXID\", true]")
echo "$RS_V1_BT" | grep -q '"result"' || fail "rustoshi getrawtransaction v1 (bool true) errored: $RS_V1_BT"
RS_V1=$(jpy "$RS_V1_BT" "json.dumps(d['result'])")
[[ -n "$RS_V1" ]] || fail "rustoshi getrawtransaction v1 result empty"

log "Core v1: $CORE_V1"
log "rust v1: $RS_V1"

# Top-level scalar fields that MUST be byte-equal.
for f in txid hash version size vsize weight locktime hex; do
    CV=$(jpy "$CORE_V1" "d.get('$f')")
    RV=$(jpy "$RS_V1"   "d.get('$f')")
    [[ -n "$CV" ]] || fail "Core v1 missing field '$f'"
    [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "v1 field '$f' mismatch: core='$CV' rust='$RV'"; }
done

# vin parity: txid, vout, sequence, scriptSig.hex per input.
NVIN_C=$(jpy "$CORE_V1" "len(d.get('vin',[]))")
NVIN_R=$(jpy "$RS_V1"   "len(d.get('vin',[]))")
[[ "$NVIN_C" == "$NVIN_R" && -n "$NVIN_C" && "$NVIN_C" -ge 1 ]] || { DECODED_T="bad"; log "vin count mismatch: core=$NVIN_C rust=$NVIN_R"; }
if [[ "$NVIN_C" == "$NVIN_R" ]]; then
    for ((i=0; i<NVIN_C; i++)); do
        for f in txid vout sequence; do
            CV=$(jpy "$CORE_V1" "d['vin'][$i].get('$f')")
            RV=$(jpy "$RS_V1"   "d['vin'][$i].get('$f')")
            [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vin[$i].$f mismatch: core='$CV' rust='$RV'"; }
        done
        CV=$(jpy "$CORE_V1" "d['vin'][$i].get('scriptSig',{}).get('hex')")
        RV=$(jpy "$RS_V1"   "d['vin'][$i].get('scriptSig',{}).get('hex')")
        [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vin[$i].scriptSig.hex mismatch: core='$CV' rust='$RV'"; }
        # scriptSig.asm present (not byte-equal).
        RA=$(jpy "$RS_V1" "'asm' in d['vin'][$i].get('scriptSig',{})")
        [[ "$RA" == "true" ]] || { DECODED_T="bad"; log "vin[$i].scriptSig.asm absent on rustoshi"; }
    done
fi

# vout parity: value, n, scriptPubKey.hex/.type/.address(if Core has it).
NVOUT_C=$(jpy "$CORE_V1" "len(d.get('vout',[]))")
NVOUT_R=$(jpy "$RS_V1"   "len(d.get('vout',[]))")
[[ "$NVOUT_C" == "$NVOUT_R" && -n "$NVOUT_C" && "$NVOUT_C" -ge 1 ]] || { DECODED_T="bad"; log "vout count mismatch: core=$NVOUT_C rust=$NVOUT_R"; }
if [[ "$NVOUT_C" == "$NVOUT_R" ]]; then
    for ((i=0; i<NVOUT_C; i++)); do
        # value: compare numerically (8-dp decimals) to avoid 1.00 vs 1 text diffs.
        CV=$(jpy "$CORE_V1" "format(float(d['vout'][$i]['value']),'.8f')")
        RV=$(jpy "$RS_V1"   "format(float(d['vout'][$i]['value']),'.8f')")
        [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vout[$i].value mismatch: core='$CV' rust='$RV'"; }
        for f in n; do
            CV=$(jpy "$CORE_V1" "d['vout'][$i].get('$f')")
            RV=$(jpy "$RS_V1"   "d['vout'][$i].get('$f')")
            [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vout[$i].$f mismatch: core='$CV' rust='$RV'"; }
        done
        for f in hex type; do
            CV=$(jpy "$CORE_V1" "d['vout'][$i]['scriptPubKey'].get('$f')")
            RV=$(jpy "$RS_V1"   "d['vout'][$i]['scriptPubKey'].get('$f')")
            [[ "$CV" == "$RV" ]] || { DECODED_T="bad"; log "vout[$i].scriptPubKey.$f mismatch: core='$CV' rust='$RV'"; }
        done
        # address: required-equal ONLY when Core emits one (decodable scripts).
        CADDR=$(jpy "$CORE_V1" "d['vout'][$i]['scriptPubKey'].get('address')")
        if [[ -n "$CADDR" && "$CADDR" != "None" ]]; then
            RADDR=$(jpy "$RS_V1" "d['vout'][$i]['scriptPubKey'].get('address')")
            [[ "$RADDR" == "$CADDR" ]] || { DECODED_T="bad"; log "vout[$i].scriptPubKey.address mismatch: core='$CADDR' rust='$RADDR'"; }
        fi
        # asm + desc present (not byte-equal).
        for f in asm desc; do
            RP=$(jpy "$RS_V1" "'$f' in d['vout'][$i]['scriptPubKey']")
            [[ "$RP" == "true" ]] || { DECODED_T="bad"; log "vout[$i].scriptPubKey.$f absent on rustoshi"; }
        done
    done
fi

[[ "$DECODED_T" == "ok" ]] || fail "v1 decoded parity failed (see log)"

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — CONFIRMED via blockhash arg.
# ════════════════════════════════════════════════════════════════════════
CONFIRMED_T="ok"

# Mine 1 block on Core that confirms TXID, mirror to rustoshi.
CONF_HASH=$(core_cli_retry generatetoaddress 1 "$MINE_ADDR")
CONF_BLOCKHASH=$(jpy "$CONF_HASH" "d[0]" 2>/dev/null)
[[ "$CONF_BLOCKHASH" =~ ^[0-9a-f]{64}$ ]] || CONF_BLOCKHASH=$(core_cli_retry getbestblockhash)
[[ "$CONF_BLOCKHASH" =~ ^[0-9a-f]{64}$ ]] || fail "could not resolve confirming blockhash: '$CONF_BLOCKHASH'"
RAW_CONF=$(core_cli_retry getblock "$CONF_BLOCKHASH" 0) || fail "Core getblock (confirming) failed"
SB=$(rs_rpc submitblock "[\"$RAW_CONF\"]")
RS_TIP2=$(jpy "$(rs_rpc getbestblockhash '[]')" "d['result']")
[[ "$RS_TIP2" == "$CONF_BLOCKHASH" ]] || fail "rustoshi did not connect the confirming block (tip=$RS_TIP2 want=$CONF_BLOCKHASH)"
log "TXID confirmed in block $CONF_BLOCKHASH on both nodes"

# getrawtransaction <txid> 1 <blockhash> on rustoshi.
RS_CONF=$(rs_rpc getrawtransaction "[\"$TXID\", 1, \"$CONF_BLOCKHASH\"]")
echo "$RS_CONF" | grep -q '"result"' || fail "rustoshi getrawtransaction <txid> 1 <blockhash> errored: $RS_CONF"
RS_CONF_R=$(jpy "$RS_CONF" "json.dumps(d['result'])")

R_BH=$(jpy "$RS_CONF_R" "d.get('blockhash')")
[[ "$R_BH" == "$CONF_BLOCKHASH" ]] || { CONFIRMED_T="bad"; log "confirmed blockhash mismatch: got='$R_BH' want='$CONF_BLOCKHASH'"; }

R_CONF=$(jpy "$RS_CONF_R" "d.get('confirmations')")
if ! [[ "$R_CONF" =~ ^[0-9]+$ ]] || [[ "$R_CONF" -lt 1 ]]; then
    CONFIRMED_T="bad"; log "confirmations absent/not >=1: '$R_CONF'"
fi

R_IAC=$(jpy "$RS_CONF_R" "d.get('in_active_chain')")
[[ "$R_IAC" == "true" ]] || { CONFIRMED_T="bad"; log "in_active_chain != true (blockhash arg given): '$R_IAC'"; }

R_TIME=$(jpy "$RS_CONF_R" "d.get('time')")
R_BTIME=$(jpy "$RS_CONF_R" "d.get('blocktime')")
[[ "$R_TIME"  =~ ^[0-9]+$ ]] || { CONFIRMED_T="bad"; log "time absent/non-int: '$R_TIME'"; }
[[ "$R_BTIME" =~ ^[0-9]+$ ]] || { CONFIRMED_T="bad"; log "blocktime absent/non-int: '$R_BTIME'"; }
# Core: time == blocktime == block nTime.
[[ "$R_TIME" == "$R_BTIME" ]] || { CONFIRMED_T="bad"; log "time != blocktime: '$R_TIME' vs '$R_BTIME'"; }
# blocktime must equal the actual block header nTime (read from rustoshi's own
# getblock — the node under test is always responsive, unlike Core under load).
BLK_NTIME=$(jpy "$(rs_rpc getblock "[\"$CONF_BLOCKHASH\"]")" "d.get('result',{}).get('time')")
[[ -z "$BLK_NTIME" || "$BLK_NTIME" == "None" || "$R_BTIME" == "$BLK_NTIME" ]] || { CONFIRMED_T="bad"; log "blocktime '$R_BTIME' != block nTime '$BLK_NTIME'"; }

[[ "$CONFIRMED_T" == "ok" ]] || fail "confirmed-via-blockhash parity failed (see log)"

# ── Sub-check 4: txindex (no blockhash) on a confirmed tx — rustoshi has it. ─
RS_TXI=$(rs_rpc getrawtransaction "[\"$TXID\", 1]")
if echo "$RS_TXI" | grep -q '"result"'; then
    RS_TXI_BH=$(jpy "$RS_TXI" "d['result'].get('blockhash')")
    [[ "$RS_TXI_BH" == "$CONF_BLOCKHASH" ]] || { CONFIRMED_T="bad"; log "txindex-resolved blockhash mismatch: '$RS_TXI_BH'"; }
    log "txindex sub-check: getrawtransaction <txid> 1 (no blockhash) resolved via txindex -> $RS_TXI_BH"
else
    fail "rustoshi --txindex enabled but getrawtransaction <txid> 1 (no blockhash) failed on a confirmed tx: $RS_TXI"
fi
[[ "$CONFIRMED_T" == "ok" ]] || fail "confirmed/txindex parity failed (see log)"

# ════════════════════════════════════════════════════════════════════════
# CHECK 3 — ERRORS: random txid -> -5; genesis-coinbase txid -> -5.
# ════════════════════════════════════════════════════════════════════════
ERRORS_T="ok"

# random unknown txid -> -5.
RAND_TXID="00000000000000000000000000000000000000000000000000000000deadbeef"
E_RAND=$(jpy "$(rs_rpc getrawtransaction "[\"$RAND_TXID\"]")" "d['error']['code']")
[[ "$E_RAND" == "-5" ]] || { ERRORS_T="bad"; log "unknown txid: expected -5, got '$E_RAND'"; }
# Core parity: Core also returns -5 for an unknown txid (txindex on).
EC_RAND=$(core_cli getrawtransaction "$RAND_TXID" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ -z "$EC_RAND" || "$EC_RAND" == "-5" ]] || { ERRORS_T="bad"; log "Core unknown-txid code != -5: '$EC_RAND'"; }

# genesis-coinbase txid (== genesis merkle root) -> -5 on both.
# Read the genesis merkleroot from rustoshi (the node under test, always up);
# both share the SAME regtest genesis so it equals Core's genesis merkleroot.
GEN_BLOCKHASH=$(jpy "$(rs_rpc getblockhash '[0]')" "d['result']")
GEN_MROOT=$(jpy "$(rs_rpc getblock "[\"$GEN_BLOCKHASH\"]")" "d.get('result',{}).get('merkleroot')")
[[ "$GEN_MROOT" =~ ^[0-9a-f]{64}$ ]] || fail "could not read genesis merkleroot from rustoshi: '$GEN_MROOT'"
E_GEN=$(jpy "$(rs_rpc getrawtransaction "[\"$GEN_MROOT\"]")" "d['error']['code']")
[[ "$E_GEN" == "-5" ]] || { ERRORS_T="bad"; log "genesis-coinbase txid: expected -5, got '$E_GEN'"; }
# message should mention the genesis-coinbase special case.
E_GEN_MSG=$(jpy "$(rs_rpc getrawtransaction "[\"$GEN_MROOT\"]")" "d['error']['message']")
echo "$E_GEN_MSG" | grep -qi "genesis" || { ERRORS_T="bad"; log "genesis-coinbase error msg lacks 'genesis': '$E_GEN_MSG'"; }
# Core parity: Core returns -5 with the same special-case for the genesis coinbase.
EC_GEN=$(core_cli getrawtransaction "$GEN_MROOT" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ -z "$EC_GEN" || "$EC_GEN" == "-5" ]] || { ERRORS_T="bad"; log "Core genesis-coinbase code != -5: '$EC_GEN'"; }

# unknown blockhash arg -> -5 ("Block hash not found").
BAD_BLOCKHASH="00000000000000000000000000000000000000000000000000000000cafebabe"
E_BBH=$(jpy "$(rs_rpc getrawtransaction "[\"$TXID\", 1, \"$BAD_BLOCKHASH\"]")" "d['error']['code']")
[[ "$E_BBH" == "-5" ]] || { ERRORS_T="bad"; log "unknown blockhash arg: expected -5, got '$E_BBH'"; }

[[ "$ERRORS_T" == "ok" ]] || fail "error-code parity failed (see log)"

log "PASS: rustoshi getrawtransaction matches Core on v0 hex + v1 decoded + confirmed envelope + error codes"
pass "$HEX_T" "$DECODED_T" "$CONFIRMED_T" "$ERRORS_T"
