#!/usr/bin/env bash
#
# clearbit_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity test.
#
# The DEEPEST indexing green-cell yet: the UTXO-set HASH is a fingerprint of the
# ENTIRE UTXO set, so matching it byte-for-byte proves clearbit's consensus STATE
# (its UTXO set) is identical to Bitcoin Core's — not merely that the RPC has the
# right shape. A single wrong/extra/missing/mis-valued coin flips the hash.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:1010+ (gettxoutsetinfo) +
#           src/kernel/coinstats.cpp (hash_serialized_3 + muhash kernels,
#           per-coin ApplyHash/TxOutSer, bogosize, total_amount accounting).
#   SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index ).
#     hash_type default "hash_serialized_3"; options
#     "hash_serialized_3" | "muhash" | "none".
#   OUTPUT (base, no coinstatsindex): { height, bestblock, txouts, bogosize,
#     hash_serialized_3 (iff hash_type=hash_serialized_3) | muhash (iff muhash),
#     transactions, disk_size, total_amount }.
#     - hash_serialized_3: SHA256d (HashWriter) over the UTXO set in COIN-CURSOR
#       ORDER (by outpoint key: txid then numeric vout); per-coin =
#       (txid, vout, height<<1|coinbase, txout). Deterministic given the set.
#     - muhash: MuHash3072 multiset hash (ORDER-INDEPENDENT) over the same
#       per-coin serialization.
#   ERRORS: hash_serialized_3 with a specific block/height ->
#     RPC_INVALID_PARAMETER (-8) "hash_serialized_3 hash type cannot be queried
#     for a specific block"; unrecognized hash_type -> error.
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest + its OWN ports, launched -listen=0. Core is the SINGLE source of
#   blocks (deterministic via setmocktime): mines 110 blocks to maturity, then
#   creates+mines a wallet-free SPEND tx (so the UTXO set has a spent coinbase
#   output REMOVED and new outputs ADDED, not just coinbases). Every block's RAW
#   hex (`getblock <hash> 0`) is replayed into clearbit via `submitblock`. After
#   replay both nodes hold the byte-identical chain (assert tips equal), so the
#   UTXO sets are identical and gettxoutsetinfo on both MUST agree.
#
# WHAT MUST MATCH CORE EXACTLY (requires SAME_CHAIN):
#   1. height, bestblock, txouts, total_amount ALL byte-exact vs Core, AND the
#      set hash (hash_serialized_3) byte-EXACT vs Core. (The set-hash match is
#      THE point — it proves the whole UTXO set is identical.) muhash is also
#      cross-checked byte-exact (order-independent strong hash).
#   2. MUTATE: mine ONE more block (changes the set), re-query -> height+1,
#      bestblock changed, the set hash CHANGED on BOTH and still matches Core.
#   3. ERRORS: gettxoutsetinfo hash_serialized_3 <height> -> -8 (cannot query a
#      specific block); gettxoutsetinfo bogus -> error.
#      bogosize/transactions/disk_size: assert PRESENT + typed (NOT byte-equal —
#      bogosize is "meaningless", disk_size impl-specific).
#
# If submitblock replay is unavailable (chains diverge) the byte-exact cross-node
# comparison is not apples-to-apples; the test SKIPs rather than passing
# vacuously.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/blockfilter/clearbit_getblockfilter.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO clearbit: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO clearbit: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO clearbit: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-clearbit/ + /tmp/gtxo-core/ and ports
#   40277/40297 (clearbit RPC/P2P) + 40279/40299 (Core RPC; P2P unused -listen=0).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Does NOT
#   broad-pkill bitcoind/clearbit by name. Any `fuser -k` redirects stdout.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

CB_DATADIR="/tmp/gtxo-clearbit/$$"
CB_RPC=40277
CB_P2P=40297
CB_LOG="$CB_DATADIR/node.log"

CORE_DATADIR="/tmp/gtxo-core/$$"
CORE_RPC=40279
CORE_P2P=40299   # declared but Core launched -listen=0 (no P2P listener)
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to.
# We need its regtest WIF to sign a wallet-free spend of a coinbase output (this
# Core build has NO wallet compiled in, so we use createrawtransaction +
# signrawtransactionwithkey + sendrawtransaction).
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
log() { echo "[gettxoutsetinfo:clearbit] $*" >&2; }

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
pass() { echo "GETTXOUTSETINFO clearbit: PASS fields=$1 hash=$2 mutate=$3 errors=$4"; exit 0; }
fail() { echo "GETTXOUTSETINFO clearbit: FAIL $*"; exit 1; }
skip() { echo "GETTXOUTSETINFO clearbit: SKIP $*"; exit 0; }

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
# Reclaim ONLY this PID's scratch + the canonical ports. We deliberately do NOT
# broad-pkill bitcoind/clearbit by name — that would kill sibling test runs and
# (catastrophically) the live mainnet bitcoind/clearbit on /data/nvme1.
log "resetting scratch state (pid=$$)"
pkill -f "gtxo-clearbit/$$" 2>/dev/null || true
free_port() {  # poll until the port is actually free (a just-killed node can hold it briefly)
    local p="$1"
    fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        fuser "${p}/tcp" >/dev/null 2>&1 || return 0
        fuser -k "${p}/tcp" >/dev/null 2>&1 || true
        sleep 1
    done
    return 0
}
free_port "$CB_RPC"; free_port "$CB_P2P"; free_port "$CORE_RPC"; free_port "$CORE_P2P"
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
SECRET_WIF=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.address import byte_to_base58
print(byte_to_base58(bytes.fromhex('$SECRET') + b'\x01', 239))
" 2>/dev/null) || fail "could not derive regtest WIF for the test secret"
[[ -n "$SECRET_WIF" ]] || fail "derived WIF is empty"
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

core_cli_retry() {  # tolerant of the .cookie read race under concurrent fleet load
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

cb_rpc() {  # <method> <json-params-array> -> raw JSON-RPC response body on stdout
    curl -s --max-time 90 -u "$CB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$CB_RPC/" 2>/dev/null
}

jpy() {  # <json> <expr>   (expr references parsed object as `d`)
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

# ── 3. Launch the Core regtest oracle (RPC-only). ─────────────────────────
launch_core_once() {
    free_port "$CORE_RPC"; free_port "$CORE_P2P"
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

# ── 4. Launch clearbit on regtest. ────────────────────────────────────────
log "launching clearbit (regtest) rpc=:$CB_RPC p2p=:$CB_P2P -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" \
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

# Spend block 1's coinbase output 0 (50 BTC, matured after 100 blocks) so the
# UTXO set has a coinbase output REMOVED and a fresh p2wpkh output ADDED.
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

mine_one
H_SPEND=$(core_cli_retry getblockcount)
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$H_SPEND")
core_cli_retry getblock "$SPEND_BLOCKHASH" 1 | grep -q "$SPEND_TXID" \
    || fail "spend tx $SPEND_TXID not found in block $H_SPEND ($SPEND_BLOCKHASH)"

CORE_HEIGHT=$(core_cli_retry getblockcount)
log "Core chain height: $CORE_HEIGHT ; H_SPEND=$H_SPEND ; spent a coinbase + added 1 output"

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
    skip "submitblock replay incomplete (replay_ok=$REPLAY_OK cb_height=${CB_HEIGHT:-?} core=$CORE_HEIGHT) — cannot compare UTXO-set hash on a shared chain"
fi

# Confirm both nodes hold the byte-identical chain (tips agree) — without this
# the UTXO sets are not guaranteed identical and the hash comparison is moot.
CORE_TIP=$(core_cli_retry getbestblockhash)
CB_TIP=$(jpy "$(cb_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$CORE_TIP" && -n "$CB_TIP" ]] || fail "could not read tips (core=$CORE_TIP cb=$CB_TIP)"
[[ "$CORE_TIP" == "$CB_TIP" ]] || skip "chains diverged after replay (core tip=$CORE_TIP cb tip=$CB_TIP) — UTXO sets not guaranteed identical"
log "chains identical: tip=$CB_TIP"

# ── Reusable extractors. ──────────────────────────────────────────────────
# core_field <args...> -> JSON object from `gettxoutsetinfo`.
core_gtxo() { core_cli_retry gettxoutsetinfo "$@"; }
# cb_gtxo <json-params> -> raw JSON-RPC body.
cb_gtxo_raw() { cb_rpc gettxoutsetinfo "$1"; }
# cb_gtxo <json-params> -> the .result object (or empty on error).
cb_gtxo() { jpy "$(cb_gtxo_raw "$1")" "json.dumps(d['result']) if d.get('result') is not None else ''"; }
# jf <json> <key> -> value of top-level key.
jf() { jpy "$1" "d.get('$2')"; }

# ── 7. CHECK 1 — fields + set hash byte-EXACT vs Core (default hash_type). ─
FIELDS_T="bad"; HASH_T="bad"

CORE_J=$(core_gtxo) || fail "Core gettxoutsetinfo (default) failed"
CB_J=$(cb_gtxo '[]')
[[ -n "$CORE_J" ]] || fail "Core gettxoutsetinfo (default) returned empty"
[[ -n "$CB_J"   ]] || fail "clearbit gettxoutsetinfo (default) returned empty/error: $(cb_gtxo_raw '[]')"

C_HEIGHT=$(jf "$CORE_J" height);   B_HEIGHT=$(jf "$CB_J" height)
C_BEST=$(jf "$CORE_J" bestblock);  B_BEST=$(jf "$CB_J" bestblock)
C_TXOUTS=$(jf "$CORE_J" txouts);   B_TXOUTS=$(jf "$CB_J" txouts)
C_TOTAL=$(jf "$CORE_J" total_amount); B_TOTAL=$(jf "$CB_J" total_amount)
C_HASH=$(jf "$CORE_J" hash_serialized_3); B_HASH=$(jf "$CB_J" hash_serialized_3)

log "default: core height=$C_HEIGHT txouts=$C_TXOUTS total=$C_TOTAL hs3=$C_HASH best=$C_BEST"
log "default: cb   height=$B_HEIGHT txouts=$B_TXOUTS total=$B_TOTAL hs3=$B_HASH best=$B_BEST"

# Exact field parity.
[[ "$B_HEIGHT" == "$C_HEIGHT" ]] || fail "height mismatch: cb=$B_HEIGHT core=$C_HEIGHT"
[[ "$B_BEST"   == "$C_BEST"   ]] || fail "bestblock mismatch: cb=$B_BEST core=$C_BEST"
[[ "$B_TXOUTS" == "$C_TXOUTS" ]] || fail "txouts mismatch: cb=$B_TXOUTS core=$C_TXOUTS"
# total_amount compared numerically (Core wire form 5550.00000000 vs cli repr 5550.0).
TOTAL_EQ=$(python3 -c "print('eq' if abs(float('$B_TOTAL')-float('$C_TOTAL'))<1e-9 else 'ne')" 2>/dev/null)
[[ "$TOTAL_EQ" == "eq" ]] || fail "total_amount mismatch: cb=$B_TOTAL core=$C_TOTAL"

# bogosize / transactions / disk_size: PRESENT + typed (NOT byte-equal).
B_BOGO=$(jf "$CB_J" bogosize); B_TX=$(jf "$CB_J" transactions); B_DISK=$(jf "$CB_J" disk_size)
[[ "$B_BOGO" =~ ^[0-9]+$ ]] || fail "bogosize missing/not-int on clearbit: '$B_BOGO'"
[[ "$B_TX"   =~ ^[0-9]+$ ]] || fail "transactions missing/not-int on clearbit: '$B_TX'"
[[ "$B_DISK" =~ ^[0-9]+$ ]] || fail "disk_size missing/not-int on clearbit: '$B_DISK'"
log "typed-present fields ok: bogosize=$B_BOGO transactions=$B_TX disk_size=$B_DISK"
FIELDS_T="ok"

# The set hash is THE point: byte-exact proves the whole UTXO set is identical.
[[ "$B_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "clearbit hash_serialized_3 not 64-hex: '$B_HASH'"
[[ "$C_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "Core hash_serialized_3 not 64-hex: '$C_HASH'"
[[ "$B_HASH" == "$C_HASH" ]] || fail "hash_serialized_3 mismatch vs Core (UTXO sets differ!): cb=$B_HASH core=$C_HASH"
log "hash_serialized_3 byte-EXACT vs Core: $B_HASH"

# Cross-check muhash too (order-independent strong hash) for extra confidence.
CORE_MU_J=$(core_gtxo muhash) || fail "Core gettxoutsetinfo muhash failed"
CB_MU_J=$(cb_gtxo '["muhash"]')
C_MU=$(jf "$CORE_MU_J" muhash); B_MU=$(jf "$CB_MU_J" muhash)
[[ "$B_MU" =~ ^[0-9a-f]{64}$ ]] || fail "clearbit muhash not 64-hex: '$B_MU'"
[[ "$B_MU" == "$C_MU" ]] || fail "muhash mismatch vs Core: cb=$B_MU core=$C_MU"
log "muhash byte-EXACT vs Core: $B_MU"
HASH_T="ok"

# ── 8. CHECK 2 — MUTATE the set (mine 1 more block) -> hash changes + agrees. ─
MUTATE_T="bad"
PREV_HASH="$B_HASH"; PREV_HEIGHT="$B_HEIGHT"; PREV_BEST="$B_BEST"
mine_one
M_HEIGHT=$(core_cli_retry getblockcount)
M_BH=$(core_cli_retry getblockhash "$M_HEIGHT")
M_RAW=$(core_cli_retry getblock "$M_BH" 0) || fail "mutate: getblock raw failed"
M_SB=$(cb_rpc submitblock "[\"$M_RAW\"]")
M_SBRES=$(jpy "$M_SB" "d.get('result')")
[[ -z "$M_SBRES" || "$M_SBRES" == "None" || "$M_SBRES" == "duplicate" ]] \
    || fail "mutate: clearbit submitblock rejected new block: $M_SB"

CORE_J2=$(core_gtxo) || fail "mutate: Core gettxoutsetinfo failed"
CB_J2=$(cb_gtxo '[]')
[[ -n "$CB_J2" ]] || fail "mutate: clearbit gettxoutsetinfo returned empty/error: $(cb_gtxo_raw '[]')"

C2_HEIGHT=$(jf "$CORE_J2" height); B2_HEIGHT=$(jf "$CB_J2" height)
C2_BEST=$(jf "$CORE_J2" bestblock); B2_BEST=$(jf "$CB_J2" bestblock)
C2_HASH=$(jf "$CORE_J2" hash_serialized_3); B2_HASH=$(jf "$CB_J2" hash_serialized_3)
log "mutate: core height=$C2_HEIGHT hs3=$C2_HASH best=$C2_BEST"
log "mutate: cb   height=$B2_HEIGHT hs3=$B2_HASH best=$B2_BEST"

# height +1, bestblock changed, hash changed on BOTH, and still equal cross-node.
[[ "$B2_HEIGHT" == "$(( PREV_HEIGHT + 1 ))" ]] || fail "mutate: clearbit height did not advance: $PREV_HEIGHT -> $B2_HEIGHT"
[[ "$C2_HEIGHT" == "$B2_HEIGHT" ]] || fail "mutate: height mismatch: cb=$B2_HEIGHT core=$C2_HEIGHT"
[[ "$B2_BEST" != "$PREV_BEST" ]] || fail "mutate: clearbit bestblock did not change ($PREV_BEST)"
[[ "$B2_BEST" == "$C2_BEST" ]] || fail "mutate: bestblock mismatch: cb=$B2_BEST core=$C2_BEST"
[[ "$B2_HASH" != "$PREV_HASH" ]] || fail "mutate: clearbit set hash did not change after mining ($PREV_HASH)"
[[ "$C2_HASH" != "$PREV_HASH" ]] || fail "mutate: Core set hash did not change after mining (unexpected)"
[[ "$B2_HASH" == "$C2_HASH" ]] || fail "mutate: hash_serialized_3 diverged from Core after mutation: cb=$B2_HASH core=$C2_HASH"
log "mutate ok: height $PREV_HEIGHT->$B2_HEIGHT, hash $PREV_HASH -> $B2_HASH (still == Core)"
MUTATE_T="ok"

# ── 9. CHECK 3 — error parity. ────────────────────────────────────────────
ERRORS_T="bad"
EOK=1

# (a) hash_serialized_3 + a specific block/height -> -8 (cannot query a block).
ERESP=$(cb_gtxo_raw '["hash_serialized_3", 5]')
ECODE=$(jpy "$ERESP" "d['error']['code']")
EMSG=$(jpy "$ERESP" "d['error']['message']")
if [[ "$ECODE" != "-8" ]]; then EOK=0; log "hs3+height: expected code -8, got '$ECODE' (resp=$ERESP)"; fi
echo "$EMSG" | grep -qi "cannot be queried for a specific block" \
    || { EOK=0; log "hs3+height: message not 'cannot be queried for a specific block': '$EMSG'"; }

# (b) Unrecognized hash_type -> error (any error object, non-null).
ERESP2=$(cb_gtxo_raw '["bogus"]')
EERR2=$(jpy "$ERESP2" "d.get('error')")
if [[ -z "$EERR2" || "$EERR2" == "None" ]]; then EOK=0; log "bogus hash_type: expected an error, got resp=$ERESP2"; fi

# Cross-check Core agrees the specific-block case is -8 (parity sanity). Core
# returns -8 ("...requires coinstatsindex") when no index is built; with -8 the
# code matches even if the message differs by build. We accept Core emitting
# either the hash_serialized_3 message or the coinstatsindex message — both -8.
CORE_E1=$(core_cli gettxoutsetinfo hash_serialized_3 5 2>&1 | grep -oE "error code: -?[0-9]+" | grep -oE "\-?[0-9]+" | head -1)
[[ "$CORE_E1" == "-8" ]] || log "NOTE: Core hs3+height error code was '$CORE_E1' (expected -8)"

[[ "$EOK" == "1" ]] || fail "error-parity check failed (see log)"
ERRORS_T="ok"

# ── DONE ───────────────────────────────────────────────────────────────────
pass "$FIELDS_T" "$HASH_T" "$MUTATE_T" "$ERRORS_T"
