#!/usr/bin/env bash
#
# beamchain_import.sh — self-contained wallet IMPORT+RESCAN regression test.
#
# Codifies the "wallet can rescan EXISTING chain blocks for its own funds, and
# adopt a foreign key's funds via importprivkey" cell — the successor to the
# recovery (10/10), spend (10/10) and history (10/10) cells.  Where recovery
# proved a restore-from-seed wallet rediscovers funds via scantxoutset (a
# chain-level scan that BYPASSES the wallet), this proves the REAL wallet
# rescan: rescanblockchain walks blocks already on disk and credits every
# wallet-owned output it finds INTO the wallet's own UTXO ledger.  It is the
# BACKWARD counterpart of the block-connect scan (beamchain commit 1dbd9c8).
#
# ── A. RESCAN (required for GREEN) ────────────────────────────────────────
#   restorewallet w1 <fixed mnemonic>   -> getnewaddress -> A1
#   generatetoaddress 101 -> A1          -> W1 mature balance M (50 BTC; the
#                                           height-1 coinbase is mature, the
#                                           rest immature) credited at CONNECT
#   RESTART the node (the in-memory wallet UTXO ledger is dropped; the chain
#   stays on disk — exactly Core's post-restart recovery situation).
#   restorewallet w2 <SAME mnemonic>     -> re-derives the identical A1
#   ASSERT W2.getbalance == 0   (restore derives keys but does NOT scan)
#   rescanblockchain on W2               -> {start_height, stop_height} (Core)
#   ASSERT W2.getbalance == M  AND  W2.listunspent shows A1's UTXOs
#   (the wallet rediscovered its funds via a REAL wallet rescan).
#
# ── B. IMPORTPRIVKEY (target) ─────────────────────────────────────────────
#   A foreign key K_ext + its address A_ext are obtained (a throwaway wallet's
#   getnewaddress + dumpprivkey, BEFORE the restart that clears the script
#   table, so A_ext is NOT a registered wallet script when its funding blocks
#   connect — an honest "foreign" key).
#   generatetoaddress 101 -> A_ext       -> funds A_ext; NOT credited to W2
#                                           (no loaded wallet owns A_ext)
#   importprivkey(K_ext, rescan=true) into W2
#   ASSERT W2.getbalance grew by A_ext's matured coinbase (50 BTC) — W2 now
#   sees the foreign key's funds.
#
# Shapes follow bitcoin-core src/wallet/rpc/transactions.cpp rescanblockchain
# ({start_height, stop_height}) and src/wallet/rpc/backup.cpp importprivkey
# (DecodeSecret -> AddKeyPubKey -> RescanWallet, returns null on success).
#
# STRICT UNIFORM INTERFACE (mirrors beamchain_history.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout.  All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: IMPORT beamchain: PASS rescan=ok importprivkey=ok rediscovered=<M>
#   FAIL: IMPORT beamchain: FAIL <short reason>
# Green REQUIRES rescan=ok.
#
# Touches ONLY /tmp/importfleet-beamchain/ and ports 21716 (RPC) / 21736
# (P2P).  Disables the Prometheus metrics endpoint (metrics_port=0) so it never
# collides with a live mainnet beamchain node.  NEVER touches /data/nvme1/ or
# testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
DATADIR="/tmp/importfleet-beamchain"
RPC_PORT=21716
P2P_PORT=21736
LOGFILE="$DATADIR/import-test.log"

# Canonical BIP-39 all-zero-entropy 12-word test mnemonic (valid checksum).
# Same FIXED seed as the recovery / spend / history cells so the cells share a
# wallet identity.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Coinbase maturity on regtest is 100 blocks.  Mine 101 so the height-1
# coinbase is mature (50 BTC spendable) while the rest are immature.
NBLOCKS=101
# M = the mature W1 balance after mining 101 blocks to A1: exactly one matured
# coinbase = 50 BTC = 5_000_000_000 satoshis.
EXPECT_M_SATS=5000000000
COINBASE_50BTC=5000000000

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[import] $*" >&2; }

# ── Cleanup trap: always kill node + wipe scratch datadir on any exit. ─────
cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
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
# pass <importprivkey-state> <rediscovered-sats>
pass() {
    echo "IMPORT beamchain: PASS rescan=ok importprivkey=$1 rediscovered=$2"
    exit 0
}
fail() {
    echo "IMPORT beamchain: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth; optional wallet path). ────────────────────────
# usage: rpc <method> <params-json> [wallet-name]
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}"
    local path="/"
    [[ -n "$wallet" ]] && path="/wallet/$wallet"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT$path" 2>/dev/null
}

# Extract a numeric "result":N scalar from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'
}
# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}

# Convert a BTC-decimal getbalance result to integer satoshis (no bc).
balance_sats() {
    local resp="$1" amt whole frac
    amt=$(echo "$resp" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://')
    [[ -z "$amt" ]] && { echo ""; return 1; }
    whole="${amt%%.*}"
    frac="${amt#*.}"
    [[ "$amt" == "$whole" ]] && frac="0"
    frac="${frac}00000000"
    frac="${frac:0:8}"
    whole=$((10#${whole:-0}))
    frac=$((10#${frac:-0}))
    echo $(( whole * 100000000 + frac ))
}

# ── Node launch helper (used twice: initial + post-restart). ───────────────
launch_node() {
    log "launching beamchain (regtest) -> $DATADIR/node.log"
    RELX_CONFIG_PATH="$DATADIR/sys.config" VMARGS_PATH="$DATADIR/vm.args" \
        "$NODE_BIN" foreground >>"$DATADIR/node.log" 2>&1 &
    NODE_PID=$!
    log "node pid=$NODE_PID"
    local deadline=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < deadline )); do
        if [[ -z "$COOKIE" ]]; then
            for c in "$DATADIR/regtest/.cookie" "$DATADIR/.cookie"; do
                if [[ -f "$c" ]]; then COOKIE=$(cat "$c"); break; fi
            done
        fi
        if [[ -n "$COOKIE" ]]; then
            local r
            r=$(rpc getblockcount)
            if echo "$r" | grep -q '"result"'; then
                log "RPC ready: $r"
                return 0
            fi
        fi
        kill -0 "$NODE_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

stop_node() {
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    NODE_PID=""
    sleep 1
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$DATADIR"
mkdir -p "$DATADIR"
exec 3>>"$LOGFILE"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -f "$NODE_BIN" ]] || fail "release binary not found at $NODE_BIN (run build-all.sh beamchain)"
command -v python3 >/dev/null 2>&1 || fail "python3 required for JSON assertions"

# ── 2. Write release config (reused across the restart). ───────────────────
cat >"$DATADIR/sys.config" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$DATADIR"},
   {p2pport, $P2P_PORT},
   {rpcport, $RPC_PORT},
   {metrics_port, 0}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$DATADIR/vm.args" <<ERLVM
-sname beamchain_importfleet_$$
-setcookie beamchain_importfleet
+P 1048576
+K true
+A 64
ERLVM

# ── 3. Launch (initial). ───────────────────────────────────────────────────
launch_node || fail "node failed to start / RPC never responded (see $DATADIR/node.log)"

# ── 4. Restore wallet w1, derive A1. ───────────────────────────────────────
log "restorewallet w1 from fixed mnemonic"
r=$(rpc restorewallet "[\"w1\",\"$MNEMONIC\"]")
echo "$r" | grep -q '"error":{' && fail "restorewallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "getnewaddress on w1 -> A1"
A1=$(result_str "$(rpc getnewaddress "[]" "w1")")
[[ -n "$A1" ]] || fail "getnewaddress w1 returned no address"
log "A1=$A1"

# ── 5. Obtain a FOREIGN key K_ext + address A_ext (for part B), captured
#       BEFORE any funding so A_ext is NOT a registered wallet script when its
#       funding blocks later connect — an honest out-of-wallet key. ─────────
log "createwallet wfk (throwaway) -> foreign address + WIF"
r=$(rpc createwallet "[\"wfk\"]")
echo "$r" | grep -q '"error":{' && fail "createwallet wfk error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
A_EXT=$(result_str "$(rpc getnewaddress "[]" "wfk")")
[[ -n "$A_EXT" ]] || fail "getnewaddress wfk returned no address"
WIF=$(result_str "$(rpc dumpprivkey "[\"$A_EXT\"]" "wfk")")
[[ -n "$WIF" ]] || fail "dumpprivkey on wfk returned no WIF"
log "A_EXT=$A_EXT WIF=${WIF:0:6}...(redacted)"

# ── 6. Fund A1 with coinbase (credited to the global ledger at CONNECT). ───
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

W1_BAL=$(balance_sats "$(rpc getbalance "[]" "w1")")
log "w1 mature balance (M) = $W1_BAL sats"
[[ "${W1_BAL:-0}" == "$EXPECT_M_SATS" ]] || fail "w1 balance after funding = ${W1_BAL:-?}, want $EXPECT_M_SATS"

# ── 7. RESTART the node — drops the in-memory wallet UTXO ledger; the chain
#       stays on disk.  This is Core's post-restart recovery situation: the
#       wallet must rebuild its ledger from the chain via rescanblockchain. ──
log "RESTART: stopping node (chain persists on disk; in-memory wallet ledger drops)"
stop_node
log "RESTART: relaunching on the same datadir"
launch_node || fail "node failed to relaunch after restart (see $DATADIR/node.log)"

HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -ge "$NBLOCKS" ]] \
    || fail "post-restart blockcount regressed (got ${HEIGHT2:-?}, want >= $NBLOCKS)"
log "post-restart height=$HEIGHT2 (chain intact)"

# ── 8. Restore W2 from the SAME seed; it re-derives A1 but has NOT scanned. ─
log "restorewallet w2 from the SAME mnemonic (fresh wallet identity)"
r=$(rpc restorewallet "[\"w2\",\"$MNEMONIC\"]")
echo "$r" | grep -q '"error":{' && fail "restorewallet w2 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

A1B=$(result_str "$(rpc getnewaddress "[]" "w2")")
[[ "$A1B" == "$A1" ]] || fail "w2 re-derived address mismatch: got $A1B want $A1"
log "w2 re-derived A1 byte-identical: $A1B"

# Headline precondition: a freshly-restored wallet that has NOT scanned the
# chain reports a ZERO balance (restore derives keys, it does not scan).
W2_BEFORE=$(balance_sats "$(rpc getbalance "[]" "w2")")
log "w2 balance BEFORE rescan = ${W2_BEFORE:-?} sats"
[[ "${W2_BEFORE:-x}" == "0" ]] \
    || fail "w2 balance BEFORE rescan expected 0, got ${W2_BEFORE:-?} (restore must not scan the chain)"

# ── 9. rescanblockchain on W2 — the REAL wallet rescan. ────────────────────
RESCAN=$(rpc rescanblockchain "[]" "w2")
echo "$RESCAN" | grep -q '"error":{' && fail "rescanblockchain error: $(echo "$RESCAN" | grep -o '"message":"[^"]*"' | head -1)"
# Assert the Core-shaped {start_height, stop_height} result.
RS_FILE="$DATADIR/rescan.json"
printf '%s' "$RESCAN" >"$RS_FILE"
RS_ASSERT=$(python3 - "$HEIGHT2" "$RS_FILE" <<'PY'
import sys, json
tip = int(sys.argv[1])
try:
    with open(sys.argv[2]) as fh:
        r = json.load(fh)["result"]
except Exception as e:
    print("PARSE_ERROR " + str(e)); sys.exit(0)
if not isinstance(r, dict):
    print("NOT_OBJECT"); sys.exit(0)
for k in ("start_height", "stop_height"):
    if k not in r:
        print("MISSING_FIELD " + k); sys.exit(0)
if int(r["start_height"]) != 0:
    print("START_HEIGHT got=%s want=0" % r["start_height"]); sys.exit(0)
if int(r["stop_height"]) != tip:
    print("STOP_HEIGHT got=%s want=%d" % (r["stop_height"], tip)); sys.exit(0)
print("OK start=%s stop=%s" % (r["start_height"], r["stop_height"]))
PY
)
log "rescanblockchain assertion: $RS_ASSERT"
case "$RS_ASSERT" in OK\ *) : ;; *) fail "rescanblockchain shape: $RS_ASSERT" ;; esac

# The headline proof: after a REAL wallet rescan, W2 rediscovered M.
W2_AFTER=$(balance_sats "$(rpc getbalance "[]" "w2")")
log "w2 balance AFTER rescan = ${W2_AFTER:-?} sats (want $EXPECT_M_SATS)"
[[ "${W2_AFTER:-x}" == "$EXPECT_M_SATS" ]] \
    || fail "w2 balance AFTER rescan = ${W2_AFTER:-?}, want $EXPECT_M_SATS (rescan did not rediscover funds)"

# listunspent must now show A1's UTXOs (rediscovered into the wallet, not via
# the chain-level scantxoutset).
LU=$(rpc listunspent "[]" "w2")
echo "$LU" | grep -q '"error":{' && fail "listunspent error: $(echo "$LU" | grep -o '"message":"[^"]*"' | head -1)"
LU_FILE="$DATADIR/listunspent.json"
printf '%s' "$LU" >"$LU_FILE"
LU_N=$(python3 -c "import sys,json; print(len(json.load(open('$LU_FILE'))['result']))" 2>/dev/null)
log "w2 listunspent = ${LU_N:-?} UTXOs after rescan"
[[ "${LU_N:-0}" -ge 1 ]] || fail "w2 listunspent empty after rescan (no UTXOs rediscovered)"

log "RESCAN GREEN: w2 rediscovered $W2_AFTER sats via a real wallet rescan ($LU_N UTXOs)"

# ── 10. importprivkey: adopt the foreign key K_ext's funds into W2. ────────
IMPORT_STATE="absent"
# Fund A_ext with 101 coinbases.  No loaded wallet owns A_ext (wfk was a
# throwaway whose scripts were dropped by the restart), so these are NOT
# credited to W2 — until importprivkey registers the key.
log "generatetoaddress $NBLOCKS -> A_EXT (foreign; not owned by any loaded wallet)"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A_EXT\"]")
if echo "$r" | grep -q '"error":{'; then
    log "WARN: funding A_EXT failed; importprivkey left untested: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
else
    BAL_BEFORE_IMPORT=$(balance_sats "$(rpc getbalance "[]" "w2")")
    log "w2 balance before importprivkey = ${BAL_BEFORE_IMPORT:-?} sats (A_EXT funds NOT yet visible)"
    IMP=$(rpc importprivkey "[\"$WIF\",\"\",true]" "w2")
    if echo "$IMP" | grep -q '"error":{'; then
        log "WARN: importprivkey errored; marking PARTIAL: $(echo "$IMP" | grep -o '"message":"[^"]*"' | head -1)"
        IMPORT_STATE="partial"
    else
        BAL_AFTER_IMPORT=$(balance_sats "$(rpc getbalance "[]" "w2")")
        GAIN=$(( ${BAL_AFTER_IMPORT:-0} - ${BAL_BEFORE_IMPORT:-0} ))
        log "w2 balance after importprivkey = ${BAL_AFTER_IMPORT:-?} sats (gain=$GAIN; want >= $COINBASE_50BTC)"
        # importprivkey rescans -> A_EXT's matured coinbase (>=1 mature output,
        # 50 BTC each) is now credited to W2.
        if [[ "$GAIN" -ge "$COINBASE_50BTC" ]]; then
            IMPORT_STATE="ok"
            log "IMPORTPRIVKEY GREEN: foreign key's matured funds (+$GAIN sats) adopted into w2"
        else
            log "WARN: importprivkey did not credit foreign funds (gain=$GAIN); marking PARTIAL"
            IMPORT_STATE="partial"
        fi
    fi
fi

# ── 11. Success — rescan is the headline requirement for GREEN. ────────────
log "PASS: rescan=ok importprivkey=$IMPORT_STATE rediscovered=$W2_AFTER"
pass "$IMPORT_STATE" "$W2_AFTER"
