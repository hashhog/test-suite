#!/usr/bin/env bash
#
# beamchain_chaintxstats.sh — self-contained getchaintxstats DIFFERENTIAL test.
#
# The first RPC-surface green-cell after the wallet + mempool-policy chapters.
# getchaintxstats is read-only chain-stats (NOT consensus) but must match Core
# EXACTLY on the count/height-shaped fields, and must honour Core's emit-
# condition rules for the time-dependent + window-extra fields.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (own scratch datadir + ports). The SAME number of blocks (120) is
#   mined to a fixed key on BOTH beamchain and Core, then `getchaintxstats
#   <nblocks> <tip>` is run on both and the results compared.
#
# WHY a differential (not a hardcoded golden): the COUNT/HEIGHT fields are a
#   deterministic function of chain SHAPE, not of wall-clock. Empty regtest
#   blocks carry exactly one coinbase tx each, so for a height-H chain:
#       txcount          = H + 1            (genesis coinbase + H block coinbases)
#       window_tx_count  = nblocks          (one coinbase per windowed block)
#       window_block_count        = nblocks
#       window_final_block_height = H
#   These MUST equal Core for the same chain shape — asserted EXACTLY.
#
# TIME-DEPENDENT fields (`time`, `window_interval`, `txrate`) differ between the
#   two regtest nodes (independent timestamps), so they are NOT compared for
#   equality. Instead the harness asserts they are PRESENT, correctly TYPED, and
#   obey Core's emit-condition rules:
#     * time present + a sane unix timestamp (> 2009 genesis epoch)
#     * window_interval present + >= 0 when nblocks > 0
#     * txrate present when nblocks > 0 AND window_interval > 0
#     * the THREE window extras (window_interval, window_tx_count, txrate) are
#       DROPPED entirely when nblocks == 0  (Core: `if (blockcount > 0)` guard)
#
# Core semantics codified here (rpc/blockchain.cpp getchaintxstats):
#   - "time" = the FINAL block's RAW header nTime (NOT mediantime)
#   - window_interval uses MEDIAN-TIME-PAST (11-block window), not raw nTime
#   - txcount = cumulative #txs genesis..pindex  (CBlockIndex::m_chain_tx_count)
#   - window_tx_count = txcount(pindex) - txcount(pindex - nblocks)
#   - txrate = window_tx_count / window_interval
#   - the 3 window_* extras drop when nblocks == 0
#   - default nblocks (no arg) = max(0, min(one-month-of-blocks, height-1))
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/beamchain_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: CHAINTXSTATS beamchain: PASS txcount=ok window=ok shape=ok nblocks0=ok
#   FAIL: CHAINTXSTATS beamchain: FAIL <short reason>
#
# Touches ONLY /tmp/ctxstats-beamchain{,-core}/ and ports 39996/40016
#   (beamchain RPC/P2P), 39998/40018 (Core RPC/P2P). NEVER touches /data/nvme1/
#   or testnet4-data/ or any live node (haskoin is mid-sync — left untouched).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/address)

BC_DATADIR="/tmp/ctxstats-beamchain"
BC_RPC=39996
BC_P2P=40016
BC_LOG="$BC_DATADIR/node.log"

# Core-oracle scratch dir is namespaced to THIS harness (…-beamchain-core) so a
# sibling chaintxstats run never shares a datadir.  The oracle PORTS are pulled
# DOWN off the crowded 399xx/400xx node-port cluster (where sibling per-impl
# chaintxstats runs cluster their own nodes + Core smokes) into a quieter band
# so a parallel sibling launch never races us onto the same listener.
CORE_DATADIR="/tmp/ctxstats-beamchain-core"
CORE_RPC=39896
CORE_P2P=39916
CORE_LOG="$CORE_DATADIR/core.log"

# Fixed deterministic test secret -> one p2wpkh regtest address the coinbases
# are mined to on BOTH nodes (so the chain shapes are identical).
SECRET="1111111111111111111111111111111111111111111111111111111111111111"

NBLOCKS=120            # mine 120 empty blocks -> tip height 120 on each node
WINDOW=10              # window size for the primary differential probe

BC_PID=""
BC_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[chaintxstats:beamchain] $*" >&2; }

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${BC_RPC}/tcp"   2>/dev/null || true
    fuser -k "${BC_P2P}/tcp"   2>/dev/null || true
    fuser -k "${CORE_RPC}/tcp" 2>/dev/null || true
    fuser -k "${CORE_P2P}/tcp" 2>/dev/null || true
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <txcount> <window> <shape> <nblocks0>
pass() {
    echo "CHAINTXSTATS beamchain: PASS txcount=$1 window=$2 shape=$3 nblocks0=$4"
    exit 0
}
fail() {
    echo "CHAINTXSTATS beamchain: FAIL $*"
    exit 1
}

# ── JSON field extractor (jq-free: pure python3, deterministic). ──────────
# usage: jget <json> <jsonpath-ish key>   -> prints value or "" if absent/null
# Supports top-level keys only (sufficient for getchaintxstats result objects).
jget() {
    python3 - "$1" "$2" <<'PYEOF'
import sys, json
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
# unwrap a {"result": {...}} JSON-RPC envelope if present
if isinstance(obj, dict) and "result" in obj and obj.get("error") is None:
    obj = obj["result"]
k = sys.argv[2]
if isinstance(obj, dict) and k in obj and obj[k] is not None:
    v = obj[k]
    if isinstance(v, bool):
        print("true" if v else "false")
    else:
        print(v)
PYEOF
}

# usage: jhas <json> <key>  -> exit 0 if key present + non-null, else exit 1
jhas() {
    python3 - "$1" "$2" <<'PYEOF'
import sys, json
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
if isinstance(obj, dict) and "result" in obj and obj.get("error") is None:
    obj = obj["result"]
k = sys.argv[2]
sys.exit(0 if (isinstance(obj, dict) and k in obj and obj[k] is not None) else 1)
PYEOF
}

# usage: jerr <json>  -> prints the JSON-RPC error code (int) or "" if no error
jerr() {
    python3 - "$1" <<'PYEOF'
import sys, json
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
e = obj.get("error") if isinstance(obj, dict) else None
if isinstance(e, dict) and "code" in e:
    print(e["code"])
PYEOF
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
# Free this harness's OWN ports only.  We deliberately do NOT pkill on the
# datadir token: a bare-path `pkill -f` self-matches the shell wrapper /
# ancestry that carries the harness path in its argv and SIGTERMs the harness
# mid-reset.  Port-scoped `fuser -k` frees the only resources a stale prior run
# could still hold (its bound RPC/P2P listeners) and can never self-match,
# since the harness holds no port at reset time.  Anything else from a prior
# run is reaped by the trap cleanup that ran on that run's exit.
log "resetting scratch state"
fuser -k "${BC_RPC}/tcp"   2>/dev/null || true
fuser -k "${BC_P2P}/tcp"   2>/dev/null || true
fuser -k "${CORE_RPC}/tcp" 2>/dev/null || true
fuser -k "${CORE_P2P}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "beamchain release binary not found at $NODE_BIN (run rebar3 as prod release)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# Derive the shared regtest p2wpkh address from the fixed secret.
ADDR=$(python3 - "$TF_PATH" "$SECRET" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k = ECKey(); k.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
PYEOF
) || fail "failed to derive regtest address from test_framework"
[[ -n "$ADDR" ]] || fail "derived empty regtest address"
log "mining address: $ADDR"

# ── Readiness poll for the Core regtest oracle. ───────────────────────────
wait_core_ready() {
    local dd="$1" rpc="$2" pid="$3" lf="$4"
    local deadline=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || { tail -n 20 "$lf" >&2 2>/dev/null || true; return 1; }
        sleep 1
    done
    tail -n 20 "$lf" >&2 2>/dev/null || true
    return 1
}

# ── 2. Launch the Core regtest oracle. ────────────────────────────────────
log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -bind="127.0.0.1:$CORE_P2P" -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
wait_core_ready "$CORE_DATADIR" "$CORE_RPC" "$CORE_BG" "$CORE_LOG" \
    || fail "Core oracle failed to start within 120s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch beamchain on regtest (release binary, foreground). ──────────
cat >"$BC_DATADIR/sys.config" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$BC_DATADIR"},
   {p2pport, $BC_P2P},
   {rpcport, $BC_RPC}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$BC_DATADIR/vm.args" <<ERLVM
-sname beamchain_ctxstatsref_$$
-setcookie beamchain_ctxstatsref
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
RELX_CONFIG_PATH="$BC_DATADIR/sys.config" VMARGS_PATH="$BC_DATADIR/vm.args" \
    "$NODE_BIN" foreground >"$BC_LOG" 2>&1 &
BC_PID=$!
log "beamchain pid=$BC_PID"
bc_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < bc_deadline )); do
    if [[ -z "$BC_COOKIE" ]]; then
        for c in "$BC_DATADIR/regtest/.cookie" "$BC_DATADIR/.cookie"; do
            [[ -f "$c" ]] && BC_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$BC_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BC_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$BC_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 20 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited during startup (see $BC_LOG)"; }
    sleep 1
done
[[ -n "$BC_COOKIE" ]] || fail "beamchain cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$BC_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$BC_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "beamchain RPC never responded within 60s"
log "beamchain RPC ready"

# ── beamchain JSON-RPC helper. ────────────────────────────────────────────
bc_rpc() {  # bc_rpc <method> [params-json]  (params default to [])
    local method="$1" params="${2:-[]}"
    curl -s --max-time 90 -u "$BC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$BC_RPC/" 2>/dev/null
}
core_rpc() {  # core_rpc <method> [args...]  -> raw bitcoin-cli output
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>/dev/null
}

# ── 4. Mine the SAME number of empty blocks on both nodes. ────────────────
log "mining $NBLOCKS blocks on Core"
core_rpc generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"
CORE_H=$(core_rpc getblockcount)
[[ "$CORE_H" == "$NBLOCKS" ]] || fail "Core height $CORE_H != expected $NBLOCKS"

log "mining $NBLOCKS blocks on beamchain"
mr=$(bc_rpc generatetoaddress "[$NBLOCKS, \"$ADDR\"]")
echo "$mr" | grep -q '"result"' || fail "beamchain generatetoaddress failed: $mr"
BC_H=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('result',''))" <<<"$(bc_rpc getblockcount)")
[[ "$BC_H" == "$NBLOCKS" ]] || fail "beamchain height $BC_H != expected $NBLOCKS"
log "both nodes at height $NBLOCKS"

# ── 5. Resolve the tip hash on each node (chain SHAPE matches, but the tip ─
#       HASHES differ because timestamps differ — so query each on its OWN tip).
CORE_TIP=$(core_rpc getbestblockhash)
[[ -n "$CORE_TIP" ]] || fail "Core getbestblockhash empty"
BC_TIP=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('result',''))" <<<"$(bc_rpc getbestblockhash)")
[[ -n "$BC_TIP" ]] || fail "beamchain getbestblockhash empty"

# ── 6. PRIMARY differential: getchaintxstats <WINDOW> <tip> on both. ──────
log "probing getchaintxstats $WINDOW <tip> on both nodes"
CORE_J=$(core_rpc getchaintxstats "$WINDOW" "$CORE_TIP")
[[ -n "$CORE_J" ]] || fail "Core getchaintxstats produced no output"
BC_RAW=$(bc_rpc getchaintxstats "[$WINDOW, \"$BC_TIP\"]")
bc_ec=$(jerr "$BC_RAW")
[[ -z "$bc_ec" ]] || fail "beamchain getchaintxstats errored (code $bc_ec): $BC_RAW"

# Pull the COUNT/HEIGHT-shaped fields from both.
C_TXCOUNT=$(jget "$CORE_J" txcount)
C_WTXC=$(jget "$CORE_J" window_tx_count)
C_WBC=$(jget "$CORE_J" window_block_count)
C_WFBH=$(jget "$CORE_J" window_final_block_height)

B_TXCOUNT=$(jget "$BC_RAW" txcount)
B_WTXC=$(jget "$BC_RAW" window_tx_count)
B_WBC=$(jget "$BC_RAW" window_block_count)
B_WFBH=$(jget "$BC_RAW" window_final_block_height)
B_WFH=$(jget "$BC_RAW" window_final_block_hash)

log "Core: txcount=$C_TXCOUNT window_tx_count=$C_WTXC window_block_count=$C_WBC window_final_block_height=$C_WFBH"
log "beam: txcount=$B_TXCOUNT window_tx_count=$B_WTXC window_block_count=$B_WBC window_final_block_height=$B_WFBH wfbhash=$B_WFH"

# ── 7a. txcount: must EQUAL Core AND equal the shape-derived value H+1. ───
EXP_TXCOUNT=$((NBLOCKS + 1))
TXCOUNT_T="ok"
if [[ "$B_TXCOUNT" != "$C_TXCOUNT" ]]; then
    fail "txcount mismatch: beamchain=$B_TXCOUNT Core=$C_TXCOUNT (window=$WINDOW)"
fi
if [[ "$B_TXCOUNT" != "$EXP_TXCOUNT" ]]; then
    fail "txcount=$B_TXCOUNT != shape-expected $EXP_TXCOUNT (height $NBLOCKS empty blocks -> H+1)"
fi

# ── 7b. window_tx_count: must EQUAL Core AND equal nblocks (1 cb per block). ─
WINDOW_T="ok"
if [[ "$B_WTXC" != "$C_WTXC" ]]; then
    fail "window_tx_count mismatch: beamchain=$B_WTXC Core=$C_WTXC (window=$WINDOW)"
fi
if [[ "$B_WTXC" != "$WINDOW" ]]; then
    fail "window_tx_count=$B_WTXC != shape-expected $WINDOW (empty blocks -> 1 coinbase each)"
fi

# ── 7c. shape: window_block_count + window_final_block_height match Core, ──
#       window_final_block_hash present + 64-hex (the impl's OWN tip hash).
SHAPE_T="ok"
if [[ "$B_WBC" != "$C_WBC" ]]; then
    fail "window_block_count mismatch: beamchain=$B_WBC Core=$C_WBC"
fi
if [[ "$B_WBC" != "$WINDOW" ]]; then
    fail "window_block_count=$B_WBC != requested $WINDOW"
fi
if [[ "$B_WFBH" != "$C_WFBH" ]]; then
    fail "window_final_block_height mismatch: beamchain=$B_WFBH Core=$C_WFBH"
fi
if [[ "$B_WFBH" != "$NBLOCKS" ]]; then
    fail "window_final_block_height=$B_WFBH != tip height $NBLOCKS"
fi
if [[ "$B_WFH" != "$BC_TIP" ]]; then
    fail "window_final_block_hash=$B_WFH != beamchain tip $BC_TIP"
fi
if ! [[ "$B_WFH" =~ ^[0-9a-f]{64}$ ]]; then
    fail "window_final_block_hash not 64-hex: $B_WFH"
fi

# ── 7d. time-dependent fields: PRESENT + correctly-typed + emit-rule-correct.
# `time` = final block RAW header nTime: must be present + a sane unix epoch.
jhas "$BC_RAW" time || fail "time field missing from getchaintxstats $WINDOW"
B_TIME=$(jget "$BC_RAW" time)
if ! [[ "$B_TIME" =~ ^[0-9]+$ ]]; then
    fail "time not an integer: $B_TIME"
fi
# 1230768000 = 2009-01-01 (Bitcoin genesis era); any regtest tip must exceed it.
if (( B_TIME < 1230768000 )); then
    fail "time=$B_TIME is not a sane unix timestamp (< 2009)"
fi

# window_interval present + >= 0 when nblocks > 0.
jhas "$BC_RAW" window_interval || fail "window_interval missing when nblocks=$WINDOW > 0"
B_WIN_INT=$(jget "$BC_RAW" window_interval)
if ! [[ "$B_WIN_INT" =~ ^-?[0-9]+$ ]]; then
    fail "window_interval not an integer: $B_WIN_INT"
fi
if (( B_WIN_INT < 0 )); then
    fail "window_interval=$B_WIN_INT < 0 (MTP must be monotonic non-decreasing)"
fi

# txrate present when nblocks > 0 AND window_interval > 0 (Core emit rule).
if (( B_WIN_INT > 0 )); then
    jhas "$BC_RAW" txrate || fail "txrate missing when nblocks>0 and window_interval=$B_WIN_INT > 0"
    B_TXRATE=$(jget "$BC_RAW" txrate)
    # txrate is a double: accept int or float, must be >= 0.
    python3 -c "import sys; v=float('$B_TXRATE'); sys.exit(0 if v>=0 else 1)" \
        || fail "txrate not a non-negative number: $B_TXRATE"
else
    # window_interval == 0: Core does NOT emit txrate.
    if jhas "$BC_RAW" txrate; then
        fail "txrate emitted even though window_interval=0 (violates Core emit rule)"
    fi
fi

# ── 8. nblocks=0 case: the THREE window extras must be DROPPED. ───────────
log "probing getchaintxstats 0 <tip> (nblocks=0 must drop window extras)"
BC0_RAW=$(bc_rpc getchaintxstats "[0, \"$BC_TIP\"]")
bc0_ec=$(jerr "$BC0_RAW")
[[ -z "$bc0_ec" ]] || fail "beamchain getchaintxstats 0 errored (code $bc0_ec): $BC0_RAW"
CORE0_J=$(core_rpc getchaintxstats 0 "$CORE_TIP")
[[ -n "$CORE0_J" ]] || fail "Core getchaintxstats 0 produced no output"

NBLOCKS0_T="ok"
# Fields that MUST still be present at nblocks=0: time, txcount,
# window_final_block_hash, window_final_block_height, window_block_count(=0).
for fld in time txcount window_final_block_hash window_final_block_height window_block_count; do
    jhas "$BC0_RAW" "$fld" || fail "nblocks=0: required field '$fld' missing"
done
B0_WBC=$(jget "$BC0_RAW" window_block_count)
[[ "$B0_WBC" == "0" ]] || fail "nblocks=0: window_block_count=$B0_WBC != 0"
# txcount must still equal Core (and the shape value) at nblocks=0.
B0_TXCOUNT=$(jget "$BC0_RAW" txcount)
C0_TXCOUNT=$(jget "$CORE0_J" txcount)
[[ "$B0_TXCOUNT" == "$C0_TXCOUNT" ]] || fail "nblocks=0: txcount beamchain=$B0_TXCOUNT != Core=$C0_TXCOUNT"
[[ "$B0_TXCOUNT" == "$EXP_TXCOUNT" ]] || fail "nblocks=0: txcount=$B0_TXCOUNT != shape-expected $EXP_TXCOUNT"
# The THREE window extras MUST be ABSENT at nblocks=0 (Core `if (blockcount>0)`).
for extra in window_interval window_tx_count txrate; do
    if jhas "$BC0_RAW" "$extra"; then
        fail "nblocks=0: '$extra' must be dropped but is present (violates Core emit rule)"
    fi
    # cross-check: Core also drops it.
    if jhas "$CORE0_J" "$extra"; then
        log "WARN: Core unexpectedly emitted '$extra' at nblocks=0 (oracle drift) — still failing beamchain on its own rule"
    fi
done

# ── 9. Error-code spot-check: a bogus blockhash -> -5 (RPC_INVALID_ADDRESS). ─
# Not part of the summary tokens (structure/error-codes were already live-
# confirmed Core-correct) but a cheap regression guard against a refactor that
# breaks the lookup path.
BOGUS="00000000000000000000000000000000000000000000000000000000deadbeef"
BAD_RAW=$(bc_rpc getchaintxstats "[1, \"$BOGUS\"]")
bad_ec=$(jerr "$BAD_RAW")
if [[ "$bad_ec" != "-5" ]]; then
    log "WARN: bogus-blockhash error code = $bad_ec (Core uses -5 RPC_INVALID_ADDRESS_OR_KEY)"
fi

# ── 10. Verdict. ──────────────────────────────────────────────────────────
log "PASS: txcount/window_tx_count/window_block_count/window_final_block_height match Core (shape-derived) + time-dependent fields present & emit-rule-correct + nblocks=0 drops the 3 window extras"
pass "$TXCOUNT_T" "$WINDOW_T" "$SHAPE_T" "$NBLOCKS0_T"
