#!/usr/bin/env bash
#
# beamchain_recovery.sh — self-contained wallet-recovery regression test.
#
# Codifies the "wallet recovery GREEN" cell landed in beamchain commit
# 9b13570 (feat(wallet): scantxoutset + restore-from-seed). Proves that a
# wallet restored from a FIXED BIP-39 mnemonic deterministically reconstructs
# byte-identical addresses, and that scantxoutset rediscovers 100% of the
# coinbase funds after a full wallet wipe + restore.
#
# Flow (matches last session's proven recovery flow):
#   restorewallet w1 <fixed mnemonic>  -> getnewaddress (bech32/p2wpkh) -> A1
#   generatetoaddress -> fund coinbase to A1
#   scantxoutset start [addr(A1)]      -> total BEFORE
#   wipe wallet state -> restorewallet w2 <SAME mnemonic> -> getnewaddress -> A1'
#   assert A1' == A1 (byte-identical re-derivation)
#   scantxoutset start [addr(A1)]      -> total AFTER ; assert AFTER == BEFORE
#   negative control: scantxoutset on a foreign address -> 0
#
# STRICT UNIFORM INTERFACE: no required args, idempotent, single clean summary
# line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: RECOVERY beamchain: PASS funded=<X> recovered=<X> addrs=match neg=0
#   FAIL: RECOVERY beamchain: FAIL <short reason>
#
# Touches ONLY /tmp/recreg-beamchain/ and ports 21506 (RPC) / 21536 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
DATADIR="/tmp/recreg-beamchain"
RPC_PORT=21506
P2P_PORT=21536
LOGFILE="$DATADIR/recovery-test.log"

# Canonical BIP-39 all-zero-entropy 12-word test mnemonic (valid checksum).
# This is the FIXED seed: restoring it twice must yield identical addresses.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Coinbase maturity on regtest is 100 blocks; mine 101 so the first reward
# (subsidy 50 BTC at height 1) is spendable / discoverable in the UTXO set.
# scantxoutset reports ALL unspent matches (mature or not), so any count > 0
# funds the test; we mine 101 to exercise a realistic, multi-block coinbase set.
NBLOCKS=101

# A foreign address NOT derived from our seed, for the negative control.
# Fixed regtest bech32 address (not in our wallet) -> must scan to 0.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[recovery] $*" >&2; }

# ── Cleanup trap: always kill node + wipe scratch datadir on any exit. ─────
cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT

# ── Emit the single summary line + exit. ───────────────────────────────────
pass() {
    echo "RECOVERY beamchain: PASS funded=$1 recovered=$2 addrs=match neg=0"
    exit 0
}
fail() {
    echo "RECOVERY beamchain: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth; optional wallet path). ────────────────────────
# usage: rpc <method> <params-json> [wallet-name]
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}"
    local path="/"
    [[ -n "$wallet" ]] && path="/wallet/$wallet"
    curl -s --max-time 15 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT$path" 2>/dev/null
}

# Extract the integer total_amount from a scantxoutset response, in satoshis.
# total_amount is a BTC decimal string (e.g. "5050.00000000"); convert to sats
# by stripping the dot and taking the 8-decimal field. Robust to integer or
# string JSON encoding.
scan_total_sats() {
    local resp="$1"
    # Pull the total_amount value (may be "NN.NNNNNNNN" or NN.NNNNNNNN).
    local amt
    amt=$(echo "$resp" | grep -o '"total_amount":[^,}]*' | head -1 | sed 's/.*://; s/[" ]//g')
    [[ -z "$amt" ]] && { echo ""; return 1; }
    # Convert BTC decimal -> satoshis (integer) without bc: split on dot.
    local whole frac
    whole="${amt%%.*}"
    frac="${amt#*.}"
    [[ "$amt" == "$whole" ]] && frac="0"        # no decimal point
    frac="${frac}00000000"                       # pad
    frac="${frac:0:8}"                           # take 8 decimal places
    # Strip leading zeros safely.
    whole=$((10#${whole:-0}))
    frac=$((10#${frac:-0}))
    echo $(( whole * 100000000 + frac ))
}

# Count txouts from a scantxoutset response.
scan_txouts() {
    echo "$1" | grep -o '"txouts":[0-9]*' | head -1 | grep -o '[0-9]*'
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$DATADIR"
mkdir -p "$DATADIR"
exec 3>>"$LOGFILE"   # keep a logfile fd around (node log lives separately)

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -f "$NODE_BIN" ]] || fail "release binary not found at $NODE_BIN (run build-all.sh beamchain)"

# ── 2. Launch beamchain on regtest (smoke-harness recipe). ─────────────────
cat >"$DATADIR/sys.config" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$DATADIR"},
   {p2pport, $P2P_PORT},
   {rpcport, $RPC_PORT}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$DATADIR/vm.args" <<ERLVM
-sname beamchain_recreg_$$
-setcookie beamchain_recreg
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) -> $DATADIR/node.log"
RELX_CONFIG_PATH="$DATADIR/sys.config" VMARGS_PATH="$DATADIR/vm.args" \
    "$NODE_BIN" foreground >"$DATADIR/node.log" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 3. Locate the cookie (datadir or regtest/ subdir) + wait for RPC. ──────
deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" ]]; then
        for c in "$DATADIR/regtest/.cookie" "$DATADIR/.cookie"; do
            if [[ -f "$c" ]]; then COOKIE=$(cat "$c"); break; fi
        done
    fi
    if [[ -n "$COOKIE" ]]; then
        r=$(rpc getblockcount)
        if echo "$r" | grep -q '"result"'; then
            log "RPC ready: $r"
            break
        fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $DATADIR/node.log)"
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 45s"
r=$(rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 45s"

# ── 4. Restore wallet w1 from the fixed mnemonic, derive A1. ───────────────
log "restorewallet w1 from fixed mnemonic"
r=$(rpc restorewallet "[\"w1\",\"$MNEMONIC\"]")
echo "$r" | grep -q '"error":null' || echo "$r" | grep -q '"result"' \
    || fail "restorewallet w1 failed: $(echo "$r" | head -c 200)"
echo "$r" | grep -q '"error":{' && fail "restorewallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "getnewaddress on w1 (bech32/p2wpkh)"
r=$(rpc getnewaddress "[]" "w1")
A1=$(echo "$r" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//')
[[ -n "$A1" ]] || fail "getnewaddress w1 returned no address: $(echo "$r" | head -c 200)"
log "A1=$A1"

# ── 5. Fund A1 with coinbase, then scantxoutset BEFORE. ────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
# Confirm height advanced.
r=$(rpc getblockcount)
HEIGHT=$(echo "$r" | grep -o '"result":[0-9]*' | grep -o '[0-9]*')
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "block height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

log "scantxoutset BEFORE [addr($A1)]"
r=$(rpc scantxoutset "[\"start\",[\"addr($A1)\"]]")
echo "$r" | grep -q '"error":{' && fail "scantxoutset BEFORE error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
BEFORE_SATS=$(scan_total_sats "$r")
BEFORE_OUTS=$(scan_txouts "$r")
[[ -n "$BEFORE_SATS" ]] || fail "scantxoutset BEFORE returned no total_amount: $(echo "$r" | head -c 200)"
[[ "${BEFORE_OUTS:-0}" -gt 0 ]] || fail "scantxoutset BEFORE found 0 txouts (funding failed)"
[[ "$BEFORE_SATS" -gt 0 ]] || fail "scantxoutset BEFORE total is 0 (funding failed)"
log "BEFORE: txouts=$BEFORE_OUTS total_sats=$BEFORE_SATS"

# ── 6. Wipe the wallet, restore the SAME seed into a fresh wallet w2. ──────
# Unload w1 and delete wallet on-disk state so w2 is a genuinely fresh restore
# (chain/UTXO state is preserved; only wallet keys are reconstructed from seed).
log "unloadwallet w1"
rpc unloadwallet "[\"w1\"]" >/dev/null 2>&1 || true
# Remove any persisted wallet files so the re-derivation cannot read cached keys.
find "$DATADIR/regtest" -maxdepth 3 -iname '*wallet*' -exec rm -rf {} + 2>/dev/null || true

log "restorewallet w2 from SAME fixed mnemonic"
r=$(rpc restorewallet "[\"w2\",\"$MNEMONIC\"]")
echo "$r" | grep -q '"error":{' && fail "restorewallet w2 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "getnewaddress on w2 (must byte-match A1)"
r=$(rpc getnewaddress "[]" "w2")
A1B=$(echo "$r" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//')
[[ -n "$A1B" ]] || fail "getnewaddress w2 returned no address: $(echo "$r" | head -c 200)"
log "A1B=$A1B"
[[ "$A1B" == "$A1" ]] || fail "re-derived address mismatch: w1=$A1 w2=$A1B"

# ── 7. scantxoutset AFTER (recovered) == BEFORE (funded). ──────────────────
log "scantxoutset AFTER [addr($A1)]"
r=$(rpc scantxoutset "[\"start\",[\"addr($A1)\"]]")
echo "$r" | grep -q '"error":{' && fail "scantxoutset AFTER error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
AFTER_SATS=$(scan_total_sats "$r")
AFTER_OUTS=$(scan_txouts "$r")
[[ -n "$AFTER_SATS" ]] || fail "scantxoutset AFTER returned no total_amount: $(echo "$r" | head -c 200)"
log "AFTER: txouts=$AFTER_OUTS total_sats=$AFTER_SATS"
[[ "$AFTER_SATS" == "$BEFORE_SATS" ]] || fail "recovered total $AFTER_SATS != funded total $BEFORE_SATS"
[[ "$AFTER_OUTS" == "$BEFORE_OUTS" ]] || fail "recovered txouts $AFTER_OUTS != funded txouts $BEFORE_OUTS"

# ── 8. Negative control: a foreign address must scan to 0. ─────────────────
log "scantxoutset NEGATIVE control [addr($FOREIGN_ADDR)]"
r=$(rpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
echo "$r" | grep -q '"error":{' && fail "scantxoutset negative-control error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
NEG_OUTS=$(scan_txouts "$r")
NEG_SATS=$(scan_total_sats "$r")
log "NEG: txouts=${NEG_OUTS:-?} total_sats=${NEG_SATS:-?}"
[[ "${NEG_OUTS:-0}" == "0" ]] || fail "negative control found ${NEG_OUTS} txouts for foreign addr (expected 0)"
[[ "${NEG_SATS:-0}" == "0" ]] || fail "negative control total ${NEG_SATS} != 0 for foreign addr"

# ── 9. Success: emit BTC totals (whole BTC) in the summary. ────────────────
FUNDED_BTC=$(( BEFORE_SATS / 100000000 ))
REC_BTC=$(( AFTER_SATS / 100000000 ))
log "PASS: funded=$FUNDED_BTC BTC recovered=$REC_BTC BTC addrs match neg=0"
pass "$FUNDED_BTC" "$REC_BTC"
