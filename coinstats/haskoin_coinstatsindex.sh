#!/usr/bin/env bash
#
# haskoin_coinstatsindex.sh — self-contained gettxoutsetinfo-AT-HISTORICAL-HEIGHT
# (coinstatsindex) Core-parity differential test for haskoin.
#
# CAPABILITY UNDER TEST
#   gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#   With -coinstatsindex=1, Core can answer the UTXO-set statistics AS OF a
#   HISTORICAL block (a height int or block hash), not just the tip. It is
#   backed by index/coinstatsindex.cpp: a per-height running MuHash3072 + coin
#   counts/amounts maintained on every block connect/disconnect.
#   Without coinstatsindex, a non-tip hash_or_height -> error -8
#   "Querying specific block heights requires coinstatsindex".
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp gettxoutsetinfo
#   bitcoin-core/src/kernel/coinstats.cpp  (muhash kernel, per-coin accounting)
#   bitcoin-core/src/index/coinstatsindex.cpp (per-height running stats)
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its own scratch
#   regtest instance + own ports, launched -listen=0 with -coinstatsindex=1 AND
#   -txindex=1. Core mines ~150 blocks to a deterministic address + at least one
#   real SPEND tx (so the UTXO set genuinely DIFFERS across heights), then we
#   FEED Core's exact block bytes to haskoin via submitblock so BOTH nodes hold
#   the BYTE-IDENTICAL chain. We then query gettxoutsetinfo AS OF a historical
#   height H well below the tip (H=100) on BOTH.
#
# STRICT SHARED CONTRACT (gated identically across all 10 impl scripts):
#   * launch BOTH impl + Core on regtest with -coinstatsindex=1 (+ -txindex=1)
#   * mine ~150 blocks w/ a few real spends so the UTXO set differs across height
#   * mirror the chain so both nodes share a byte-identical tip
#   * wait for coinstatsindex to sync (getindexinfo synced, or @tip works)
#   * pick a HISTORICAL height H << tip (H=100)
#   * gettxoutsetinfo "muhash" H (and default hash_type) on BOTH
#   * GATE: impl.height==H==Core.height; impl.bestblock==Core.bestblock (the
#     hash AT height H, NOT the tip); impl.txouts==Core.txouts;
#     impl.total_amount==Core.total_amount; impl.<hash>==Core's.
#   * ERROR gate: with coinstatsindex DISABLED a non-tip hash_or_height must
#     error, matching Core.
#
# Summary line (stdout), EXACTLY:
#   PASS: COINSTATSINDEX haskoin: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok
#   FAIL: COINSTATSINDEX haskoin: FAIL <reason>
#   SKIP: COINSTATSINDEX haskoin: SKIP <reason>
#
# STRICT UNIFORM INTERFACE: set -uo pipefail, idempotent, trap cleanup, scratch
#   /tmp datadirs + unique ports, ONE clean summary line on stdout, all noise ->
#   stderr/logfile, exit 0/1. Touches ONLY /tmp/csi-haskoin/ + /tmp/csi-core/
#   and ports 40379/40399 (haskoin RPC/P2P) + 40381/40401 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node; never
#   broad-pkills bitcoind by name (a live mainnet bitcoind may be running).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
HK_DIR="$BASEDIR/haskoin"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (MiniWallet)
SPEND_BUILDER="$BASEDIR/test-suite/blockfilter/build_spend_chain.py"

HK_BIN="$(find "$HK_DIR/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"

export LD_LIBRARY_PATH="/home/work/.local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}"

HK_DATADIR="/tmp/csi-haskoin"
HK_RPC=40379
HK_P2P=40399
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""
HK_PID=""

CORE_DATADIR="/tmp/csi-core"
CORE_RPC=40381
CORE_P2P=40401
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

# Separate Core instance used ONLY for the "coinstatsindex DISABLED" error gate.
CORE_NOIDX_DATADIR="/tmp/csi-core-noidx"
CORE_NOIDX_RPC=40383
CORE_NOIDX_P2P=40403
CORE_NOIDX_LOG="$CORE_NOIDX_DATADIR/core.log"
CORE_NOIDX_BG=""

export haskoin_datadir="$HK_DATADIR"

# Deterministic test secret -> one p2wpkh bcrt1 address Core mines blocks to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=150        # >>100 so the historical height H=100 sits well below tip.
HIST_H=100         # the HISTORICAL height we query AS OF.
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[coinstatsindex:haskoin] $*" >&2; }

# ── free_port: kill OUR port holder and POLL until the socket is free. ─────
free_port() {
    local p="$1"
    fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        fuser "${p}/tcp" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}

# ── Cleanup: kill OUR nodes + wipe scratch on any exit (no broad pkill). ──
cleanup() {
    local ec=$?
    if [[ -n "$HK_PID" ]] && kill -0 "$HK_PID" 2>/dev/null; then
        kill "$HK_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HK_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HK_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    "$CORE_CLI" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    [[ -n "$CORE_NOIDX_BG" ]] && kill "$CORE_NOIDX_BG" 2>/dev/null || true
    free_port "$HK_RPC"
    free_port "$HK_P2P"
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    free_port "$CORE_NOIDX_RPC"
    free_port "$CORE_NOIDX_P2P"
    rm -rf "$HK_DATADIR" "$CORE_DATADIR" "$CORE_NOIDX_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "COINSTATSINDEX haskoin: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok reorg=ok"
    exit 0
}
fail() {
    echo "COINSTATSINDEX haskoin: FAIL $*"
    exit 1
}
skip() {
    echo "COINSTATSINDEX haskoin: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset (only OUR scratch markers + OUR ports). ───────────
log "resetting scratch state"
pkill -f "csi-haskoin" >/dev/null 2>&1 || true
free_port "$HK_RPC"
free_port "$HK_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
free_port "$CORE_NOIDX_RPC"
free_port "$CORE_NOIDX_P2P"
rm -rf "$HK_DATADIR" "$CORE_DATADIR" "$CORE_NOIDX_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR" "$CORE_NOIDX_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -n "$HK_BIN" && -x "$HK_BIN" ]]   || skip "haskoin binary not found under $HK_DIR/dist-newstyle (build with: cabal build exe:haskoin)"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"
[[ -f "$SPEND_BUILDER" ]]            || fail "spend-chain builder not found at $SPEND_BUILDER"

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

# Second deterministic address for the reorg phase's competing chain B, so B's
# blocks differ from A's even at equal heights (distinct coinbase scriptPubKey).
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"
DEST_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$DEST_SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic reorg dest address"
[[ "$DEST_ADDR" == bcrt1* && "$DEST_ADDR" != "$ADDR" ]] || fail "reorg dest address bad: '$DEST_ADDR'"

# ── RPC helpers ───────────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# noidx Core helper (error-gate instance, coinstatsindex DISABLED).
core_noidx_cli() { "$CORE_CLI" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" "$@"; }

hk_rpc() {
    curl -s --max-time 120 -u "$HK_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HK_RPC/" 2>/dev/null
}

# jpy <json> <expr>  (expr references parsed object as `d`); errors swallowed.
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

# ── 3. Launch the Core regtest oracle WITH -coinstatsindex=1 -txindex=1. ──
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -fallbackfee=0.0002 -coinstatsindex=1 -txindex=1 >"$CORE_LOG" 2>&1 &
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
    log "launching Core oracle (-coinstatsindex=1 -txindex=1) rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch haskoin on regtest. ──────────────────────────────────────────
# haskoin's `node` subcommand now exposes --coinstatsindex (Bitcoin Core
# -coinstatsindex=1): a per-height running MuHash3072 + coin counts/amounts,
# maintained incrementally on block connect/disconnect, which lets
# gettxoutsetinfo answer for a historical height/hash. We launch with both
# --coinstatsindex (the capability under test) and --blockfilterindex (so the
# shared IndexManager backfill path is exercised end-to-end).
log "launching haskoin (regtest) rpc=:$HK_RPC p2p=:$HK_P2P -> $HK_LOG"
"$HK_BIN" --network Regtest --datadir "$HK_DATADIR" \
    node --rpcport="$HK_RPC" --port="$HK_P2P" --listen=False --metricsport 0 \
    --coinstatsindex --blockfilterindex \
    >"$HK_LOG" 2>&1 &
HK_PID=$!
hk_deadline=$(( $(date +%s) + 180 ))
HK_DEAD_STREAK=0
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        hk_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    # Require TWO consecutive death observations (with a short settle between)
    # before declaring startup failure — the GHC RTS can momentarily look
    # un-pollable right after fork while it is still wiring up the RPC port.
    if kill -0 "$HK_PID" 2>/dev/null; then
        HK_DEAD_STREAK=0
    else
        HK_DEAD_STREAK=$(( HK_DEAD_STREAK + 1 ))
        if (( HK_DEAD_STREAK >= 2 )); then
            tail -n 20 "$HK_LOG" >&2 2>/dev/null || true
            fail "haskoin exited during startup (see $HK_LOG)"
        fi
    fi
    sleep 2
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 180s"
hk_rpc getblockcount '[]' | grep -q '"result"' || fail "haskoin RPC never responded within 180s"
log "haskoin RPC ready"

# ── 5. Build a chain on Core that INCLUDES A SPEND (no wallet needed). ─────
log "building Core chain with a spend via MiniWallet (coinbase blocks=$NBLOCKS)"
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"
CHAIN_OUT=$(python3 "$SPEND_BUILDER" \
    "$TF_PATH" "$CORE_RPC" "$CORE_COOKIE_FILE" "$NBLOCKS" "$ADDR" 2>>"$CORE_LOG") \
    || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "build_spend_chain.py failed (see $CORE_LOG)"; }

TOTAL=$(awk '/^TOTAL /{print $2}'               <<<"$CHAIN_OUT")
SPEND_HEIGHT=$(awk '/^SPEND_HEIGHT /{print $2}' <<<"$CHAIN_OUT")
SPEND_HASH=$(awk '/^SPEND_HASH /{print $2}'     <<<"$CHAIN_OUT")
SPEND_TXID=$(awk '/^SPEND_TXID /{print $2}'     <<<"$CHAIN_OUT")
[[ -n "$TOTAL" && -n "$SPEND_HEIGHT" && -n "$SPEND_HASH" && -n "$SPEND_TXID" ]] \
    || fail "build_spend_chain.py did not return chain coordinates: $CHAIN_OUT"
[[ "$TOTAL" -gt "$HIST_H" ]] || fail "chain tip $TOTAL is not above historical height $HIST_H"
log "Core chain built: height $TOTAL, spend tx $SPEND_TXID confirmed in block $SPEND_HASH (h$SPEND_HEIGHT)"

# ── 6. FEED Core's exact block bytes to haskoin via submitblock. ──────────
log "submitting $TOTAL Core blocks to haskoin via submitblock"
for h in $(seq 1 "$TOTAL"); do
    bh=$(core_cli_retry getblockhash "$h")  || fail "Core getblockhash $h failed"
    raw=$(core_cli_retry getblock "$bh" 0)  || fail "Core getblock $bh 0 failed"
    sb=$(hk_rpc submitblock "[\"$raw\"]")
    err=$(jpy "$sb" "d.get('error')")
    res=$(jpy "$sb" "d.get('result')")
    if [[ -n "$err" && "$err" != "None" ]]; then
        fail "haskoin submitblock rejected block $h (error): $sb"
    fi
    if [[ -n "$res" && "$res" != "None" ]]; then
        fail "haskoin submitblock rejected block $h (result '$res'): $sb"
    fi
done
HK_HEIGHT=$(jpy "$(hk_rpc getblockcount '[]')" "d['result']")
[[ "$HK_HEIGHT" == "$TOTAL" ]] || fail "haskoin height after submitblock is $HK_HEIGHT, expected $TOTAL (chain shape mismatch)"
log "both nodes at height $TOTAL with byte-identical chains"

# ── 7. Wait for Core's coinstatsindex to finish syncing. ──────────────────
log "waiting for Core coinstatsindex to sync"
CSI_SYNCED=0
csi_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < csi_deadline )); do
    II=$(core_cli_retry getindexinfo) || true
    SY=$(jpy "$II" "d.get('coinstatsindex',{}).get('synced')")
    BH=$(jpy "$II" "d.get('coinstatsindex',{}).get('best_block_height')")
    if [[ "$SY" == "true" && "$BH" == "$TOTAL" ]]; then CSI_SYNCED=1; break; fi
    sleep 1
done
[[ "$CSI_SYNCED" == "1" ]] || fail "Core coinstatsindex did not sync to height $TOTAL within 120s"
# Sanity: Core can answer an at-tip muhash query.
core_cli_retry gettxoutsetinfo muhash "$TOTAL" >/dev/null \
    || fail "Core gettxoutsetinfo muhash@tip failed even after index synced"
log "Core coinstatsindex synced to height $TOTAL"

# ── 8. THE AT-HEIGHT GATE: query gettxoutsetinfo AS OF historical height H. ─
# Core: gettxoutsetinfo "muhash" H  -> stats AS OF block at height H.
# We also exercise the DEFAULT hash_type at height H (Core, with
# coinstatsindex, returns hash_serialized_3 for a historical height too).
log "querying gettxoutsetinfo AS OF historical height H=$HIST_H on BOTH nodes"

# Core ground-truth at H (muhash).
C_MUH=$(core_cli_retry gettxoutsetinfo muhash "$HIST_H") || fail "Core gettxoutsetinfo muhash $HIST_H failed"
C_HEIGHT=$(jpy "$C_MUH" "d['height']")
C_BEST=$(jpy   "$C_MUH" "d['bestblock']")
C_TXOUTS=$(jpy "$C_MUH" "d['txouts']")
C_TOTAL=$(jpy  "$C_MUH" "d['total_amount']")
C_HASH=$(jpy   "$C_MUH" "d['muhash']")
# Independent ground-truth: the canonical block hash AT height H (must == bestblock).
C_BLOCKHASH_H=$(core_cli_retry getblockhash "$HIST_H") || fail "Core getblockhash $HIST_H failed"

[[ "$C_HEIGHT" == "$HIST_H" ]] || fail "Core sanity: muhash@$HIST_H returned height=$C_HEIGHT (expected $HIST_H)"
[[ "$C_BEST" == "$C_BLOCKHASH_H" ]] || fail "Core sanity: muhash@$HIST_H bestblock=$C_BEST != block hash at H=$C_BLOCKHASH_H"
[[ "$C_BEST" != "$(core_cli_retry getblockhash "$TOTAL")" ]] || fail "Core sanity: muhash@$HIST_H bestblock equals TIP hash (index not historical)"
log "Core @H=$HIST_H : height=$C_HEIGHT bestblock=$C_BEST txouts=$C_TXOUTS total=$C_TOTAL muhash=$C_HASH"

# haskoin at H (muhash).
H_RESP=$(hk_rpc gettxoutsetinfo "[\"muhash\", $HIST_H]")
# If the impl errors on a historical hash_or_height, that is a real FAIL
# (the capability is missing), UNLESS it errors with Core's exact
# coinstatsindex-disabled message — but haskoin has coinstatsindex
# substrate, so erroring here is a missing-wiring FAIL.
if echo "$H_RESP" | grep -q '"result"' && [[ "$(jpy "$H_RESP" "d.get('result')")" != "None" ]]; then
    H_HEIGHT=$(jpy "$H_RESP" "d['result']['height']")
    H_BEST=$(jpy   "$H_RESP" "d['result']['bestblock']")
    H_TXOUTS=$(jpy "$H_RESP" "d['result']['txouts']")
    H_TOTAL=$(jpy  "$H_RESP" "d['result']['total_amount']")
    H_HASH=$(jpy   "$H_RESP" "d['result'].get('muhash','')")
    log "haskoin @H=$HIST_H (muhash): height=$H_HEIGHT bestblock=$H_BEST txouts=$H_TXOUTS total=$H_TOTAL muhash=$H_HASH"

    AT_H=ok; TXO=ok; AMT=ok; HSH=ok; BST=ok
    [[ "$H_HEIGHT" == "$HIST_H" ]] || { AT_H=bad; log "height mismatch: impl=$H_HEIGHT expected H=$HIST_H (Core=$C_HEIGHT)"; }
    [[ "$H_BEST" == "$C_BEST" ]]   || { BST=bad;  log "bestblock mismatch: impl=$H_BEST Core(@H)=$C_BEST (impl likely returned TIP, not H)"; }
    [[ "$H_TXOUTS" == "$C_TXOUTS" ]] || { TXO=bad; log "txouts mismatch: impl=$H_TXOUTS Core(@H)=$C_TXOUTS"; }
    TOTAL_EQ=$(python3 -c "print('eq' if abs(float('$C_TOTAL')-float('$H_TOTAL'))<1e-9 else 'ne')" 2>/dev/null)
    [[ "$TOTAL_EQ" == "eq" ]] || { AMT=bad; log "total_amount mismatch: impl=$H_TOTAL Core(@H)=$C_TOTAL"; }
    if [[ -z "$H_HASH" ]]; then
        HSH=bad; log "impl returned no muhash field at H"
    elif [[ "$H_HASH" != "$C_HASH" ]]; then
        HSH=bad; log "muhash mismatch: impl=$H_HASH Core(@H)=$C_HASH"
    fi

    if [[ "$AT_H" != ok || "$TXO" != ok || "$AMT" != ok || "$HSH" != ok || "$BST" != ok ]]; then
        # Most likely: the impl ignored the height arg and answered for the TIP.
        TIP_HASH=$(core_cli_retry getblockhash "$TOTAL")
        if [[ "$H_HEIGHT" == "$TOTAL" || "$H_BEST" == "$TIP_HASH" ]]; then
            fail "at-height not honored: impl ignored hash_or_height=$HIST_H and answered for the TIP (height=$H_HEIGHT bestblock=$H_BEST). coinstatsindex present-but-unwired."
        fi
        fail "at-height divergence vs Core@H=$HIST_H: atheight=$AT_H txouts=$TXO amount=$AMT hash=$HSH bestblock=$BST"
    fi
    log "at-height muhash matches Core (height/bestblock/txouts/total_amount/muhash all exact)"
else
    # impl errored on a historical hash_or_height.
    E_CODE=$(jpy "$H_RESP" "d['error']['code']")
    E_MSG=$(jpy  "$H_RESP" "d['error']['message']")
    log "haskoin gettxoutsetinfo muhash $HIST_H errored: code=$E_CODE msg=$E_MSG"
    fail "impl rejects historical hash_or_height (code=$E_CODE: '$E_MSG'); coinstatsindex at-height query not wired (substrate exists in src/Haskoin/Index.hs but is never instantiated/queried)"
fi

# ── 8b. Also exercise hash_serialized_3 at height H (Core parity). ─────────
# IMPORTANT (matches the committed-green blockbrew reference harness, and
# verified empirically against bitcoind v31.99): the coinstatsindex stores a
# per-height MuHash only — Core REJECTS `hash_serialized_3` for a specific
# block with RPC_INVALID_PARAMETER (-8) "hash_serialized_3 hash type cannot
# be queried for a specific block" EVEN with -coinstatsindex=1. The impl must
# reproduce whatever Core does. We assert parity in BOTH directions:
#   * Core errs -8  -> impl must err -8 too.
#   * Core serves it -> impl must serve a byte-identical hash_serialized_3.
CORE_DEF_RAW=$(core_cli gettxoutsetinfo hash_serialized_3 "$HIST_H" 2>&1)
CORE_DEF_ERR=$(echo "$CORE_DEF_RAW" | grep -i "error code" | grep -oE '\-?[0-9]+' | head -1)
H_DEF=$(hk_rpc gettxoutsetinfo "[\"hash_serialized_3\", $HIST_H]")
if [[ -n "$CORE_DEF_ERR" ]]; then
    # Core rejects hash_serialized_3 + specific block. The impl must too.
    if echo "$H_DEF" | grep -q '"result"' && [[ "$(jpy "$H_DEF" "d.get('result')")" != "None" ]]; then
        fail "hash_serialized_3@$HIST_H: Core rejects (code=$CORE_DEF_ERR) but impl served a result"
    fi
    H_DEF_CODE=$(jpy "$H_DEF" "d['error']['code']")
    [[ "$H_DEF_CODE" == "$CORE_DEF_ERR" ]] \
        || fail "hash_serialized_3@$HIST_H error-code parity: Core=$CORE_DEF_ERR impl=$H_DEF_CODE"
    log "at-height hash_serialized_3: Core+impl both reject with $CORE_DEF_ERR (parity)"
else
    # Core served a hash_serialized_3 at H via the index: compare byte-exact.
    C_DEF_HEIGHT=$(jpy "$CORE_DEF_RAW" "d['height']")
    C_DEF_HASH=$(jpy   "$CORE_DEF_RAW" "d['hash_serialized_3']")
    if echo "$H_DEF" | grep -q '"result"' && [[ "$(jpy "$H_DEF" "d.get('result')")" != "None" ]]; then
        H_DEF_HEIGHT=$(jpy "$H_DEF" "d['result']['height']")
        H_DEF_HASH=$(jpy   "$H_DEF" "d['result'].get('hash_serialized_3','')")
        [[ "$H_DEF_HEIGHT" == "$HIST_H" ]] || fail "impl hash_serialized_3@$HIST_H height=$H_DEF_HEIGHT (expected $HIST_H)"
        [[ "$H_DEF_HASH" == "$C_DEF_HASH" ]] || fail "impl hash_serialized_3@$HIST_H mismatch: impl=$H_DEF_HASH Core=$C_DEF_HASH"
        log "at-height hash_serialized_3 matches Core"
    else
        H_DEF_CODE=$(jpy "$H_DEF" "d['error']['code']")
        H_DEF_MSG=$(jpy  "$H_DEF" "d['error']['message']")
        fail "impl rejects hash_serialized_3 at historical height $HIST_H (code=$H_DEF_CODE: '$H_DEF_MSG'); Core (with coinstatsindex) answers it"
    fi
fi

# ── 9. ERROR GATE: coinstatsindex DISABLED -> non-tip query must error. ───
# Launch a SECOND Core instance WITHOUT coinstatsindex and confirm a non-tip
# hash_or_height yields -8 "Querying specific block heights requires
# coinstatsindex". This is the contract the impl must also honor when its
# coinstatsindex is off.
log "error gate: launching disabled-index Core (no -coinstatsindex) rpc=:$CORE_NOIDX_RPC"
"$CORE_BIN" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" -port="$CORE_NOIDX_P2P" \
    -listen=0 -fallbackfee=0.0002 >"$CORE_NOIDX_LOG" 2>&1 &
CORE_NOIDX_BG=$!
ng_deadline=$(( $(date +%s) + 60 ))
NOIDX_OK=0
while (( $(date +%s) < ng_deadline )); do
    if core_noidx_cli getblockcount >/dev/null 2>&1; then NOIDX_OK=1; break; fi
    kill -0 "$CORE_NOIDX_BG" 2>/dev/null || break
    sleep 1
done
if [[ "$NOIDX_OK" == "1" ]]; then
    core_noidx_cli generatetoaddress 5 "$ADDR" >/dev/null 2>&1 || true
    NOIDX_ERR=$(core_noidx_cli gettxoutsetinfo muhash 2 2>&1 \
        | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
    [[ "$NOIDX_ERR" == "-8" ]] || log "note: disabled-index Core error code for muhash <height> was '$NOIDX_ERR' (expected -8)"
    log "error gate (Core, no coinstatsindex): muhash <height> -> code $NOIDX_ERR (expected -8)"
else
    log "note: disabled-index Core oracle did not start; skipping the Core side of the error gate"
fi

# ── 9.5 REORG-SAFETY GATE ──────────────────────────────────────────────────
# WHY: the at-height gate above only proves the impl maintains the per-height
# MuHash on a LINEAR chain (connect-only). It CANNOT catch a reorg-desync — an
# impl that reverses the index on disconnect but never RE-ADDS on reconnect of
# the new chain's blocks will pass linear yet serve a stale (chain-A) muhash for
# a height that was reorged onto chain B. Core's coinstatsindex (BaseIndex +
# index/coinstatsindex.cpp: CustomAppend on connect, CustomRemove on disconnect)
# re-runs CustomAppend when B's blocks reconnect, so its per-height MuHash tracks
# the ACTIVE chain. This gate forces a reorg and asserts haskoin agrees.
#
# REORG DESIGN (impl-agnostic; mirrored to the impl the SAME way the linear chain
# was — via submitblock, so no impl-specific invalidateblock is needed; the
# remaining-7 fanout MUST mirror these exact steps):
#   (1) Both nodes already share linear chain A at tip N (= $TOTAL).
#   (2) On the Core ORACLE only: invalidateblock(getblockhash(F+1)) for a fork
#       point F < N. That disconnects A's F+1..N (Core runs CustomRemove for each).
#       Then generatetoaddress a LONGER competing chain B from F to N+3 to a
#       DETERMINISTIC address. B has strictly more work, so Core reorgs A->B and
#       its index re-runs CustomAppend for B's F+1..N+3.
#   (3) Mirror B to the impl by submitblock-ing B's blocks F+1..N+3 in order. The
#       impl MUST reorg from A to B (B has more work). Poll until impl tip ==
#       Core tip (B).
#   (4) Pick a height H_R with F < H_R <= N — a height whose block DIFFERS between
#       A and B. Call gettxoutsetinfo muhash H_R on BOTH and ASSERT
#       impl.muhash@H_R == Core.muhash@H_R AND impl.bestblock@H_R ==
#       Core.bestblock@H_R (the B-chain block at H_R, NOT A's). FAILS iff the
#       impl's index did not reconnect B's blocks (the connect-on-reconnect gap).
REORG_OK="ok"
REORG_DEPTH=5                         # A's blocks F+1..N that get reorged out
REORG_F=$(( TOTAL - REORG_DEPTH ))    # fork point F (< N)
REORG_NEWTIP=$(( TOTAL + 3 ))         # B's tip height (N+3): strictly more work
REORG_H=$TOTAL                        # H_R: the OLD tip height (F < H_R <= N); block differs A vs B

# A's block hash at H_R (must change after the reorg, proving A!=B at H_R).
A_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "Core getblockhash $REORG_H (chain A) failed"
log "reorg: chain A tip N=$TOTAL, fork F=$REORG_F, B newtip=$REORG_NEWTIP, reorg-H=$REORG_H (A@H_R=$A_HASH_AT_HR)"

# (2) On the Core oracle: invalidate F+1, then build longer chain B to a
#     DETERMINISTIC address ($DEST_ADDR, distinct from the A-mining address so
#     B's blocks are deterministically different from A's even at equal heights).
FORK_CHILD=$(core_cli_retry getblockhash "$(( REORG_F + 1 ))") || fail "Core getblockhash F+1 failed"
core_cli invalidateblock "$FORK_CHILD" >/dev/null 2>&1 || fail "Core invalidateblock $FORK_CHILD failed"
INVAL_TIP=$(core_cli_retry getblockcount) || fail "Core getblockcount after invalidate failed"
[[ "$INVAL_TIP" == "$REORG_F" ]] || fail "Core after invalidate is at $INVAL_TIP, expected fork F=$REORG_F"
NB_B=$(( REORG_NEWTIP - REORG_F ))   # number of B blocks (= depth+3)
core_cli_retry generatetoaddress "$NB_B" "$DEST_ADDR" >/dev/null || fail "Core generatetoaddress (chain B) failed"
CORE_BTIP_H=$(core_cli_retry getblockcount) || fail "Core getblockcount (B tip) failed"
[[ "$CORE_BTIP_H" == "$REORG_NEWTIP" ]] || fail "Core B tip height $CORE_BTIP_H != expected $REORG_NEWTIP"
CORE_BTIP=$(core_cli_retry getbestblockhash) || fail "Core getbestblockhash (B) failed"
B_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "Core getblockhash $REORG_H (chain B) failed"
[[ "$B_HASH_AT_HR" != "$A_HASH_AT_HR" ]] \
    || fail "reorg sanity: block at H_R=$REORG_H unchanged after reorg (A=B; not a real reorg)"
log "reorg: Core reorged to B, tip=$CORE_BTIP @h$CORE_BTIP_H; B@H_R=$B_HASH_AT_HR (differs from A@H_R)"

# (3) Mirror B to haskoin: submitblock B's blocks F+1..N+3 in order; haskoin must
#     reorg A->B (B carries strictly more work). CORE_COOKIE_FILE was set in §5.
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"
log "reorg: mirroring B's blocks $(( REORG_F + 1 ))..$REORG_NEWTIP to haskoin via submitblock"
B_RAW_LIST=$(python3 -c "
import sys, json, base64, urllib.request
cookie=open('$CORE_COOKIE_FILE').read().strip()
auth='Basic '+base64.b64encode(cookie.encode()).decode()
def rpc(method, params):
    body=json.dumps({'jsonrpc':'1.0','id':1,'method':method,'params':params}).encode()
    req=urllib.request.Request('http://127.0.0.1:$CORE_RPC/', data=body,
        headers={'Content-Type':'application/json','Authorization':auth})
    return json.load(urllib.request.urlopen(req, timeout=60))['result']
for h in range($(( REORG_F + 1 )), $REORG_NEWTIP+1):
    bh=rpc('getblockhash',[h])
    raw=rpc('getblock',[bh,0])
    print('%d %s'%(h, raw))
" 2>/dev/null) || fail "Core raw-block fetch for chain B failed"
GOT_B=$(echo "$B_RAW_LIST" | grep -c .)
[[ "$GOT_B" == "$NB_B" ]] || fail "fetched $GOT_B B-blocks from Core, expected $NB_B"
while read -r h RAW; do
    [[ -n "$RAW" ]] || continue
    kill -0 "$HK_PID" 2>/dev/null || fail "haskoin died during B replication at h=$h (see $HK_LOG)"
    SB=$(hk_rpc submitblock "[\"$RAW\"]")
    SB_ERR=$(jpy "$SB" "d.get('error')")
    if [[ -n "$SB_ERR" && "$SB_ERR" != "None" ]]; then log "reorg submitblock h=$h err='$SB_ERR'"; fi
done <<< "$B_RAW_LIST"

# Poll until haskoin tip == Core tip (B). If haskoin never adopts B, that itself
# is a reorg failure (could not switch to the more-work chain).
HK_REORG_OK=0
for _ in $(seq 1 30); do
    HK_BTIP=$(jpy "$(hk_rpc getbestblockhash '[]')" "d.get('result')")
    HK_BTIP_H=$(jpy "$(hk_rpc getblockcount '[]')" "d.get('result')")
    if [[ "$HK_BTIP" == "$CORE_BTIP" && "$HK_BTIP_H" == "$CORE_BTIP_H" ]]; then HK_REORG_OK=1; break; fi
    sleep 1
done
if [[ "$HK_REORG_OK" != "1" ]]; then
    REORG_OK="bad"; log "haskoin did not adopt chain B (impl tip=$HK_BTIP @h$HK_BTIP_H, Core B tip=$CORE_BTIP @h$CORE_BTIP_H)"
else
    log "reorg: haskoin adopted chain B (tip $HK_BTIP @h$HK_BTIP_H)"
    # (4) The reorg differential: gettxoutsetinfo muhash H_R on BOTH. Assert the
    #     impl serves B's per-height MuHash + bestblock, NOT A's stale value.
    RB_MUH=$(core_cli_retry gettxoutsetinfo muhash "$REORG_H") || fail "Core gettxoutsetinfo muhash $REORG_H (post-reorg) failed"
    RC_BEST=$(jpy   "$RB_MUH" "d['bestblock']")
    RC_MUHASH=$(jpy "$RB_MUH" "d.get('muhash','')")
    RC_HEIGHT=$(jpy "$RB_MUH" "d['height']")
    [[ "$RC_HEIGHT" == "$REORG_H" ]] || fail "Core post-reorg muhash@H_R height=$RC_HEIGHT != H_R=$REORG_H"
    [[ "$RC_BEST" == "$B_HASH_AT_HR" ]] || fail "Core post-reorg bestblock@H_R=$RC_BEST != B@H_R=$B_HASH_AT_HR (oracle wrong?)"

    HK_RMUH=$(hk_rpc gettxoutsetinfo "[\"muhash\", $REORG_H]")
    if echo "$HK_RMUH" | grep -q '"result"' && [[ "$(jpy "$HK_RMUH" "d.get('result')")" != "None" ]]; then
        RB_BEST=$(jpy   "$HK_RMUH" "d['result']['bestblock']")
        RB_MUHASH=$(jpy "$HK_RMUH" "d['result'].get('muhash','')")
        RB_HEIGHT=$(jpy "$HK_RMUH" "d['result']['height']")
        log "reorg @H_R=$REORG_H: core(best=$RC_BEST muhash=$RC_MUHASH) haskoin(height=$RB_HEIGHT best=$RB_BEST muhash=$RB_MUHASH)"
        if [[ "$RB_BEST" == "$A_HASH_AT_HR" ]]; then
            REORG_OK="bad"; log "reorg DESYNC: haskoin bestblock@H_R=$RB_BEST is A's stale block (B@H_R=$B_HASH_AT_HR) — index did not reconnect B"
        fi
        [[ "$RB_HEIGHT" == "$REORG_H" ]] || { REORG_OK="bad"; log "reorg: haskoin height@H_R=$RB_HEIGHT != H_R=$REORG_H"; }
        [[ "$RB_BEST" == "$B_HASH_AT_HR" && "$RB_BEST" == "$RC_BEST" ]] \
            || { REORG_OK="bad"; log "reorg: bestblock@H_R mismatch (haskoin=$RB_BEST want B@H_R=$B_HASH_AT_HR core=$RC_BEST)"; }
        [[ -n "$RB_MUHASH" && "$RB_MUHASH" == "$RC_MUHASH" ]] \
            || { REORG_OK="bad"; log "reorg: muhash@H_R MISMATCH (haskoin=$RB_MUHASH core=$RC_MUHASH) — impl served stale chain-A index after reorg"; }
    else
        RR_EC=$(jpy "$HK_RMUH" "d['error']['code']")
        RR_EM=$(jpy "$HK_RMUH" "d['error']['message']")
        REORG_OK="bad"; log "reorg: haskoin gettxoutsetinfo muhash $REORG_H errored after reorg: code=$RR_EC msg='$RR_EM'"
    fi
fi

[[ "$REORG_OK" == "ok" ]] || fail "reorg-safety gate failed at H_R=$REORG_H (impl muhash/bestblock did not follow reorg from A to B; coinstatsindex reconnects on connect+disconnect but NOT on reconnect of the new chain)"
log "REORG OK @H_R=$REORG_H: haskoin muhash+bestblock match Core's B-chain values after reorg"

# ── 10. Reached only if every at-height gate AND the reorg gate passed. ────
log "PASS: haskoin gettxoutsetinfo AS-OF historical height + reorg-safety matches Core"
pass
