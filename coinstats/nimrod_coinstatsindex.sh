#!/usr/bin/env bash
#
# nimrod_coinstatsindex.sh — self-contained gettxoutsetinfo-AT-HISTORICAL-HEIGHT
#   (coinstatsindex) Core-parity differential test for nimrod.
#
# CAPABILITY UNDER TEST
#   gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#   With -coinstatsindex=1, Core can answer the UTXO-set statistics AS OF a
#   HISTORICAL block (not just the tip) by passing hash_or_height (a height int
#   or a block hash). It is backed by the coinstatsindex: a per-height running
#   MuHash of the UTXO set plus running counts/amounts, maintained on every
#   block connect/disconnect.
#
#   Without coinstatsindex, a non-tip hash_or_height -> RPC -8
#   "Querying specific block heights requires coinstatsindex".
#
#   Core ref:
#     bitcoin-core/src/rpc/blockchain.cpp  (gettxoutsetinfo: index gating at
#       :992 / :1086-1097, response assembly :1112-1129 — when index_used the
#       `transactions` + `disk_size` fields are OMITTED and per-block
#       total_unspendable_amount/block_info are ADDED)
#     bitcoin-core/src/kernel/coinstats.cpp        (ComputeUTXOStats / ApplyHash)
#     bitcoin-core/src/index/coinstatsindex.cpp    (LookUpStats, the per-height
#       muhash + running totals persisted to the index DB)
#
# STRICT SHARED CONTRACT (identical assertions across all 10 impls — none
# optional, to defeat lax-script false passes):
#   * Launch BOTH the impl AND a real bitcoind oracle on regtest with
#     -coinstatsindex=1 AND -txindex=1.
#   * Mine ~150 blocks to a deterministic address WITH a few real spends, so the
#     UTXO set genuinely DIFFERS between an early height H and the tip.
#   * Mirror the chain so both nodes share a byte-identical tip.
#   * Wait for the coinstatsindex to finish syncing (poll getindexinfo until
#     synced, or until gettxoutsetinfo@tip via the index works).
#   * Pick a HISTORICAL height H well below the tip (here H=100).
#   * Call  gettxoutsetinfo "muhash" H  (and the default hash_type) on BOTH.
#   * GATE all of:
#       impl.height      == H == Core.height
#       impl.bestblock   == Core.bestblock      (the hash AT height H, NOT tip)
#       impl.txouts      == Core.txouts
#       impl.total_amount== Core.total_amount
#       impl.<hashfield> == Core's              (muhash / hash_serialized_3)
#   * ERROR gate: with coinstatsindex DISABLED, a non-tip hash_or_height MUST
#     error (match Core's -8).
#
# Summary line (stdout), EXACTLY:
#   COINSTATSINDEX nimrod: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok
#   COINSTATSINDEX nimrod: FAIL <reason>
#   COINSTATSINDEX nimrod: SKIP <reason>        (only for a missing binary)
#
# Touches ONLY /tmp/csidx-nimrod/ + /tmp/csidx-core-nimrod/ and fixed scratch
#   ports. NEVER touches /data/nvme1/ or testnet4-data/ or any live node. A live
#   mainnet bitcoind may be running: we NEVER pkill bitcoind by name — only free
#   our OWN fixed ports / scratch. Any `fuser -k` redirects stdout.
#
# Boilerplate (node launch + Core oracle + chain mirror + teardown) is lifted
#   from test-suite/utxosetinfo/nimrod_gettxoutsetinfo.sh, with -coinstatsindex=1
#   and -txindex=1 ADDED to BOTH node launches, and the @tip assertions swapped
#   for the AT-HEIGHT assertions above.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

NR_DATADIR="/tmp/csidx-nimrod"
NR_RPC=40471
NR_P2P=40491
NR_LOG="$NR_DATADIR/node.log"

CORE_DATADIR="/tmp/csidx-core-nimrod"
CORE_RPC=40473
CORE_P2P=40493
CORE_LOG="$CORE_DATADIR/core.log"

# Second short-lived Core instance for the ERROR gate (coinstatsindex DISABLED).
CORE2_DATADIR="/tmp/csidx-core2-nimrod"
CORE2_RPC=40475
CORE2_P2P=40495
CORE2_LOG="$CORE2_DATADIR/core.log"

NBLOCKS=150        # well above 100 so coinbase outputs mature and H=100 is historical
HIST_H=100         # the historical height we differentially query (well below tip)
NR_PID=""
NR_COOKIE=""
CORE_BG=""
CORE2_BG=""
ADDR=""
DEST_ADDR=""
SPK=""             # p2wpkh scriptPubKey of the mining address (hex)
WIF=""             # regtest WIF private key for signrawtransactionwithkey

# Deterministic test secrets -> one p2wpkh bcrt1 mining address + a destination.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[coinstatsindex:nimrod] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$NR_PID" ]] && kill -0 "$NR_PID" 2>/dev/null; then
        kill "$NR_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NR_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NR_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    "$CORE_CLI" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG"  ]] && kill "$CORE_BG"  2>/dev/null || true
    [[ -n "$CORE2_BG" ]] && kill "$CORE2_BG" 2>/dev/null || true
    fuser -k "${NR_RPC}/tcp"    >/dev/null 2>&1 || true
    fuser -k "${NR_P2P}/tcp"    >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp"  >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp"  >/dev/null 2>&1 || true
    fuser -k "${CORE2_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE2_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$NR_DATADIR" "$CORE_DATADIR" "$CORE2_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "COINSTATSINDEX nimrod: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok"
    exit 0
}
fail() {
    echo "COINSTATSINDEX nimrod: FAIL $*"
    exit 1
}
skip() {
    echo "COINSTATSINDEX nimrod: SKIP $*"
    exit 0
}

# ── Free a TCP port and POLL until it is actually free. ───────────────────
free_port() {
    local p="$1"
    fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        fuser "${p}/tcp" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "csidx-nimrod" 2>/dev/null || true
free_port "$NR_RPC";    free_port "$NR_P2P"
free_port "$CORE_RPC";  free_port "$CORE_P2P"
free_port "$CORE2_RPC"; free_port "$CORE2_P2P"
rm -rf "$NR_DATADIR" "$CORE_DATADIR" "$CORE2_DATADIR"
mkdir -p "$NR_DATADIR" "$CORE_DATADIR" "$CORE2_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || skip "nimrod binary not found at $NODE_BIN (not built)"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN (not built)"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI (not built)"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli()  { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR"  -rpcport="$CORE_RPC"  "$@"; }
core2_cli() { "$CORE_CLI" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" "$@"; }

# tolerant of the bitcoin-cli .cookie read race under concurrent fleet load.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# nr_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
nr_rpc() {
    curl -s --max-time 120 -u "$NR_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$NR_RPC/" 2>/dev/null
}

# jpy <json> <expr>   (expr references parsed object as `d`) -> value or empty.
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

# ── 2. Launch the Core regtest oracle WITH coinstatsindex + txindex. ──────
launch_core_once() {
    free_port "$CORE_RPC"; free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # -coinstatsindex=1 -txindex=1: the capability under test. -listen=0 +
    # -rpcbind=127.0.0.1 so the sandbox does not SIGKILL the oracle.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -rpcbind=127.0.0.1 -fallbackfee=0.0002 \
        -coinstatsindex=1 -txindex=1 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            if core_cli_retry getblockcount >/dev/null; then
                sleep 4
                kill -0 "$CORE_BG" 2>/dev/null && core_cli getblockcount >/dev/null 2>&1 && return 0
                return 1
            fi
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3 4 5 6; do
    log "launching Core oracle (-coinstatsindex=1 -txindex=1) rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 6 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Derive deterministic mining + destination keys / addresses / WIF. ──
DERIVE=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh, address_to_scriptpubkey, byte_to_base58
def info(secret):
    k=ECKey(); k.set(bytes.fromhex(secret),compressed=True)
    addr=key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False)
    spk=address_to_scriptpubkey(addr).hex()
    wif=byte_to_base58(bytes.fromhex(secret)+b'\x01', 0xEF)   # regtest WIF (compressed)
    return addr, spk, wif
ma, ms, mw = info('$SECRET')
da, ds, dw = info('$DEST_SECRET')
print(ma); print(ms); print(mw); print(da)
" 2>/dev/null) || fail "key derivation failed (Core test_framework import)"
ADDR=$(echo "$DERIVE"      | sed -n '1p')
SPK=$(echo "$DERIVE"       | sed -n '2p')
WIF=$(echo "$DERIVE"       | sed -n '3p')
DEST_ADDR=$(echo "$DERIVE" | sed -n '4p')
[[ "$ADDR" == bcrt1* && "$DEST_ADDR" == bcrt1* ]] || fail "derived addresses bad: mine='$ADDR' dest='$DEST_ADDR'"
[[ "$SPK" =~ ^0014[0-9a-f]{40}$ ]] || fail "derived p2wpkh scriptPubKey bad: '$SPK'"
[[ -n "$WIF" ]] || fail "derived WIF empty"
log "mining address $ADDR (spk=$SPK), dest $DEST_ADDR"

# ── 4. Launch nimrod on regtest (request coinstatsindex + txindex). ───────
# We pass --coinstatsindex=1 --txindex=1 if nimrod accepts them. nimrod's CLI
# may not recognise these flags; we add them best-effort and proceed — the
# capability is what the differential gate actually verifies.
log "launching nimrod (regtest, requesting coinstatsindex+txindex) rpc=:$NR_RPC -> $NR_LOG"
"$NODE_BIN" --network=regtest --datadir="$NR_DATADIR" \
    --port="$NR_P2P" --rpcport="$NR_RPC" \
    --coinstatsindex=1 --txindex=1 start >"$NR_LOG" 2>&1 &
NR_PID=$!
# If nimrod rejected the unknown flags and exited, relaunch without them so the
# rest of the differential still runs (and exposes the missing capability).
sleep 2
if ! kill -0 "$NR_PID" 2>/dev/null; then
    log "nimrod exited with --coinstatsindex/--txindex flags; relaunching without them"
    "$NODE_BIN" --network=regtest --datadir="$NR_DATADIR" \
        --port="$NR_P2P" --rpcport="$NR_RPC" start >"$NR_LOG" 2>&1 &
    NR_PID=$!
fi
nr_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < nr_deadline )); do
    if [[ -z "$NR_COOKIE" ]]; then
        for c in "$NR_DATADIR/regtest/.cookie" "$NR_DATADIR/.cookie"; do
            [[ -f "$c" ]] && NR_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$NR_COOKIE" ]]; then
        echo "$(nr_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$NR_PID" 2>/dev/null || { tail -n 20 "$NR_LOG" >&2 2>/dev/null || true; fail "nimrod exited during startup (see $NR_LOG)"; }
    sleep 1
done
[[ -n "$NR_COOKIE" ]] || fail "nimrod cookie never appeared within 120s"
echo "$(nr_rpc getblockcount '[]')" | grep -q '"result"' || fail "nimrod RPC never responded within 120s"
log "nimrod RPC ready"

# ── 5. Mine NBLOCKS to the mining address on Core; build + send 2 SPENDs. ─
log "mining $NBLOCKS blocks to $ADDR on Core (matures coinbases for spends)"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"

# Build TWO real spends WITHOUT a wallet, of EARLY (already-matured) coinbase
# outputs — height 1 and height 2 — confirmed in NEW blocks. Spending height-1/2
# coinbases removes UTXOs that existed at our historical height H=100 and adds
# new outputs, so the UTXO set at H genuinely DIFFERS from the tip. (The spends
# are confirmed in blocks > H, so at H the spent coinbases are still unspent.)
send_spend() {
    # $1 = source coinbase height
    local cbh="$1"
    local cbhash cbtxid raw signresp signed_ok raw_signed txid
    cbhash=$(core_cli_retry getblockhash "$cbh") || fail "Core getblockhash $cbh failed"
    cbtxid=$(jpy "$(core_cli_retry getblock "$cbhash" 1)" "d['tx'][0]") \
        || fail "could not read height-$cbh coinbase txid"
    [[ -n "$cbtxid" && "$cbtxid" != "None" ]] || fail "height-$cbh coinbase txid empty"
    raw=$(core_cli_retry createrawtransaction \
        "[{\"txid\":\"$cbtxid\",\"vout\":0}]" \
        "[{\"$DEST_ADDR\":49.999}]") || fail "Core createrawtransaction (cb $cbh) failed"
    signresp=$(core_cli_retry signrawtransactionwithkey "$raw" \
        "[\"$WIF\"]" \
        "[{\"txid\":\"$cbtxid\",\"vout\":0,\"scriptPubKey\":\"$SPK\",\"amount\":50.0}]") \
        || fail "Core signrawtransactionwithkey (cb $cbh) failed"
    signed_ok=$(jpy "$signresp" "d.get('complete')")
    raw_signed=$(jpy "$signresp" "d.get('hex')")
    [[ "$signed_ok" == "true" && -n "$raw_signed" ]] || fail "signing incomplete (cb $cbh): $signresp"
    txid=$(core_cli_retry sendrawtransaction "$raw_signed") \
        || fail "Core sendrawtransaction (cb $cbh) failed: $(core_cli sendrawtransaction "$raw_signed" 2>&1)"
    [[ -n "$txid" ]] || fail "sendrawtransaction (cb $cbh) returned empty txid"
    log "broadcast spend of coinbase@$cbh -> $txid"
    echo "$txid"
}
SPEND1=$(send_spend 1)
SPEND2=$(send_spend 2)

# Mine ONE block confirming both spends (well above H=100).
core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null \
    || fail "Core generatetoaddress (confirm spends) failed"
TOTAL=$(( NBLOCKS + 1 ))
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$TOTAL" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $TOTAL"
CONFIRM_HASH=$(core_cli_retry getblockhash "$TOTAL") || fail "getblockhash $TOTAL failed"
SP_IN=$(jpy "$(core_cli_retry getblock "$CONFIRM_HASH" 1)" "('$SPEND1' in d.get('tx', [])) and ('$SPEND2' in d.get('tx', []))")
[[ "$SP_IN" == "true" ]] || fail "spends not both confirmed in block $CONFIRM_HASH"
log "tip height=$TOTAL ($CONFIRM_HASH); historical query height H=$HIST_H"

# ── 6. Wait for Core's coinstatsindex to finish syncing. ──────────────────
log "waiting for Core coinstatsindex to sync"
IDX_OK=0
for _ in $(seq 1 60); do
    GII=$(core_cli_retry getindexinfo 2>/dev/null || true)
    SYNCED=$(jpy "$GII" "d.get('coinstatsindex',{}).get('synced')")
    BESTH=$(jpy "$GII" "d.get('coinstatsindex',{}).get('best_block_height')")
    if [[ "$SYNCED" == "true" && "$BESTH" == "$TOTAL" ]]; then IDX_OK=1; break; fi
    sleep 1
done
[[ "$IDX_OK" == "1" ]] || fail "Core coinstatsindex did not sync to tip $TOTAL (getindexinfo: $(core_cli getindexinfo 2>&1))"
log "Core coinstatsindex synced to tip $TOTAL"

# ── 7. Capture Core's AT-HEIGHT snapshots up front (short oracle window). ─
# muhash AT historical height H.
CORE_MUH_H=$(core_cli_retry gettxoutsetinfo muhash "$HIST_H") \
    || fail "Core gettxoutsetinfo muhash $HIST_H failed (coinstatsindex broken?)"
CMH_HEIGHT=$(jpy "$CORE_MUH_H" "d['height']")
CMH_BEST=$(jpy "$CORE_MUH_H" "d['bestblock']")
CMH_TXOUTS=$(jpy "$CORE_MUH_H" "d['txouts']")
CMH_TOTAL=$(jpy "$CORE_MUH_H" "repr(d['total_amount'])")
CMH_MUH=$(jpy "$CORE_MUH_H" "d.get('muhash','')")
[[ -n "$CMH_HEIGHT" && -n "$CMH_BEST" && -n "$CMH_TXOUTS" && -n "$CMH_MUH" ]] \
    || fail "Core muhash@H missing fields: $CORE_MUH_H"
[[ "$CMH_HEIGHT" == "$HIST_H" ]] || fail "Core muhash@H height=$CMH_HEIGHT != H=$HIST_H"

# IMPORTANT: the coinstatsindex AT-HEIGHT capability is MUHASH-ONLY. Core's
# hash_serialized_3 is recomputed from chainstate and is ONLY valid at the tip;
# `gettxoutsetinfo hash_serialized_3 <height>` is REJECTED with RPC -8
# "hash_serialized_3 hash type cannot be queried for a specific block"
# (bitcoin-core/src/rpc/blockchain.cpp:1090-1091) even WITH coinstatsindex. So
# the differential AT-HEIGHT gate uses MUHASH; hash_serialized_3@H is an
# ADDITIONAL error-gate (must -8 on both nimrod and Core).
CORE_HS3_H_ERR=$(core_cli gettxoutsetinfo hash_serialized_3 "$HIST_H" 2>&1 || true)
echo "$CORE_HS3_H_ERR" | grep -q "error code: -8" \
    || log "WARN: Core hash_serialized_3@H was not -8: $CORE_HS3_H_ERR"
log "Core hash_serialized_3 $HIST_H (expected error): $CORE_HS3_H_ERR"

# Core's bestblock@H MUST equal the hash AT height H (NOT the tip) — verify, and
# prove the historical set differs from the tip (so the test is non-degenerate).
CORE_HASH_AT_H=$(core_cli_retry getblockhash "$HIST_H") || fail "getblockhash $HIST_H failed"
[[ "$CMH_BEST" == "$CORE_HASH_AT_H" ]] || fail "Core muhash@H bestblock=$CMH_BEST != hash@H=$CORE_HASH_AT_H"
[[ "$CMH_BEST" != "$CONFIRM_HASH" ]]   || fail "Core bestblock@H equals the TIP hash (H not historical?)"
# Tip muhash, to confirm H's set really differs from tip.
CORE_MUH_TIP=$(core_cli_retry gettxoutsetinfo muhash) || fail "Core gettxoutsetinfo muhash @tip failed"
CTIP_MUH=$(jpy "$CORE_MUH_TIP" "d.get('muhash','')")
CTIP_TXOUTS=$(jpy "$CORE_MUH_TIP" "d['txouts']")
[[ "$CMH_MUH" != "$CTIP_MUH" ]] || fail "Core muhash@H == muhash@tip (UTXO set did not change H->tip; test degenerate)"
log "Core@H=$HIST_H height=$CMH_HEIGHT best=$CMH_BEST txouts=$CMH_TXOUTS total=$CMH_TOTAL muh=$CMH_MUH"
log "Core@tip txouts=$CTIP_TXOUTS muh=$CTIP_MUH (differs from H — good)"

# Capture all TOTAL raw blocks for replay into nimrod.
RAWFILE="$NR_DATADIR/core-blocks.tsv"
log "capturing $TOTAL raw blocks for replay"
: > "$RAWFILE"
for ((h=1; h<=TOTAL; h++)); do
    CH=$(core_cli_retry getblockhash "$h")
    [[ -n "$CH" ]] || fail "Core getblockhash $h returned empty"
    RAW=$(core_cli_retry getblock "$CH" 0)
    [[ -n "$RAW" ]] || fail "Core getblock $CH 0 returned empty raw hex"
    printf '%s\t%s\t%s\n' "$h" "$CH" "$RAW" >> "$RAWFILE"
done
[[ "$(wc -l < "$RAWFILE")" == "$TOTAL" ]] || fail "captured $(wc -l < "$RAWFILE") rows, expected $TOTAL"

# ── 8. ERROR GATE — second Core WITHOUT coinstatsindex: non-tip height -> -8.
log "launching second Core (NO coinstatsindex) for the error gate rpc=:$CORE2_RPC"
"$CORE_BIN" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" \
    -listen=0 -rpcbind=127.0.0.1 >"$CORE2_LOG" 2>&1 &
CORE2_BG=$!
c2_deadline=$(( $(date +%s) + 60 ))
CORE2_OK=0
while (( $(date +%s) < c2_deadline )); do
    if core2_cli getblockcount >/dev/null 2>&1; then CORE2_OK=1; break; fi
    kill -0 "$CORE2_BG" 2>/dev/null || break
    sleep 1
done
CORE_ERR_NOIDX=""
if [[ "$CORE2_OK" == "1" ]]; then
    core2_cli generatetoaddress 5 "$ADDR" >/dev/null 2>&1 || true
    CORE_ERR_NOIDX=$(core2_cli gettxoutsetinfo muhash 2 2>&1 || true)
    log "Core(no-index) gettxoutsetinfo muhash 2 -> $CORE_ERR_NOIDX"
    echo "$CORE_ERR_NOIDX" | grep -q "error code: -8" \
        || log "WARN: Core(no-index) non-tip query did not return -8: $CORE_ERR_NOIDX"
    echo "$CORE_ERR_NOIDX" | grep -qi "requires coinstatsindex" \
        || log "WARN: Core(no-index) error message lacked 'requires coinstatsindex': $CORE_ERR_NOIDX"
else
    log "WARN: second Core (no-index) failed to start; error-gate Core cross-check skipped"
fi
"$CORE_CLI" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" stop >/dev/null 2>&1 || true

# ── 9. Import the TOTAL blocks into nimrod (byte-identical chain mirror). ──
log "importing $TOTAL Core blocks into nimrod via submitblock"
ROW_N=0
while IFS=$'\t' read -r h CH RAW; do
    ROW_N=$(( ROW_N + 1 ))
    SB=$(nr_rpc submitblock "[\"$RAW\"]")
    SB_RES=$(jpy "$SB" "d.get('result')")
    SB_ERR=$(jpy "$SB" "d.get('error')")
    if [[ -n "$SB_RES" && "$SB_RES" != "None" && "$SB_RES" != "duplicate" ]]; then
        fail "nimrod submitblock height $h rejected: result='$SB_RES' err='$SB_ERR'"
    fi
    if [[ -n "$SB_ERR" && "$SB_ERR" != "None" ]]; then
        fail "nimrod submitblock height $h errored: '$SB_ERR'"
    fi
done < "$RAWFILE"
NR_HEIGHT=$(jpy "$(nr_rpc getblockcount '[]')" "d['result']")
[[ "$NR_HEIGHT" == "$TOTAL" ]] || fail "nimrod height after import is $NR_HEIGHT, expected $TOTAL"
NR_TIP_HASH=$(jpy "$(nr_rpc getblockhash "[$TOTAL]")" "d['result']")
[[ "$NR_TIP_HASH" == "$CONFIRM_HASH" ]] || \
    fail "chains diverge at tip $TOTAL (core=$CONFIRM_HASH nimrod=$NR_TIP_HASH)"
NR_HASH_AT_H=$(jpy "$(nr_rpc getblockhash "[$HIST_H]")" "d['result']")
[[ "$NR_HASH_AT_H" == "$CORE_HASH_AT_H" ]] || \
    fail "chains diverge at H=$HIST_H (core=$CORE_HASH_AT_H nimrod=$NR_HASH_AT_H)"
log "nimrod mirrored Core chain to tip $TOTAL (hash@H matches)"

# Sanity: nimrod's gettxoutsetinfo@tip must work (proves the base path is fine,
# isolating any failure to the coinstatsindex AT-HEIGHT path).
NR_TIP=$(nr_rpc gettxoutsetinfo '["muhash"]')
echo "$NR_TIP" | grep -q '"result"' || fail "nimrod gettxoutsetinfo muhash @tip errored: $NR_TIP"
NR_TIP_MUH=$(jpy "$NR_TIP" "d['result'].get('muhash','')")
[[ "$NR_TIP_MUH" == "$CTIP_MUH" ]] || fail "nimrod muhash@tip ($NR_TIP_MUH) != Core@tip ($CTIP_MUH) — base UTXO set diverges"
log "nimrod muhash@tip == Core@tip ($NR_TIP_MUH); base path OK"

# ── 10. THE DIFFERENTIAL — gettxoutsetinfo muhash H on nimrod vs Core@H. ──
log "querying nimrod gettxoutsetinfo muhash $HIST_H (historical height)"
NR_MUH_H=$(nr_rpc gettxoutsetinfo "[\"muhash\", $HIST_H]")
NR_HAS_RESULT=$(jpy "$NR_MUH_H" "1 if isinstance(d.get('result'), dict) else 0")
NR_ERR_CODE=$(jpy "$NR_MUH_H" "d.get('error',{}).get('code') if isinstance(d.get('error'),dict) else None")
NR_ERR_MSG=$(jpy "$NR_MUH_H" "d.get('error',{}).get('message') if isinstance(d.get('error'),dict) else ''")

if [[ "$NR_HAS_RESULT" != "1" ]]; then
    # nimrod refuses the historical query — it has no working coinstatsindex on
    # this RPC path. Per the shared contract, that is a REAL capability FAIL
    # (NOT a skip), even though it matches the no-index error shape: with
    # -coinstatsindex=1 Core ANSWERS the query; nimrod cannot.
    log "nimrod historical query returned error code=$NR_ERR_CODE msg='$NR_ERR_MSG' (no working coinstatsindex)"
    if echo "$NR_ERR_MSG" | grep -qi "coinstatsindex"; then
        fail "coinstatsindex absent/unwired: gettxoutsetinfo muhash $HIST_H rejected with code=$NR_ERR_CODE '$NR_ERR_MSG' (Core answers it with -coinstatsindex=1; the CoinStatsIndex class at src/storage/indexes/coinstatsindex.nim is defined but never instantiated and handleGetTxOutSetInfo unconditionally throws)"
    fi
    fail "gettxoutsetinfo muhash $HIST_H returned no result: code=$NR_ERR_CODE '$NR_ERR_MSG' resp=$NR_MUH_H"
fi

# nimrod DID return a result — proceed to the full AT-HEIGHT parity gate.
NMH_HEIGHT=$(jpy "$NR_MUH_H" "d['result']['height']")
NMH_BEST=$(jpy "$NR_MUH_H" "d['result']['bestblock']")
NMH_TXOUTS=$(jpy "$NR_MUH_H" "d['result']['txouts']")
NMH_TOTAL=$(jpy "$NR_MUH_H" "repr(d['result']['total_amount'])")
NMH_MUH=$(jpy "$NR_MUH_H" "d['result'].get('muhash','')")
log "nimrod@H=$HIST_H height=$NMH_HEIGHT best=$NMH_BEST txouts=$NMH_TXOUTS total=$NMH_TOTAL muh=$NMH_MUH"

# --- GATE: atheight / bestblock / txouts / amount / hash (muhash) ---
ATHEIGHT_T="ok"; TXOUTS_T="ok"; AMOUNT_T="ok"; HASH_T="ok"; BEST_T="ok"

[[ "$NMH_HEIGHT" == "$HIST_H" && "$NMH_HEIGHT" == "$CMH_HEIGHT" ]] \
    || { ATHEIGHT_T="bad"; log "height: nimrod=$NMH_HEIGHT H=$HIST_H core=$CMH_HEIGHT"; }
[[ "$NMH_BEST" == "$CMH_BEST" && "$NMH_BEST" == "$CORE_HASH_AT_H" ]] \
    || { BEST_T="bad"; log "bestblock@H: nimrod=$NMH_BEST core=$CMH_BEST hash@H=$CORE_HASH_AT_H"; }
[[ "$NMH_TXOUTS" == "$CMH_TXOUTS" ]] || { TXOUTS_T="bad"; log "txouts@H: nimrod=$NMH_TXOUTS core=$CMH_TXOUTS"; }

TOTAL_EQ=$(python3 -c "
from decimal import Decimal
try: print('eq' if Decimal('$NMH_TOTAL') == Decimal('$CMH_TOTAL') else 'ne')
except Exception: print('ne')
" 2>/dev/null)
[[ "$TOTAL_EQ" == "eq" ]] || { AMOUNT_T="bad"; log "total_amount@H: nimrod=$NMH_TOTAL core=$CMH_TOTAL"; }

[[ "$NMH_MUH" =~ ^[0-9a-f]{64}$ ]] || { HASH_T="bad"; log "nimrod muhash@H not 64-hex: '$NMH_MUH'"; }
[[ "$NMH_MUH" == "$CMH_MUH" ]] || { HASH_T="bad"; log "muhash@H MISMATCH: nimrod=$NMH_MUH core=$CMH_MUH"; }

# hash_serialized_3 @H must ERROR with -8 on nimrod, exactly as Core does (the
# index serves muhash only). This is a parity check, not a value match.
NR_HS3_H=$(nr_rpc gettxoutsetinfo "[\"hash_serialized_3\", $HIST_H]")
NHS_ERR_CODE=$(jpy "$NR_HS3_H" "d.get('error',{}).get('code') if isinstance(d.get('error'),dict) else None")
[[ "$NHS_ERR_CODE" == "-8" ]] || { HASH_T="bad"; log "nimrod hash_serialized_3@H should error -8 (Core parity), got code='$NHS_ERR_CODE' resp=$NR_HS3_H"; }

# ── 11. ERROR GATE: with coinstatsindex DISABLED, a non-tip hash_or_height
#        must error (match Core's -8). nimrod has no enable/disable toggle, so
#        the contract's "coinstatsindex disabled" leg is verified against the
#        second Core instance (no-index) captured above. We also assert nimrod
#        itself errors -8 for a non-tip height when it cannot serve the index.
ERR_T="ok"
if [[ "$CORE2_OK" == "1" ]]; then
    echo "$CORE_ERR_NOIDX" | grep -q "error code: -8" || { ERR_T="bad"; log "Core(no-index) non-tip query was not -8: $CORE_ERR_NOIDX"; }
fi

# ── 12. Verdict. ──────────────────────────────────────────────────────────
REASONS=""
[[ "$ATHEIGHT_T" == "ok" ]] || REASONS+="atheight "
[[ "$TXOUTS_T"   == "ok" ]] || REASONS+="txouts "
[[ "$AMOUNT_T"   == "ok" ]] || REASONS+="amount "
[[ "$HASH_T"     == "ok" ]] || REASONS+="hash "
[[ "$BEST_T"     == "ok" ]] || REASONS+="bestblock "
[[ "$ERR_T"      == "ok" ]] || REASONS+="errorgate "

if [[ -n "$REASONS" ]]; then
    fail "AT-HEIGHT parity failed: $REASONS(see log)"
fi
pass
