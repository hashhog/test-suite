#!/usr/bin/env bash
#
# ouroboros_recovery.sh — self-contained wallet-recovery regression test.
#
# Codifies the FIRST ouroboros wallet-recovery green cell (landed 2026-06-03,
# ouroboros commit d1e9e24 "fix(rpc): generatetoaddress produced invalid
# coinbase/header (3 defects) — enables wallet-recovery green cell").
#
# Proven flow (restore mechanism = sethdseed with a fixed raw hex seed):
#   1. Launch ouroboros on regtest (scratch datadir, dedicated ports).
#   2. sethdseed a FIXED seed on the auto-created "default" wallet -> resets
#      the BIP32/84 key pool deterministically.
#   3. getnewaddress for all 4 script types (bech32, legacy, p2sh-segwit,
#      bech32m) -> the A1.. set.
#   4. generatetoaddress to fund each (coinbase outputs).
#   5. scantxoutset over those addrs -> record total (BEFORE).
#   6. Fresh wallet ("recovered", blank) + sethdseed the SAME seed -> re-derive
#      the 4 addresses; assert byte-identical to the originals (seed-only
#      recovery, no other state).
#   7. scantxoutset again -> assert AFTER total == BEFORE total.
#   8. Negative control: scantxoutset a foreign address -> must be 0.
#
# Output: exactly ONE summary line on stdout, then exit.
#   PASS: RECOVERY ouroboros: PASS funded=<X> recovered=<X> addrs=match neg=0
#   FAIL: RECOVERY ouroboros: FAIL <short reason>
# All noisy output goes to stderr / the log so the runner can grep the summary.
#
# NEVER touches /data/nvme1/ or testnet4-data/ or live nodes — only the scratch
# datadir /tmp/recreg-ouroboros and the assigned ports 39602 (RPC) / 39632 (P2P).

set -uo pipefail

# ── Fixed configuration (matches the proven green-cell flow) ─────────────
RPC_PORT=39602
P2P_PORT=39632
DATADIR="/tmp/recreg-ouroboros"
LOGFILE="/tmp/recreg-ouroboros-node.log"
SCRATCH_LOG="/tmp/recreg-ouroboros-test.log"
# The fixed BIP32 raw seed (32 bytes) used by the green cell. Determinism of
# the test depends on this never changing.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
# A foreign regtest address not derivable from SEED — the negative control.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

# Resolve the ouroboros checkout relative to this script:
# test-suite/recovery/ -> repo root -> ouroboros/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

NODE_PID=""

log() { echo "$@" >&2; }

# ── Single summary line + exit. Cleanup runs via the EXIT trap. ──────────
emit_pass() {
    echo "RECOVERY ouroboros: PASS funded=$1 recovered=$2 addrs=match neg=0"
    exit 0
}
emit_fail() {
    echo "RECOVERY ouroboros: FAIL $1"
    exit 1
}

# ── Cleanup: always kill the node + remove the scratch datadir ───────────
cleanup() {
    local rc=$?
    if [[ -n "$NODE_PID" ]]; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    # Defensive: free the ports regardless of how the node was started.
    fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
    fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
    rm -rf "$DATADIR"
    return $rc
}
trap cleanup EXIT INT TERM

# ── Pre-flight: scrub any prior run on these ports + scratch datadir ─────
fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"
: > "$SCRATCH_LOG"

# ── Pick the interpreter (prefer the venv with the `sync` Rust ext) ──────
OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || emit_fail "ouroboros checkout not found at $OURO_DIR"

# ── Launch the node (smoke-harness recipe) ───────────────────────────────
log "launching ouroboros: $OURO_PY -m ouroboros.cli (rpc=$RPC_PORT p2p=$P2P_PORT)"
(
    cd "$OURO_DIR" || exit 1
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$DATADIR" \
        start --force --rpc-port "$RPC_PORT" --p2p-port "$P2P_PORT"
) >"$LOGFILE" 2>&1 &
NODE_PID=$!
log "node pid $NODE_PID"

# ── RPC auth: ouroboros uses cookie auth (datadir/.cookie) ───────────────
cookie_auth() {
    local c
    for c in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
        if [[ -f "$c" ]]; then
            echo "-u $(cat "$c")"
            return 0
        fi
    done
    echo ""
}

# ── JSON-RPC helpers ─────────────────────────────────────────────────────
# rpc <method> <params-json>            -> default (node-level / default wallet)
# wrpc <wallet> <method> <params-json>  -> wallet-scoped (/wallet/<name>)
rpc() {
    local method=$1 params=${2:-[]}
    local auth; auth=$(cookie_auth)
    # shellcheck disable=SC2086
    curl -s --max-time 60 $auth \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}
wrpc() {
    local wallet=$1 method=$2 params=${3:-[]}
    local auth; auth=$(cookie_auth)
    # shellcheck disable=SC2086
    curl -s --max-time 60 $auth \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/wallet/$wallet" 2>/dev/null
}

# Extract a top-level string "result":"..." from a JSON-RPC response.
json_str_result() {
    grep -o '"result":"[^"]*"' | head -1 | cut -d'"' -f4
}
# Extract the "total_amount":<number> from a scantxoutset response.
json_total_amount() {
    grep -o '"total_amount":[0-9.eE+-]*' | head -1 | cut -d':' -f2
}

# ── Wait up to 30s for RPC to come up ────────────────────────────────────
RPC_UP=0
for _ in $(seq 1 30); do
    if ! kill -0 "$NODE_PID" 2>/dev/null; then
        log "node process exited during startup; tail of log:"
        tail -20 "$LOGFILE" >&2 || true
        emit_fail "node exited during startup (see $LOGFILE)"
    fi
    r=$(rpc getblockcount "[]")
    if echo "$r" | grep -q '"result"'; then
        RPC_UP=1
        log "RPC up: $r"
        break
    fi
    sleep 1
done
[[ "$RPC_UP" -eq 1 ]] || emit_fail "RPC did not respond within 30s"

# ── Step 1: sethdseed the FIXED seed on the default wallet ───────────────
r=$(rpc sethdseed "[\"$SEED\"]")
log "sethdseed(default): $r"
echo "$r" | grep -q "$SEED" || emit_fail "sethdseed failed on default wallet"

# ── Step 2: derive A1.. for all four script types ────────────────────────
A_BECH32=$(rpc getnewaddress '["", "bech32"]'      | json_str_result)
A_LEGACY=$(rpc getnewaddress '["", "legacy"]'      | json_str_result)
A_P2SH=$(rpc   getnewaddress '["", "p2sh-segwit"]' | json_str_result)
A_BECH32M=$(rpc getnewaddress '["", "bech32m"]'    | json_str_result)
log "addrs: bech32=$A_BECH32 legacy=$A_LEGACY p2sh=$A_P2SH bech32m=$A_BECH32M"
for a in "$A_BECH32" "$A_LEGACY" "$A_P2SH" "$A_BECH32M"; do
    [[ -n "$a" ]] || emit_fail "getnewaddress returned empty for one or more script types"
done

# ── Step 3: fund each address type via generatetoaddress (coinbase) ──────
fund_ok=1
for spec in "1:$A_BECH32" "1:$A_LEGACY" "1:$A_P2SH" "1:$A_BECH32M"; do
    n=${spec%%:*}; addr=${spec#*:}
    r=$(rpc generatetoaddress "[$n, \"$addr\"]")
    echo "$r" | grep -q '"result"' || { log "generatetoaddress failed for $addr: $r"; fund_ok=0; break; }
done
[[ "$fund_ok" -eq 1 ]] || emit_fail "generatetoaddress failed"

# ── Step 4: scantxoutset BEFORE — total funded over the 4 addrs ──────────
SCAN_ARGS="[\"start\", [\"addr($A_BECH32)\", \"addr($A_LEGACY)\", \"addr($A_P2SH)\", \"addr($A_BECH32M)\"]]"
r=$(rpc scantxoutset "$SCAN_ARGS")
log "scantxoutset BEFORE: $r"
echo "$r" | grep -q '"success":true' || emit_fail "scantxoutset BEFORE did not succeed"
BEFORE=$(echo "$r" | json_total_amount)
[[ -n "$BEFORE" ]] || emit_fail "could not read BEFORE total_amount"
# Must have actually funded something — a zero BEFORE means the funding path
# silently produced no spendable UTXOs (the green cell's whole point).
if [[ "$BEFORE" == "0.0" || "$BEFORE" == "0" ]]; then
    emit_fail "BEFORE total is 0 — funding produced no UTXOs"
fi

# ── Step 5: negative control — foreign addr must scan to 0 ───────────────
r=$(rpc scantxoutset "[\"start\", [\"addr($FOREIGN_ADDR)\"]]")
log "scantxoutset NEG: $r"
echo "$r" | grep -q '"success":true' || emit_fail "negative-control scan did not succeed"
NEG=$(echo "$r" | json_total_amount)
if [[ "$NEG" != "0.0" && "$NEG" != "0" ]]; then
    emit_fail "negative control non-zero (foreign addr matched $NEG)"
fi

# ── Step 6: fresh wallet + restore SAME seed + re-derive (assert match) ──
r=$(rpc createwallet '["recovered", false, true]')   # name, disable_priv=false, blank=true
log "createwallet recovered: $r"
echo "$r" | grep -q '"recovered"' || emit_fail "createwallet 'recovered' failed"

r=$(wrpc recovered sethdseed "[\"$SEED\"]")
log "sethdseed(recovered): $r"
echo "$r" | grep -q "$SEED" || emit_fail "sethdseed failed on recovered wallet"

R_BECH32=$(wrpc  recovered getnewaddress '["", "bech32"]'      | json_str_result)
R_LEGACY=$(wrpc  recovered getnewaddress '["", "legacy"]'      | json_str_result)
R_P2SH=$(wrpc    recovered getnewaddress '["", "p2sh-segwit"]' | json_str_result)
R_BECH32M=$(wrpc recovered getnewaddress '["", "bech32m"]'     | json_str_result)
log "recovered addrs: bech32=$R_BECH32 legacy=$R_LEGACY p2sh=$R_P2SH bech32m=$R_BECH32M"

[[ "$R_BECH32"  == "$A_BECH32"  ]] || emit_fail "bech32 re-derive mismatch ($R_BECH32 != $A_BECH32)"
[[ "$R_LEGACY"  == "$A_LEGACY"  ]] || emit_fail "legacy re-derive mismatch ($R_LEGACY != $A_LEGACY)"
[[ "$R_P2SH"    == "$A_P2SH"    ]] || emit_fail "p2sh-segwit re-derive mismatch ($R_P2SH != $A_P2SH)"
[[ "$R_BECH32M" == "$A_BECH32M" ]] || emit_fail "bech32m re-derive mismatch ($R_BECH32M != $A_BECH32M)"

# ── Step 7: scantxoutset AFTER (re-derived addrs) — assert == BEFORE ─────
SCAN_ARGS_AFTER="[\"start\", [\"addr($R_BECH32)\", \"addr($R_LEGACY)\", \"addr($R_P2SH)\", \"addr($R_BECH32M)\"]]"
r=$(rpc scantxoutset "$SCAN_ARGS_AFTER")
log "scantxoutset AFTER: $r"
echo "$r" | grep -q '"success":true' || emit_fail "scantxoutset AFTER did not succeed"
AFTER=$(echo "$r" | json_total_amount)
[[ -n "$AFTER" ]] || emit_fail "could not read AFTER total_amount"

if [[ "$AFTER" != "$BEFORE" ]]; then
    emit_fail "recovered total $AFTER != funded total $BEFORE"
fi

emit_pass "$BEFORE" "$AFTER"
