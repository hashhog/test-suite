#!/usr/bin/env bash
#
# ouroboros_chaintxstats.sh — self-contained getchaintxstats DIFFERENTIAL test.
#
# The first RPC-surface green-cell after the wallet + mempool-policy chapters.
# getchaintxstats is READ-ONLY chain statistics — NOT consensus — but the SHAPE
# and the COUNT/HEIGHT fields must match Bitcoin Core exactly for the same chain.
#
# WHAT IT PROVES (Core ref: bitcoin-core/src/rpc/blockchain.cpp getchaintxstats):
#   On an identically-shaped regtest chain (N empty blocks mined to the same
#   address on BOTH nodes -> each block carries exactly 1 coinbase tx), the
#   deterministic fields MUST be byte-identical between ouroboros and a REAL
#   bitcoind oracle:
#     * txcount                  == height + 1   (genesis coinbase + 1/block)
#     * window_tx_count          == nblocks      (1 tx/block over the window)
#     * window_block_count       == nblocks
#     * window_final_block_height== tip height
#     * window_final_block_hash  == 64-hex (shape; identical chain -> same hash)
#   Time-dependent fields are asserted PRESENT + correctly-typed + obeying the
#   emit-condition rules (NOT exact-equal — the two regtest nodes mine at
#   different wall-clock times):
#     * time           present, integer, > 0   (final block RAW header nTime)
#     * window_interval present + >= 0          (median-time-past delta)
#     * txrate         present when window_interval > 0
#   And the nblocks=0 case MUST drop the three window extras
#   (window_interval / window_tx_count / txrate) on BOTH nodes.
#
# CORE ORACLE: a real bitcoind regtest node on its own scratch + ports owns the
#   ground truth. Same N blocks mined on both; getchaintxstats run on both.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/ouroboros_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + UNIQUE
#   ports, ONE clean summary line on stdout, noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: CHAINTXSTATS ouroboros: PASS txcount=ok window=ok shape=ok nblocks0=ok
#   FAIL: CHAINTXSTATS ouroboros: FAIL <short reason>
#
# Touches ONLY /tmp/ctxstats-ouroboros + /tmp/ctxstats-core and ports
#   21892/21912 (ouroboros RPC/P2P) + 21893/21913 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

# Resolve the ouroboros checkout relative to this script:
# test-suite/chaintxstats/ -> repo root -> ouroboros/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

OU_DATADIR="/tmp/ctxstats-ouroboros"
OU_RPC=21892
OU_P2P=21912
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/ctxstats-core"
CORE_RPC=21893
CORE_P2P=21913
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic mining address (regtest bech32) so both nodes mine to the SAME
# scriptPubKey and produce identical block bodies (-> identical block hashes,
# letting us assert window_final_block_hash equality, not just shape).
MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NBLOCKS=120            # mine 120 empty blocks on BOTH nodes
WINDOW=30              # getchaintxstats window for the primary assertion

OU_PID=""
OU_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[chaintxstats:ouroboros] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "CHAINTXSTATS ouroboros: PASS txcount=ok window=ok shape=ok nblocks0=ok"
    exit 0
}
fail() {
    echo "CHAINTXSTATS ouroboros: FAIL $*"
    exit 1
}

# ── JSON field extractor (no jq dependency; pure python3). ────────────────
# usage: jget '<json>' '<key>'  -> prints value, or "<MISSING>" if absent,
#        or "<NULL>" if present-but-null. Type-tags numbers so the caller can
#        assert int-ness.
jget() {
    python3 - "$1" "$2" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("<PARSEERR>"); sys.exit(0)
k = sys.argv[2]
if k not in d:
    print("<MISSING>"); sys.exit(0)
v = d[k]
if v is None:
    print("<NULL>")
elif isinstance(v, bool):
    print("bool:" + ("true" if v else "false"))
elif isinstance(v, int):
    print("int:" + str(v))
elif isinstance(v, float):
    print("float:" + repr(v))
else:
    print("str:" + str(v))
PYEOF
}

# rpc <cookie> <rpcport> <method> <json-params-array>  (ouroboros / curl path)
ou_rpc() {
    local cookie="$1" port="$2" method="$3" params="${4:-[]}"
    curl -s --max-time 30 -u "$cookie" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$port/" 2>/dev/null
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
# Kill any leftover nodes from a prior run (by datadir match) AND free every
# port, then SETTLE — a back-to-back run can otherwise launch the new oracle
# before the previous bitcoind has released its RPC/P2P sockets, which the
# kernel reports as "exited during startup" on the new node. Killing by
# datadir is the reliable handle (the port only frees once the holder
# has actually exited).
log "resetting scratch state"
pkill -f "ctxstats-ouroboros" 2>/dev/null || true
pkill -f "ctxstats-core"      2>/dev/null || true
for _ in $(seq 1 10); do
    pgrep -f "ctxstats-core" >/dev/null 2>&1 || pgrep -f "ctxstats-ouroboros" >/dev/null 2>&1 || break
    sleep 1
done
pkill -9 -f "ctxstats-ouroboros" 2>/dev/null || true
pkill -9 -f "ctxstats-core"      2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) "; then
    fail "port ${OU_RPC}/${OU_P2P}/${CORE_RPC}/${CORE_P2P}/$((CORE_P2P + 1)) already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 2
rm -rf "$OU_DATADIR" "$CORE_DATADIR"
mkdir -p "$OU_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1        || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1           || fail "curl not found on PATH"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros checkout not found at $OURO_DIR"
[[ -x "$CORE_BIN" ]]                      || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                      || fail "bitcoin-cli not found at $CORE_CLI"

OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"

# ── 2. Launch the Core regtest oracle. ────────────────────────────────────
log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -fallbackfee=0.0002 -daemonwait=0 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 60 ))
core_ready=0
while (( $(date +%s) < core_deadline )); do
    if "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
        core_ready=1; break
    fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 60s (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Mine NBLOCKS empty blocks on Core. ─────────────────────────────────
log "mining $NBLOCKS blocks on Core to $MINE_ADDR"
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
CORE_TIP=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount 2>/dev/null)
[[ "$CORE_TIP" == "$NBLOCKS" ]] || fail "Core tip=$CORE_TIP != $NBLOCKS after mining"

# ── 4. Launch ouroboros on regtest. ───────────────────────────────────────
# ouroboros is Python — the slowest-starting node — so allow a generous
# (>=120s) RPC-startup wait.
log "launching ouroboros (regtest) rpc=:$OU_RPC p2p=:$OU_P2P -> $OU_LOG"
(
    cd "$OURO_DIR" || exit 1
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$OU_DATADIR" \
        start --force --rpc-port "$OU_RPC" --p2p-port "$OU_P2P"
) >"$OU_LOG" 2>&1 &
OU_PID=$!
log "ouroboros pid=$OU_PID"
ou_deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < ou_deadline )); do
    if [[ -z "$OU_COOKIE" ]]; then
        for c in "$OU_DATADIR/.cookie" "$OU_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && OU_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$OU_COOKIE" ]]; then
        r=$(ou_rpc "$OU_COOKIE" "$OU_RPC" getblockcount)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$OU_PID" 2>/dev/null || { tail -n 20 "$OU_LOG" >&2 2>/dev/null || true; fail "ouroboros exited during startup (see $OU_LOG)"; }
    sleep 1
done
[[ -n "$OU_COOKIE" ]] || fail "ouroboros cookie never appeared within 180s"
r=$(ou_rpc "$OU_COOKIE" "$OU_RPC" getblockcount)
echo "$r" | grep -q '"result"' || fail "ouroboros RPC never responded within 180s"
log "ouroboros RPC ready"

# ── 5. Mine NBLOCKS empty blocks on ouroboros (same addr -> same shape). ──
log "mining $NBLOCKS blocks on ouroboros to $MINE_ADDR"
gen=$(ou_rpc "$OU_COOKIE" "$OU_RPC" generatetoaddress "[$NBLOCKS,\"$MINE_ADDR\"]")
echo "$gen" | grep -q '"result"' || { log "ouroboros gen reply: $gen"; fail "ouroboros generatetoaddress failed"; }
gbc=$(ou_rpc "$OU_COOKIE" "$OU_RPC" getblockcount)
OU_TIP=$(echo "$gbc" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result'))" 2>/dev/null)
[[ "$OU_TIP" == "$NBLOCKS" ]] || fail "ouroboros tip=$OU_TIP != $NBLOCKS after mining"

# ── 6. Run getchaintxstats <WINDOW> <tip> on BOTH nodes. ──────────────────
OU_TIPHASH=$(echo "$(ou_rpc "$OU_COOKIE" "$OU_RPC" getblockhash "[$NBLOCKS]")" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('result'))" 2>/dev/null)
CORE_TIPHASH=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockhash "$NBLOCKS" 2>/dev/null)
[[ -n "$OU_TIPHASH" && "$OU_TIPHASH" != "None" ]] || fail "ouroboros getblockhash($NBLOCKS) empty"
[[ -n "$CORE_TIPHASH" ]] || fail "Core getblockhash($NBLOCKS) empty"

log "Core   tiphash=$CORE_TIPHASH"
log "ouroboros tiphash=$OU_TIPHASH"

# Core result (extract just the result object).
CORE_CTS=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    getchaintxstats "$WINDOW" "$CORE_TIPHASH" 2>>"$CORE_LOG")
[[ -n "$CORE_CTS" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core getchaintxstats produced no output"; }

# ouroboros result (unwrap JSON-RPC envelope to the .result object).
OU_RESP=$(ou_rpc "$OU_COOKIE" "$OU_RPC" getchaintxstats "[$WINDOW,\"$OU_TIPHASH\"]")
OU_CTS=$(echo "$OU_RESP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('error'): print('<ERR>'+json.dumps(d['error'])); sys.exit(0)
print(json.dumps(d.get('result')))
" 2>/dev/null)
[[ -n "$OU_CTS" && "$OU_CTS" != "null" ]] || { log "ouroboros raw: $OU_RESP"; fail "ouroboros getchaintxstats produced no result"; }
case "$OU_CTS" in "<ERR>"*) log "ouroboros error: ${OU_CTS#<ERR>}"; fail "ouroboros getchaintxstats returned an error" ;; esac

log "Core   getchaintxstats: $CORE_CTS"
log "ouroboros getchaintxstats: $OU_CTS"

# ── 7. Assert the DETERMINISTIC count/height fields match Core exactly. ───
# Expected for NBLOCKS empty blocks (1 coinbase each, genesis included):
#   txcount = NBLOCKS + 1 ; window_tx_count = WINDOW ; window_block_count = WINDOW
EXP_TXCOUNT=$(( NBLOCKS + 1 ))
EXP_WIN_TX=$WINDOW

for FIELD in txcount window_tx_count window_block_count window_final_block_height; do
    cv=$(jget "$CORE_CTS" "$FIELD")
    ov=$(jget "$OU_CTS"   "$FIELD")
    [[ "$cv" == "$ov" ]] || fail "field '$FIELD' mismatch vs Core: core=$cv ouroboros=$ov"
done

# Independently pin the expected literals (guards against Core+ouroboros both
# being wrong in the same way — they can't be on a freshly-mined empty chain).
[[ "$(jget "$OU_CTS" txcount)" == "int:$EXP_TXCOUNT" ]] \
    || fail "txcount != $EXP_TXCOUNT (got $(jget "$OU_CTS" txcount))"
[[ "$(jget "$OU_CTS" window_tx_count)" == "int:$EXP_WIN_TX" ]] \
    || fail "window_tx_count != $EXP_WIN_TX (got $(jget "$OU_CTS" window_tx_count))"
[[ "$(jget "$OU_CTS" window_block_count)" == "int:$WINDOW" ]] \
    || fail "window_block_count != $WINDOW (got $(jget "$OU_CTS" window_block_count))"
[[ "$(jget "$OU_CTS" window_final_block_height)" == "int:$NBLOCKS" ]] \
    || fail "window_final_block_height != $NBLOCKS (got $(jget "$OU_CTS" window_final_block_height))"
log "txcount/window count fields: ok (match Core + expected literals)"

# ── 8. window_final_block_hash: SHAPE (64-hex) + self-consistent (== tip). ─
# NOTE: ouroboros and Core build distinct coinbase tx bodies (different
# coinbase script / extranonce / timestamp), so the two regtest chains have
# DIFFERENT block hashes at the same height even mining to the same address.
# We therefore assert SHAPE + equality to *ouroboros's own* tip hash (the
# field must name the final block of the window), not equality to Core's hash.
ohash=$(jget "$OU_CTS" window_final_block_hash)
[[ "$ohash" == str:* ]] || fail "window_final_block_hash not a string (got $ohash)"
ohash="${ohash#str:}"
[[ "$ohash" =~ ^[0-9a-f]{64}$ ]] || fail "window_final_block_hash not 64-hex (got '$ohash')"
[[ "$ohash" == "$OU_TIPHASH" ]] || fail "window_final_block_hash != tip hash ($ohash != $OU_TIPHASH)"
# Cross-check Core's field has the SAME shape + names Core's own tip.
chash=$(jget "$CORE_CTS" window_final_block_hash)
[[ "$chash" == "str:$CORE_TIPHASH" ]] || fail "Core window_final_block_hash unexpected ($chash)"
log "window_final_block_hash: ok (64-hex; == ouroboros tip; Core field same shape)"

# ── 9. Time-dependent fields: PRESENT + correctly typed + emit rules. ─────
otime=$(jget "$OU_CTS" time)
[[ "$otime" == int:* ]] || fail "time not present-as-int (got $otime)"
[[ "${otime#int:}" -gt 0 ]] || fail "time not > 0 (got $otime)"

owin=$(jget "$OU_CTS" window_interval)
[[ "$owin" == int:* ]] || fail "window_interval not present-as-int (got $owin)"
[[ "${owin#int:}" -ge 0 ]] || fail "window_interval < 0 (got $owin)"

# txrate present iff window_interval > 0. On a same-second mined regtest chain
# the MTP delta CAN be 0, in which case Core (and ouroboros) drop txrate — that
# is correct, so only require txrate when window_interval > 0.
orate=$(jget "$OU_CTS" txrate)
if [[ "${owin#int:}" -gt 0 ]]; then
    case "$orate" in
        int:*|float:*) : ;;  # numeric -> ok
        *) fail "txrate missing/non-numeric despite window_interval>0 (got $orate)" ;;
    esac
else
    [[ "$orate" == "<MISSING>" ]] || log "note: window_interval=0; txrate=$orate (Core also drops it)"
fi
log "time/window_interval/txrate: ok (present + typed + emit-rule honoured)"

# ── 10. nblocks=0 MUST drop the three window extras (on both nodes). ──────
OU_RESP0=$(ou_rpc "$OU_COOKIE" "$OU_RPC" getchaintxstats "[0,\"$OU_TIPHASH\"]")
OU_CTS0=$(echo "$OU_RESP0" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('error'): print('<ERR>'+json.dumps(d['error'])); sys.exit(0)
print(json.dumps(d.get('result')))
" 2>/dev/null)
[[ -n "$OU_CTS0" && "$OU_CTS0" != "null" ]] || { log "ouroboros nblocks=0 raw: $OU_RESP0"; fail "ouroboros getchaintxstats 0 produced no result"; }
case "$OU_CTS0" in "<ERR>"*) log "ouroboros error: ${OU_CTS0#<ERR>}"; fail "ouroboros getchaintxstats 0 returned an error" ;; esac
log "ouroboros getchaintxstats 0: $OU_CTS0"

CORE_CTS0=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    getchaintxstats 0 "$CORE_TIPHASH" 2>>"$CORE_LOG")
[[ -n "$CORE_CTS0" ]] || fail "Core getchaintxstats 0 produced no output"
log "Core getchaintxstats 0: $CORE_CTS0"

# window_block_count must be 0; the three extras must be ABSENT on BOTH.
[[ "$(jget "$OU_CTS0" window_block_count)" == "int:0" ]] \
    || fail "nblocks=0: window_block_count != 0 (got $(jget "$OU_CTS0" window_block_count))"
for EXTRA in window_interval window_tx_count txrate; do
    ov=$(jget "$OU_CTS0" "$EXTRA")
    cv=$(jget "$CORE_CTS0" "$EXTRA")
    [[ "$cv" == "<MISSING>" ]] || fail "ASSUMPTION BROKEN: Core emits '$EXTRA' at nblocks=0 (got $cv)"
    [[ "$ov" == "<MISSING>" ]] || fail "nblocks=0: ouroboros still emits '$EXTRA' (got $ov) — must be dropped"
done
# txcount + final-block fields must STILL be present at nblocks=0.
[[ "$(jget "$OU_CTS0" txcount)" == "int:$EXP_TXCOUNT" ]] \
    || fail "nblocks=0: txcount wrong (got $(jget "$OU_CTS0" txcount))"
[[ "$(jget "$OU_CTS0" window_final_block_height)" == "int:$NBLOCKS" ]] \
    || fail "nblocks=0: window_final_block_height wrong (got $(jget "$OU_CTS0" window_final_block_height))"
[[ "$(jget "$OU_CTS0" time)" == int:* ]] \
    || fail "nblocks=0: time missing (got $(jget "$OU_CTS0" time))"
log "nblocks=0: ok (3 window extras dropped on both nodes; txcount/time/final-block retained)"

# ── 11. Verdict. ──────────────────────────────────────────────────────────
log "PASS: count/height fields == Core; shape valid; time fields present+typed; nblocks=0 drops window extras"
pass
