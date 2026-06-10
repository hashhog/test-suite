#!/usr/bin/env bash
#
# blockbrew_recovery.sh — wallet-recovery regression test for blockbrew (Go).
#
# Codifies the recovery green cell landed last session into a permanent,
# self-contained, repeatable check. Proves blockbrew can RESTORE a wallet
# from a fixed BIP-39 mnemonic and re-derive byte-identical keys/addresses
# so that funds are recoverable after total wallet-file loss.
#
# Recovery mechanism (confirmed from the committed code in
# blockbrew/internal/rpc/multiwallet_methods.go + internal/wallet/manager.go):
#   createwallet(name, disable_private_keys, blank, passphrase, avoid_reuse,
#                descriptors, load_on_startup, external_signer,
#                seed_passphrase, MNEMONIC)
# The 10th positional arg (index 9) is a BIP-39 mnemonic to RESTORE from —
# blockbrew's non-Core seed-only recovery extension. Same words always
# re-derive byte-identical keys+addresses. Default address type is P2WPKH
# (bech32). RPC auth is cookie-based at <datadir>/regtest/.cookie.
#
# FLOW:
#   1. Launch blockbrew on regtest (scratch datadir, dedicated ports).
#   2. createwallet w1 RESTORED from FIXED mnemonic.
#   3. getnewaddress on w1 -> A1.
#   4. generatetoaddress 101 -> A1 (fund coinbase, mature 1 block).
#   5. scantxoutset addr(A1) BEFORE -> record total.
#   6. Unload w1 (simulate disk loss), createwallet w2 RESTORED from SAME mnemonic.
#   7. getnewaddress on w2 -> A1' ; ASSERT A1' == A1 (byte-identical).
#   8. scantxoutset addr(A1') AFTER -> ASSERT AFTER == BEFORE.
#   9. Negative control: scantxoutset on a foreign addr -> ASSERT 0.
#
# OUTPUT: exactly one summary line on stdout, all noise on stderr / log.
#   PASS: RECOVERY blockbrew: PASS funded=<X> recovered=<X> addrs=match neg=0
#   FAIL: RECOVERY blockbrew: FAIL <short reason>
#
# Touches ONLY /tmp/recreg-blockbrew/ and ports 21503 (RPC) / 21533 (P2P).
# Never touches /data/nvme1/, testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
BIN="$BASEDIR/blockbrew/blockbrew"
DATADIR="/tmp/recreg-blockbrew"
RPC_PORT=21503
P2P_PORT=21533
LOG="/tmp/recreg-blockbrew.log"
URL="http://127.0.0.1:${RPC_PORT}/"

# Fixed BIP-39 test mnemonic (the standard all-"abandon" vector; valid
# checksum, used in blockbrew's own w111 wallet tests). Deterministic seed.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
# Foreign address for the negative control (a different valid regtest bech32
# addr that the seed does not own).
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""

# ── Single-line failure exit ──────────────────────────────────────────────
fail() {
    echo "RECOVERY blockbrew: FAIL $*"
    exit 1
}

# ── Cleanup trap: always kill the node + remove scratch datadir ────────────
cleanup() {
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    rm -rf "$DATADIR" "$LOG" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Pre-flight: clean slate (idempotent) ───────────────────────────────────
[[ -x "$BIN" ]] || fail "blockbrew binary not found/executable at $BIN"
command -v curl  >/dev/null 2>&1 || fail "curl not available"
command -v python3 >/dev/null 2>&1 || fail "python3 not available"

# Kill any prior node still holding our ports, wipe scratch datadir.
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR" "$LOG"
mkdir -p "$DATADIR"

# ── Launch (smoke-harness recipe) ──────────────────────────────────────────
"$BIN" \
    -network=regtest -datadir="$DATADIR" \
    -listen="127.0.0.1:${P2P_PORT}" -rpcbind="127.0.0.1:${RPC_PORT}" \
    -maxoutbound=0 -nolisten \
    >"$LOG" 2>&1 &
NODE_PID=$!

# ── RPC helpers ────────────────────────────────────────────────────────────
# Cookie is written to <datadir>/regtest/.cookie shortly after start.
COOKIE_FILE="$DATADIR/regtest/.cookie"

rpc_raw() {  # rpc_raw <url> <method> <params-json>
    local cookie=""
    [[ -f "$COOKIE_FILE" ]] && cookie="$(cat "$COOKIE_FILE")"
    curl -s --max-time 20 ${cookie:+-u "$cookie"} \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" \
        "$1" 2>/dev/null
}
rpc()  { rpc_raw "$URL" "$1" "$2"; }                       # node-level
rpcw() { rpc_raw "${URL}wallet/$1" "$2" "$3"; }            # wallet-scoped

# Extract .result.<path> from a JSON-RPC reply; empty string on error/missing.
jget() {  # jget <python-expr-on-d> ; reads stdin
    python3 -c '
import sys, json
try:
    obj = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
if obj.get("error"):
    print(""); sys.exit(0)
d = obj.get("result")
try:
    print(eval(sys.argv[1]))
except Exception:
    print("")
' "$1"
}

# ── Wait for RPC (getblockcount) up to 30s ─────────────────────────────────
deadline=$(( $(date +%s) + 30 ))
ready=0
while (( $(date +%s) < deadline )); do
    if ! kill -0 "$NODE_PID" 2>/dev/null; then
        fail "node exited during startup (see $LOG)"
    fi
    r=$(rpc getblockcount "[]")
    if echo "$r" | grep -q '"result"'; then ready=1; break; fi
    sleep 1
done
(( ready == 1 )) || fail "RPC did not come up within 30s"

# ── 1. Create wallet w1 RESTORED from fixed mnemonic ───────────────────────
# args: name, disable_private_keys, blank, passphrase, avoid_reuse,
#       descriptors, load_on_startup, external_signer, seed_passphrase, mnemonic
CW_PARAMS="[\"w1\", false, false, \"\", false, true, false, \"\", \"\", \"$MNEMONIC\"]"
r=$(rpc createwallet "$CW_PARAMS")
name=$(echo "$r" | jget "d['name']")
[[ "$name" == "w1" ]] || fail "createwallet w1 (restore) failed: $r"

# ── 2. getnewaddress -> A1 ─────────────────────────────────────────────────
A1=$(rpcw w1 getnewaddress "[]" | jget "d")
[[ -n "$A1" ]] || fail "getnewaddress on w1 returned empty"
case "$A1" in
    bcrt1*) : ;;  # expected P2WPKH bech32 on regtest
    *) fail "A1 not a regtest bech32 address: $A1" ;;
esac

# ── 3. Fund A1: generatetoaddress 101 blocks (coinbase + maturity) ─────────
r=$(rpc generatetoaddress "[101, \"$A1\"]")
nblocks=$(echo "$r" | jget "len(d)")
[[ "$nblocks" == "101" ]] || fail "generatetoaddress did not mine 101 blocks (got '$nblocks'): $(echo "$r" | head -c 200)"

# ── 4. scantxoutset BEFORE ─────────────────────────────────────────────────
r=$(rpc scantxoutset "[\"start\", [\"addr($A1)\"]]")
BEFORE=$(echo "$r" | jget "repr(d['total_amount'])")
[[ -n "$BEFORE" ]] || fail "scantxoutset BEFORE failed: $(echo "$r" | head -c 200)"
# Sanity: funding must be non-zero, otherwise the test proves nothing.
nonzero=$(echo "$r" | jget "1 if float(d['total_amount']) > 0 else 0")
[[ "$nonzero" == "1" ]] || fail "scantxoutset BEFORE total is zero (funding did not register): $BEFORE"

# ── 5. Simulate loss: unload w1, restore FRESH wallet w2 from SAME seed ────
r=$(rpc unloadwallet "[\"w1\"]")
echo "$r" | grep -q '"error":null' || fail "unloadwallet w1 failed: $r"

CW2_PARAMS="[\"w2\", false, false, \"\", false, true, false, \"\", \"\", \"$MNEMONIC\"]"
r=$(rpc createwallet "$CW2_PARAMS")
name=$(echo "$r" | jget "d['name']")
[[ "$name" == "w2" ]] || fail "createwallet w2 (restore SAME seed) failed: $r"

# ── 6. Re-derive address; ASSERT byte-identical to A1 ──────────────────────
A1P=$(rpcw w2 getnewaddress "[]" | jget "d")
[[ -n "$A1P" ]] || fail "getnewaddress on restored w2 returned empty"
[[ "$A1P" == "$A1" ]] || fail "re-derived address mismatch: w1=$A1 w2=$A1P"

# ── 7. scantxoutset AFTER; ASSERT AFTER == BEFORE ──────────────────────────
r=$(rpc scantxoutset "[\"start\", [\"addr($A1P)\"]]")
AFTER=$(echo "$r" | jget "repr(d['total_amount'])")
[[ -n "$AFTER" ]] || fail "scantxoutset AFTER failed: $(echo "$r" | head -c 200)"
[[ "$AFTER" == "$BEFORE" ]] || fail "recovered total != funded total (before=$BEFORE after=$AFTER)"

# ── 8. Negative control: foreign address must scan to 0 ────────────────────
r=$(rpc scantxoutset "[\"start\", [\"addr($FOREIGN_ADDR)\"]]")
NEG=$(echo "$r" | jget "repr(d['total_amount'])")
[[ -n "$NEG" ]] || fail "negative-control scantxoutset failed: $(echo "$r" | head -c 200)"
is_zero=$(echo "$r" | jget "1 if float(d['total_amount']) == 0 else 0")
[[ "$is_zero" == "1" ]] || fail "negative control non-zero (foreign addr owned funds?): $NEG"

# ── Success ────────────────────────────────────────────────────────────────
echo "RECOVERY blockbrew: PASS funded=${BEFORE} recovered=${AFTER} addrs=match neg=0"
exit 0
