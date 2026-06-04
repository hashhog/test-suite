#!/usr/bin/env bash
#
# hotbuns_import.sh — self-contained wallet IMPORT + RESCAN regression test.
#
# Codifies the "wallet rescans the existing chain to rediscover its funds and
# adopts a foreign key's funds" cell for hotbuns — the next wallet-completeness
# cell after recovery, spend, and history. Proves rescanblockchain +
# importprivkey work using ONLY wallet-native RPCs on regtest.
#
# CORE PROOF (rescanblockchain — REQUIRED for green):
#   createwallet w1 <fixed mnemonic>   -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> w1 mature balance M (block-connect scan)
#   createwallet w2 <SAME mnemonic>    -> restored keys, but NO chain scan yet
#   ASSERT w2.getbalance == 0          (restore derives keys, does NOT scan chain)
#   w2.rescanblockchain                -> {start_height, stop_height} Core shape
#   ASSERT w2.getbalance == M          (rediscovered its OWN funds via a REAL
#                                        wallet rescan, NOT scantxoutset)
#   ASSERT w2.listunspent shows A1's UTXOs
#
# TARGET PROOF (importprivkey — ok|partial|absent):
#   dumpprivkey from a THIRD wallet w3 (foreign key K_ext + address A_ext) ->
#   generatetoaddress to A_ext to fund it -> w2.importprivkey(K_ext, rescan) ->
#   w2 now ALSO sees A_ext's mature funds.
#
# STRICT UNIFORM INTERFACE (mirrors hotbuns_history.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: IMPORT hotbuns: PASS rescan=ok importprivkey=<ok|partial|absent> rediscovered=<M>
#   FAIL: IMPORT hotbuns: FAIL <short reason>
#
# Touches ONLY /tmp/importfleet-hotbuns/ and ports 39814 (RPC) / 39834 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
DATADIR="/tmp/importfleet-hotbuns"
RPC_PORT=39814
P2P_PORT=39834
LOGFILE="$DATADIR/node.log"

# Canonical BIP-39 all-zero-entropy 12-word test mnemonic (valid checksum) —
# the SAME FIXED seed the recovery + spend + history cells use (shared wallet
# identity). Source: test-suite/recovery/hotbuns_recovery.sh.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# A SECOND, DIFFERENT valid BIP-39 mnemonic for w3 (the foreign-key source) so
# its dumpprivkey'd key is genuinely not in w2's seed. (all-zero but for the
# last word -> different checksum word "art"? use the canonical "legal winner"
# vector which is a distinct, checksum-valid mnemonic.)
MNEMONIC_FOREIGN="legal winner thank year wave sausage worth useful legal winner thank yellow"

# Mine 101 so the height-1 coinbase is mature (generate) at tip 101.
NBLOCKS=101

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[import] $*" >&2; }

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
    fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
    fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Emit the single summary line + exit. ───────────────────────────────────
# pass <importprivkey-state> <rediscovered-sats>
pass() {
    echo "IMPORT hotbuns: PASS rescan=ok importprivkey=$1 rediscovered=$2"
    exit 0
}
fail() {
    echo "IMPORT hotbuns: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth). Optional /wallet/<name> path suffix. ─────────
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}"
    local url="http://127.0.0.1:$RPC_PORT/"
    [[ -n "$wallet" ]] && url="http://127.0.0.1:$RPC_PORT/wallet/$wallet"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$url" 2>/dev/null
}

# Extract a numeric "result":N scalar (integer or decimal) from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'
}

# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}

# Convert a BTC decimal string to integer satoshis (handles a leading '-').
btc_to_sats() {
    local amt="$1" sign=1 whole frac
    [[ -z "$amt" ]] && { echo ""; return 1; }
    if [[ "$amt" == -* ]]; then sign=-1; amt="${amt#-}"; fi
    whole="${amt%%.*}"
    if [[ "$amt" == *.* ]]; then frac="${amt#*.}"; else frac="0"; fi
    frac="${frac}00000000"; frac="${frac:0:8}"
    whole=$((10#${whole:-0})); frac=$((10#${frac:-0}))
    echo $(( sign * (whole * 100000000 + frac) ))
}

HAVE_PY=0
command -v python3 >/dev/null 2>&1 && HAVE_PY=1

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
command -v bun >/dev/null 2>&1 || fail "bun runtime not found on PATH"
[[ -f "$NODE_DIR/src/index.ts" ]] || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"

# ── 2. Launch hotbuns on regtest. ──────────────────────────────────────────
log "launching hotbuns (regtest) rpc=:$RPC_PORT p2p=:$P2P_PORT -> $LOGFILE"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$DATADIR" \
        --port="$P2P_PORT" --rpcport="$RPC_PORT"
) >"$LOGFILE" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 3. Locate the cookie + wait for RPC. ───────────────────────────────────
deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" ]]; then
        for c in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
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
    kill -0 "$NODE_PID" 2>/dev/null || { tail -n 20 "$LOGFILE" >&2 2>/dev/null || true; fail "node exited during startup (see $LOGFILE)"; }
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 60s"
r=$(rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 60s"

# ── 4. Create w1 from the FIXED mnemonic, derive A1. ───────────────────────
# createwallet positional params (recovery cell):
#   [name, disable_private_keys, blank, passphrase, avoid_reuse,
#    descriptors, load_on_startup, mnemonic, mnemonic_passphrase]
log "createwallet w1 from fixed mnemonic"
r=$(rpc createwallet "[\"w1\", false, false, \"\", false, true, false, \"$MNEMONIC\", \"\"]")
echo "$r" | grep -q '"name":"w1"' || fail "createwallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "getnewaddress on w1 -> A1"
A1=$(result_str "$(rpc getnewaddress "[]" w1)")
[[ -n "$A1" ]] || fail "getnewaddress (w1) returned no address"
log "A1=$A1"

# ── 5. Fund A1 with 101 coinbases (block-connect scan credits w1). ─────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS, \"$A1\"]" w1)
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# w1 mature balance M (the block-connect scan rediscovered nothing; it credited
# as the blocks connected). Only the height-1 coinbase is mature at tip 101.
M_BTC=$(result_num "$(rpc getbalance "[]" w1)")
M=$(btc_to_sats "$M_BTC")
[[ -n "$M" && "$M" -gt 0 ]] || fail "w1 mature balance is 0 after funding (got '$M_BTC')"
log "w1 mature balance M = $M_BTC BTC ($M sats)"

# ── 6. Create w2 from the SAME mnemonic — keys derived, ledger empty. ──────
log "createwallet w2 from the SAME fixed mnemonic (fresh ledger)"
r=$(rpc createwallet "[\"w2\", false, false, \"\", false, true, false, \"$MNEMONIC\", \"\"]")
echo "$r" | grep -q '"name":"w2"' || fail "createwallet w2 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

# w2 has the same keys (recovery cell proves byte-identical derivation) but has
# never scanned the chain -> balance MUST be 0. This is the whole point of a
# rescan: restore derives keys, it does NOT scan.
W2_PRE_BTC=$(result_num "$(rpc getbalance "[]" w2)")
W2_PRE=$(btc_to_sats "$W2_PRE_BTC")
log "w2 balance BEFORE rescan = $W2_PRE_BTC BTC ($W2_PRE sats)"
[[ "${W2_PRE:-0}" -eq 0 ]] || fail "w2 balance is non-zero ($W2_PRE_BTC) BEFORE any rescan — restore must not scan the chain"

# Confirm w2 actually re-derives A1 (same seed) so the rescan has a needle.
A2=$(result_str "$(rpc getnewaddress "[]" w2)")
[[ "$A2" == "$A1" ]] || fail "w2 re-derived address $A2 != w1 A1 $A1 (seed restore mismatch)"
log "w2 re-derived A1 == w1 A1 ($A2)"
# Re-check balance still 0 after deriving the address (deriving must not credit).
W2_PRE2_BTC=$(result_num "$(rpc getbalance "[]" w2)")
[[ "$(btc_to_sats "$W2_PRE2_BTC")" -eq 0 ]] || fail "w2 balance became non-zero merely by deriving an address (got $W2_PRE2_BTC)"

# ── 7. rescanblockchain on w2 -> rediscovers M via a REAL wallet rescan. ───
log "rescanblockchain on w2 (full chain)"
RB=$(rpc rescanblockchain "[]" w2)
echo "$RB" | grep -q '"error":{' && fail "rescanblockchain error: $(echo "$RB" | grep -o '"message":"[^"]*"' | head -1)"
# Core shape: {start_height, stop_height}.
echo "$RB" | grep -q '"start_height"' || fail "rescanblockchain result missing start_height: $(echo "$RB" | head -c 200)"
echo "$RB" | grep -q '"stop_height"'  || fail "rescanblockchain result missing stop_height: $(echo "$RB" | head -c 200)"
if [[ "$HAVE_PY" -eq 1 ]]; then
    RB_OK=$(echo "$RB" | HEIGHT="$HEIGHT" python3 -c '
import sys, os, json
r = json.load(sys.stdin)["result"]
sh = r.get("start_height"); st = r.get("stop_height")
tip = int(os.environ["HEIGHT"])
if sh != 0:
    print("FAIL start_height %r != 0" % sh); sys.exit(0)
if st != tip:
    print("FAIL stop_height %r != tip %d" % (st, tip)); sys.exit(0)
print("OK")
')
    [[ "$RB_OK" == "OK" ]] || fail "rescanblockchain result shape wrong: $RB_OK"
fi
log "rescanblockchain returned {start_height:0, stop_height:$HEIGHT}"

# w2 balance AFTER rescan MUST equal M (rediscovered its OWN funds).
W2_POST_BTC=$(result_num "$(rpc getbalance "[]" w2)")
W2_POST=$(btc_to_sats "$W2_POST_BTC")
log "w2 balance AFTER rescan = $W2_POST_BTC BTC ($W2_POST sats)"
[[ "${W2_POST:-0}" -eq "$M" ]] || fail "w2 post-rescan balance $W2_POST != w1 M $M (rescan did not rediscover the funds)"

# w2.listunspent must show A1's UTXOs (the rediscovered coins).
LU=$(rpc listunspent "[0, 9999999, [\"$A1\"]]" w2)
echo "$LU" | grep -q '"error":{' && fail "listunspent (w2) error: $(echo "$LU" | grep -o '"message":"[^"]*"' | head -1)"
if [[ "$HAVE_PY" -eq 1 ]]; then
    LU_N=$(echo "$LU" | A1="$A1" python3 -c '
import sys, os, json
d = json.load(sys.stdin)["result"]
a1 = os.environ["A1"]
print(sum(1 for u in d if u.get("address")==a1))
')
else
    LU_N=$(echo "$LU" | grep -o "\"address\":\"$A1\"" | wc -l | tr -d ' ')
fi
log "w2.listunspent A1 entries = ${LU_N:-0}"
[[ "${LU_N:-0}" -gt 0 ]] || fail "w2.listunspent shows no A1 UTXOs after rescan"

log "RESCAN PROOF GREEN: w2 rediscovered M=$M_BTC via rescanblockchain, listunspent shows A1"

# ── 8. importprivkey (target): adopt a FOREIGN key's funds. ────────────────
# Source a foreign key from a third wallet w3 (different seed) via dumpprivkey,
# fund its address with a coinbase, then importprivkey(rescan) into w2.
IMPORT_STATE="absent"
do_importprivkey() {
    log "createwallet w3 from a DIFFERENT mnemonic (foreign-key source)"
    local r
    r=$(rpc createwallet "[\"w3\", false, false, \"\", false, true, false, \"$MNEMONIC_FOREIGN\", \"\"]")
    echo "$r" | grep -q '"name":"w3"' || { log "createwallet w3 failed: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"; return 1; }

    local A_ext
    A_ext=$(result_str "$(rpc getnewaddress "[]" w3)")
    [[ -n "$A_ext" ]] || { log "w3 getnewaddress returned nothing"; return 1; }
    # The foreign address must NOT be one of w2's own addresses.
    [[ "$A_ext" != "$A1" ]] || { log "foreign addr collided with A1"; return 1; }
    log "A_ext=$A_ext (foreign)"

    # dumpprivkey the WIF for A_ext from w3.
    local K_ext
    K_ext=$(result_str "$(rpc dumpprivkey "[\"$A_ext\"]" w3)")
    [[ -n "$K_ext" ]] || { log "dumpprivkey returned nothing (dumpprivkey absent?)"; return 1; }
    log "K_ext WIF obtained (len=${#K_ext})"

    # Fund A_ext with 101 coinbases so it has a mature balance.
    r=$(rpc generatetoaddress "[$NBLOCKS, \"$A_ext\"]" w3)
    echo "$r" | grep -q '"error":{' && { log "generatetoaddress(A_ext) error"; return 1; }
    local TIP2
    TIP2=$(result_num "$(rpc getblockcount)")
    log "funded A_ext; tip now $TIP2"

    # w3's own mature balance from A_ext (the amount w2 should adopt).
    local EXT_BTC EXT
    EXT_BTC=$(result_num "$(rpc getbalance "[]" w3)")
    EXT=$(btc_to_sats "$EXT_BTC")
    [[ -n "$EXT" && "$EXT" -gt 0 ]] || { log "w3 (A_ext) mature balance is 0 ($EXT_BTC)"; return 1; }
    log "A_ext mature balance = $EXT_BTC BTC ($EXT sats)"

    # w2 balance before import (should still be just M; A_ext is foreign).
    local W2_BEFORE
    W2_BEFORE=$(btc_to_sats "$(result_num "$(rpc getbalance "[]" w2)")")
    log "w2 balance before importprivkey = $W2_BEFORE sats"

    # importprivkey(K_ext, "imported", rescan=true) into w2.
    local IMP
    IMP=$(rpc importprivkey "[\"$K_ext\", \"imported\", true]" w2)
    if echo "$IMP" | grep -q '"error":{'; then
        log "importprivkey error: $(echo "$IMP" | grep -o '"message":"[^"]*"' | head -1)"
        # The method exists but errored -> partial.
        IMPORT_STATE="partial"
        return 1
    fi
    # Method returned (Core returns null). Mark at least partial now.
    IMPORT_STATE="partial"
    log "importprivkey returned: $(echo "$IMP" | head -c 120)"

    # w2 should now ALSO see A_ext's funds: balance == M + EXT.
    local W2_AFTER want
    W2_AFTER=$(btc_to_sats "$(result_num "$(rpc getbalance "[]" w2)")")
    want=$(( W2_BEFORE + EXT ))
    log "w2 balance after importprivkey = $W2_AFTER sats (want $want = $W2_BEFORE + $EXT)"
    if [[ "$W2_AFTER" -eq "$want" ]]; then
        # w2.listunspent must include A_ext now.
        local LU2 n2
        LU2=$(rpc listunspent "[0, 9999999, [\"$A_ext\"]]" w2)
        if [[ "$HAVE_PY" -eq 1 ]]; then
            n2=$(echo "$LU2" | A="$A_ext" python3 -c '
import sys, os, json
d = json.load(sys.stdin)["result"]
print(sum(1 for u in d if u.get("address")==os.environ["A"]))
')
        else
            n2=$(echo "$LU2" | grep -o "\"address\":\"$A_ext\"" | wc -l | tr -d ' ')
        fi
        [[ "${n2:-0}" -gt 0 ]] || { log "w2.listunspent missing A_ext after import"; return 1; }
        IMPORT_STATE="ok"
        log "IMPORTPRIVKEY PROOF GREEN: w2 adopted A_ext funds (+$EXT_BTC), listunspent shows A_ext"
        return 0
    fi
    log "importprivkey did not credit A_ext into w2 (balance unchanged) -> partial"
    return 1
}

# importprivkey is the TARGET, not required for green. Run it best-effort; a
# failure downgrades to partial/absent but does NOT fail the test.
if do_importprivkey; then
    log "importprivkey state = ok"
else
    log "importprivkey state = $IMPORT_STATE (rescan still green)"
fi

# ── 9. Success — rescan is green; report the importprivkey state. ──────────
log "PASS: rescan=ok importprivkey=$IMPORT_STATE rediscovered=$M_BTC"
pass "$IMPORT_STATE" "$M_BTC"
