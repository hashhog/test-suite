#!/usr/bin/env bash
#
# rustoshi_recovery.sh — self-contained wallet-recovery regression test (regtest).
#
# Codifies the "wallet recovery green" cell landed 2026-06-03 in rustoshi
# (commits a103be9 scantxoutset + 4174dbe sethdseed). Proves seed-only recovery:
# a wallet that loses its disk state can re-derive byte-identical addresses and
# rediscover 100% of its on-chain funds from the master seed alone.
#
# Proven flow (matches commit 4174dbe's verified-on-regtest description):
#   createwallet -> sethdseed(FIXED 64-byte seed) -> getnewaddress (A1) ->
#   generatetoaddress (fund coinbase) -> scantxoutset BEFORE (record total) ->
#   "disk loss": unloadwallet -> fresh createwallet -> sethdseed(SAME seed) ->
#   re-derive (assert byte-identical to A1) -> scantxoutset AFTER ->
#   assert AFTER == BEFORE -> negative control (foreign addr -> 0).
#
# Restore mechanism for rustoshi: `sethdseed` takes a 64-byte (128 hex char)
# master seed (documented Core divergence — Core takes a WIF privkey). RPC auth
# is cookie-based (<datadir>/.cookie), matching tools/smoke-harness.sh.
#
# Single wallet is loaded at any moment (the first is unloaded before the second
# is created) so RPC routing resolves the default wallet unambiguously — rustoshi
# does not wire /wallet/<name> URL routing, so multi-wallet calls are ambiguous.
#
# Interface contract (the assembled nightly runner depends on it):
#   - No required args. set -uo pipefail. Idempotent (wipes scratch + frees ports).
#   - Scratch datadir /tmp/recreg-rustoshi/, RPC 21500, P2P 21530.
#   - Always cleans up (trap): kills the node + rm -rf the scratch datadir.
#   - Prints EXACTLY ONE summary line to stdout, all other output to stderr/log:
#       PASS: RECOVERY rustoshi: PASS funded=<X> recovered=<X> addrs=match neg=0   (exit 0)
#       FAIL: RECOVERY rustoshi: FAIL <short reason>                                (exit 1)
#
# NEVER touches /data/nvme1/, testnet4-data/, or live nodes — only the scratch
# datadir and the assigned ports.

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
BIN="$BASEDIR/rustoshi/target/release/rustoshi"
DATADIR="/tmp/recreg-rustoshi"
RPC_PORT=21500
P2P_PORT=21530
LOG="$DATADIR/node.log"
RUNLOG="$DATADIR/recovery.log"   # noisy test output goes here / to stderr

# FIXED 64-byte master seed (128 hex chars) — the seed that worked last session.
# Deterministic, so every run derives the SAME first address.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

# A regtest address from a DIFFERENT seed, used as the negative control. It must
# never appear in the funded UTXO set, so scantxoutset must return 0 for it.
FOREIGN_ADDR="bcrt1qy4yalzz4gql22r2dq0wvvyw6rh9reuscy60nwp"

NODE_PID=""

# ── stderr logger (keeps stdout clean for the single summary line) ──────────
log() { echo "[recovery] $*" >&2; }

# ── Emit the one summary line + exit ────────────────────────────────────────
pass() {
    # $1 funded  $2 recovered
    echo "RECOVERY rustoshi: PASS funded=$1 recovered=$2 addrs=match neg=0"
    exit 0
}
fail() {
    echo "RECOVERY rustoshi: FAIL $*"
    exit 1
}

# ── Cleanup: always kill node + wipe scratch datadir ────────────────────────
cleanup() {
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    rm -rf "$DATADIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── RPC helper (cookie auth, like smoke-harness.sh) ─────────────────────────
# Usage: rpc <method> [json-params]   — echoes the raw JSON response.
rpc() {
    local method=$1 params="${2:-[]}" auth=""
    for c in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
        if [[ -f "$c" ]]; then auth="-u $(cat "$c")"; break; fi
    done
    # shellcheck disable=SC2086
    curl -s --max-time 30 $auth \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

# Extract a JSON string result ("result":"..."), empty if absent/error.
res_str() { grep -o '"result":"[^"]*"' | head -1 | cut -d'"' -f4; }

# Extract scantxoutset total_amount via python3 (robust float parse); empty on error.
scan_total() {
    python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d["result"]["total_amount"])
except Exception:
    pass
' 2>/dev/null
}

# Float equality with a small epsilon (amounts are BTC floats).
floats_equal() {
    python3 -c '
import sys
try:
    a = float(sys.argv[1]); b = float(sys.argv[2])
    sys.exit(0 if abs(a - b) < 1e-8 else 1)
except Exception:
    sys.exit(2)
' "$1" "$2"
}

# ── Pre-flight: idempotent reset ────────────────────────────────────────────
log "pre-flight: freeing ports + wiping scratch datadir"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR" 2>/dev/null || true
mkdir -p "$DATADIR" || fail "cannot create scratch datadir $DATADIR"

[[ -x "$BIN" ]] || fail "rustoshi binary not found at $BIN (build with: cargo build --release)"

# ── Launch the node (recipe from tools/smoke-harness.sh) ────────────────────
log "launching rustoshi regtest (rpc=$RPC_PORT p2p=$P2P_PORT datadir=$DATADIR)"
"$BIN" --network=regtest --datadir="$DATADIR" \
    --port="$P2P_PORT" --rpcbind="127.0.0.1:$RPC_PORT" \
    >"$LOG" 2>&1 &
NODE_PID=$!

if ! kill -0 "$NODE_PID" 2>/dev/null; then
    fail "node process exited immediately (see $LOG)"
fi

# ── Wait up to 30s for RPC ──────────────────────────────────────────────────
log "waiting for RPC..."
rpc_ready=0
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
    if echo "$(rpc getblockcount)" | grep -q '"result"'; then rpc_ready=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node died during startup (see $LOG)"
    sleep 1
done
[[ "$rpc_ready" == "1" ]] || fail "RPC did not respond within 30s"
log "RPC ready"

# ── Step 1: create funding wallet + restore the FIXED seed ─────────────────
log "step 1: createwallet 'funding' + sethdseed (restore fixed seed)"
out=$(rpc createwallet '["funding"]')
echo "$out" | grep -q '"funding"' || fail "createwallet funding failed: $out"

out=$(rpc sethdseed "[true, \"$SEED\"]")
echo "$out" | grep -q '"result"' || fail "sethdseed (initial) failed: $out"

# ── Step 2: derive A1 (the address we will fund + later recover) ───────────
A1=$(rpc getnewaddress | res_str)
[[ -n "$A1" ]] || fail "getnewaddress (initial) returned empty"
log "step 2: derived A1=$A1"

# ── Step 3: fund A1 via coinbase (101 blocks -> 100 mature coinbases) ──────
log "step 3: generatetoaddress 101 -> A1 (fund coinbase outputs)"
out=$(rpc generatetoaddress "[101, \"$A1\"]")
echo "$out" | grep -q '"result"' || fail "generatetoaddress failed: $out"

# ── Step 4: scantxoutset BEFORE — record the total at A1 ───────────────────
BEFORE=$(rpc scantxoutset "[\"start\", [\"addr($A1)\"]]" | scan_total)
[[ -n "$BEFORE" ]] || fail "scantxoutset BEFORE returned no total_amount"
log "step 4: BEFORE total at A1 = $BEFORE BTC"
# Sanity: must have actually funded something.
if floats_equal "$BEFORE" "0"; then
    fail "BEFORE total is 0 (funding did not land)"
fi

# ── Step 5: simulate disk loss -> fresh wallet + restore the SAME seed ─────
# Unload the funding wallet first so only ONE wallet is ever loaded (rustoshi
# does not wire /wallet/<name> URL routing; the default-wallet resolver is
# unambiguous only with a single loaded wallet). A brand-new wallet name stands
# in for a wallet that lost its disk state.
log "step 5: unloadwallet 'funding' -> createwallet 'recovered' -> sethdseed (SAME seed)"
out=$(rpc unloadwallet '["funding"]')
echo "$out" | grep -q '"result"' || fail "unloadwallet funding failed: $out"

out=$(rpc createwallet '["recovered"]')
echo "$out" | grep -q '"recovered"' || fail "createwallet recovered failed: $out"

out=$(rpc sethdseed "[true, \"$SEED\"]")
echo "$out" | grep -q '"result"' || fail "sethdseed (restore) failed: $out"

# ── Step 6: re-derive — MUST be byte-identical to A1 ───────────────────────
A1r=$(rpc getnewaddress | res_str)
[[ -n "$A1r" ]] || fail "getnewaddress (recovered) returned empty"
log "step 6: recovered first address = $A1r (expected $A1)"
[[ "$A1r" == "$A1" ]] || fail "address mismatch after restore: got $A1r expected $A1"

# ── Step 7: scantxoutset AFTER — MUST equal BEFORE ─────────────────────────
AFTER=$(rpc scantxoutset "[\"start\", [\"addr($A1r)\"]]" | scan_total)
[[ -n "$AFTER" ]] || fail "scantxoutset AFTER returned no total_amount"
log "step 7: AFTER total at recovered address = $AFTER BTC"
if ! floats_equal "$AFTER" "$BEFORE"; then
    fail "recovered total $AFTER != funded total $BEFORE"
fi

# ── Step 8: negative control — a foreign address must scan to 0 ────────────
NEG=$(rpc scantxoutset "[\"start\", [\"addr($FOREIGN_ADDR)\"]]" | scan_total)
[[ -n "$NEG" ]] || fail "negative-control scantxoutset returned no total_amount"
log "step 8: negative-control total (foreign addr) = $NEG BTC"
if ! floats_equal "$NEG" "0"; then
    fail "negative control non-zero: foreign addr scanned $NEG (expected 0)"
fi

# ── All assertions passed ───────────────────────────────────────────────────
log "all assertions passed: funded=$BEFORE recovered=$AFTER addrs=match neg=0"
pass "$BEFORE" "$AFTER"
