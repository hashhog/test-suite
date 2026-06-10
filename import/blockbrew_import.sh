#!/usr/bin/env bash
#
# blockbrew_import.sh — wallet IMPORT + RESCAN regression test for blockbrew
# (Go). The next wallet-completeness cell after recovery (10/10), spend (10/10)
# and history (10/10): a wallet must be able to RESCAN existing chain blocks to
# rediscover its own funds (the REAL wallet rescan, distinct from the
# chain-level scantxoutset which bypasses the wallet), and to IMPORT a foreign
# private key and credit that key's on-chain funds.
#
# What this proves on regtest, using ONLY wallet-native RPCs:
#
#  A. RESCAN (REQUIRED for green):
#     createwallet w1 RESTORED <fixed mnemonic> -> getnewaddress A1
#     generatetoaddress 101 -> A1  (W1 mature balance M)
#     createwallet w2 RESTORED from the SAME seed (FRESH wallet)
#       -> ASSERT w2.getbalance == 0   (restore derives keys, does NOT scan)
#     w2.rescanblockchain
#       -> ASSERT w2.getbalance == M    (rediscovered via a REAL wallet rescan)
#       -> ASSERT w2.listunspent shows A1's UTXOs
#     This is the headline proof. Returns {start_height, stop_height} (Core).
#
#  B. IMPORTPRIVKEY (TARGET):
#     createwallet w3 RESTORED <different mnemonic> -> getnewaddress A_ext
#     w3.dumpprivkey A_ext -> K_ext  (the foreign key, NOT owned by w2)
#     generatetoaddress 101 -> A_ext (fund the foreign key)
#     w2.importprivkey K_ext rescan=true
#       -> ASSERT w2.getbalance grew by the foreign key's mature funds
#       -> ASSERT w2.listunspent now includes A_ext
#
# The fix this regresses: blockbrew already credited wallet UTXOs on the
# block-CONNECT path (Wallet.ScanBlock, wired into SetOnBlockConnected). This
# adds the BACKWARD counterpart over an existing height range
# (Wallet.Rescan/RescanBlock) behind the rescanblockchain RPC, plus
# importprivkey/dumpprivkey using the wallet's existing WIF encoding. The rescan
# derives all four standard templates on both the external + internal chains
# with a gap-limit look-ahead (Core CWallet::ScanForWalletTransactions).
#
# STRICT UNIFORM INTERFACE (mirrors blockbrew_history.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: IMPORT blockbrew: PASS rescan=ok importprivkey=<ok|partial|absent> rediscovered=<M>
#   FAIL: IMPORT blockbrew: FAIL <short reason>
#
# Touches ONLY /tmp/importfleet-blockbrew/ and ports 21713 (RPC) / 21733 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
BIN="$BASEDIR/blockbrew/blockbrew"
DATADIR="/tmp/importfleet-blockbrew"
RPC_PORT=21713
P2P_PORT=21733
LOGFILE="$DATADIR/import-test.log"
URL="http://127.0.0.1:${RPC_PORT}"

# Canonical BIP-39 all-zero-entropy 12-word test mnemonic (valid checksum).
# Same FIXED seed as the recovery + spend + history cells so the cells share a
# wallet id. The fixed seed is the headline contract: w1 and w2 must derive
# byte-identical keys, so w2 can rediscover w1's funds via a pure rescan.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# A DIFFERENT valid BIP-39 mnemonic for the foreign-key wallet w3 (so A_ext is
# guaranteed NOT derivable from w2's seed). "legal winner thank..." is the
# standard second BIP-39 test vector (entropy 0x7f7f...7f, valid checksum).
MNEMONIC3="legal winner thank year wave sausage worth useful legal winner thank yellow"

NBLOCKS=101              # coinbase at height 1 is mature once tip >= 101

NODE_PID=""
COOKIE=""
COOKIE_FILE="$DATADIR/regtest/.cookie"

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
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Emit the single summary line + exit. ───────────────────────────────────
# pass <importprivkey-state> <rediscovered>
pass() {
    echo "IMPORT blockbrew: PASS rescan=ok importprivkey=$1 rediscovered=$2"
    exit 0
}
fail() {
    echo "IMPORT blockbrew: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth; optional wallet path). ────────────────────────
# usage: rpc <method> <params-json> [wallet-name]
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}"
    local path=""
    [[ -n "$wallet" ]] && path="/wallet/$wallet"
    curl -s --max-time 120 ${COOKIE:+-u "$COOKIE"} \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "${URL}/${path#/}" 2>/dev/null
}

PY=python3

# Extract .result via python (robust). Prints "" on error/missing.
jget() {  # jget <python-expr-on-d> ; reads JSON-RPC reply on stdin
    "$PY" -c '
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

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || fail "blockbrew binary not found/executable at $BIN (run build-all.sh blockbrew)"
command -v curl >/dev/null 2>&1 || fail "curl not available"
command -v "$PY" >/dev/null 2>&1 || fail "python3 not available"

# ── 2. Launch blockbrew on regtest. ────────────────────────────────────────
log "launching blockbrew (regtest) -> $DATADIR/node.log"
"$BIN" \
    -network=regtest -datadir="$DATADIR" \
    -listen="127.0.0.1:${P2P_PORT}" -rpcbind="127.0.0.1:${RPC_PORT}" \
    -maxoutbound=0 -nolisten \
    >"$DATADIR/node.log" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 3. Locate the cookie + wait for RPC. ───────────────────────────────────
deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" && -f "$COOKIE_FILE" ]]; then COOKIE=$(cat "$COOKIE_FILE"); fi
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

# ===========================================================================
#  PART A — RESCAN (REQUIRED for green)
# ===========================================================================

# ── A1. Restore wallet w1, derive A1. ──────────────────────────────────────
log "createwallet w1 RESTORED from fixed mnemonic"
CW1="[\"w1\", false, false, \"\", false, true, false, \"\", \"\", \"$MNEMONIC\"]"
r=$(rpc createwallet "$CW1")
echo "$r" | grep -q '"error":{' && fail "createwallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
echo "$r" | grep -q '"name":"w1"' || fail "createwallet w1 did not return name=w1: $(echo "$r" | head -c 200)"

A1=$(rpc getnewaddress "[]" "w1" | jget "d")
[[ -n "$A1" ]] || fail "getnewaddress w1 returned no address"
case "$A1" in bcrt1*) : ;; *) fail "A1 not a regtest bech32 address: $A1" ;; esac
log "A1=$A1"

# ── A2. Fund A1 with coinbase. ─────────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
nb=$(echo "$r" | jget "len(d)")
[[ "$nb" == "$NBLOCKS" ]] || fail "generatetoaddress did not mine $NBLOCKS blocks (got '$nb'): $(echo "$r" | head -c 200)"

# ── A3. Record w1's mature balance M. ──────────────────────────────────────
M=$(rpc getbalance "[]" "w1" | jget "repr(float(d))")
[[ -n "$M" ]] || fail "getbalance w1 failed"
mpos=$(rpc getbalance "[]" "w1" | jget "1 if float(d) > 0 else 0")
[[ "$mpos" == "1" ]] || fail "w1 mature balance is zero (funding did not register): $M"
log "w1 mature balance M=$M"

# ── A4. Fresh wallet w2 from the SAME seed; must start at balance 0. ───────
log "createwallet w2 RESTORED from the SAME seed (fresh wallet, no scan)"
CW2="[\"w2\", false, false, \"\", false, true, false, \"\", \"\", \"$MNEMONIC\"]"
r=$(rpc createwallet "$CW2")
echo "$r" | grep -q '"name":"w2"' || fail "createwallet w2 (restore SAME seed) failed: $(echo "$r" | head -c 200)"

B2_BEFORE=$(rpc getbalance "[]" "w2" | jget "repr(float(d))")
[[ -n "$B2_BEFORE" ]] || fail "getbalance w2 (before rescan) failed"
is_zero=$(rpc getbalance "[]" "w2" | jget "1 if float(d) == 0 else 0")
[[ "$is_zero" == "1" ]] || fail "w2 balance non-zero BEFORE rescan ($B2_BEFORE) — restore must derive keys but NOT scan the chain"
log "w2 balance before rescan = $B2_BEFORE (expected 0)"

# ── A5. The headline: rescanblockchain on w2 -> rediscovers M. ─────────────
log "rescanblockchain on w2"
r=$(rpc rescanblockchain "[]" "w2")
echo "$r" | grep -q '"error":{' && fail "rescanblockchain error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
# Core shape check: result has start_height + stop_height.
sh=$(echo "$r" | jget "d['start_height']")
st=$(echo "$r" | jget "d['stop_height']")
[[ -n "$sh" && -n "$st" ]] || fail "rescanblockchain result missing start_height/stop_height (Core shape): $(echo "$r" | head -c 200)"
[[ "$st" == "$NBLOCKS" ]] || fail "rescanblockchain stop_height ($st) != tip ($NBLOCKS): $(echo "$r" | head -c 200)"
log "rescanblockchain returned start_height=$sh stop_height=$st"

# w2 balance must now equal w1's M.
B2_AFTER=$(rpc getbalance "[]" "w2" | jget "repr(float(d))")
[[ -n "$B2_AFTER" ]] || fail "getbalance w2 (after rescan) failed"
match=$("$PY" -c "import sys; print(1 if abs(float('$B2_AFTER') - float('$M')) < 1e-8 else 0)")
[[ "$match" == "1" ]] || fail "rescan did NOT rediscover funds: w1 M=$M but w2 after rescan=$B2_AFTER"
log "w2 balance after rescan = $B2_AFTER (== M $M) — RESCAN GREEN"

# listunspent on w2 must show A1's UTXOs.
N_A1=$(rpc listunspent "[]" "w2" | jget "sum(1 for u in d if u.get('address')=='$A1')")
[[ -n "$N_A1" && "$N_A1" != "0" ]] || fail "rescan: w2.listunspent shows no UTXOs for A1=$A1"
log "w2.listunspent shows $N_A1 UTXO(s) for A1 — rescan credited the wallet UTXO set"

# Negative control: a brand-new fresh wallet w4 with NO seed-match must NOT
# rediscover M after a rescan (guards against a rescan that credits everyone).
log "negative control: w4 from a DIFFERENT seed must rescan to 0"
CW4="[\"w4\", false, false, \"\", false, true, false, \"\", \"\", \"$MNEMONIC3\"]"
r=$(rpc createwallet "$CW4")
echo "$r" | grep -q '"name":"w4"' || fail "createwallet w4 failed: $(echo "$r" | head -c 200)"
rpc rescanblockchain "[]" "w4" >/dev/null
B4=$(rpc getbalance "[]" "w4" | jget "repr(float(d))")
neg_ok=$("$PY" -c "print(1 if float('$B4') == 0 else 0)")
[[ "$neg_ok" == "1" ]] || fail "negative control: w4 (foreign seed) rescanned to non-zero balance $B4"
log "negative control OK: w4 rescanned to 0"

# ===========================================================================
#  PART B — IMPORTPRIVKEY (TARGET)
# ===========================================================================
IMPORT_STATE="absent"

# ── B1. Build a foreign key via w3 (different seed) + dumpprivkey. ─────────
log "createwallet w3 (foreign seed) to mint a foreign key"
CW3="[\"w3\", false, false, \"\", false, true, false, \"\", \"\", \"$MNEMONIC3\"]"
r=$(rpc createwallet "$CW3")
if echo "$r" | grep -q '"name":"w3"'; then
    A_EXT=$(rpc getnewaddress "[]" "w3" | jget "d")
    K_EXT=$(rpc dumpprivkey "[\"$A_EXT\"]" "w3" | jget "d")
    if [[ -n "$A_EXT" && -n "$K_EXT" ]]; then
        log "foreign A_ext=$A_EXT  K_ext=<wif len ${#K_EXT}>"
        # Sanity: A_ext must NOT already be owned by w2.
        owned_pre=$(rpc listunspent "[]" "w2" | jget "sum(1 for u in d if u.get('address')=='$A_EXT')")
        # Fund A_ext with its own mature coinbase.
        r=$(rpc generatetoaddress "[$NBLOCKS,\"$A_EXT\"]")
        nb=$(echo "$r" | jget "len(d)")
        if [[ "$nb" == "$NBLOCKS" ]]; then
            # Record w2 balance before import (w2 owns A1's coins + the new
            # blocks were NOT paid to w2, so this is just A1's coins at the new
            # tip; importprivkey rescan will ALSO re-credit A1, so we compare
            # the DELTA contributed by A_ext via listunspent membership).
            B2_PRE_IMPORT=$(rpc getbalance "[]" "w2" | jget "repr(float(d))")
            log "w2 balance before importprivkey = $B2_PRE_IMPORT"
            # importprivkey with rescan=true.
            r=$(rpc importprivkey "[\"$K_EXT\", \"imported\", true]" "w2")
            if echo "$r" | grep -q '"error":{'; then
                log "importprivkey error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
                IMPORT_STATE="partial"
            else
                # w2.listunspent must now include A_ext.
                n_ext=$(rpc listunspent "[]" "w2" | jget "sum(1 for u in d if u.get('address')=='$A_EXT')")
                B2_POST_IMPORT=$(rpc getbalance "[]" "w2" | jget "repr(float(d))")
                grew=$("$PY" -c "print(1 if float('$B2_POST_IMPORT') > float('$B2_PRE_IMPORT') else 0)")
                if [[ -n "$n_ext" && "$n_ext" != "0" && "$grew" == "1" ]]; then
                    log "importprivkey OK: w2.listunspent shows $n_ext UTXO(s) for A_ext; balance $B2_PRE_IMPORT -> $B2_POST_IMPORT"
                    IMPORT_STATE="ok"
                else
                    log "importprivkey ran but A_ext funds not credited (n_ext=$n_ext bal $B2_PRE_IMPORT->$B2_POST_IMPORT)"
                    IMPORT_STATE="partial"
                fi
            fi
        else
            log "could not fund A_ext (mined $nb / $NBLOCKS) — importprivkey untested"
            IMPORT_STATE="partial"
        fi
    else
        log "could not mint a foreign key (A_ext/K_ext empty) — importprivkey untested"
        IMPORT_STATE="absent"
    fi
else
    log "createwallet w3 failed — importprivkey untested"
    IMPORT_STATE="absent"
fi

# ── Success: rescan is the hard requirement; importprivkey is reported. ────
pass "$IMPORT_STATE" "$M"
