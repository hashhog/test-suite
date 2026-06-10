#!/usr/bin/env bash
#
# clearbit_recovery.sh — self-contained wallet-recovery regression test.
#
# Codifies the recovery GREEN cell landed in clearbit a339747
# ("feat(wallet): wire wallet manager + scantxoutset + sethdseed -> recovery
#  GREEN").  Proves, end to end on a throwaway regtest node, that a clearbit
# wallet funded with coinbase can be wiped and deterministically restored from
# a FIXED BIP-32 seed:
#
#     createwallet(blank) -> sethdseed(SEED) -> getnewaddress = A1
#       -> generatetoaddress (fund A1 with coinbase) -> scantxoutset = BEFORE
#       -> fresh wallet + sethdseed(SAME SEED) -> getnewaddress = A1' (must == A1)
#       -> scantxoutset = AFTER (must == BEFORE)
#       -> negative control: scan a different-seed address -> must == 0
#
# Recovery mechanism for clearbit is `sethdseed` (the EXACT RPC wired in the
# committed recovery code, src/rpc.zig::handleSetHdSeed + src/wallet.zig::
# setHdSeed).  clearbit's sethdseed takes a HEX seed (a pragmatic divergence
# from Core's WIF, documented in that commit) so a known seed restores
# byte-for-byte.
#
# Uniform interface for the assembled nightly runner:
#   - no required args; idempotent; cleans its own scratch + port on entry/exit
#   - emits exactly ONE summary line on stdout, everything else on stderr/log
#       PASS: RECOVERY clearbit: PASS funded=<X> recovered=<X> addrs=match neg=0
#       FAIL: RECOVERY clearbit: FAIL <short reason>
#   - exit 0 on PASS, exit 1 on FAIL
#
# SAFETY: only ever touches /tmp/recreg-clearbit/ and ports 21507/21537.
#         NEVER /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Fixed config (the recipe from tools/smoke-harness.sh + last session) ─────
IMPL="clearbit"
RPC_PORT=21507
P2P_PORT=21537
SCRATCH="/tmp/recreg-clearbit"
NETDIR="$SCRATCH/regtest"          # clearbit appends the network subdir
COOKIE_FILE="$NETDIR/.cookie"
LOG="$SCRATCH/node.log"
BASE="http://127.0.0.1:$RPC_PORT"

# The seed that worked last session (16-byte BIP-32 test seed, hex).
SEED="000102030405060708090a0b0c0d0e0f"
# A DIFFERENT seed for the negative control (a valid, decodable clearbit
# address that owns no UTXOs).
NEG_SEED="ffeeddccbbaa99887766554433221100"

# Resolve the binary the same way build-all.sh / smoke-harness.sh do.
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"

NODE_PID=""

# ── Logging: everything noisy goes to stderr; stdout stays clean ─────────────
log() { echo "[clearbit-recovery] $*" >&2; }

# ── One summary line + exit ──────────────────────────────────────────────────
pass() {
    # $1 funded $2 recovered
    echo "RECOVERY $IMPL: PASS funded=$1 recovered=$2 addrs=match neg=0"
    exit 0
}
fail() {
    echo "RECOVERY $IMPL: FAIL $*"
    exit 1
}

# ── Idempotent teardown (entry + trap-on-exit) ───────────────────────────────
kill_port() {
    # Port-kill removed (2026-06-10 fuser incident): wait briefly for OUR ports to be
    # released after the PID-scoped kill. NEVER kills by port.
    local __hp
    for __hp in "$RPC_PORT" "$P2P_PORT"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
}

cleanup() {
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill -TERM "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    kill_port
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── RPC helper: HTTP Basic with the cookie (__cookie__:<hex>) ────────────────
COOKIE=""
rpc() {
    # $1 = url path (e.g. "/" or "/wallet/w1"), $2 = method, $3 = params JSON
    local path="$1" method="$2" params="${3:-[]}"
    curl -s --max-time 30 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$BASE$path" 2>/dev/null
}

# Pull a "result" string value out of a JSON-RPC reply.
result_str() { grep -o '"result":"[^"]*"' | cut -d'"' -f4; }
# Pull total_amount (a float) out of a scantxoutset reply.
total_amount() { grep -o '"total_amount":[0-9.]*' | cut -d: -f2; }
# True if the reply carries a non-null error.
has_error() { grep -q '"error":{'; }

# ── Begin ────────────────────────────────────────────────────────────────────
log "starting; scratch=$SCRATCH rpc=$RPC_PORT p2p=$P2P_PORT"

[[ -x "$BIN" ]] || fail "binary not found at $BIN (build clearbit first)"

# Idempotent: clear any prior node + scratch BEFORE we start.
kill_port
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH" || fail "cannot create scratch $SCRATCH"

# ── Launch (smoke-harness.sh recipe) ─────────────────────────────────────────
"$BIN" --regtest --datadir="$SCRATCH" --port="$P2P_PORT" --rpcport="$RPC_PORT" \
    >"$LOG" 2>&1 &
NODE_PID=$!
log "launched pid $NODE_PID"

# Give the process a beat; bail early if it died immediately.
sleep 1
kill -0 "$NODE_PID" 2>/dev/null || fail "node exited immediately (see $LOG)"

# ── Wait for cookie + RPC (up to 30s) ────────────────────────────────────────
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
    if [[ -f "$COOKIE_FILE" ]]; then
        COOKIE="$(cat "$COOKIE_FILE" 2>/dev/null)"
        if [[ -n "$COOKIE" ]]; then
            r="$(rpc "/" getblockcount "[]")"
            echo "$r" | grep -q '"result"' && break
        fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node died during startup (see $LOG)"
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "no cookie at $COOKIE_FILE within 30s"
r="$(rpc "/" getblockcount "[]")"
echo "$r" | grep -q '"result"' || fail "RPC did not respond within 30s"
log "RPC ready ($r)"

# ── Step 1: create blank wallet, restore FIXED seed, derive A1 ───────────────
# createwallet must be addressed at "/" (the /wallet/<name> path 404s before
# the wallet exists).  Args: [name, disable_private_keys=false, blank=true].
r="$(rpc "/" createwallet '["w1",false,true]')"
echo "$r" | has_error && fail "createwallet w1: $r"
log "created blank wallet w1"

r="$(rpc "/wallet/w1" sethdseed "[true,\"$SEED\"]")"
echo "$r" | has_error && fail "sethdseed w1: $r"
log "sethdseed w1 ok"

A1="$(rpc "/wallet/w1" getnewaddress "[]" | result_str)"
[[ -n "$A1" ]] || fail "getnewaddress w1 returned empty"
log "derived A1=$A1"

# ── Step 2: fund A1 with coinbase (10 blocks -> 500 BTC) ─────────────────────
NBLOCKS=10
r="$(rpc "/" generatetoaddress "[$NBLOCKS,\"$A1\"]")"
echo "$r" | has_error && fail "generatetoaddress: $r"
echo "$r" | grep -q '"result":\[' || fail "generatetoaddress: no block hashes ($r)"
log "mined $NBLOCKS coinbase blocks to A1"

# ── Step 3: scantxoutset BEFORE ──────────────────────────────────────────────
r="$(rpc "/" scantxoutset "[\"start\",[\"addr($A1)\"]]")"
echo "$r" | has_error && fail "scantxoutset BEFORE: $r"
echo "$r" | grep -q '"success":true' || fail "scantxoutset BEFORE not success ($r)"
BEFORE="$(echo "$r" | total_amount)"
[[ -n "$BEFORE" ]] || fail "scantxoutset BEFORE: could not parse total_amount ($r)"
log "BEFORE total_amount=$BEFORE"
# Funding must be non-zero, else the test proves nothing.
case "$BEFORE" in
    0|0.0|0.00000000|"") fail "funded amount is zero (BEFORE=$BEFORE) — funding step did not take" ;;
esac

# ── Step 4: fresh wallet, restore SAME seed, re-derive ───────────────────────
r="$(rpc "/" createwallet '["w2",false,true]')"
echo "$r" | has_error && fail "createwallet w2: $r"
r="$(rpc "/wallet/w2" sethdseed "[true,\"$SEED\"]")"
echo "$r" | has_error && fail "sethdseed w2 (restore): $r"
A1b="$(rpc "/wallet/w2" getnewaddress "[]" | result_str)"
[[ -n "$A1b" ]] || fail "getnewaddress w2 returned empty"
log "re-derived A1b=$A1b"

# Assert byte-identical re-derivation.
[[ "$A1b" == "$A1" ]] || fail "address mismatch after restore: orig=$A1 restored=$A1b"
log "address match: restored == original"

# ── Step 5: scantxoutset AFTER (via the re-derived address) ──────────────────
r="$(rpc "/" scantxoutset "[\"start\",[\"addr($A1b)\"]]")"
echo "$r" | has_error && fail "scantxoutset AFTER: $r"
echo "$r" | grep -q '"success":true' || fail "scantxoutset AFTER not success ($r)"
AFTER="$(echo "$r" | total_amount)"
[[ -n "$AFTER" ]] || fail "scantxoutset AFTER: could not parse total_amount ($r)"
log "AFTER total_amount=$AFTER"

# Assert recovered == funded.
[[ "$AFTER" == "$BEFORE" ]] || fail "recovered != funded: before=$BEFORE after=$AFTER"

# ── Step 6: negative control — a different-seed address must own nothing ─────
r="$(rpc "/" createwallet '["wneg",false,true]')"
echo "$r" | has_error && fail "createwallet wneg: $r"
r="$(rpc "/wallet/wneg" sethdseed "[true,\"$NEG_SEED\"]")"
echo "$r" | has_error && fail "sethdseed wneg: $r"
FADDR="$(rpc "/wallet/wneg" getnewaddress "[]" | result_str)"
[[ -n "$FADDR" ]] || fail "getnewaddress wneg returned empty"
[[ "$FADDR" != "$A1" ]] || fail "negative-control address collided with A1 ($FADDR)"
log "negative-control addr=$FADDR"

r="$(rpc "/" scantxoutset "[\"start\",[\"addr($FADDR)\"]]")"
echo "$r" | has_error && fail "scantxoutset NEG: $r"
echo "$r" | grep -q '"success":true' || fail "scantxoutset NEG not success ($r)"
NEG="$(echo "$r" | total_amount)"
log "NEG total_amount=$NEG"
case "$NEG" in
    0|0.0|0.00000000) : ;;  # expected
    *) fail "negative control found funds: foreign addr total_amount=$NEG (expected 0)" ;;
esac

# ── All assertions passed ────────────────────────────────────────────────────
log "all checks passed: funded=$BEFORE recovered=$AFTER addrs=match neg=$NEG"
pass "$BEFORE" "$AFTER"
