#!/usr/bin/env bash
# ============================================================================
# nimrod_recovery.sh — wallet-recovery regression test for nimrod (regtest)
# ============================================================================
# Codifies the recovery green cell landed in nimrod commit 64462fa
# ("feat(wallet): sethdseed (restore-from-seed) -> wallet recovery green")
# into a permanent, self-contained nightly check.
#
# Restore mechanism (nimrod): the `sethdseed` RPC. It accepts a raw hex BIP-32
# seed (16..64 bytes) OR a BIP-39 mnemonic, runs it through
# HMAC-SHA512(key="Bitcoin seed") and re-derives the whole BIP-84 tree, so the
# same seed yields byte-identical addresses. See nimrod/src/wallet/wallet.nim
# (setHdSeed) and nimrod/src/rpc/server.nim (handleSetHdSeed).
#
# Flow:
#   create wallet -> sethdseed(FIXED hex seed) -> getnewaddress (bech32) = A1
#   -> generatetoaddress (fund coinbase to A1) -> scantxoutset addr(A1) = BEFORE
#   -> fresh wallet -> sethdseed(SAME seed) -> getnewaddress = A1' (assert == A1)
#   -> scantxoutset addr(A1') = AFTER (assert AFTER == BEFORE)
#   -> negative control: scantxoutset on a foreign address must total 0.
#
# STRICT UNIFORM INTERFACE: no required args, set -uo pipefail, idempotent,
# trap-based cleanup, exactly ONE summary line on stdout:
#   PASS: RECOVERY nimrod: PASS funded=<X> recovered=<X> addrs=match neg=0
#   FAIL: RECOVERY nimrod: FAIL <short reason>
# All noisy output goes to stderr / the log so stdout stays grep-clean.
#
# ⚠️ Touches ONLY /tmp/recreg-nimrod/ and ports 39601 (RPC) / 39631 (P2P).
#    Never touches /data/nvme1/, testnet4-data/, or any live node.
# ============================================================================
set -uo pipefail

# ── Config ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NIMROD_BIN="$BASEDIR/nimrod/bin/nimrod"

DATADIR="/tmp/recreg-nimrod"
RPC_PORT=39601
P2P_PORT=39631
NETWORK="regtest"
COOKIE="$DATADIR/$NETWORK/.cookie"
LOG="$DATADIR/node.log"

# FIXED seed that worked last session: a known 32-byte raw BIP-32 hex seed.
# Determinism is the whole point — the same seed must regenerate the same
# addresses regardless of when/where the test runs.
FIXED_SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
# A DIFFERENT fixed seed used to derive the negative-control address. Its
# address is guaranteed valid for the same wallet/HRP yet never funded, so
# scantxoutset on it must total 0. (Deriving the control rather than
# hard-coding a HRP-specific string keeps the test HRP-agnostic — nimrod's
# regtest wallet emits the testnet `tb1` HRP, a known nimrod quirk.)
FOREIGN_SEED="ffffeeeeddddccccbbbbaaaa999988887777666655554444333322221111ffff"

NODE_PID=""

# ── Helpers (everything noisy → stderr) ──────────────────────────────────
log() { echo "[recreg-nimrod] $*" >&2; }

fail() {
    # $1 = short reason
    echo "RECOVERY nimrod: FAIL $1"
    exit 1
}

cleanup() {
    local rc=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        local w=0
        while (( w < 15 )) && kill -0 "$NODE_PID" 2>/dev/null; do
            sleep 1; (( w++ ))
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    # Defensive: free our ports in case a stray child lingers.
    fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
    fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
    rm -rf "$DATADIR" 2>/dev/null || true
    return $rc
}
trap cleanup EXIT INT TERM

# Kill anything already bound to our ports, then wipe scratch datadir.
kill_stale() {
    fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
    fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
    sleep 1
    rm -rf "$DATADIR" 2>/dev/null || true
    mkdir -p "$DATADIR"
}

# rpc <method> [params-json]  → prints raw response to stdout
rpc() {
    local method=$1 params="${2:-[]}"
    local auth=""
    [[ -f "$COOKIE" ]] && auth="-u $(cat "$COOKIE")"
    local payload="{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
    # shellcheck disable=SC2086
    curl -s --max-time 30 $auth \
        -H 'content-type: text/plain' \
        --data-binary "$payload" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

# Extract a (dotted) field from a JSON blob, robust against ordering/whitespace.
# JSON is passed on argv[1], the dotted path on argv[2]. Empty path => whole blob.
# Usage: jget '<json>' '<dotted.path>'
jget() {
    JBLOB="$1" JPATH="$2" python3 -c '
import os, json
raw = os.environ["JBLOB"]
path = os.environ["JPATH"]
try:
    cur = json.loads(raw)
except Exception:
    raise SystemExit(0)
for part in path.split("."):
    if part == "":
        continue
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        raise SystemExit(0)
if isinstance(cur, (dict, list)):
    print(json.dumps(cur))
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("")
else:
    print(cur)
'
}

# Pull the top-level "result" object out of a JSON-RPC response as a JSON blob.
rpc_result() {
    JBLOB="$1" python3 -c '
import os, json
try:
    print(json.dumps(json.loads(os.environ["JBLOB"]).get("result")))
except Exception:
    print("null")
'
}

# Pull the top-level "result" as a bare scalar string (for getnewaddress etc.).
rpc_result_str() {
    JBLOB="$1" python3 -c '
import os, json
try:
    r = json.loads(os.environ["JBLOB"]).get("result")
    print("" if r is None else r)
except Exception:
    print("")
'
}

wait_for_rpc() {
    local deadline=$(( $(date +%s) + 40 ))
    while (( $(date +%s) < deadline )); do
        local r
        r=$(rpc getblockcount)
        if echo "$r" | grep -q '"result"'; then
            return 0
        fi
        # bail early if the node died
        if [[ -n "$NODE_PID" ]] && ! kill -0 "$NODE_PID" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

# ── 0. Preconditions ──────────────────────────────────────────────────────
[[ -x "$NIMROD_BIN" ]] || fail "nimrod binary not found at $NIMROD_BIN"
command -v curl >/dev/null 2>&1   || fail "curl not available"
command -v python3 >/dev/null 2>&1 || fail "python3 not available"

# ── 1. Idempotent reset + launch ──────────────────────────────────────────
kill_stale
log "launching nimrod regtest (rpc=$RPC_PORT p2p=$P2P_PORT datadir=$DATADIR)"
"$NIMROD_BIN" --network="$NETWORK" --datadir="$DATADIR" \
    --port="$P2P_PORT" --rpcport="$RPC_PORT" start \
    >"$LOG" 2>&1 &
NODE_PID=$!

if ! kill -0 "$NODE_PID" 2>/dev/null; then
    fail "node process exited immediately (see $LOG)"
fi

if ! wait_for_rpc; then
    fail "RPC did not come up within 40s (see $LOG)"
fi
log "RPC ready"

# Sanity: fresh regtest must be at height 0 (getblockcount returns a bare int).
H0=$(rpc_result_str "$(rpc getblockcount)")
[[ "$H0" == "0" ]] || log "warning: initial height is '$H0' (expected 0)"

# ── 2. Create wallet + inject FIXED seed (restore mechanism: sethdseed) ────
# sethdseed is THE restore-from-seed RPC added in nimrod 64462fa. It must be
# present — refuse to lie green on a stale binary that lacks it.
log "createwallet wA"
r=$(rpc createwallet '["wA"]')
echo "$r" | grep -q '"result"' || fail "createwallet wA failed: $(echo "$r" | head -c200)"

log "sethdseed (fixed seed) on wA"
r=$(rpc sethdseed "[true, \"$FIXED_SEED\"]")
if echo "$r" | grep -qi 'method not found'; then
    fail "sethdseed RPC missing — rebuild nimrod (needs commit 64462fa)"
fi
echo "$r" | grep -q '"error":null' || fail "sethdseed wA failed: $(echo "$r" | head -c200)"

# ── 3. Derive A1 (bech32 / P2WPKH — nimrod default script) ─────────────────
log "getnewaddress wA"
r=$(rpc getnewaddress '[""]')
A1=$(rpc_result_str "$r")
# HRP-agnostic: nimrod regtest emits the testnet "tb1" bech32 HRP (a known
# nimrod quirk). Accept any bech32-style segwit address (tb1 / bcrt1 / bc1) —
# the recovery semantics (determinism + balance) are what matter, not the HRP.
[[ -n "$A1" && "$A1" == *1q* ]] || fail "getnewaddress A1 invalid: '$A1' (resp=$(echo "$r" | head -c200))"
log "A1=$A1"

# ── 4. Fund A1 with coinbase via generatetoaddress ────────────────────────
log "generatetoaddress 101 -> A1 (mature a coinbase)"
r=$(rpc generatetoaddress "[101, \"$A1\"]")
echo "$r" | grep -q '"result"' || fail "generatetoaddress failed: $(echo "$r" | head -c200)"

# ── 5. scantxoutset BEFORE wipe — record funded total ──────────────────────
log "scantxoutset addr($A1) BEFORE"
r=$(rpc scantxoutset "[\"start\", [\"addr($A1)\"]]")
echo "$r" | grep -q '"result"' || fail "scantxoutset BEFORE failed: $(echo "$r" | head -c200)"
RES=$(rpc_result "$r")
FUNDED=$(jget "$RES" "total_amount")
SUCCESS=$(jget "$RES" "success")
[[ "$SUCCESS" == "true" ]] || fail "scantxoutset BEFORE not successful"
[[ -n "$FUNDED" ]] || fail "scantxoutset BEFORE returned no total_amount"
# Must have found a non-zero balance, else the fund step silently no-op'd.
python3 -c "import sys; sys.exit(0 if float('$FUNDED')>0 else 1)" \
    || fail "funded total is zero before wipe (funded=$FUNDED)"
log "BEFORE funded=$FUNDED"

# ── 6. Fresh wallet + restore SAME seed → re-derive ────────────────────────
log "unload wA, create fresh wB"
rpc unloadwallet '["wA"]' >/dev/null 2>&1 || true
r=$(rpc createwallet '["wB"]')
echo "$r" | grep -q '"result"' || fail "createwallet wB failed: $(echo "$r" | head -c200)"

log "sethdseed (SAME seed) on wB"
r=$(rpc sethdseed "[true, \"$FIXED_SEED\"]")
echo "$r" | grep -q '"error":null' || fail "sethdseed wB failed: $(echo "$r" | head -c200)"

log "getnewaddress wB (must re-derive identically)"
r=$(rpc getnewaddress '[""]')
A1B=$(rpc_result_str "$r")
[[ -n "$A1B" ]] || fail "getnewaddress after restore returned empty: $(echo "$r" | head -c200)"
log "A1B=$A1B"

if [[ "$A1B" != "$A1" ]]; then
    fail "re-derived address mismatch: A1=$A1 A1B=$A1B"
fi

# ── 7. scantxoutset AFTER — must equal BEFORE ──────────────────────────────
log "scantxoutset addr($A1B) AFTER"
r=$(rpc scantxoutset "[\"start\", [\"addr($A1B)\"]]")
echo "$r" | grep -q '"result"' || fail "scantxoutset AFTER failed: $(echo "$r" | head -c200)"
RES=$(rpc_result "$r")
RECOVERED=$(jget "$RES" "total_amount")
[[ -n "$RECOVERED" ]] || fail "scantxoutset AFTER returned no total_amount"
log "AFTER recovered=$RECOVERED"

python3 -c "import sys; sys.exit(0 if abs(float('$RECOVERED')-float('$FUNDED'))<1e-8 else 1)" \
    || fail "recovered ($RECOVERED) != funded ($FUNDED)"

# ── 8. Negative control — a foreign (unfunded) address must total 0 ────────
# Derive the control address from a DIFFERENT seed on a fresh wallet so it is
# guaranteed valid for the same HRP, distinct from A1, and never funded.
log "createwallet wC, sethdseed (foreign seed) for negative control"
rpc unloadwallet '["wB"]' >/dev/null 2>&1 || true
r=$(rpc createwallet '["wC"]')
echo "$r" | grep -q '"result"' || fail "createwallet wC failed: $(echo "$r" | head -c200)"
r=$(rpc sethdseed "[true, \"$FOREIGN_SEED\"]")
echo "$r" | grep -q '"error":null' || fail "sethdseed wC failed: $(echo "$r" | head -c200)"
r=$(rpc getnewaddress '[""]')
FOREIGN_ADDR=$(rpc_result_str "$r")
[[ -n "$FOREIGN_ADDR" ]] || fail "could not derive negative-control address"
[[ "$FOREIGN_ADDR" != "$A1" ]] || fail "negative-control address collided with A1"
log "negative-control addr=$FOREIGN_ADDR"

log "scantxoutset addr($FOREIGN_ADDR) (negative control — expect 0)"
r=$(rpc scantxoutset "[\"start\", [\"addr($FOREIGN_ADDR)\"]]")
echo "$r" | grep -q '"result"' || fail "negative-control scan failed: $(echo "$r" | head -c200)"
RES=$(rpc_result "$r")
NEGTOT=$(jget "$RES" "total_amount")
[[ -n "$NEGTOT" ]] || fail "negative-control scan returned no total_amount"
python3 -c "import sys; sys.exit(0 if abs(float('$NEGTOT'))<1e-8 else 1)" \
    || fail "negative control returned non-zero total ($NEGTOT)"
NEG=0

# ── 9. Done — emit the single clean summary line ───────────────────────────
echo "RECOVERY nimrod: PASS funded=$FUNDED recovered=$RECOVERED addrs=match neg=$NEG"
exit 0
