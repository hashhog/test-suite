#!/usr/bin/env bash
#
# hotbuns_recovery.sh — self-contained wallet-recovery regression test (regtest).
#
# Codifies the recovery green cell landed in hotbuns commit 271130b
# ("feat(wallet): createwallet mnemonic restore -> wallet recovery green").
#
# Recovery mechanism (hotbuns): `createwallet` with a BIP-39 mnemonic param
# (positions 8/9: mnemonic, mnemonic_passphrase). Supplying the SAME mnemonic on
# a fresh wallet deterministically re-derives byte-identical keys — hotbuns'
# seed-only wallet-recovery path (see src/rpc/server.ts createWallet +
# src/wallet/wallet.ts Wallet.create(config, mnemonic, passphrase)).
#
# Flow:
#   1. createwallet "w1" with FIXED mnemonic -> getnewaddress -> A1
#   2. generatetoaddress N blocks to A1 (coinbase funding)
#   3. scantxoutset addr(A1) -> record BEFORE total
#   4. unloadwallet w1, createwallet "w2" with SAME mnemonic -> getnewaddress -> A2
#   5. assert A2 == A1 (byte-identical re-derivation)
#   6. scantxoutset addr(A2) -> AFTER total ; assert AFTER == BEFORE
#   7. negative control: scantxoutset a foreign address -> must be 0
#
# Output: exactly ONE summary line on stdout, then exit.
#   PASS: RECOVERY hotbuns: PASS funded=<X> recovered=<X> addrs=match neg=0
#   FAIL: RECOVERY hotbuns: FAIL <short reason>
#
# Touches ONLY /tmp/recreg-hotbuns/ and ports 21504 (RPC) / 21534 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or live nodes.

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
DATADIR="/tmp/recreg-hotbuns"
RPC_PORT=21504
P2P_PORT=21534
LOGFILE="$DATADIR/node.log"

# Canonical BIP-39 test vector — checksum-valid, the exact mnemonic the hotbuns
# wallet unit tests use (src/wallet/wallet.test.ts:30 TEST_MNEMONIC) and the one
# the recovery green cell was verified against last session.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Number of coinbase-funding blocks. Any positive count works since we assert
# AFTER == BEFORE rather than a hardcoded amount; >100 keeps it well-funded.
FUND_BLOCKS=104

# A foreign regtest bech32 address the wallet does NOT control (negative control).
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""

# ── Logging / failure helpers ──────────────────────────────────────────────
log()  { echo "[recovery-hotbuns] $*" >&2; }

fail() {
    # Single clean summary line on stdout, everything else already went to stderr.
    echo "RECOVERY hotbuns: FAIL $*"
    exit 1
}

# ── Cleanup (trap on ANY exit) ──────────────────────────────────────────────
cleanup() {
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        # Give it up to 10s to exit gracefully, then SIGKILL.
        for _ in $(seq 1 10); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    rm -rf "$DATADIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── RPC helper ──────────────────────────────────────────────────────────────
# Cookie auth: hotbuns writes "__cookie__:<hex>" to {datadir}/.cookie on start
# (src/rpc/server.ts). Mirror smoke-harness.sh rpc_call: -u <cookie-contents>.
rpc() {
    local method=$1
    local params="${2:-[]}"
    local auth=""
    local candidate
    for candidate in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
        if [[ -f "$candidate" ]]; then
            auth="-u $(cat "$candidate")"
            break
        fi
    done
    local payload
    payload="{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
    # shellcheck disable=SC2086
    curl -s --max-time 30 $auth \
        --data-binary "$payload" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

# Extract a JSON string field's value (.result when result is a bare string,
# or .result.<key>). Uses bun's JSON.parse for robustness (the node ships bun).
json_get() {
    # $1 = JSON text, $2 = JS expression on the parsed object `o`
    local text=$1 expr=$2
    printf '%s' "$text" | bun -e '
        let s = "";
        for await (const chunk of Bun.stdin.stream()) s += new TextDecoder().decode(chunk);
        let o;
        try { o = JSON.parse(s); } catch (e) { process.stdout.write(""); process.exit(0); }
        let v;
        try { v = (function(o){ return ('"$expr"'); })(o); } catch (e) { v = undefined; }
        process.stdout.write(v === undefined || v === null ? "" : String(v));
    ' 2>/dev/null
}

# ── 0. Idempotent reset ─────────────────────────────────────────────────────
log "resetting scratch state (datadir + ports)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$DATADIR" 2>/dev/null || true
mkdir -p "$DATADIR"

command -v bun >/dev/null 2>&1 || fail "bun runtime not found on PATH"

# ── 1. Launch hotbuns on regtest (smoke-harness recipe) ─────────────────────
log "launching hotbuns regtest rpc=:$RPC_PORT p2p=:$P2P_PORT datadir=$DATADIR"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$DATADIR" \
        --port="$P2P_PORT" --rpcport="$RPC_PORT"
) >"$LOGFILE" 2>&1 &
NODE_PID=$!

# ── 2. Wait up to 30s for RPC ────────────────────────────────────────────────
log "waiting for RPC (pid $NODE_PID)"
ready=0
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
    if ! kill -0 "$NODE_PID" 2>/dev/null; then
        log "node process exited early; last log lines:"
        tail -n 20 "$LOGFILE" >&2 2>/dev/null || true
        fail "node exited before RPC came up"
    fi
    r=$(rpc getblockcount)
    if echo "$r" | grep -q '"result"'; then
        ready=1
        break
    fi
    sleep 1
done
[[ $ready -eq 1 ]] || fail "RPC did not respond within 30s"
log "RPC ready"

# ── 3. Create wallet w1 from FIXED mnemonic, derive A1 ──────────────────────
# createwallet params: [name, disable_priv, blank, passphrase, avoid_reuse,
#                       descriptors, load_on_startup, mnemonic, mnemonic_passphrase]
log "createwallet w1 from fixed mnemonic"
r=$(rpc createwallet "[\"w1\", false, false, \"\", false, true, false, \"$MNEMONIC\", \"\"]")
name=$(json_get "$r" "o.result && o.result.name")
[[ "$name" == "w1" ]] || fail "createwallet w1 failed: $(echo "$r" | head -c 200)"

A1=$(json_get "$(rpc getnewaddress)" "o.result")
[[ -n "$A1" ]] || fail "getnewaddress (A1) returned empty"
log "A1=$A1"

# ── 4. Fund A1 via coinbase ──────────────────────────────────────────────────
log "generatetoaddress $FUND_BLOCKS blocks to A1"
r=$(rpc generatetoaddress "[$FUND_BLOCKS, \"$A1\"]")
echo "$r" | grep -q '"result"' || fail "generatetoaddress failed: $(echo "$r" | head -c 200)"
height=$(json_get "$(rpc getblockcount)" "o.result")
[[ "$height" == "$FUND_BLOCKS" ]] || fail "expected height $FUND_BLOCKS, got ${height:-empty}"

# ── 5. scantxoutset BEFORE (record total funded to A1) ──────────────────────
log "scantxoutset BEFORE on addr($A1)"
r=$(rpc scantxoutset "[\"start\", [\"addr($A1)\"]]")
echo "$r" | grep -q '"success":true' || fail "scantxoutset(before) failed: $(echo "$r" | head -c 200)"
BEFORE=$(json_get "$r" "o.result && o.result.total_amount")
[[ -n "$BEFORE" ]] || fail "scantxoutset(before) returned no total_amount"
# Must actually be funded (> 0) or the test proves nothing.
case "$BEFORE" in
    0|0.0|0.00000000|"") fail "BEFORE total is zero — funding did not land (got '$BEFORE')" ;;
esac
log "BEFORE total_amount=$BEFORE"

# ── 6. Fresh wallet w2 from the SAME mnemonic, re-derive A2 ─────────────────
log "unloadwallet w1; createwallet w2 from SAME mnemonic"
rpc unloadwallet "[\"w1\"]" >/dev/null 2>&1 || true

r=$(rpc createwallet "[\"w2\", false, false, \"\", false, true, false, \"$MNEMONIC\", \"\"]")
name=$(json_get "$r" "o.result && o.result.name")
[[ "$name" == "w2" ]] || fail "createwallet w2 (restore) failed: $(echo "$r" | head -c 200)"

A2=$(json_get "$(rpc getnewaddress)" "o.result")
[[ -n "$A2" ]] || fail "getnewaddress (A2) returned empty"
log "A2=$A2"

# ── 7. Assert byte-identical re-derivation ───────────────────────────────────
[[ "$A2" == "$A1" ]] || fail "restored address mismatch: A1=$A1 A2=$A2"

# ── 8. scantxoutset AFTER (recovered total) ─────────────────────────────────
log "scantxoutset AFTER on addr($A2)"
r=$(rpc scantxoutset "[\"start\", [\"addr($A2)\"]]")
echo "$r" | grep -q '"success":true' || fail "scantxoutset(after) failed: $(echo "$r" | head -c 200)"
AFTER=$(json_get "$r" "o.result && o.result.total_amount")
[[ -n "$AFTER" ]] || fail "scantxoutset(after) returned no total_amount"
log "AFTER total_amount=$AFTER"

# ── 9. Assert AFTER == BEFORE (full recovery) ───────────────────────────────
[[ "$AFTER" == "$BEFORE" ]] || fail "recovered total $AFTER != funded total $BEFORE"

# ── 10. Negative control: foreign address must scan to 0 ─────────────────────
log "negative control: scantxoutset addr($FOREIGN_ADDR)"
r=$(rpc scantxoutset "[\"start\", [\"addr($FOREIGN_ADDR)\"]]")
echo "$r" | grep -q '"success":true' || fail "scantxoutset(neg) failed: $(echo "$r" | head -c 200)"
NEG=$(json_get "$r" "o.result && o.result.total_amount")
case "${NEG:-MISSING}" in
    0|0.0|0.00000000) NEG=0 ;;
    *) fail "negative control non-zero: foreign addr total=$NEG" ;;
esac
log "NEG total_amount=0 OK"

# ── Success — one clean summary line on stdout ──────────────────────────────
echo "RECOVERY hotbuns: PASS funded=$BEFORE recovered=$AFTER addrs=match neg=$NEG"
exit 0
