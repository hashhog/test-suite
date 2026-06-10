#!/usr/bin/env bash
# =============================================================================
# camlcoin wallet-recovery regression test  (nightly check)
# =============================================================================
# Codifies the recovery green cell landed in camlcoin f9f5fc4
# ("feat(wallet): scantxoutset + sethdseed -> wallet recovery GREEN").
#
# Proven recovery flow (regtest, self-contained):
#   1. sethdseed <FIXED hex seed>            -> deterministic HD master key
#   2. getnewaddress                         -> A1 (bech32 / bcrt1 p2wpkh)
#   3. generatetoaddress 101 -> A1           -> 101 mature coinbase outputs
#   4. scantxoutset BEFORE (addr(A1))        -> record total_amount
#   5. sethdseed <SAME seed>                 -> fresh-wallet recovery
#        (set_hd_seed clears the keypool + resets every derivation index,
#         exactly Core's CWallet::SetHDSeed + newkeypool flush; re-deriving
#         from index 0 reproduces the original address sequence)
#   6. getnewaddress                         -> A1' MUST be byte-identical to A1
#   7. scantxoutset AFTER (addr(A1))         -> total_amount MUST == BEFORE
#   8. negative control: scantxoutset on a FOREIGN addr (derived from a
#        different seed) MUST succeed with total_amount == 0
#
# Uniform runner interface (the assembled recovery runner greps stdout):
#   on success: RECOVERY camlcoin: PASS funded=<X> recovered=<X> addrs=match neg=0   (exit 0)
#   on failure: RECOVERY camlcoin: FAIL <short reason>                               (exit 1)
# All noisy output goes to stderr / the log; stdout carries ONLY the summary.
#
# Ports / scratch dir are dedicated to this test. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.
# =============================================================================

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ---- fixed config -----------------------------------------------------------
NODE="camlcoin"
BASEDIR="${HASHHOG_ROOT}"
BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
DATADIR="/tmp/recreg-camlcoin"
RPC_PORT=21505
P2P_PORT=21535
RPC_URL="http://127.0.0.1:${RPC_PORT}/"
LOG="$DATADIR/recovery-test.log"

# Fixed BIP-32 seed (the value used last session: the classic
# 00..1f test vector). Restoring this seed must always reproduce the same
# addresses, which is the whole point of the recovery guarantee.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
# A second, distinct seed used only to mint a VALID foreign address for the
# negative control (its UTXO total against the funded chain must be 0).
FOREIGN_SEED="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

NODE_PID=""

# ---- output helpers ---------------------------------------------------------
# Everything except the final summary line goes to stderr so the runner can
# grep a clean single PASS/FAIL line off stdout.
logmsg() { echo "[recreg:$NODE] $*" >&2; }

pass() {
    # $1 funded  $2 recovered
    echo "RECOVERY ${NODE}: PASS funded=$1 recovered=$2 addrs=match neg=0"
    exit 0
}

fail() {
    echo "RECOVERY ${NODE}: FAIL $*"
    exit 1
}

# ---- cleanup (runs on ANY exit, incl. signals) ------------------------------
cleanup() {
    if [[ -n "${NODE_PID:-}" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    pkill -f "recreg-camlcoin" 2>/dev/null || true
    rm -rf "$DATADIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; trap - INT;  kill -INT  $$' INT
trap 'cleanup; trap - TERM; kill -TERM $$' TERM
trap 'cleanup; trap - HUP;  kill -HUP  $$' HUP

# ---- RPC helper (cookie auth) ----------------------------------------------
# camlcoin writes "__cookie__:<hex>" to $DATADIR/.cookie at startup and
# authenticates Basic-auth against it (lib/cli.ml / lib/rpc.ml check_auth).
rpc() {
    local method="$1" params="${2:-[]}"
    local cookie=""
    [[ -f "$DATADIR/.cookie" ]] && cookie="-u $(cat "$DATADIR/.cookie")"
    # shellcheck disable=SC2086
    curl -s --max-time 30 $cookie \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$RPC_URL" 2>>"$LOG"
}

# Extract the "result" JSON string value of getnewaddress / a bcrt1 address.
extract_addr() {
    grep -o 'bcrt1[ac-hj-np-z02-9]*' | head -1
}

# Extract "total_amount":N.NNNNNNNN -> integer satoshis (avoids float compare).
extract_total_sats() {
    # value like 5050.00000000 -> strip the dot, keep 8 decimal places.
    local v
    v=$(grep -o '"total_amount":[0-9]*\.[0-9]*' | head -1 | grep -o '[0-9]*\.[0-9]*')
    [[ -z "$v" ]] && { echo ""; return; }
    local int frac
    int="${v%.*}"
    frac="${v#*.}"
    # pad/truncate frac to 8 digits
    frac="${frac}00000000"
    frac="${frac:0:8}"
    echo "${int}${frac}" | sed 's/^0*\([0-9]\)/\1/'
}

# =============================================================================
# 0. idempotent reset: kill stale node on our ports + wipe scratch datadir
# =============================================================================
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
pkill -f "recreg-camlcoin" 2>/dev/null || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"
: > "$LOG"

[[ -x "$BIN" ]] || fail "binary not found at $BIN"

# =============================================================================
# 1. launch camlcoin on regtest (smoke-harness recipe)
# =============================================================================
logmsg "launching $BIN on regtest (rpc=$RPC_PORT p2p=$P2P_PORT datadir=$DATADIR)"
"$BIN" --network regtest --datadir "$DATADIR" \
    --port "$P2P_PORT" --rpcport "$RPC_PORT" \
    >>"$LOG" 2>&1 &
NODE_PID=$!

if ! kill -0 "$NODE_PID" 2>/dev/null; then
    fail "node process exited immediately (see $LOG)"
fi

# ---- wait up to 40s for RPC -------------------------------------------------
rpc_up=0
for _ in $(seq 1 40); do
    if [[ -f "$DATADIR/.cookie" ]]; then
        r=$(rpc getblockcount)
        if echo "$r" | grep -q '"result"'; then rpc_up=1; break; fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node died during startup (see $LOG)"
    sleep 1
done
[[ $rpc_up -eq 1 ]] || fail "RPC did not respond within 40s"
logmsg "RPC ready"

# =============================================================================
# 2. restore wallet from the FIXED seed + derive A1
# =============================================================================
r=$(rpc sethdseed "[true,\"$SEED\"]")
echo "$r" | grep -q '"seed_hex"' || fail "sethdseed(initial) failed: $r"

A1=$(rpc getnewaddress | extract_addr)
[[ -n "$A1" ]] || fail "getnewaddress(A1) returned no bcrt1 address"
logmsg "A1=$A1"

# =============================================================================
# 3. fund A1 with 101 coinbase blocks (>100 so the first is mature)
# =============================================================================
r=$(rpc generatetoaddress "[101,\"$A1\"]")
echo "$r" | grep -q '"result":\[' || fail "generatetoaddress failed: $r"

height=$(rpc getblockcount | grep -o '"result":[0-9]*' | grep -o '[0-9]*')
[[ "$height" == "101" ]] || fail "expected height 101 after funding, got ${height:-none}"

# =============================================================================
# 4. scantxoutset BEFORE  (record funded total)
# =============================================================================
before_json=$(rpc scantxoutset "[\"start\",[\"addr($A1)\"]]")
echo "$before_json" | grep -q '"success":true' || fail "scantxoutset BEFORE not success: $before_json"
FUNDED_SATS=$(echo "$before_json" | extract_total_sats)
[[ -n "$FUNDED_SATS" && "$FUNDED_SATS" != "0" ]] || fail "scantxoutset BEFORE total is empty/zero (funding did not land)"
logmsg "funded total (sats) = $FUNDED_SATS"

# =============================================================================
# 5. RECOVERY: re-seed the SAME seed -> fresh keypool, indices reset
#    (this is the seed-only recovery path: keypool cleared, re-derive from 0)
# =============================================================================
r=$(rpc sethdseed "[true,\"$SEED\"]")
echo "$r" | grep -q '"seed_hex"' || fail "sethdseed(recovery) failed: $r"

# =============================================================================
# 6. re-derive A1' -> MUST be byte-identical to A1
# =============================================================================
A1R=$(rpc getnewaddress | extract_addr)
[[ -n "$A1R" ]] || fail "getnewaddress(A1') returned no bcrt1 address"
[[ "$A1R" == "$A1" ]] || fail "re-derived address mismatch: A1=$A1 A1'=$A1R"
logmsg "re-derived A1' == A1 ($A1R)"

# =============================================================================
# 7. scantxoutset AFTER -> total MUST equal the funded BEFORE total
# =============================================================================
after_json=$(rpc scantxoutset "[\"start\",[\"addr($A1R)\"]]")
echo "$after_json" | grep -q '"success":true' || fail "scantxoutset AFTER not success: $after_json"
RECOVERED_SATS=$(echo "$after_json" | extract_total_sats)
[[ -n "$RECOVERED_SATS" ]] || fail "scantxoutset AFTER total is empty"
[[ "$RECOVERED_SATS" == "$FUNDED_SATS" ]] \
    || fail "recovered total $RECOVERED_SATS != funded total $FUNDED_SATS"
logmsg "recovered total (sats) = $RECOVERED_SATS (== funded)"

# =============================================================================
# 8. negative control: a VALID foreign address (different seed) must scan to 0
# =============================================================================
r=$(rpc sethdseed "[true,\"$FOREIGN_SEED\"]")
echo "$r" | grep -q '"seed_hex"' || fail "sethdseed(foreign) failed: $r"
FADDR=$(rpc getnewaddress | extract_addr)
[[ -n "$FADDR" ]] || fail "could not derive a foreign address for neg control"
neg_json=$(rpc scantxoutset "[\"start\",[\"addr($FADDR)\"]]")
echo "$neg_json" | grep -q '"success":true' || fail "neg-control scan not success: $neg_json"
NEG_SATS=$(echo "$neg_json" | extract_total_sats)
[[ "$NEG_SATS" == "0" || -z "$NEG_SATS" ]] \
    || fail "negative control found funds for foreign addr ($NEG_SATS sats)"
logmsg "negative control: foreign addr $FADDR -> 0 (as expected)"

# restore the canonical seed so the wallet is left in the recovered state
rpc sethdseed "[true,\"$SEED\"]" >/dev/null 2>&1 || true

# =============================================================================
# success
# =============================================================================
# Report BTC (whole) for readability: sats / 1e8, integer part.
FUNDED_BTC=$(( FUNDED_SATS / 100000000 ))
RECOVERED_BTC=$(( RECOVERED_SATS / 100000000 ))
pass "$FUNDED_BTC" "$RECOVERED_BTC"
