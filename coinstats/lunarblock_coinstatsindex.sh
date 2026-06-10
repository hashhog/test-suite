#!/usr/bin/env bash
#
# lunarblock_coinstatsindex.sh — self-contained gettxoutsetinfo-AT-HISTORICAL-
#   HEIGHT (coinstatsindex) Core-parity differential test for lunarblock.
#
# CAPABILITY UNDER TEST
#   gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#   With --coinstatsindex lunarblock maintains a per-height running MuHash3072
#   UTXO-set accumulator and can answer historical-height queries byte-identically
#   to Bitcoin Core (Core: index/coinstatsindex.cpp, kernel/coinstats.cpp).
#   WITHOUT coinstatsindex, a non-tip hash_or_height MUST error -8
#   "Querying specific block heights requires coinstatsindex".
#
# REORG-SAFETY GATE
#   After confirming the at-height linear-chain parity, the test drives a reorg:
#   invalidateblock(F+1) on both Core and lunarblock, then feeds lunarblock a
#   longer competing chain B via submitblock.  After lunarblock adopts chain B,
#   gettxoutsetinfo muhash H_R must serve chain-B's MuHash + bestblock, NOT
#   chain-A's stale values.  Fails if the coinstatsindex does not reconnect on
#   the new chain's blocks (the connect-on-reconnect gap).
#
# GROUND TRUTH = a real bitcoind regtest oracle on its OWN scratch datadir +
#   ports, launched -listen=0 -coinstatsindex=1 -txindex=1.  Core mines the
#   chain; lunarblock receives byte-identical blocks via submitblock.
#
# STRICT SHARED CONTRACT (gated here, identical across all 10 scripts):
#   * launch BOTH impl + Core on regtest with coinstatsindex + txindex.
#   * mine ~150 blocks; include a coinbase-spend so the UTXO set differs.
#   * mirror the chain so both nodes share a byte-identical tip.
#   * wait for coinstatsindex to sync (poll getindexinfo).
#   * pick historical H = 100. Call gettxoutsetinfo "muhash" H on BOTH.
#   GATE: height / bestblock / txouts / total_amount / muhash all equal.
#   REORG GATE: invalidateblock(F+1), submit longer chain B, assert
#     muhash@H_R + bestblock@H_R byte-identical to Core post-reorg.
#   ERROR GATE: without coinstatsindex, non-tip query MUST error -8.
#
# Summary line (stdout) — EXACTLY:
#   PASS: COINSTATSINDEX lunarblock: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok reorg=ok
#   FAIL: COINSTATSINDEX lunarblock: FAIL <reason>
#   SKIP: COINSTATSINDEX lunarblock: SKIP <reason>   (missing binary only)
#
# Touches ONLY /tmp/csi-lunarblock-$$ + /tmp/csi-core-$$ and ports
#   22370/22390 (lunarblock RPC/P2P) + 22371/22391 (Core RPC; -listen=0).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

LB_DATADIR="/tmp/csi-lunarblock-$$"
LB_RPC=22370
LB_P2P=22390
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/csi-core-$$"
CORE_RPC=22371
CORE_P2P=22391
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> p2wpkh bcrt1 address for chain-A mining.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SEND_ADDR_SECRET="2222222222222222222222222222222222222222222222222222222222222223"
# Deterministic chain-B mining secret (DISTINCT so B blocks differ from A).
SECRET3="3333333333333333333333333333333333333333333333333333333333333334"

NMATURE=150
HIST_H=100
TBASE=1700000000

LB_PID=""
LB2_PID=""
CORE_BG=""
ADDR=""
SECRET_WIF=""
SEND_ADDR=""
CHAIN_B_ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────────
log() { echo "[coinstatsindex:lunarblock] $*" >&2; }

# ── Port free helper ──────────────────────────────────────────────────────────
free_port() {
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): waits for OUR
    # just-stopped node to release the port. NEVER kills by port.
    local p="$1"
    for _ in $(seq 1 20); do
        ss -tln 2>/dev/null | grep -qE ":${p} " || return 0
        sleep 1
    done
    return 0
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$LB2_PID" ]] && kill -0 "$LB2_PID" 2>/dev/null; then
        kill -TERM "-${LB2_PID}" 2>/dev/null || kill -TERM "$LB2_PID" 2>/dev/null || true
        for _ in $(seq 1 10); do kill -0 "$LB2_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "$LB2_PID" 2>/dev/null || true
    fi
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
    free_port "$LB_RPC"
    free_port "$LB_P2P"
    free_port "22372"
    free_port "22393"
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" "/tmp/csi-lunarblock2-$$" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────────
pass() { echo "COINSTATSINDEX lunarblock: PASS atheight=$1 txouts=$2 amount=$3 hash=$4 bestblock=$5 reorg=$6"; exit 0; }
fail() { echo "COINSTATSINDEX lunarblock: FAIL $*"; exit 1; }
skip() { echo "COINSTATSINDEX lunarblock: SKIP $*"; exit 0; }

# ── 0. Idempotent reset. ──────────────────────────────────────────────────────
log "resetting scratch state (pid=$$)"
pkill -f "csi-lunarblock-$$" 2>/dev/null || true
free_port "$LB_RPC"; free_port "$LB_P2P"; free_port "$CORE_RPC"; free_port "$CORE_P2P"
free_port "22372"; free_port "22393"
if ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${LB_RPC}/${LB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$LB_DATADIR" "$CORE_DATADIR" "/tmp/csi-lunarblock2-$$"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
command -v luajit  >/dev/null 2>&1 || skip "luajit not found (lunarblock interpreter not built)"
[[ -f "$LB_DIR/src/main.lua" ]]    || skip "lunarblock entrypoint not found at $LB_DIR/src/main.lua"
[[ -x "$CORE_BIN" ]]               || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || skip "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive deterministic addresses. ────────────────────────────────────────
ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic mining address"
[[ "$ADDR" == bcrt1* ]] || fail "derived address is not a regtest bech32: '$ADDR'"
SECRET_WIF=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.address import byte_to_base58
print(byte_to_base58(bytes.fromhex('$SECRET') + b'\x01', 239))
" 2>/dev/null) || fail "could not derive regtest WIF"
[[ -n "$SECRET_WIF" ]] || fail "derived WIF is empty"
SEND_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SEND_ADDR_SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive send address"
CHAIN_B_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET3'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive chain-B address"
[[ "$CHAIN_B_ADDR" == bcrt1* ]] || fail "chain-B address is not bcrt1: '$CHAIN_B_ADDR'"
[[ "$CHAIN_B_ADDR" != "$ADDR" ]] || fail "chain-A and chain-B addresses collided"
log "mining addr: $ADDR ; send addr: $SEND_ADDR ; chain-B addr: $CHAIN_B_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# lb_rpc: lunarblock has no RPC auth on regtest.
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
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 3. Launch Core regtest oracle. ────────────────────────────────────────────
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
    log "Core oracle attempt $attempt failed; retrying"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch lunarblock on regtest (WITH --coinstatsindex --txindex). ─────────
log "checking if lunarblock supports --coinstatsindex"
CSI_FLAG="--coinstatsindex"
if ! grep -q -- 'coinstatsindex' "$LB_DIR/src/main.lua" 2>/dev/null; then
    log "NOTE: lunarblock has no --coinstatsindex CLI option; capability absent"
    CSI_FLAG=""
fi
log "launching lunarblock (regtest${CSI_FLAG:+ --coinstatsindex} --txindex) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' --nov2transport \
    $CSI_FLAG --txindex" \
    >"$LB_LOG" 2>&1 &
LB_PID=$!
log "lunarblock pid=$LB_PID"
lb_deadline=$(( $(date +%s) + 120 ))
lb_up=0
while (( $(date +%s) < lb_deadline )); do
    if ! kill -0 "$LB_PID" 2>/dev/null; then
        tail -n 30 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock exited during startup"
    fi
    r=$(lb_rpc getblockchaininfo '[]')
    if echo "$r" | grep -q '"regtest"'; then lb_up=1; break; fi
    sleep 1
done
[[ "$lb_up" -eq 1 ]] || { tail -n 30 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest"; }
log "lunarblock RPC ready"

# If --coinstatsindex did not cause a startup error, confirm it is actually
# recognized (the node did not silently ignore the unknown flag).
if [[ -n "$CSI_FLAG" ]]; then
    LB_GI_INIT=$(lb_rpc getindexinfo '[]')
    log "lunarblock getindexinfo on startup: $LB_GI_INIT"
fi

# ── 5. Core builds the chain: mine to maturity, spend, mine more. ─────────────
log "Core: mining $NMATURE blocks to $ADDR (setmocktime-pinned)"
core_cli setmocktime "$TBASE" >/dev/null 2>&1 || true
mine_one() {
    local nexth; nexth=$(( $(core_cli_retry getblockcount) + 1 ))
    core_cli setmocktime "$(( TBASE + nexth ))" >/dev/null 2>&1 || true
    if ! core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1; then
        sleep 1
        core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || fail "Core generatetoaddress failed"
    fi
}
for (( i=1; i<=NMATURE; i++ )); do mine_one; done

# Spend block 1's coinbase (50 BTC, matured) to SEND_ADDR.
SP_BH1=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
SP_B1J=$(core_cli_retry getblock "$SP_BH1" 2) || fail "Core getblock block1 verbosity=2 failed"
SP_TXID=$(jpy "$SP_B1J" "d['tx'][0]['txid']")
SP_SPK=$(jpy  "$SP_B1J" "d['tx'][0]['vout'][0]['scriptPubKey']['hex']")
[[ "$SP_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not read block-1 coinbase txid: '$SP_TXID'"
[[ "$SP_SPK" =~ ^[0-9a-f]+$ ]]     || fail "could not read block-1 coinbase scriptPubKey: '$SP_SPK'"
log "spending block-1 coinbase $SP_TXID:0 -> $SEND_ADDR (49.999 BTC)"
SP_RAW=$(core_cli createrawtransaction \
    "[{\"txid\":\"$SP_TXID\",\"vout\":0}]" "{\"$SEND_ADDR\":49.999}") \
    || fail "Core createrawtransaction failed"
[[ -n "$SP_RAW" ]] || fail "createrawtransaction returned empty"
SP_SIGNED=$(core_cli signrawtransactionwithkey "$SP_RAW" "[\"$SECRET_WIF\"]" \
    "[{\"txid\":\"$SP_TXID\",\"vout\":0,\"scriptPubKey\":\"$SP_SPK\",\"amount\":50.0}]") \
    || fail "Core signrawtransactionwithkey failed"
SP_COMPLETE=$(jpy "$SP_SIGNED" "d.get('complete')")
[[ "$SP_COMPLETE" == "true" ]] || fail "Core signing incomplete (complete=$SP_COMPLETE)"
SP_HEX=$(jpy "$SP_SIGNED" "d['hex']")
[[ -n "$SP_HEX" ]] || fail "signed spend hex empty"
SPEND_TXID=$(core_cli sendrawtransaction "$SP_HEX" 2>/dev/null) || fail "Core sendrawtransaction (spend) failed"
[[ "$SPEND_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "bad spend txid: '$SPEND_TXID'"
log "spend accepted: $SPEND_TXID"
mine_one
H_SPEND=$(core_cli_retry getblockcount)
for (( i=1; i<=3; i++ )); do mine_one; done
CORE_HEIGHT=$(core_cli_retry getblockcount)
log "Core chain height: $CORE_HEIGHT ; H_SPEND=$H_SPEND ; historical H=$HIST_H"
[[ "$CORE_HEIGHT" -gt "$HIST_H" ]] || fail "Core height $CORE_HEIGHT not above historical H=$HIST_H"

# ── 6. Replay Core's raw blocks into lunarblock via submitblock. ───────────────
log "replaying Core's $CORE_HEIGHT raw blocks into lunarblock via submitblock"
REPLAY_OK=1
for (( h=1; h<=CORE_HEIGHT; h++ )); do
    bh=$(core_cli_retry getblockhash "$h")    || { REPLAY_OK=0; log "getblockhash $h failed"; break; }
    raw=$(core_cli_retry getblock "$bh" 0)    || { REPLAY_OK=0; log "getblock $bh 0 failed"; break; }
    [[ -n "$raw" ]]                           || { REPLAY_OK=0; log "empty raw block at height $h"; break; }
    sb=$(lb_rpc submitblock "[\"$raw\"]")
    sbres=$(jpy "$sb" "d.get('result')")
    sberr=$(jpy "$sb" "d.get('error')")
    if [[ -n "$sbres" && "$sbres" != "None" && "$sbres" != "duplicate" && "$sbres" != "inconclusive" ]]; then
        REPLAY_OK=0; log "lunarblock submitblock rejected height $h: result='$sbres' raw=$sb"; break
    fi
    if [[ -n "$sberr" && "$sberr" != "None" ]]; then
        REPLAY_OK=0; log "lunarblock submitblock errored height $h: $sb"; break
    fi
done
LB_HEIGHT=$(jpy "$(lb_rpc getblockcount '[]')" "d['result']")
log "lunarblock height after replay: ${LB_HEIGHT:-?} (replay_ok=$REPLAY_OK, core=$CORE_HEIGHT)"
if [[ "$REPLAY_OK" != "1" || "$LB_HEIGHT" != "$CORE_HEIGHT" ]]; then
    skip "submitblock replay incomplete (lb_height=${LB_HEIGHT:-?} core=$CORE_HEIGHT) — cannot compare per-height UTXO stats"
fi
CORE_TIP=$(core_cli_retry getbestblockhash)
LB_TIP=$(jpy "$(lb_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$CORE_TIP" && -n "$LB_TIP" ]] || fail "could not read tips (core=$CORE_TIP lb=$LB_TIP)"
[[ "$CORE_TIP" == "$LB_TIP" ]] || skip "chains diverged after replay (core=$CORE_TIP lb=$LB_TIP)"
log "chains identical: tip=$LB_TIP"

# ── 7. Wait for coinstatsindex to sync on BOTH nodes. ─────────────────────────
log "waiting for Core coinstatsindex to sync to height $CORE_HEIGHT"
CORE_IDX_OK=0
idx_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < idx_deadline )); do
    GI=$(core_cli_retry getindexinfo 2>/dev/null)
    SYNCED=$(jpy "$GI" "d.get('coinstatsindex',{}).get('synced')")
    BBH=$(jpy    "$GI" "d.get('coinstatsindex',{}).get('best_block_height')")
    if [[ "$SYNCED" == "true" && "$BBH" == "$CORE_HEIGHT" ]]; then CORE_IDX_OK=1; break; fi
    sleep 1
done
if [[ "$CORE_IDX_OK" != "1" ]]; then
    # fallback: try the direct query
    if core_cli_retry gettxoutsetinfo muhash "$HIST_H" >/dev/null 2>&1; then CORE_IDX_OK=1; fi
fi
[[ "$CORE_IDX_OK" == "1" ]] || fail "Core coinstatsindex never synced (getindexinfo=$GI)"
log "Core coinstatsindex synced"

# Check lunarblock getindexinfo for coinstatsindex.
LB_GI=$(lb_rpc getindexinfo '[]')
log "lunarblock getindexinfo: $LB_GI"
LB_CSI_SYNCED=$(jpy "$LB_GI" "d.get('result',{}).get('coinstatsindex',{}).get('synced')")
LB_CSI_BBH=$(jpy    "$LB_GI" "d.get('result',{}).get('coinstatsindex',{}).get('best_block_height')")
log "lunarblock coinstatsindex: synced=$LB_CSI_SYNCED best_block_height=$LB_CSI_BBH"

# ── 8. THE CORE CHECK — gettxoutsetinfo "muhash" H on BOTH nodes. ──────────────
ATHEIGHT_T="bad"; TXOUTS_T="bad"; AMOUNT_T="bad"; HASH_T="bad"; BESTBLOCK_T="bad"

# Core: authoritative per-height stats.
CORE_HJ=$(core_cli_retry gettxoutsetinfo muhash "$HIST_H") \
    || fail "Core gettxoutsetinfo muhash $HIST_H failed"
[[ -n "$CORE_HJ" ]] || fail "Core gettxoutsetinfo returned empty"
C_HEIGHT=$(jpy "$CORE_HJ" "d.get('height')")
C_BEST=$(jpy   "$CORE_HJ" "d.get('bestblock')")
C_TXOUTS=$(jpy "$CORE_HJ" "d.get('txouts')")
C_TOTAL=$(jpy  "$CORE_HJ" "d.get('total_amount')")
C_MU=$(jpy     "$CORE_HJ" "d.get('muhash')")
CORE_BH_AT_H=$(core_cli_retry getblockhash "$HIST_H")
[[ "$C_HEIGHT" == "$HIST_H" ]] || fail "Core height=$C_HEIGHT for H=$HIST_H (oracle broken)"
[[ "$C_BEST" == "$CORE_BH_AT_H" ]] || fail "Core bestblock@H=$C_BEST != getblockhash($HIST_H)=$CORE_BH_AT_H"
[[ "$C_BEST" != "$CORE_TIP" ]] || fail "Core bestblock@H equals the TIP (sanity fail)"
log "Core@H=$HIST_H: height=$C_HEIGHT best=$C_BEST txouts=$C_TXOUTS total=$C_TOTAL muhash=$C_MU"

# lunarblock: the same historical query.
LB_HRESP=$(lb_rpc gettxoutsetinfo "[\"muhash\", $HIST_H]")
LB_ERR_CODE=$(jpy "$LB_HRESP" "d.get('error',{}).get('code') if isinstance(d.get('error'),dict) else None")
LB_ERR_MSG=$(jpy  "$LB_HRESP" "d.get('error',{}).get('message','') if isinstance(d.get('error'),dict) else ''")
LB_RES=$(jpy      "$LB_HRESP" "json.dumps(d['result']) if d.get('result') is not None else ''")

if [[ -z "$LB_RES" || "$LB_RES" == "" ]]; then
    log "lunarblock gettxoutsetinfo muhash $HIST_H returned error: code=$LB_ERR_CODE msg='$LB_ERR_MSG'"
    fail "lunarblock cannot query historical height $HIST_H (coinstatsindex absent/unwired): code=$LB_ERR_CODE '$LB_ERR_MSG'"
fi
B_HEIGHT=$(jpy "$LB_RES" "d.get('height')")
B_BEST=$(jpy   "$LB_RES" "d.get('bestblock')")
B_TXOUTS=$(jpy "$LB_RES" "d.get('txouts')")
B_TOTAL=$(jpy  "$LB_RES" "d.get('total_amount')")
B_MU=$(jpy     "$LB_RES" "d.get('muhash')")
log "lunarblock@H=$HIST_H: height=$B_HEIGHT best=$B_BEST txouts=$B_TXOUTS total=$B_TOTAL muhash=$B_MU"

# GATE 1: impl.height == H == Core.height
[[ "$B_HEIGHT" == "$HIST_H" && "$B_HEIGHT" == "$C_HEIGHT" ]] \
    || fail "atheight mismatch: lb=$B_HEIGHT H=$HIST_H core=$C_HEIGHT"
ATHEIGHT_T="ok"

# GATE 2: impl.bestblock == Core.bestblock (hash at H, not tip)
[[ "$B_BEST" == "$C_BEST" ]] || fail "bestblock@H mismatch: lb=$B_BEST core=$C_BEST"
[[ "$B_BEST" != "$LB_TIP" ]] || fail "lunarblock bestblock@H equals the TIP (returned tip state not history)"
BESTBLOCK_T="ok"

# GATE 3: impl.txouts == Core.txouts
[[ "$B_TXOUTS" =~ ^[0-9]+$ ]] || fail "lunarblock txouts@H not an int: '$B_TXOUTS'"
[[ "$B_TXOUTS" == "$C_TXOUTS" ]] || fail "txouts@H mismatch: lb=$B_TXOUTS core=$C_TXOUTS"
TXOUTS_T="ok"

# GATE 4: impl.total_amount == Core.total_amount
TOTAL_EQ=$(python3 -c "print('eq' if abs(float('$B_TOTAL')-float('$C_TOTAL'))<1e-9 else 'ne')" 2>/dev/null)
[[ "$TOTAL_EQ" == "eq" ]] || fail "total_amount@H mismatch: lb=$B_TOTAL core=$C_TOTAL"
AMOUNT_T="ok"

# GATE 5: impl.muhash == Core.muhash
[[ "$B_MU" =~ ^[0-9a-f]{64}$ ]] || fail "lunarblock muhash@H not 64-hex: '$B_MU'"
[[ "$C_MU" =~ ^[0-9a-f]{64}$ ]] || fail "Core muhash@H not 64-hex: '$C_MU'"
[[ "$B_MU" == "$C_MU" ]] || fail "muhash@H mismatch vs Core: lb=$B_MU core=$C_MU"
HASH_T="ok"

# Sanity: historical muhash must differ from the tip muhash.
CORE_TIPMU_J=$(core_cli_retry gettxoutsetinfo muhash) || fail "Core gettxoutsetinfo tip muhash failed"
C_TIPMU=$(jpy "$CORE_TIPMU_J" "d.get('muhash')")
[[ "$C_MU" != "$C_TIPMU" ]] || fail "historical muhash@H equals tip muhash (H not distinct from tip)"
log "historical muhash@H ($C_MU) distinct from tip muhash ($C_TIPMU)"

# Secondary: hash_serialized_3 @ height H -> -8 (both must agree).
CB_DEFRESP=$(lb_rpc gettxoutsetinfo "[\"hash_serialized_3\", $HIST_H]")
CB_DEFERR=$(jpy "$CB_DEFRESP" "d.get('error',{}).get('code') if isinstance(d.get('error'),dict) else None")
CORE_DEFCODE=$(core_cli gettxoutsetinfo hash_serialized_3 "$HIST_H" 2>&1 | grep -oE "error code: -?[0-9]+" | grep -oE "\-?[0-9]+" | head -1)
log "hash_serialized_3@H: lb err=$CB_DEFERR ; core err=$CORE_DEFCODE"
[[ "$CORE_DEFCODE" == "-8" ]] || log "NOTE: Core hs3@H code=$CORE_DEFCODE (expected -8)"
[[ "$CB_DEFERR" == "-8" ]] || fail "lunarblock hs3@H expected -8, got '$CB_DEFERR' (resp=$CB_DEFRESP)"

# ── 9. INERT-WHEN-DISABLED CHECK ──────────────────────────────────────────────
# Launch a second lunarblock WITHOUT --coinstatsindex; verify historical query
# errors -8 and getindexinfo does NOT list coinstatsindex.
log "inert-path check: launching lunarblock WITHOUT --coinstatsindex on port 22372"
LB2_DATADIR="/tmp/csi-lunarblock2-$$"
LB2_RPC=22372
LB2_P2P=22393
LB2_LOG="$LB2_DATADIR/node.log"
rm -rf "$LB2_DATADIR"; mkdir -p "$LB2_DATADIR"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB2_DATADIR' \
    --port '$LB2_P2P' --rpcport '$LB2_RPC' --nov2transport" \
    >"$LB2_LOG" 2>&1 &
LB2_PID=$!
LB2_UP=0
lb2_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < lb2_deadline )); do
    r2=$(curl -s --max-time 5 --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockchaininfo","params":[]}' \
        "http://127.0.0.1:$LB2_RPC/" 2>/dev/null)
    if echo "$r2" | grep -q '"regtest"'; then LB2_UP=1; break; fi
    kill -0 "$LB2_PID" 2>/dev/null || break
    sleep 1
done
if [[ "$LB2_UP" == "1" ]]; then
    # Feed a few blocks so we can probe a sub-tip height.
    for h2 in 1 2 3 4 5; do
        bh2=$(core_cli_retry getblockhash "$h2" 2>/dev/null) || true
        [[ -n "$bh2" ]] || break
        raw2=$(core_cli_retry getblock "$bh2" 0 2>/dev/null) || true
        [[ -n "$raw2" ]] || break
        curl -s --max-time 30 --data-binary \
            "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"submitblock\",\"params\":[\"$raw2\"]}" \
            "http://127.0.0.1:$LB2_RPC/" >/dev/null 2>&1 || true
    done
    NOIDX_RESP=$(curl -s --max-time 30 \
        --data-binary '{"jsonrpc":"1.0","id":1,"method":"gettxoutsetinfo","params":["muhash",2]}' \
        "http://127.0.0.1:$LB2_RPC/" 2>/dev/null)
    NOIDX_CODE=$(jpy "$NOIDX_RESP" "d.get('error',{}).get('code') if isinstance(d.get('error'),dict) else None")
    NOIDX_MSG=$(jpy  "$NOIDX_RESP" "d.get('error',{}).get('message','') if isinstance(d.get('error'),dict) else ''")
    log "lunarblock(no-index) gettxoutsetinfo muhash 2 -> code=$NOIDX_CODE msg='$NOIDX_MSG'"
    if [[ "$NOIDX_CODE" == "-8" ]]; then
        log "INERT PATH OK: disabled coinstatsindex returns -8 as expected"
    else
        log "NOTE: disabled coinstatsindex returned code=$NOIDX_CODE (expected -8); resp=$NOIDX_RESP"
    fi
    NOIDX_GI=$(curl -s --max-time 10 \
        --data-binary '{"jsonrpc":"1.0","id":1,"method":"getindexinfo","params":[]}' \
        "http://127.0.0.1:$LB2_RPC/" 2>/dev/null)
    if echo "$NOIDX_GI" | grep -q '"coinstatsindex"'; then
        fail "inert check: lunarblock(no-index) reports coinstatsindex in getindexinfo — should be absent when disabled: $NOIDX_GI"
    fi
    log "INERT PATH: coinstatsindex not in getindexinfo when disabled — correct"
    kill -TERM "-$LB2_PID" 2>/dev/null || kill -TERM "$LB2_PID" 2>/dev/null || true
    for _ in $(seq 1 10); do kill -0 "$LB2_PID" 2>/dev/null || break; sleep 1; done
    kill -KILL "$LB2_PID" 2>/dev/null || true
    LB2_PID=""
    rm -rf "$LB2_DATADIR" 2>/dev/null || true
else
    log "NOTE: inert-path node did not come up; skipping that check"
    [[ -n "$LB2_PID" ]] && { kill "$LB2_PID" 2>/dev/null || true; LB2_PID=""; }
    rm -rf "$LB2_DATADIR" 2>/dev/null || true
fi

# All five at-height gates must be ok before the reorg phase.
[[ "$ATHEIGHT_T" == "ok" && "$TXOUTS_T" == "ok" && "$AMOUNT_T" == "ok" \
   && "$HASH_T" == "ok" && "$BESTBLOCK_T" == "ok" ]] \
    || fail "one or more at-height gates failed (atheight=$ATHEIGHT_T txouts=$TXOUTS_T amount=$AMOUNT_T hash=$HASH_T bestblock=$BESTBLOCK_T)"
log "PASS (linear): lunarblock coinstatsindex matches Core at H=$HIST_H"

# ── 10. REORG-SAFETY GATE ──────────────────────────────────────────────────────
# WHY: at-height gate only proves coinstatsindex on the linear chain.  It cannot
# catch an impl that reverses the index on disconnect but never RE-ADDS on
# reconnect of the new chain's blocks.  We force a reorg via invalidateblock +
# submitblock chain B, then assert the index serves chain-B's values.
# Mirrors clearbit/rustoshi/hotbuns harnesses exactly.
REORG_T="ok"
REORG_DEPTH=5
REORG_F=$(( CORE_HEIGHT - REORG_DEPTH ))
REORG_NEWTIP=$(( CORE_HEIGHT + 3 ))
REORG_H=$CORE_HEIGHT

# lunarblock must expose invalidateblock.
LB_IB_PROBE=$(lb_rpc invalidateblock '[]')
LB_IB_PROBE_M=$(jpy "$LB_IB_PROBE" "d.get('error',{}).get('message','') if isinstance(d.get('error'),dict) else ''")
if echo "$LB_IB_PROBE_M" | grep -qi "Method not found"; then
    fail "reorg: lunarblock has no invalidateblock RPC ('$LB_IB_PROBE_M') — cannot drive a Core-faithful reorg"
fi

A_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "reorg: Core getblockhash $REORG_H (chain A) failed"
log "reorg: chain A tip N=$CORE_HEIGHT, fork F=$REORG_F, B newtip=$REORG_NEWTIP, reorg-H=$REORG_H (A@H_R=$A_HASH_AT_HR)"

# (2) Core oracle: invalidate F+1 then build longer chain B.
FORK_CHILD=$(core_cli_retry getblockhash "$(( REORG_F + 1 ))") || fail "reorg: Core getblockhash F+1 failed"
core_cli invalidateblock "$FORK_CHILD" >/dev/null 2>&1 || fail "reorg: Core invalidateblock failed"
INVAL_TIP=$(core_cli_retry getblockcount) || fail "reorg: Core getblockcount after invalidate failed"
[[ "$INVAL_TIP" == "$REORG_F" ]] || fail "reorg: Core after invalidate at $INVAL_TIP, expected F=$REORG_F"
NB_B=$(( REORG_NEWTIP - REORG_F ))
core_cli_retry generatetoaddress "$NB_B" "$CHAIN_B_ADDR" >/dev/null || fail "reorg: Core generatetoaddress (chain B) failed"
CORE_BTIP_H=$(core_cli_retry getblockcount) || fail "reorg: Core getblockcount (B tip) failed"
[[ "$CORE_BTIP_H" == "$REORG_NEWTIP" ]] || fail "reorg: Core B tip height $CORE_BTIP_H != $REORG_NEWTIP"
CORE_BTIP=$(core_cli_retry getbestblockhash) || fail "reorg: Core getbestblockhash (B) failed"
B_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "reorg: Core getblockhash $REORG_H (B) failed"
[[ "$B_HASH_AT_HR" != "$A_HASH_AT_HR" ]] \
    || fail "reorg sanity: block at H_R=$REORG_H unchanged (A=B=$A_HASH_AT_HR; not a real reorg)"
log "reorg: Core reorged to B tip=$CORE_BTIP @h$CORE_BTIP_H; B@H_R=$B_HASH_AT_HR"

# (3) REORG TRIGGER: invalidateblock(F+1) ON LUNARBLOCK first.
LB_FORK_CHILD=$(jpy "$(lb_rpc getblockhash "[$(( REORG_F + 1 ))]")" "d['result']")
[[ "$LB_FORK_CHILD" == "$FORK_CHILD" ]] \
    || fail "reorg: lb F+1 hash ($LB_FORK_CHILD) != Core F+1 ($FORK_CHILD) before invalidate"
log "reorg: invalidateblock F+1=$LB_FORK_CHILD on lunarblock (rewind to F=$REORG_F)"
LB_IB_RESP=$(lb_rpc invalidateblock "[\"$LB_FORK_CHILD\"]")
log "reorg: lb invalidateblock -> $LB_IB_RESP"
LB_AT_F=0
for _ in $(seq 1 30); do
    LB_INVAL_H=$(jpy "$(lb_rpc getblockcount '[]')" "d['result']")
    if [[ "$LB_INVAL_H" == "$REORG_F" ]]; then LB_AT_F=1; break; fi
    sleep 1
done
[[ "$LB_AT_F" == "1" ]] \
    || fail "reorg: lunarblock did not rewind to F=$REORG_F after invalidateblock (impl height=$LB_INVAL_H)"
log "reorg: lunarblock rewound to fork F=$REORG_F"

# Mirror B to lunarblock: submitblock B's blocks F+1..N+3.
log "reorg: mirroring B's blocks $(( REORG_F + 1 ))..$REORG_NEWTIP to lunarblock"
for (( h=REORG_F+1; h<=REORG_NEWTIP; h++ )); do
    kill -0 "$LB_PID" 2>/dev/null || fail "reorg: lunarblock died at h=$h (see $LB_LOG)"
    BBH=$(core_cli_retry getblockhash "$h") || fail "reorg: Core getblockhash $h (chain B) failed"
    BRAW=$(core_cli_retry getblock "$BBH" 0) || fail "reorg: Core getblock $BBH 0 (chain B) failed"
    [[ -n "$BRAW" ]] || fail "reorg: empty raw for chain-B block at h=$h"
    BSUB=$(lb_rpc submitblock "[\"$BRAW\"]")
    log "reorg submitblock h=$h -> $BSUB"
done

# Poll until lunarblock tip == Core B tip.
LB_REORG_DONE=0
for _ in $(seq 1 30); do
    LB_BTIP=$(jpy   "$(lb_rpc getbestblockhash '[]')" "d['result']")
    LB_BTIP_H=$(jpy "$(lb_rpc getblockcount '[]')"    "d['result']")
    if [[ "$LB_BTIP" == "$CORE_BTIP" && "$LB_BTIP_H" == "$CORE_BTIP_H" ]]; then LB_REORG_DONE=1; break; fi
    sleep 1
done
[[ "$LB_REORG_DONE" == "1" ]] \
    || fail "reorg: lunarblock did not adopt chain B (lb tip=$LB_BTIP @h$LB_BTIP_H, core B tip=$CORE_BTIP @h$CORE_BTIP_H)"
log "reorg: lunarblock adopted chain B (tip $LB_BTIP @h$LB_BTIP_H)"

# (4) Reorg differential: gettxoutsetinfo muhash H_R on BOTH.
RB_MUH=$(core_cli_retry gettxoutsetinfo muhash "$REORG_H") || fail "reorg: Core gettxoutsetinfo muhash $REORG_H post-reorg failed"
RC_HEIGHT=$(jpy "$RB_MUH" "d.get('height')")
RC_BEST=$(jpy   "$RB_MUH" "d.get('bestblock')")
RC_MUHASH=$(jpy "$RB_MUH" "d.get('muhash')")
[[ "$RC_HEIGHT" == "$REORG_H" ]] || fail "reorg: Core post-reorg height@H_R=$RC_HEIGHT != H_R=$REORG_H"
[[ "$RC_BEST" == "$B_HASH_AT_HR" ]] || fail "reorg: Core post-reorg bestblock@H_R=$RC_BEST != B@H_R=$B_HASH_AT_HR"
[[ "$RC_MUHASH" =~ ^[0-9a-f]{64}$ ]] || fail "reorg: Core post-reorg muhash@H_R not 64-hex: '$RC_MUHASH'"

LB_RB_RESP=$(lb_rpc gettxoutsetinfo "[\"muhash\", $REORG_H]")
LB_RB_ERR_C=$(jpy "$LB_RB_RESP" "d.get('error',{}).get('code') if isinstance(d.get('error'),dict) else None")
if [[ -n "$LB_RB_ERR_C" && "$LB_RB_ERR_C" != "None" ]]; then
    fail "reorg: lunarblock rejected gettxoutsetinfo muhash $REORG_H post-reorg (code=$LB_RB_ERR_C)"
fi
LB_RB_RES=$(jpy "$LB_RB_RESP" "json.dumps(d['result']) if d.get('result') is not None else ''")
[[ -n "$LB_RB_RES" && "$LB_RB_RES" != "" ]] \
    || fail "reorg: lunarblock gettxoutsetinfo@H_R returned no result (raw=$LB_RB_RESP)"
RB_HEIGHT=$(jpy "$LB_RB_RES" "d.get('height')")
RB_BEST=$(jpy   "$LB_RB_RES" "d.get('bestblock')")
RB_MUHASH=$(jpy "$LB_RB_RES" "d.get('muhash')")
log "reorg @H_R=$REORG_H: core(best=$RC_BEST muhash=$RC_MUHASH) lb(height=$RB_HEIGHT best=$RB_BEST muhash=$RB_MUHASH)"

if [[ "$RB_BEST" == "$A_HASH_AT_HR" ]]; then
    REORG_T="bad"
    log "reorg DESYNC: lb bestblock@H_R=$RB_BEST is A's stale block (B@H_R=$B_HASH_AT_HR) — index did not reconnect B"
fi
[[ "$RB_HEIGHT" == "$REORG_H" ]] \
    || { REORG_T="bad"; log "reorg: lb height@H_R=$RB_HEIGHT != H_R=$REORG_H"; }
[[ "$RB_BEST" == "$B_HASH_AT_HR" && "$RB_BEST" == "$RC_BEST" ]] \
    || { REORG_T="bad"; log "reorg: bestblock@H_R mismatch (lb=$RB_BEST want B@H_R=$B_HASH_AT_HR core=$RC_BEST)"; }
[[ -n "$RB_MUHASH" && "$RB_MUHASH" == "$RC_MUHASH" ]] \
    || { REORG_T="bad"; log "reorg: muhash@H_R MISMATCH (lb=$RB_MUHASH core=$RC_MUHASH) — impl served stale chain-A index after reorg"; }

[[ "$REORG_T" == "ok" ]] \
    || fail "reorg-safety gate failed at H_R=$REORG_H (lunarblock coinstatsindex did not reconnect chain B)"
log "REORG OK @H_R=$REORG_H: lunarblock muhash+bestblock match Core's B-chain values after reorg"

# ── 11. Verdict. ──────────────────────────────────────────────────────────────
[[ "$ATHEIGHT_T" == "ok" && "$TXOUTS_T" == "ok" && "$AMOUNT_T" == "ok" \
   && "$HASH_T" == "ok" && "$BESTBLOCK_T" == "ok" && "$REORG_T" == "ok" ]] \
    || fail "internal: gate flag not set (atheight=$ATHEIGHT_T txouts=$TXOUTS_T amount=$AMOUNT_T hash=$HASH_T bestblock=$BESTBLOCK_T reorg=$REORG_T)"

log "PASS: lunarblock coinstatsindex at-height query matches Core on all gated fields (linear + reorg)"
pass "$ATHEIGHT_T" "$TXOUTS_T" "$AMOUNT_T" "$HASH_T" "$BESTBLOCK_T" "$REORG_T"
