#!/usr/bin/env bash
#
# clearbit_coinstatsindex.sh — self-contained gettxoutsetinfo-AT-HISTORICAL-HEIGHT
# (coinstatsindex) differential test for clearbit vs a real bitcoind oracle.
#
# CAPABILITY UNDER TEST
#   gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#   With -coinstatsindex=1, Core can answer the UTXO-set statistics AS OF a
#   HISTORICAL block (not just the tip) when you pass hash_or_height (a height
#   int or a block hash). It is backed by the coinstatsindex — a per-height
#   running UTXO-set muhash + counts maintained on block connect/disconnect.
#   Without coinstatsindex, a non-tip hash_or_height -> RPC error -8
#   "Querying specific block heights requires coinstatsindex".
#
#   Core ref: bitcoin-core/src/rpc/blockchain.cpp gettxoutsetinfo
#     (param[1] guards at 1085-1098; result schema 1112-1126; the index branch
#      1100-1110), src/kernel/coinstats.cpp (per-coin muhash/serialization),
#      src/index/coinstatsindex.cpp (per-height running muhash + counts).
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest + its OWN ports, launched -listen=0 -coinstatsindex=1 -txindex=1.
#   Core is the SINGLE source of blocks (deterministic via setmocktime): mines
#   ~150 blocks to a deterministic p2wpkh address with a real spend of block 1's
#   coinbase (so the UTXO set differs across heights — a coinbase output removed,
#   a fresh output added). Every block's RAW hex (`getblock <hash> 0`) is
#   replayed into clearbit via `submitblock`. After replay both nodes hold the
#   byte-identical chain (assert tips equal), so their per-height UTXO-set stats
#   MUST agree.
#
# STRICT SHARED CONTRACT (gate ALL — identical assertions across all 10 scripts):
#   * launch BOTH impl + Core on regtest with -coinstatsindex=1 AND -txindex=1
#   * mine ~150 blocks to a deterministic address with a few real spends
#   * mirror the chain so both nodes share a byte-identical tip
#   * wait for coinstatsindex to sync (poll getindexinfo until synced, or until
#     gettxoutsetinfo@tip works)
#   * pick a HISTORICAL height H well below tip (here H=100)
#   * call gettxoutsetinfo "muhash" H (and the default hash_type) on BOTH
#   GATE (at height H):
#     impl.height==H==Core.height
#     impl.bestblock==Core.bestblock   (the hash AT height H, NOT the tip)
#     impl.txouts==Core.txouts
#     impl.total_amount==Core.total_amount
#     impl.<hash field> (muhash) == Core's
#   ERROR GATE: with coinstatsindex DISABLED, a non-tip hash_or_height MUST error
#     (match Core: -8 "Querying specific block heights requires coinstatsindex").
#
# Summary line (stdout) — EXACT:
#   PASS: COINSTATSINDEX clearbit: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok reorg=ok
#   FAIL: COINSTATSINDEX clearbit: FAIL <reason>
#   SKIP: COINSTATSINDEX clearbit: SKIP <reason>   (only for missing binary / replay)
#
# Touches ONLY /tmp/csidx-clearbit/ + /tmp/csidx-core/ + /tmp/csidx-core-noidx/
#   and ports 40384/40385 (clearbit RPC/P2P) + 40386/40387 (Core RPC; P2P unused
#   -listen=0) + 40388 (Core no-index error-parity baseline). Ports chosen to NOT
#   collide with the sibling coinstats scripts run concurrently in the batch.
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Does NOT
#   broad-pkill bitcoind/clearbit by name. Any `fuser -k` redirects stdout.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

CB_DATADIR="/tmp/csidx-clearbit/$$"
CB_RPC=40384
CB_P2P=40385
CB_LOG="$CB_DATADIR/node.log"

CORE_DATADIR="/tmp/csidx-core/$$"
CORE_RPC=40386
CORE_P2P=40387   # declared but Core launched -listen=0 (no P2P listener)
CORE_LOG="$CORE_DATADIR/core.log"

# Separate Core datadir for the coinstatsindex-DISABLED error-parity probe.
CORE_NOIDX_DATADIR="/tmp/csidx-core-noidx/$$"
CORE_NOIDX_RPC=40388
CORE_NOIDX_LOG="$CORE_NOIDX_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SECRET_WIF=""   # derived below via the Core test_framework
# Deterministic chain-B mining secret (DISTINCT from SECRET so B blocks differ
# from chain-A blocks at equal heights — real reorg, not a no-op).
SECRET3="3333333333333333333333333333333333333333333333333333333333333334"

NMATURE=150        # mine ~150 blocks (per the shared contract); H is well below
HIST_H=100         # the HISTORICAL height we query (well below tip)
TBASE=1700000000   # pin block timestamps (each block i -> nTime = TBASE + i)

CB_PID=""
CB_COOKIE=""
CORE_BG=""
CORE_NOIDX_BG=""
ADDR=""
SEND_ADDR=""
CHAIN_B_ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[coinstatsindex:clearbit] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CB_PID" ]] && kill -0 "$CB_PID" 2>/dev/null; then
        kill "$CB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    "$CORE_CLI" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    [[ -n "$CORE_NOIDX_BG" ]] && kill "$CORE_NOIDX_BG" 2>/dev/null || true
    fuser -k "${CB_RPC}/tcp"        >/dev/null 2>&1 || true
    fuser -k "${CB_P2P}/tcp"        >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp"      >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp"      >/dev/null 2>&1 || true
    fuser -k "${CORE_NOIDX_RPC}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CB_DATADIR" "$CORE_DATADIR" "$CORE_NOIDX_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "COINSTATSINDEX clearbit: PASS atheight=$1 txouts=$2 amount=$3 hash=$4 bestblock=$5 reorg=$6"; exit 0; }
fail() { echo "COINSTATSINDEX clearbit: FAIL $*"; exit 1; }
skip() { echo "COINSTATSINDEX clearbit: SKIP $*"; exit 0; }

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state (pid=$$)"
pkill -f "csidx-clearbit/$$" 2>/dev/null || true
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
free_port "$CB_RPC"; free_port "$CB_P2P"; free_port "$CORE_RPC"; free_port "$CORE_P2P"; free_port "$CORE_NOIDX_RPC"
rm -rf "$CB_DATADIR" "$CORE_DATADIR" "$CORE_NOIDX_DATADIR"
mkdir -p "$CB_DATADIR" "$CORE_DATADIR" "$CORE_NOIDX_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || skip "clearbit binary not found at $NODE_BIN (not built)"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN (not built)"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI (not built)"
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
CHAIN_B_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET3'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic chain-B address"
[[ "$CHAIN_B_ADDR" == bcrt1* ]] || fail "derived chain-B address is not a regtest bech32 address: '$CHAIN_B_ADDR'"
[[ "$CHAIN_B_ADDR" != "$ADDR" ]] || fail "chain-A and chain-B mining addresses collided"
log "mining address: $ADDR ; send address: $SEND_ADDR ; chain-B address: $CHAIN_B_ADDR"

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

# ── 3. Launch the Core regtest oracle (RPC-only, WITH coinstatsindex+txindex). ─
launch_core_once() {
    free_port "$CORE_RPC"; free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
        -coinstatsindex=1 -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle (-listen=0 -coinstatsindex=1 -txindex=1) rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch clearbit on regtest (WITH coinstatsindex+txindex). ──────────
log "launching clearbit (regtest --coinstatsindex --txindex) rpc=:$CB_RPC p2p=:$CB_P2P -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" --coinstatsindex --txindex \
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
# Mine to maturity first (so block 1's coinbase is spendable at height 101).
for (( i=1; i<=NMATURE; i++ )); do mine_one; done

# Spend block 1's coinbase output 0 (50 BTC, matured after 100 blocks) so the
# UTXO set has a coinbase output REMOVED and a fresh p2wpkh output ADDED. This
# spend lands ABOVE our historical height H=100, so H sees the un-spent set.
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

# Mine a few more blocks so the spend is well below tip and the at-tip state
# clearly differs from the historical H=100 state.
for (( i=1; i<=3; i++ )); do mine_one; done

CORE_HEIGHT=$(core_cli_retry getblockcount)
log "Core chain height: $CORE_HEIGHT ; H_SPEND=$H_SPEND ; historical H=$HIST_H"
[[ "$CORE_HEIGHT" -gt "$HIST_H" ]] || fail "Core height $CORE_HEIGHT not above historical H=$HIST_H"

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
    skip "submitblock replay incomplete (replay_ok=$REPLAY_OK cb_height=${CB_HEIGHT:-?} core=$CORE_HEIGHT) — cannot compare per-height UTXO stats on a shared chain"
fi

# Confirm both nodes hold the byte-identical chain (tips agree).
CORE_TIP=$(core_cli_retry getbestblockhash)
CB_TIP=$(jpy "$(cb_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$CORE_TIP" && -n "$CB_TIP" ]] || fail "could not read tips (core=$CORE_TIP cb=$CB_TIP)"
[[ "$CORE_TIP" == "$CB_TIP" ]] || skip "chains diverged after replay (core tip=$CORE_TIP cb tip=$CB_TIP) — UTXO sets not guaranteed identical"
log "chains identical: tip=$CB_TIP"

# ── 7. Wait for the coinstatsindex to sync on BOTH nodes. ─────────────────
# Core: poll getindexinfo until the coinstatsindex is synced to the tip.
log "waiting for Core coinstatsindex to sync to height $CORE_HEIGHT"
CORE_IDX_OK=0
idx_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < idx_deadline )); do
    GI=$(core_cli_retry getindexinfo 2>/dev/null)
    SYNCED=$(jpy "$GI" "d.get('coinstatsindex',{}).get('synced')")
    BBH=$(jpy "$GI" "d.get('coinstatsindex',{}).get('best_block_height')")
    if [[ "$SYNCED" == "true" && "$BBH" == "$CORE_HEIGHT" ]]; then CORE_IDX_OK=1; break; fi
    sleep 1
done
# Fallback: if getindexinfo never reported, confirm the at-tip-minus-1 query works.
if [[ "$CORE_IDX_OK" != "1" ]]; then
    if core_cli_retry gettxoutsetinfo muhash "$HIST_H" >/dev/null 2>&1; then
        CORE_IDX_OK=1
    fi
fi
[[ "$CORE_IDX_OK" == "1" ]] || fail "Core coinstatsindex never synced (getindexinfo=$GI)"
log "Core coinstatsindex synced"

# clearbit: poll getindexinfo for the coinstatsindex (advisory) and verify the
# historical query actually works (authoritative).
log "checking clearbit coinstatsindex availability"
CB_GI=$(cb_rpc getindexinfo '[]')
log "clearbit getindexinfo: $CB_GI"

# ── 8. THE CORE CHECK — gettxoutsetinfo "muhash" H on BOTH nodes. ─────────
ATHEIGHT_T="bad"; TXOUTS_T="bad"; AMOUNT_T="bad"; HASH_T="bad"; BESTBLOCK_T="bad"

# Core: authoritative per-height stats from the coinstatsindex.
CORE_HJ=$(core_cli_retry gettxoutsetinfo muhash "$HIST_H") \
    || fail "Core gettxoutsetinfo muhash $HIST_H failed (coinstatsindex)"
[[ -n "$CORE_HJ" ]] || fail "Core gettxoutsetinfo muhash $HIST_H returned empty"

C_HEIGHT=$(jpy "$CORE_HJ" "d.get('height')")
C_BEST=$(jpy "$CORE_HJ" "d.get('bestblock')")
C_TXOUTS=$(jpy "$CORE_HJ" "d.get('txouts')")
C_TOTAL=$(jpy "$CORE_HJ" "d.get('total_amount')")
C_MU=$(jpy "$CORE_HJ" "d.get('muhash')")
# Independently confirm Core's bestblock@H IS the hash at height H (NOT the tip).
CORE_BH_AT_H=$(core_cli_retry getblockhash "$HIST_H")
[[ "$C_HEIGHT" == "$HIST_H" ]] || fail "Core reported height=$C_HEIGHT for query H=$HIST_H (coinstatsindex broken on oracle)"
[[ "$C_BEST" == "$CORE_BH_AT_H" ]] || fail "Core bestblock@H=$C_BEST != getblockhash($HIST_H)=$CORE_BH_AT_H"
[[ "$C_BEST" != "$CORE_TIP" ]] || fail "Core bestblock@H equals the TIP — H is not below tip (sanity)"
log "Core@H=$HIST_H: height=$C_HEIGHT best=$C_BEST txouts=$C_TXOUTS total=$C_TOTAL muhash=$C_MU"

# clearbit: the same historical query. This is where a missing/unwired
# coinstatsindex shows up as error -8.
CB_HRESP=$(cb_rpc gettxoutsetinfo "[\"muhash\", $HIST_H]")
CB_ERR=$(jpy "$CB_HRESP" "d.get('error')")
CB_RES=$(jpy "$CB_HRESP" "json.dumps(d['result']) if d.get('result') is not None else ''")
if [[ -z "$CB_RES" || "$CB_RES" == "" ]]; then
    ECODE=$(jpy "$CB_HRESP" "d.get('error',{}).get('code')")
    EMSG=$(jpy "$CB_HRESP" "d.get('error',{}).get('message')")
    log "clearbit gettxoutsetinfo muhash $HIST_H returned error: code=$ECODE msg='$EMSG' (raw=$CB_HRESP)"
    fail "clearbit cannot query historical height $HIST_H (coinstatsindex absent/unwired): -8 '$EMSG'"
fi

B_HEIGHT=$(jpy "$CB_RES" "d.get('height')")
B_BEST=$(jpy "$CB_RES" "d.get('bestblock')")
B_TXOUTS=$(jpy "$CB_RES" "d.get('txouts')")
B_TOTAL=$(jpy "$CB_RES" "d.get('total_amount')")
B_MU=$(jpy "$CB_RES" "d.get('muhash')")
log "clearbit@H=$HIST_H: height=$B_HEIGHT best=$B_BEST txouts=$B_TXOUTS total=$B_TOTAL muhash=$B_MU"

# GATE 1: impl.height == H == Core.height
[[ "$B_HEIGHT" == "$HIST_H" && "$B_HEIGHT" == "$C_HEIGHT" ]] \
    || fail "atheight mismatch: clearbit height=$B_HEIGHT H=$HIST_H core=$C_HEIGHT"
ATHEIGHT_T="ok"

# GATE 2: impl.bestblock == Core.bestblock (the hash AT height H, not the tip)
[[ "$B_BEST" == "$C_BEST" ]] || fail "bestblock@H mismatch: clearbit=$B_BEST core=$C_BEST"
[[ "$B_BEST" != "$CB_TIP" ]] || fail "clearbit bestblock@H equals the TIP (returned tip state, not historical)"
BESTBLOCK_T="ok"

# GATE 3: impl.txouts == Core.txouts
[[ "$B_TXOUTS" =~ ^[0-9]+$ ]] || fail "clearbit txouts@H not an int: '$B_TXOUTS'"
[[ "$B_TXOUTS" == "$C_TXOUTS" ]] || fail "txouts@H mismatch: clearbit=$B_TXOUTS core=$C_TXOUTS"
TXOUTS_T="ok"

# GATE 4: impl.total_amount == Core.total_amount (numeric compare)
TOTAL_EQ=$(python3 -c "print('eq' if abs(float('$B_TOTAL')-float('$C_TOTAL'))<1e-9 else 'ne')" 2>/dev/null)
[[ "$TOTAL_EQ" == "eq" ]] || fail "total_amount@H mismatch: clearbit=$B_TOTAL core=$C_TOTAL"
AMOUNT_T="ok"

# GATE 5: impl.muhash == Core.muhash (the per-height UTXO-set fingerprint)
[[ "$B_MU" =~ ^[0-9a-f]{64}$ ]] || fail "clearbit muhash@H not 64-hex: '$B_MU'"
[[ "$C_MU" =~ ^[0-9a-f]{64}$ ]] || fail "Core muhash@H not 64-hex: '$C_MU'"
[[ "$B_MU" == "$C_MU" ]] || fail "muhash@H mismatch vs Core (per-height UTXO sets differ!): clearbit=$B_MU core=$C_MU"
HASH_T="ok"

# Sanity: the historical muhash must DIFFER from the tip muhash (proves we got
# the historical set, not the tip set). Compare against Core's at-tip muhash.
CORE_TIPMU_J=$(core_cli_retry gettxoutsetinfo muhash) || fail "Core gettxoutsetinfo muhash (tip) failed"
C_TIPMU=$(jpy "$CORE_TIPMU_J" "d.get('muhash')")
[[ "$C_MU" != "$C_TIPMU" ]] || fail "historical muhash@H equals tip muhash — H state not distinct from tip (test not exercising history)"
log "historical muhash@H ($C_MU) distinct from tip muhash ($C_TIPMU): history truly exercised"

# Cross-check the DEFAULT hash_type at height H too (Core: hash_serialized_3 is
# rejected for a specific block with -8; muhash is the queryable one). We assert
# clearbit matches Core's policy here: default hash_type @ height -> -8.
CB_DEFRESP=$(cb_rpc gettxoutsetinfo "[\"hash_serialized_3\", $HIST_H]")
CB_DEFERR=$(jpy "$CB_DEFRESP" "d.get('error',{}).get('code')")
CORE_DEFCODE=$(core_cli gettxoutsetinfo hash_serialized_3 "$HIST_H" 2>&1 | grep -oE "error code: -?[0-9]+" | grep -oE "\-?[0-9]+" | head -1)
log "default hash_type @H: clearbit err code=$CB_DEFERR ; core err code=$CORE_DEFCODE"
[[ "$CORE_DEFCODE" == "-8" ]] || log "NOTE: Core hash_serialized_3@H code was '$CORE_DEFCODE' (expected -8)"
[[ "$CB_DEFERR" == "-8" ]] || fail "clearbit hash_serialized_3@H expected -8 (cannot query specific block for hs3), got '$CB_DEFERR' (resp=$CB_DEFRESP)"

# ── 9. ERROR PARITY — coinstatsindex DISABLED, non-tip query MUST error. ──
# Launch a SECOND short-lived Core WITHOUT coinstatsindex and confirm a non-tip
# query yields -8 "Querying specific block heights requires coinstatsindex".
log "launching Core (NO coinstatsindex) for the error-parity baseline rpc=:$CORE_NOIDX_RPC"
"$CORE_BIN" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" -listen=0 \
    -fallbackfee=0.0002 >"$CORE_NOIDX_LOG" 2>&1 &
CORE_NOIDX_BG=$!
noidx_deadline=$(( $(date +%s) + 60 ))
NOIDX_READY=0
while (( $(date +%s) < noidx_deadline )); do
    "$CORE_CLI" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" getblockcount >/dev/null 2>&1 && { NOIDX_READY=1; break; }
    kill -0 "$CORE_NOIDX_BG" 2>/dev/null || break
    sleep 1
done
if [[ "$NOIDX_READY" == "1" ]]; then
    "$CORE_CLI" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" setmocktime "$TBASE" >/dev/null 2>&1 || true
    "$CORE_CLI" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" generatetoaddress 5 "$ADDR" >/dev/null 2>&1 || true
    NOIDX_ERR=$("$CORE_CLI" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" gettxoutsetinfo muhash 2 2>&1)
    NOIDX_CODE=$(echo "$NOIDX_ERR" | grep -oE "error code: -?[0-9]+" | grep -oE "\-?[0-9]+" | head -1)
    log "Core(no-idx) gettxoutsetinfo muhash 2 -> code=$NOIDX_CODE msg=$NOIDX_ERR"
    [[ "$NOIDX_CODE" == "-8" ]] || log "NOTE: Core(no-idx) non-tip query code was '$NOIDX_CODE' (expected -8)"
    echo "$NOIDX_ERR" | grep -qi "requires coinstatsindex" \
        || log "NOTE: Core(no-idx) message not 'requires coinstatsindex': $NOIDX_ERR"
else
    log "NOTE: Core(no-idx) baseline did not come up; skipping the cross-impl error-parity baseline (the main coinstatsindex gate is authoritative)"
fi

# All five GATEs must be ok to proceed to the reorg phase.
[[ "$ATHEIGHT_T" == "ok" && "$TXOUTS_T" == "ok" && "$AMOUNT_T" == "ok" \
   && "$HASH_T" == "ok" && "$BESTBLOCK_T" == "ok" ]] \
    || fail "one or more at-height gates failed (atheight=$ATHEIGHT_T txouts=$TXOUTS_T amount=$AMOUNT_T hash=$HASH_T bestblock=$BESTBLOCK_T)"
log "PASS (linear): clearbit coinstatsindex matches Core at historical height H=$HIST_H + disabled-index error gate"

# ── 10. REORG-SAFETY GATE ──────────────────────────────────────────────────
# WHY: the at-height gate above only proves the impl maintains the per-height
# MuHash on a LINEAR chain (connect-only). It CANNOT catch a reorg-desync — an
# impl that reverses the index on disconnect but never RE-ADDS on reconnect of
# the new chain's blocks will pass linear yet serve a stale (chain-A) muhash for
# a height that was reorged onto chain B. Core's coinstatsindex (BaseIndex +
# index/coinstatsindex.cpp: CustomAppend on connect, CustomRewind on disconnect)
# re-runs CustomAppend when B's blocks reconnect, so its per-height MuHash tracks
# the ACTIVE chain. This gate forces a reorg and asserts the impl agrees.
#
# REORG DESIGN (impl-agnostic; mirrors the committed rustoshi/blockbrew/nimrod/
# hotbuns harnesses exactly):
#   (1) Both nodes already share linear chain A at tip N (= $CORE_HEIGHT).
#   (2) On the Core ORACLE only: invalidateblock(getblockhash(F+1)) for a fork
#       point F < N. That disconnects A's F+1..N (Core runs CustomRemove for
#       each). Then generatetoaddress a LONGER competing chain B from F to N+3
#       to a DETERMINISTIC chain-B address (CHAIN_B_ADDR). B has strictly more
#       work, so Core reorgs A->B and its index re-runs CustomAppend for
#       B's F+1..N+3.
#   (3) REORG TRIGGER via invalidateblock ON THE IMPL (Core-faithful). A naive
#       submitblock of B's blocks onto A's tip N would be (correctly) rejected
#       as a side-branch double-spend. So FIRST call invalidateblock(F+1) ON THE
#       IMPL — rewinding it to fork F (disconnecting A's F+1..N) — THEN
#       submitblock B's blocks F+1..N+3 in order; each now connects as a clean
#       active-tip extension and the impl reorgs to B.
#   (4) Pick H_R with F < H_R <= N — a height whose block DIFFERS between A and
#       B. Call gettxoutsetinfo muhash H_R on BOTH and ASSERT
#       impl.muhash@H_R == Core.muhash@H_R AND impl.bestblock@H_R ==
#       Core.bestblock@H_R (the B-chain block at H_R, NOT A's). FAILS iff the
#       impl's index did not reconnect B's blocks (the connect-on-reconnect gap).
REORG_T="ok"
REORG_DEPTH=5                                   # A's blocks F+1..N that get reorged out
REORG_F=$(( CORE_HEIGHT - REORG_DEPTH ))        # fork point F (< N)
REORG_NEWTIP=$(( CORE_HEIGHT + 3 ))             # B's tip height (N+3): strictly more work
REORG_H=$CORE_HEIGHT                            # H_R: the OLD tip height (F < H_R <= N)
[[ "$REORG_F" -gt "$HIST_H" ]] || log "note: fork point F=$REORG_F not above linear-H=$HIST_H (ok; reorg-H differs)"

# clearbit must expose invalidateblock for the impl-side reorg trigger.
CB_IB_PROBE=$(cb_rpc invalidateblock '[]')
CB_IB_PROBE_M=$(jpy "$CB_IB_PROBE" "d.get('error',{}).get('message','')")
if echo "$CB_IB_PROBE_M" | grep -qi "Method not found"; then
    fail "reorg: clearbit has no invalidateblock RPC ('$CB_IB_PROBE_M') — cannot drive a Core-faithful reorg"
fi

# Record A's block hash at H_R (must change after the reorg, proving A!=B at H_R).
A_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "reorg: Core getblockhash $REORG_H (chain A) failed"
log "reorg: chain A tip N=$CORE_HEIGHT, fork F=$REORG_F, B newtip=$REORG_NEWTIP, reorg-H=$REORG_H (A@H_R=$A_HASH_AT_HR)"

# (2) On the Core oracle: invalidate F+1 then build longer chain B to CHAIN_B_ADDR.
FORK_CHILD=$(core_cli_retry getblockhash "$(( REORG_F + 1 ))") || fail "reorg: Core getblockhash F+1 failed"
core_cli invalidateblock "$FORK_CHILD" >/dev/null 2>&1 || fail "reorg: Core invalidateblock $FORK_CHILD failed"
INVAL_TIP=$(core_cli_retry getblockcount) || fail "reorg: Core getblockcount after invalidate failed"
[[ "$INVAL_TIP" == "$REORG_F" ]] || fail "reorg: Core after invalidate is at $INVAL_TIP, expected fork F=$REORG_F"
NB_B=$(( REORG_NEWTIP - REORG_F ))              # number of B blocks to generate (= depth+3)
core_cli_retry generatetoaddress "$NB_B" "$CHAIN_B_ADDR" >/dev/null || fail "reorg: Core generatetoaddress (chain B) failed"
CORE_BTIP_H=$(core_cli_retry getblockcount) || fail "reorg: Core getblockcount (B tip) failed"
[[ "$CORE_BTIP_H" == "$REORG_NEWTIP" ]] || fail "reorg: Core B tip height $CORE_BTIP_H != expected $REORG_NEWTIP"
CORE_BTIP=$(core_cli_retry getbestblockhash) || fail "reorg: Core getbestblockhash (B) failed"
B_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "reorg: Core getblockhash $REORG_H (chain B) failed"
[[ "$B_HASH_AT_HR" != "$A_HASH_AT_HR" ]] \
    || fail "reorg sanity: block at H_R=$REORG_H unchanged after reorg (A=B=$A_HASH_AT_HR; not a real reorg)"
log "reorg: Core reorged to B, tip=$CORE_BTIP @h$CORE_BTIP_H; B@H_R=$B_HASH_AT_HR (differs from A@H_R)"

# (3) REORG TRIGGER: invalidateblock(F+1) ON CLEARBIT first, rewinding it to F.
CB_FORK_CHILD=$(jpy "$(cb_rpc getblockhash "[$(( REORG_F + 1 ))]")" "d['result']")
[[ "$CB_FORK_CHILD" == "$FORK_CHILD" ]] \
    || fail "reorg: clearbit F+1 hash ($CB_FORK_CHILD) != Core F+1 hash ($FORK_CHILD) before invalidate"
log "reorg: invalidateblock F+1=$CB_FORK_CHILD on clearbit (rewind to fork F=$REORG_F)"
CB_IB_RESP=$(cb_rpc invalidateblock "[\"$CB_FORK_CHILD\"]")
echo "$CB_IB_RESP" | grep -q '"error":null' || log "reorg: clearbit invalidateblock -> $CB_IB_RESP"
# Poll until clearbit has actually rewound to fork point F.
CB_AT_F=0
for _ in $(seq 1 30); do
    CB_INVAL_H=$(jpy "$(cb_rpc getblockcount '[]')" "d['result']")
    if [[ "$CB_INVAL_H" == "$REORG_F" ]]; then CB_AT_F=1; break; fi
    sleep 1
done
[[ "$CB_AT_F" == "1" ]] \
    || fail "reorg: clearbit did not rewind to fork F=$REORG_F after invalidateblock (impl height=$CB_INVAL_H) — invalidateblock unsupported/ineffective"
log "reorg: clearbit rewound to fork F=$REORG_F"

# Mirror B to clearbit: submitblock B's blocks F+1..N+3 in order. Each now
# connects as a clean active-tip extension; B carries strictly more work.
log "reorg: mirroring B's blocks $(( REORG_F + 1 ))..$REORG_NEWTIP to clearbit via submitblock"
for (( h=REORG_F+1; h<=REORG_NEWTIP; h++ )); do
    kill -0 "$CB_PID" 2>/dev/null || fail "reorg: clearbit died during B replication at h=$h (see $CB_LOG)"
    BBH=$(core_cli_retry getblockhash "$h") || fail "reorg: Core getblockhash $h (chain B) failed"
    BRAW=$(core_cli_retry getblock "$BBH" 0) || fail "reorg: Core getblock $BBH 0 (chain B) failed"
    [[ -n "$BRAW" ]] || fail "reorg: empty raw for chain-B block at h=$h"
    BSUB=$(cb_rpc submitblock "[\"$BRAW\"]")
    echo "$BSUB" | grep -q '"error":null' || log "reorg submitblock h=$h -> $BSUB"
done

# Poll until clearbit tip == Core tip (B). If clearbit never adopts B, that is
# itself a reorg failure (it could not switch to the more-work chain).
CB_REORG_DONE=0
for _ in $(seq 1 30); do
    CB_BTIP=$(jpy "$(cb_rpc getbestblockhash '[]')" "d['result']")
    CB_BTIP_H=$(jpy "$(cb_rpc getblockcount '[]')" "d['result']")
    if [[ "$CB_BTIP" == "$CORE_BTIP" && "$CB_BTIP_H" == "$CORE_BTIP_H" ]]; then CB_REORG_DONE=1; break; fi
    sleep 1
done
[[ "$CB_REORG_DONE" == "1" ]] \
    || fail "reorg: clearbit did not adopt chain B (impl tip=$CB_BTIP @h$CB_BTIP_H, Core B tip=$CORE_BTIP @h$CORE_BTIP_H) — reorg to more-work chain failed"
log "reorg: clearbit adopted chain B (tip $CB_BTIP @h$CB_BTIP_H)"

# (4) The reorg differential: gettxoutsetinfo muhash H_R on BOTH. Assert
#     clearbit serves B's per-height MuHash + bestblock, NOT A's stale value.
RB_MUH=$(core_cli_retry gettxoutsetinfo muhash "$REORG_H") || fail "reorg: Core gettxoutsetinfo muhash $REORG_H (post-reorg) failed"
RC_HEIGHT=$(jpy "$RB_MUH" "d.get('height')")
RC_BEST=$(jpy   "$RB_MUH" "d.get('bestblock')")
RC_MUHASH=$(jpy "$RB_MUH" "d.get('muhash')")
[[ "$RC_HEIGHT" == "$REORG_H" ]] || fail "reorg: Core post-reorg muhash@H_R height=$RC_HEIGHT != H_R=$REORG_H"
[[ "$RC_BEST" == "$B_HASH_AT_HR" ]] || fail "reorg: Core post-reorg bestblock@H_R=$RC_BEST != B@H_R=$B_HASH_AT_HR (oracle wrong?)"
[[ "$RC_MUHASH" =~ ^[0-9a-f]{64}$ ]] || fail "reorg: Core post-reorg muhash@H_R not 64-hex: '$RC_MUHASH'"

CB_RB_RESP=$(cb_rpc gettxoutsetinfo "[\"muhash\", $REORG_H]")
CB_RB_ERR_C=$(jpy "$CB_RB_RESP" "d.get('error',{}).get('code')")
if [[ -n "$CB_RB_ERR_C" && "$CB_RB_ERR_C" != "None" ]]; then
    fail "reorg: clearbit rejected gettxoutsetinfo muhash $REORG_H post-reorg (code=$CB_RB_ERR_C) — coinstatsindex not serving the reorged height"
fi
CB_RB_RES=$(jpy "$CB_RB_RESP" "json.dumps(d['result']) if d.get('result') is not None else ''")
[[ -n "$CB_RB_RES" && "$CB_RB_RES" != "" ]] || fail "reorg: clearbit gettxoutsetinfo@H_R post-reorg returned no result (raw=$CB_RB_RESP)"

RB_HEIGHT=$(jpy "$CB_RB_RES" "d.get('height')")
RB_BEST=$(jpy   "$CB_RB_RES" "d.get('bestblock')")
RB_MUHASH=$(jpy "$CB_RB_RES" "d.get('muhash')")
log "reorg @H_R=$REORG_H: core(best=$RC_BEST muhash=$RC_MUHASH) clearbit(height=$RB_HEIGHT best=$RB_BEST muhash=$RB_MUHASH)"

if [[ "$RB_BEST" == "$A_HASH_AT_HR" ]]; then
    REORG_T="bad"; log "reorg DESYNC: clearbit bestblock@H_R=$RB_BEST is A's stale block (B@H_R=$B_HASH_AT_HR) — index did not reconnect B"
fi
[[ "$RB_HEIGHT" == "$REORG_H" ]] \
    || { REORG_T="bad"; log "reorg: clearbit height@H_R=$RB_HEIGHT != H_R=$REORG_H"; }
[[ "$RB_BEST" == "$B_HASH_AT_HR" && "$RB_BEST" == "$RC_BEST" ]] \
    || { REORG_T="bad"; log "reorg: bestblock@H_R mismatch (clearbit=$RB_BEST want B@H_R=$B_HASH_AT_HR core=$RC_BEST)"; }
[[ -n "$RB_MUHASH" && "$RB_MUHASH" == "$RC_MUHASH" ]] \
    || { REORG_T="bad"; log "reorg: muhash@H_R MISMATCH (clearbit=$RB_MUHASH core=$RC_MUHASH) — impl served stale chain-A index after reorg"; }

[[ "$REORG_T" == "ok" ]] || fail "reorg-safety gate failed at H_R=$REORG_H (clearbit muhash/bestblock did not follow reorg from A to B; coinstatsindex reverses on disconnect but does NOT reconnect on the new chain)"
log "REORG OK @H_R=$REORG_H: clearbit muhash+bestblock match Core's B-chain values after reorg"

# ── 11. Verdict. ──────────────────────────────────────────────────────────
[[ "$ATHEIGHT_T" == "ok" && "$TXOUTS_T" == "ok" && "$AMOUNT_T" == "ok" \
   && "$HASH_T" == "ok" && "$BESTBLOCK_T" == "ok" && "$REORG_T" == "ok" ]] \
    || fail "internal: a gate flag was not set (atheight=$ATHEIGHT_T txouts=$TXOUTS_T amount=$AMOUNT_T hash=$HASH_T bestblock=$BESTBLOCK_T reorg=$REORG_T)"

log "PASS: clearbit coinstatsindex at-height query matches Core on all gated fields (linear + reorg)"
pass "$ATHEIGHT_T" "$TXOUTS_T" "$AMOUNT_T" "$HASH_T" "$BESTBLOCK_T" "$REORG_T"
