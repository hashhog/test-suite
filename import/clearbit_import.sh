#!/usr/bin/env bash
#
# clearbit_import.sh — self-contained wallet IMPORT+RESCAN regression test.
#
# Codifies the wallet IMPORT+RESCAN cell for clearbit, the successor to the
# recovery / spend / history cells. Proves, end to end on a throwaway regtest
# node, that clearbit performs a REAL wallet rescan (rescanblockchain) — the
# BACKWARD counterpart of the block-connect wallet scan it already wires — plus
# importprivkey (decode a WIF + add the key + rescan to credit that key's
# funds).
#
#   A. RESCAN (REQUIRED for green) — a REAL wallet rescan that scans EXISTING
#      chain blocks for outputs paying wallet-owned scripts and credits them
#      into the wallet's own UTXO ledger / history (NOT scantxoutset, which
#      bypasses the wallet):
#        - createwallet w1 (blank) -> sethdseed(FIXED SEED) -> getnewaddress A1
#        - generatetoaddress 101 A1   -> W1 mature balance M (50 BTC: the
#          height-1 coinbase matured at tip 101)
#        - fresh wallet w2 -> sethdseed(SAME SEED) -> getnewaddress (must == A1)
#        - W2.getbalance == 0   (restore derives keys but does NOT scan the chain)
#        - W2.rescanblockchain -> {start_height:0, stop_height:101}  (Core shape)
#        - W2.getbalance == M  AND  W2.listunspent shows A1's UTXOs
#          (the wallet rediscovered its funds via a REAL wallet rescan).
#
#   B. IMPORTPRIVKEY (TARGET) — decode a WIF, add the key + its scripts to the
#      wallet, and (rescan=true) credit that key's existing funds:
#        - foreign wallet wf (DIFFERENT seed) -> getnewaddress A_ext (P2PKH so
#          it commits to hash160 and dumpprivkey can export it)
#        - dumpprivkey(A_ext) -> WIF K_ext  (A_ext/K_ext are foreign to W2)
#        - generatetoaddress 101 A_ext   (fund A_ext's coinbase to maturity)
#        - W2.importprivkey(K_ext, "ext", rescan=true)
#        - W2.getbalance now ALSO includes A_ext's mature funds.
#
# Reference shapes/semantics: bitcoin-core/src/wallet/rpc/transactions.cpp
# (rescanblockchain -> {start_height, stop_height}) and wallet/rpc/backup.cpp
# (importprivkey decodes a WIF + rescans; dumpprivkey exports a WIF).
#
# clearbit divergence (documented in the recovery/history cells): sethdseed
# takes a HEX seed (not a Core WIF) so a known seed restores byte-for-byte.
#
# STRICT UNIFORM INTERFACE (mirrors clearbit_history.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout; all noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: IMPORT clearbit: PASS rescan=ok importprivkey=<ok|partial|absent> rediscovered=<M>
#   FAIL: IMPORT clearbit: FAIL <short reason>
# Green REQUIRES rescan=ok (exit 0). Any rescan failure -> FAIL (exit 1).
#
# Touches ONLY /tmp/importfleet-clearbit/ and ports 39817 (RPC) / 39837 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
IMPL="clearbit"
RPC_PORT=39817
P2P_PORT=39837
DATADIR="/tmp/importfleet-clearbit"
NETDIR="$DATADIR/regtest"          # clearbit appends the network subdir
COOKIE_FILE="$NETDIR/.cookie"
LOGFILE="$DATADIR/node.log"
BASE="http://127.0.0.1:$RPC_PORT"

# Resolve the binary the same way build-all.sh / smoke-harness.sh do.
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"

# The FIXED 16-byte BIP-32 test seed (hex) the recovery + spend + history cells
# use, so the four cells share the same wallet identity.
SEED="000102030405060708090a0b0c0d0e0f"
# A DIFFERENT seed for the FOREIGN wallet (the importprivkey source).
FOREIGN_SEED="ffeeddccbbaa99887766554433221100"

# Coinbase maturity on regtest is 100 blocks. Mine 101 so the first reward
# (height 1) is mature/spendable at tip 101 -> M = 50 BTC.
NBLOCKS=101
M_EXPECT="50.00000000"   # the matured-coinbase balance after rescan to tip 101

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy goes to stderr, never stdout. ────────────────
log() { echo "[import] $*" >&2; }

# ── Cleanup trap: always kill node + wipe scratch datadir on any exit. ─────
kill_port() {
    fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
    fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
}
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
    kill_port
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Emit the single summary line + exit. ───────────────────────────────────
# pass <importprivkey-state> <rediscovered-amount>
pass() {
    echo "IMPORT $IMPL: PASS rescan=ok importprivkey=$1 rediscovered=$2"
    exit 0
}
fail() {
    echo "IMPORT $IMPL: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth; wallet path). ─────────────────────────────────
# usage: rpc <path> <method> <params-json>
rpc() {
    local path="$1" method="$2" params="${3:-[]}"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$BASE$path" 2>/dev/null
}

# Extract a numeric "result":N scalar (integer or decimal) from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":-\?[0-9.]*' | head -1 | sed 's/"result"://'
}
# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}
has_error() { echo "$1" | grep -q '"error":{'; }
err_msg() { echo "$1" | grep -o '"message":"[^"]*"' | head -1; }

# Float equality with a small epsilon (BTC amounts are floats).
floats_equal() {
    python3 -c '
import sys
a, b = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if abs(a - b) < 1e-6 else 1)
' "$1" "$2"
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
kill_port
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR" || fail "cannot create scratch $DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || fail "binary not found at $BIN (build clearbit first: zig build -Doptimize=ReleaseFast)"

# ── 2. Launch clearbit on regtest. ─────────────────────────────────────────
log "launching clearbit (regtest) -> $LOGFILE"
"$BIN" --regtest --datadir="$DATADIR" --port="$P2P_PORT" --rpcport="$RPC_PORT" \
    >"$LOGFILE" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"
sleep 1
kill -0 "$NODE_PID" 2>/dev/null || fail "node exited immediately (see $LOGFILE)"

# ── 3. Locate the cookie + wait for RPC. ───────────────────────────────────
deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" && -f "$COOKIE_FILE" ]]; then
        COOKIE="$(cat "$COOKIE_FILE" 2>/dev/null)"
    fi
    if [[ -n "$COOKIE" ]]; then
        r=$(rpc "/" getblockcount)
        if echo "$r" | grep -q '"result"'; then
            log "RPC ready: $r"
            break
        fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $LOGFILE)"
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 45s"
r=$(rpc "/" getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 45s"

# ════════════════════════════════════════════════════════════════════════════
# A. RESCAN (REQUIRED) — the headline proof.
# ════════════════════════════════════════════════════════════════════════════

# ── 4. Create blank wallet w1, restore FIXED seed, derive A1. ──────────────
log "createwallet w1 (blank) + sethdseed restore"
r=$(rpc "/" createwallet '["w1",false,true]')
has_error "$r" && fail "createwallet w1: $(err_msg "$r")"
r=$(rpc "/wallet/w1" sethdseed "[true,\"$SEED\"]")
has_error "$r" && fail "sethdseed w1: $(err_msg "$r")"

A1=$(result_str "$(rpc "/wallet/w1" getnewaddress "[]")")
[[ -n "$A1" ]] || fail "getnewaddress w1 returned no address"
log "A1=$A1"

# ── 5. Fund A1 with coinbase -> W1 mature balance M. ───────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc "/" generatetoaddress "[$NBLOCKS,\"$A1\"]")
has_error "$r" && fail "generatetoaddress error: $(err_msg "$r")"
HEIGHT=$(result_num "$(rpc "/" getblockcount)")
[[ "${HEIGHT:-0}" -eq "$NBLOCKS" ]] || fail "unexpected tip height $HEIGHT (expected $NBLOCKS)"

M=$(result_num "$(rpc "/wallet/w1" getbalance "[]")")
[[ -n "$M" ]] || fail "w1 getbalance returned nothing"
floats_equal "$M" "$M_EXPECT" || fail "w1 mature balance $M != expected $M_EXPECT"
case "$M" in 0|0.0|0.00000000|"") fail "w1 mature balance is zero (funding did not take)" ;; esac
log "W1 mature balance M=$M"

# ── 6. Fresh wallet w2, restore SAME seed, re-derive A1 (must match). ──────
r=$(rpc "/" createwallet '["w2",false,true]')
has_error "$r" && fail "createwallet w2: $(err_msg "$r")"
r=$(rpc "/wallet/w2" sethdseed "[true,\"$SEED\"]")
has_error "$r" && fail "sethdseed w2 (restore): $(err_msg "$r")"
A1b=$(result_str "$(rpc "/wallet/w2" getnewaddress "[]")")
[[ -n "$A1b" ]] || fail "getnewaddress w2 returned empty"
[[ "$A1b" == "$A1" ]] || fail "address mismatch after restore: orig=$A1 restored=$A1b"
log "w2 re-derived A1 == original (restore deterministic)"

# ── 7. W2 balance BEFORE rescan must be 0 (restore derives keys, no scan). ─
BAL_PRE=$(result_num "$(rpc "/wallet/w2" getbalance "[]")")
floats_equal "${BAL_PRE:-0}" "0" || fail "w2 balance non-zero BEFORE rescan (got $BAL_PRE) — restore must not scan the chain"
log "w2 balance BEFORE rescan = ${BAL_PRE:-0} (as expected: restore does not scan)"

# Also confirm listunspent is empty pre-rescan.
LU_PRE=$(rpc "/wallet/w2" listunspent "[]")
NPRE=$(echo "$LU_PRE" | grep -o '"txid"' | wc -l | tr -d ' ')
[[ "${NPRE:-0}" -eq 0 ]] || fail "w2 listunspent not empty BEFORE rescan (got $NPRE entries)"

# ── 8. THE HEADLINE: rescanblockchain on w2 -> rediscovers M. ──────────────
log "rescanblockchain (w2)"
RB=$(rpc "/wallet/w2" rescanblockchain "[]")
has_error "$RB" && fail "rescanblockchain error: $(err_msg "$RB")"
# Assert Core-shaped {start_height:0, stop_height:tip}.
RB_CHECK=$(HEIGHT="$HEIGHT" python3 -c '
import sys, json, os
raw = sys.argv[1]
try:
    obj = json.loads(raw)["result"]
except Exception as e:
    print(f"FAIL parse: {e}"); sys.exit(0)
if not isinstance(obj, dict):
    print(f"FAIL result not an object: {obj}"); sys.exit(0)
if obj.get("start_height") != 0:
    print(f"FAIL start_height != 0: {obj.get(chr(39)+chr(115)+chr(116)+chr(97)+chr(114)+chr(116)+chr(95)+chr(104)+chr(101)+chr(105)+chr(103)+chr(104)+chr(116)+chr(39))}"); sys.exit(0)
tip = int(os.environ["HEIGHT"])
if obj.get("stop_height") != tip:
    print(f"FAIL stop_height {obj.get(chr(39)+chr(115)+chr(116)+chr(111)+chr(112)+chr(95)+chr(104)+chr(101)+chr(105)+chr(103)+chr(104)+chr(116)+chr(39))} != tip {tip}"); sys.exit(0)
print("OK")
' "$RB")
[[ "$RB_CHECK" == "OK" ]] || fail "rescanblockchain shape: $RB_CHECK"
log "rescanblockchain returned Core-shaped {start_height:0, stop_height:$HEIGHT}"

# ── 9. W2 balance AFTER rescan == M (funds rediscovered via wallet rescan). ─
BAL_POST=$(result_num "$(rpc "/wallet/w2" getbalance "[]")")
[[ -n "$BAL_POST" ]] || fail "w2 getbalance returned nothing after rescan"
floats_equal "$BAL_POST" "$M" || fail "w2 balance after rescan ($BAL_POST) != M ($M)"
log "w2 balance after rescan = $BAL_POST == M (funds rediscovered via REAL wallet rescan)"

# ── 10. W2 listunspent shows A1's UTXOs after rescan. ──────────────────────
# clearbit's listunspent reports {txid,vout,amount,confirmations,...} (no
# address field). A1 received all $NBLOCKS coinbases, so the rescan must have
# credited exactly $NBLOCKS owned UTXOs into w2 — and their TOTAL amount
# (mature + immature) must be $NBLOCKS * 50 BTC. (getbalance == M above already
# proves the MATURE subset; this proves the full set was rediscovered.)
LU=$(rpc "/wallet/w2" listunspent "[]")
has_error "$LU" && fail "listunspent errored after rescan"
NLU=$(echo "$LU" | grep -o '"txid"' | wc -l | tr -d ' ')
[[ "${NLU:-0}" -eq "$NBLOCKS" ]] || fail "listunspent has $NLU UTXOs after rescan (expected $NBLOCKS — one per coinbase to A1)"
LU_SUM=$(echo "$LU" | python3 -c '
import sys, json
try:
    res = json.load(sys.stdin)["result"]
except Exception as e:
    print(f"ERR {e}"); sys.exit(0)
print(f"{sum(float(u[chr(97)+chr(109)+chr(111)+chr(117)+chr(110)+chr(116)]) for u in res):.8f}")
')
case "$LU_SUM" in ERR*) fail "listunspent parse: $LU_SUM" ;; esac
EXPECT_TOTAL=$(python3 -c "print(f'{$NBLOCKS * 50.0:.8f}')")
floats_equal "$LU_SUM" "$EXPECT_TOTAL" || fail "listunspent total ($LU_SUM) != $EXPECT_TOTAL after rescan"
log "w2 listunspent shows $NLU UTXO(s) totalling $LU_SUM (= $NBLOCKS coinbases to A1) after rescan -> RESCAN GREEN"

# ════════════════════════════════════════════════════════════════════════════
# B. IMPORTPRIVKEY (TARGET) — foreign WIF import + rescan.
# ════════════════════════════════════════════════════════════════════════════
IMPORT_STATE="absent"

# ── 11. Build the foreign key via a second wallet (different seed). ────────
# wf uses a DIFFERENT seed so its address/key are foreign to w2. We use a
# P2PKH (legacy) address so dumpprivkey can export the WIF (it commits to
# hash160 of the compressed pubkey).
log "constructing foreign key via wallet wf (different seed) + dumpprivkey"
r=$(rpc "/" createwallet '["wf",false,true]')
if has_error "$r"; then
    log "WARN createwallet wf failed ($(err_msg "$r")) -> importprivkey=absent"
else
    r=$(rpc "/wallet/wf" sethdseed "[true,\"$FOREIGN_SEED\"]")
    if has_error "$r"; then
        log "WARN sethdseed wf failed -> importprivkey=absent"
    else
        # getnewaddress with the "legacy" type -> P2PKH (hash160-committing).
        A_EXT=$(result_str "$(rpc "/wallet/wf" getnewaddress "[\"\",\"legacy\"]")")
        [[ -z "$A_EXT" ]] && A_EXT=$(result_str "$(rpc "/wallet/wf" getnewaddress "[\"\",[\"legacy\"]]")")
        if [[ -z "$A_EXT" ]]; then
            log "WARN could not derive a legacy A_ext -> importprivkey=absent"
        else
            log "A_ext=$A_EXT"
            WIF=$(result_str "$(rpc "/wallet/wf" dumpprivkey "[\"$A_EXT\"]")")
            if [[ -z "$WIF" ]]; then
                log "WARN dumpprivkey returned empty -> importprivkey=absent"
            else
                log "foreign WIF obtained (len ${#WIF})"
                # A_ext comes from a DIFFERENT seed than w2 so it is foreign by
                # construction (sanity: it must not equal A1).
                if [[ "$A_EXT" == "$A1" ]]; then
                    log "WARN A_ext collided with A1 -> importprivkey=absent"
                else
                    # Fund A_ext with coinbase to maturity.
                    log "generatetoaddress 101 -> A_ext (fund the foreign key)"
                    r=$(rpc "/" generatetoaddress "[101,\"$A_EXT\"]")
                    if has_error "$r"; then
                        log "WARN funding A_ext failed -> importprivkey=partial"
                        IMPORT_STATE="partial"
                    else
                        BAL_BEFORE_IMPORT=$(result_num "$(rpc "/wallet/w2" getbalance "[]")")
                        NLU_BEFORE=$(rpc "/wallet/w2" listunspent "[]" | grep -o '"txid"' | wc -l | tr -d ' ')
                        log "w2 balance before importprivkey = $BAL_BEFORE_IMPORT (utxos=$NLU_BEFORE)"
                        IP=$(rpc "/wallet/w2" importprivkey "[\"$WIF\",\"ext\",true]")
                        if has_error "$IP"; then
                            log "WARN importprivkey errored: $(err_msg "$IP") -> importprivkey=partial"
                            IMPORT_STATE="partial"
                        else
                            BAL_AFTER_IMPORT=$(result_num "$(rpc "/wallet/w2" getbalance "[]")")
                            NLU_AFTER=$(rpc "/wallet/w2" listunspent "[]" | grep -o '"txid"' | wc -l | tr -d ' ')
                            log "w2 balance after importprivkey = $BAL_AFTER_IMPORT (utxos=$NLU_AFTER)"
                            # The imported key must add mature funds: balance
                            # strictly increased AND listunspent gained UTXOs
                            # (clearbit's listunspent carries no address field,
                            # so we detect the credit by balance + UTXO-count
                            # growth — the imported foreign key's coins).
                            GREW=$(python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) + 1e-6 else 1)' "${BAL_AFTER_IMPORT:-0}" "${BAL_BEFORE_IMPORT:-0}" && echo yes || echo no)
                            if [[ "$GREW" == "yes" ]] && [[ "${NLU_AFTER:-0}" -gt "${NLU_BEFORE:-0}" ]]; then
                                IMPORT_STATE="ok"
                                log "importprivkey GREEN: w2 now sees A_ext's funds ($BAL_BEFORE_IMPORT -> $BAL_AFTER_IMPORT; utxos $NLU_BEFORE -> $NLU_AFTER)"
                            else
                                log "WARN importprivkey did not credit A_ext funds (grew=$GREW, utxos $NLU_BEFORE->$NLU_AFTER) -> importprivkey=partial"
                                IMPORT_STATE="partial"
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

# ── 12. Success (rescan is GREEN; importprivkey state reported). ───────────
log "PASS: rescan=ok importprivkey=$IMPORT_STATE rediscovered=$BAL_POST"
pass "$IMPORT_STATE" "$BAL_POST"
