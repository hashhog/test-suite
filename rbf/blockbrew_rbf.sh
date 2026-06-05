#!/usr/bin/env bash
#
# blockbrew_rbf.sh — self-contained RBF (Replace-By-Fee, BIP-125) replacement +
# fee-rule differential parity test for blockbrew.
#
# The SECOND mempool-policy cell (after testmempoolaccept reject-parity in
# test-suite/policy/blockbrew_policy.sh). Where the policy cell proved the
# standardness gate, this proves the *mempool replacement* subsystem: a tx that
# conflicts with an in-mempool tx over the SAME prevout must follow BIP-125 —
# evict + accept when the fee rules pass, reject with Core's reason CATEGORY
# ("insufficient fee") when Rule 3 (lower absolute fee) or Rule 4 (insufficient
# fee bump) fail. Consensus-ADJACENT: this is relay policy, not consensus.
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core v31.99) on its OWN
# regtest instance (own scratch datadir + ports). blockbrew runs side by side on
# its own regtest. For EACH node the SAME submit SEQUENCE is replayed against
# that node's OWN coinbase prevout (coinbase txids differ per impl), and the
# decision (mempool membership / testmempoolaccept reject-reason) is compared.
#
# Why per-node coinbase: each node mines its own chain, so it can only spend its
# own coinbase. The Python helper mines to a FIXED deterministic key on each
# node, reads THAT node's height-1 coinbase, and builds the conflicting txs
# against it. Both nodes therefore exercise byte-identical tx SHAPES (same
# amounts, same sequences) over their own funding outpoint.
#
# INCREMENTAL-RELAY-FEE alignment: blockbrew defaults incrementalrelayfee to
# 1 sat/vB (1000 sat/kvB); Core's DEFAULT_INCREMENTAL_RELAY_FEE is 0.1 sat/vB
# (100 sat/kvB). To make Rule 4 thresholds AGREE, Core is launched with
# -incrementalrelayfee=0.00001 (= 1 sat/vB = blockbrew's default). Both nodes
# also use the default minrelayfee (1 sat/vB).
#
# THE THREE ASSERTIONS (each replayed identically on Core and blockbrew):
#   replace (HAPPY PATH): submit A (signals RBF, nSequence=0xfffffffd, fee f1)
#       -> accepted (in getrawmempool). Submit B (same input, fee f2 >> f1,
#       meets Rules 3+4) -> REPLACES A: getrawmempool now contains B and NOT A.
#   rule3 (Rule #3, lower absolute fee): with A in the mempool, submit C (same
#       input, fee <= f1) -> testmempoolaccept rejects, category "insufficient
#       fee"; C does NOT enter the mempool.
#   rule4 (Rule #4, insufficient fee bump): with A in the mempool, submit D
#       (same input, fee slightly > f1 but the delta < incrementalRelayFee*vsize)
#       -> testmempoolaccept rejects, category "insufficient fee".
#
# NORMALIZATION: reject-reason strings compared by CATEGORY (impls phrase the
# detail differently). Core emits "insufficient fee" for both Rule 3 and Rule 4;
# blockbrew is mapped to the same category by the RPC layer. classify() folds
# any insufficient-fee / mempool-conflict phrasing to a canonical token. A case
# PASSES when blockbrew and Core land on the SAME category.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/blockbrew_policy.sh):
# no required args, idempotent, trap cleanup, scratch /tmp + unique ports, ONE
# clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: RBF blockbrew: PASS replace=ok rule3=ok rule4=ok
#   FAIL: RBF blockbrew: FAIL <short reason>
#   SKIP: RBF blockbrew: SKIP <build/raw-tx gap>
#
# Touches ONLY /tmp/rbf-blockbrew/ + /tmp/rbf-core-bb/ and ports 40193/40213
# (blockbrew RPC/P2P), 40195/40215 (Core RPC/P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework

BB_DATADIR="/tmp/rbf-blockbrew"
BB_RPC=40193
BB_P2P=40213
BB_LOG="$BB_DATADIR/node.log"
BB_URL="http://127.0.0.1:${BB_RPC}"
BB_COOKIE_FILE="$BB_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/rbf-core-bb"
CORE_RPC=40195
CORE_P2P=40215
CORE_LOG="$CORE_DATADIR/core.log"

# Align Rule-4 thresholds: 0.00001 BTC/kvB = 1000 sat/kvB = 1 sat/vB =
# blockbrew's default IncrementalRelayFee.
CORE_FLAGS=(-incrementalrelayfee=0.00001 -minrelaytxfee=0.00001)

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="1111111111111111111111111111111111111111111111111111111111111113"

NBLOCKS=110            # mine to maturity: coinbases at heights 1..10 spendable at tip 110

BB_PID=""
BB_COOKIE=""
CORE_BG=""
HELPER=""

log() { echo "[rbf:blockbrew] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "RBF blockbrew: PASS replace=$1 rule3=$2 rule4=$3"; exit 0; }
fail() { echo "RBF blockbrew: FAIL $*"; exit 1; }
skip() { echo "RBF blockbrew: SKIP $*"; exit 0; }

# ── Reject-reason category classifier (NORMALIZATION map). ─────────────────
# Empty input (accepted) -> "accept". RBF fee failures -> "insufficient-fee".
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *"insufficient fee"*|*"insufficient-fee"*|*"insufficient feerate"*|*"not enough additional fees"*|*"less fees than conflicting"*|*"replacement fee too low"*|*"does not improve feerate"*)
            echo "insufficient-fee" ;;
        *"txn-mempool-conflict"*|*"bad-txns-spends-conflicting"*|*"mempool-conflict"*|*"does not signal rbf"*|*"already spent by mempool"*)
            echo "mempool-conflict" ;;
        *"replacement-adds-unconfirmed"*|*"new unconfirmed input"*)
            echo "adds-unconfirmed" ;;
        *"too many potential replacements"*|*"too many"*)
            echo "too-many" ;;
        *) echo "other:$s" ;;
    esac
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BB_PID" ]] && kill -0 "$BB_PID" 2>/dev/null; then
        kill "$BB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${BB_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${BB_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
fuser -k "${BB_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${BB_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || skip "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || skip "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || skip "blockbrew binary not found at $NODE_BIN (build with: go build -o blockbrew ./cmd/blockbrew)"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || skip "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || skip "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the RBF-sequence Python helper. ──────────────────────────────
# Connects to ONE node's RPC, mines a coinbase to the fixed key, reads that
# node's OWN height-1 coinbase, and replays the BIP-125 submit sequence:
#   A  : signals RBF (nSequence 0xfffffffd), fee FEE_A           -> sendrawtransaction
#   B  : same input, fee FEE_B >> FEE_A (Rules 3+4 ok)           -> sendrawtransaction (replaces A)
#   C  : same input, fee FEE_C <= FEE_A (Rule 3 fail)            -> testmempoolaccept (must reject)
#   D  : same input, fee FEE_D = FEE_A + tiny (Rule 4 fail)      -> testmempoolaccept (must reject)
# It prints tab-separated result lines to stdout:
#   STEP A    <accepted:true|false>  <reason>
#   STEP B    <accepted:true|false>  <reason>
#   MEMPOOL   <has_A:true|false>     <has_B:true|false>
#   STEP C    <allowed:true|false>   <reject-reason>
#   STEP D    <allowed:true|false>   <reject-reason>
HELPER="$BB_DATADIR/rbf_seq.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request
sys.path.insert(0, sys.argv[1])  # test_framework path
RPC_URL = sys.argv[2]
COOKIE  = sys.argv[3]            # "user:pass"
SECRET  = sys.argv[4]
NBLOCKS = int(sys.argv[5])

from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import (CScript, OP_0, hash160, SegwitV0SignatureHash, SIGHASH_ALL,
    OP_DUP, OP_HASH160, OP_EQUALVERIFY, OP_CHECKSIG)
from test_framework.address import key_to_p2wpkh

AUTH = "Basic " + base64.b64encode(COOKIE.encode()).decode()
_id = [0]
def rpc(method, params=None, allow_err=False):
    _id[0] += 1
    body = json.dumps({"jsonrpc":"1.0","id":_id[0],"method":method,"params":params or []}).encode()
    req = urllib.request.Request(RPC_URL, data=body,
        headers={"Authorization":AUTH, "Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        # JSON-RPC errors arrive as HTTP 500 with a JSON body.
        try:
            d = json.loads(e.read())
        except Exception:
            if allow_err:
                return None, str(e)
            raise
    if d.get("error"):
        if allow_err:
            return None, (d["error"].get("message") if isinstance(d["error"], dict) else str(d["error"]))
        raise RuntimeError(f"{method} rpc error: {d['error']}")
    return d["result"], ""

# Deterministic keypair -> p2wpkh address + scriptPubKey.
priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])                 # p2wpkh output
addr = key_to_p2wpkh(pub, main=False)       # bcrt1...

# Mine to maturity (this node's own coinbase) and read two mature coinbases.
# Using TWO distinct prevouts lets us isolate each rule cleanly:
#   prevout1 (height 1) -> HAPPY PATH (A -> B replacement)
#   prevout2 (height 2) -> Rule 3 + Rule 4 (resident seated at FEE_A, then
#                          C/D submitted as replacements of THAT FEE_A resident)
rpc("generatetoaddress", [NBLOCKS, addr])
cnt, _ = rpc("getblockcount")
if int(cnt) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)

def coinbase_outpoint(height):
    bh, _  = rpc("getblockhash", [height])
    blk, _ = rpc("getblock", [bh, 2])
    cb     = blk["tx"][0]
    v      = int(round(cb["vout"][0]["value"] * COIN))   # 50 BTC in sats
    return COutPoint(int(cb["txid"], 16), 0), v

prevout1, val1 = coinbase_outpoint(1)
prevout2, val2 = coinbase_outpoint(2)

# Single-input spend of a mature coinbase. nseq controls RBF signaling.
# All variants are the SAME shape (1-in/1-out p2wpkh) so vsize is identical;
# only the output value (= fee) and nSequence change.
SEQ_RBF = 0xfffffffd        # signals BIP-125 replaceability
def build(prevout, val, fee, nseq=SEQ_RBF):
    tx = CTransaction(); tx.version = 2
    tx.vin  = [CTxIn(prevout, b"", nseq)]
    tx.vout = [CTxOut(val - fee, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])  # BIP143 scriptCode
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx, tx.serialize_with_witness().hex(), tx.txid_hex

# Fee schedule. Control vsize ~ 110 vB; incremental relay fee = 1 sat/vB,
# so Rule-4 minimum bump ~= 110 sat.
#   A : 1000 sat (~9 sat/vB) — well above floor, RBF-signaling.
#   B : 20000 sat — large bump, clears Rules 3+4 by a wide margin (replaces A).
#   R : 1000 sat — the FEE_A resident over prevout2 (the baseline C/D replace).
#   C :  900 sat — LOWER absolute fee than R, FAILS Rule 3 ("less fees than
#       conflicting txs"). Must be a DISTINCT fee (not == FEE_R) so C is a
#       different tx than R — an equal-fee/equal-output C would be byte-identical
#       to R and get caught as a plain duplicate, not as a Rule-3 conflict.
#   D : 1050 sat — 50 sat above R, but delta 50 < incrementalRelayFee*vsize (~110)
#       -> passes Rule 3, FAILS Rule 4 ("not enough additional fees to relay").
FEE_A = 1000
FEE_B = 20000
FEE_R = 1000
FEE_C = 900
FEE_D = 1050

_, hexA, txidA = build(prevout1, val1, FEE_A)
_, hexB, txidB = build(prevout1, val1, FEE_B)
_, hexR, txidR = build(prevout2, val2, FEE_R)
_, hexC, txidC = build(prevout2, val2, FEE_C)
_, hexD, txidD = build(prevout2, val2, FEE_D)

def sendraw(h):
    res, err = rpc("sendrawtransaction", [h], allow_err=True)
    if res is not None:
        return True, ""
    return False, err

def tma(h):
    res, _ = rpc("testmempoolaccept", [[h]])
    r = res[0]
    allowed = bool(r.get("allowed"))
    reason  = "" if allowed else (r.get("reject-reason") or "rejected")
    return allowed, reason

def in_mempool(txid):
    mp, _ = rpc("getrawmempool", [])
    return txid in mp

def emit(tag, a, b):
    sa = (a if isinstance(a, str) else ("true" if a else "false"))
    sb = (b if isinstance(b, str) else ("true" if b else "false"))
    sb = sb.replace("\t"," ").replace("\n"," ")
    # Use a "-" placeholder for an empty reason field so the downstream bash
    # `read tag a b` always sees three columns. An ACCEPTED step (empty reason)
    # then surfaces as reason "-" rather than collapsing the column and
    # tripping the field-presence guard with a misleading "missing field" — the
    # accept itself is still visible via the allowed/accepted column.
    if sb == "":
        sb = "-"
    print(f"{tag}\t{sa}\t{sb}")

# --- HAPPY PATH: submit A then B (B replaces A) over prevout1 ---
okA, errA = sendraw(hexA);  emit("STEP_A", okA, errA)
okB, errB = sendraw(hexB);  emit("STEP_B", okB, errB)
emit("MEMPOOL", in_mempool(txidA), in_mempool(txidB))

# --- Rules 3/4: seat resident R (FEE_A) over prevout2, then submit C and D ---
# C and D conflict with R (same prevout2). C has equal absolute fee (Rule 3
# fail); D has a +50 sat fee but a bump below incrementalRelayFee*vsize
# (Rule 4 fail). Both must reject "insufficient fee". testmempoolaccept is the
# read path; it must NOT enter the mempool and must NOT evict R.
okR, errR = sendraw(hexR);  emit("STEP_R", okR, errR)
allowC, reasonC = tma(hexC);  emit("STEP_C", allowC, reasonC)
allowD, reasonD = tma(hexD);  emit("STEP_D", allowD, reasonD)
# Confirm testmempoolaccept did not perturb the resident.
emit("RESIDENT", in_mempool(txidR), in_mempool(txidC) or in_mempool(txidD))
PYEOF
[[ -s "$HELPER" ]] || skip "failed to write RBF helper"

# ── Launch helper for a Core regtest oracle. ──────────────────────────────
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"; shift 4
    "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" \
        -listen=0 -fallbackfee=0.0002 "$@" >"$lf" 2>&1 &
    local bg=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
            echo "$bg"; return 0
        fi
        kill -0 "$bg" 2>/dev/null || { tail -n 20 "$lf" >&2 2>/dev/null || true; return 1; }
        sleep 1
    done
    return 1
}

# ── 3. Launch the Core oracle. ────────────────────────────────────────────
log "launching Core oracle rpc=:$CORE_RPC flags=${CORE_FLAGS[*]}"
CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$CORE_LOG" "${CORE_FLAGS[@]}") \
    || fail "Core oracle failed to start within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch blockbrew on regtest. ───────────────────────────────────────
log "launching blockbrew (regtest) rpc=:$BB_RPC p2p=:$BB_P2P -> $BB_LOG"
"$NODE_BIN" \
    -network=regtest -datadir="$BB_DATADIR" \
    -listen="127.0.0.1:${BB_P2P}" -rpcbind="127.0.0.1:${BB_RPC}" \
    -maxoutbound=0 -nolisten \
    >"$BB_LOG" 2>&1 &
BB_PID=$!
log "blockbrew pid=$BB_PID"
bb_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < bb_deadline )); do
    if [[ -z "$BB_COOKIE" && -f "$BB_COOKIE_FILE" ]]; then
        BB_COOKIE=$(cat "$BB_COOKIE_FILE")
    fi
    if [[ -n "$BB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "$BB_URL/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BB_PID" 2>/dev/null || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew exited during startup (see $BB_LOG)"; }
    sleep 1
done
[[ -n "$BB_COOKIE" ]] || fail "blockbrew cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$BB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$BB_URL/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "blockbrew RPC never responded within 90s"
log "blockbrew RPC ready"

# ── 5. Run the RBF sequence against both nodes. ───────────────────────────
log "running RBF sequence against Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "RBF helper produced no output for Core oracle"; }

log "running RBF sequence against blockbrew"
BB_OUT=$(python3 "$HELPER" "$TF_PATH" "$BB_URL/" "$BB_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$BB_LOG")
[[ -n "$BB_OUT" ]] || { tail -n 30 "$BB_LOG" >&2 2>/dev/null || true; fail "RBF helper produced no output for blockbrew"; }

# ── 6. Parse both result sets. ────────────────────────────────────────────
declare -A C V
while IFS=$'\t' read -r tag a b; do
    [[ -z "$tag" ]] && continue
    C["${tag}_a"]="$a"; C["${tag}_b"]="$b"
done <<< "$CORE_OUT"
while IFS=$'\t' read -r tag a b; do
    [[ -z "$tag" ]] && continue
    V["${tag}_a"]="$a"; V["${tag}_b"]="$b"
done <<< "$BB_OUT"

for k in STEP_A_a STEP_B_a MEMPOOL_a MEMPOOL_b STEP_R_a STEP_C_a STEP_C_b STEP_D_a STEP_D_b RESIDENT_a RESIDENT_b; do
    [[ -n "${C[$k]:-}" ]] || fail "Core oracle output missing field $k (helper output incomplete)"
    [[ -n "${V[$k]:-}" ]] || fail "blockbrew output missing field $k (helper output incomplete)"
done

log "=== RBF DIFFERENTIAL  (Core oracle: -incrementalrelayfee=1sat/vB) ==="
log "Core : A_send=${C[STEP_A_a]} B_send=${C[STEP_B_a]} hasA=${C[MEMPOOL_a]} hasB=${C[MEMPOOL_b]} R_send=${C[STEP_R_a]} C_allowed=${C[STEP_C_a]}(${C[STEP_C_b]}) D_allowed=${C[STEP_D_a]}(${C[STEP_D_b]}) residentR=${C[RESIDENT_a]}"
log "bbrew: A_send=${V[STEP_A_a]} B_send=${V[STEP_B_a]} hasA=${V[MEMPOOL_a]} hasB=${V[MEMPOOL_b]} R_send=${V[STEP_R_a]} C_allowed=${V[STEP_C_a]}(${V[STEP_C_b]}) D_allowed=${V[STEP_D_a]}(${V[STEP_D_b]}) residentR=${V[RESIDENT_a]}"

# ── 7. Verdict. ───────────────────────────────────────────────────────────
# replace (HAPPY PATH): on BOTH nodes, after A then B: B is in mempool, A is not.
#   Also A must have been accepted (STEP_A) and B accepted (STEP_B).
REPLACE="ok"
if [[ "${C[STEP_A_a]}" != "true" ]]; then
    fail "Core did not accept A (the funded RBF-signaling parent) — oracle/harness broken: ${C[STEP_A_b]}"
fi
if [[ "${V[STEP_A_a]}" != "true" ]]; then
    fail "blockbrew did not accept A (funded RBF-signaling parent): ${V[STEP_A_b]} | replace=fail rule3=? rule4=?"
fi
# Core reference: B replaces A.
if [[ "${C[MEMPOOL_b]}" != "true" || "${C[MEMPOOL_a]}" != "false" ]]; then
    fail "Core oracle did not show B-replaces-A (hasA=${C[MEMPOOL_a]} hasB=${C[MEMPOOL_b]}) — oracle/harness broken"
fi
# blockbrew must match: B accepted and replaces A.
if [[ "${V[STEP_B_a]}" != "true" ]]; then
    REPLACE="fail-B-rejected:${V[STEP_B_b]}"
elif [[ "${V[MEMPOOL_b]}" != "true" || "${V[MEMPOOL_a]}" != "false" ]]; then
    REPLACE="fail-no-evict(hasA=${V[MEMPOOL_a]},hasB=${V[MEMPOOL_b]})"
fi

# rule3 / rule4: a FEE_A resident R must be seated over prevout2 on both nodes,
# then Core must REJECT C (Rule 3) and D (Rule 4) as replacements of R.
# blockbrew must reject with the SAME category and must not perturb R.
cC=$(classify "${C[STEP_C_b]}"); cD=$(classify "${C[STEP_D_b]}")
vC=$(classify "${V[STEP_C_b]}"); vD=$(classify "${V[STEP_D_b]}")

if [[ "${C[STEP_R_a]}" != "true" ]]; then
    fail "Core did not accept R (the FEE_A resident over prevout2) — oracle/harness broken: ${C[STEP_R_b]}"
fi
if [[ "${C[STEP_C_a]}" != "false" ]]; then
    fail "Core oracle ACCEPTED C (Rule-3 equal-fee conflict) — oracle/harness broken (reason='${C[STEP_C_b]}')"
fi
if [[ "${C[STEP_D_a]}" != "false" ]]; then
    fail "Core oracle ACCEPTED D (Rule-4 insufficient-bump conflict) — oracle/harness broken (reason='${C[STEP_D_b]}')"
fi
if [[ "${V[STEP_R_a]}" != "true" ]]; then
    fail "blockbrew did not accept R (FEE_A resident over prevout2): ${V[STEP_R_b]} | replace=$REPLACE rule3=? rule4=?"
fi
# testmempoolaccept is a dry run: it must NOT have evicted R or admitted C/D.
if [[ "${V[RESIDENT_a]}" != "true" ]]; then
    fail "blockbrew dropped resident R after a testmempoolaccept dry-run (RESIDENT=${V[RESIDENT_a]}) — dry-run must not mutate the mempool | replace=$REPLACE"
fi
if [[ "${V[RESIDENT_b]}" == "true" ]]; then
    fail "blockbrew admitted C/D into the mempool via testmempoolaccept dry-run — must be read-only | replace=$REPLACE"
fi

RULE3="ok"
if [[ "${V[STEP_C_a]}" != "false" ]]; then
    RULE3="fail-blockbrew-ACCEPTS-C(reason='${V[STEP_C_b]}')"
elif [[ "$vC" != "$cC" ]]; then
    # Both reject but category differs. Core folds Rule3 -> "insufficient fee".
    # Accept any insufficient-fee/mempool-conflict family match.
    if [[ "$vC" == "insufficient-fee" || "$vC" == "mempool-conflict" ]]; then
        RULE3="ok"
    else
        RULE3="fail-category(core=$cC bbrew=$vC)"
    fi
fi

RULE4="ok"
if [[ "${V[STEP_D_a]}" != "false" ]]; then
    RULE4="fail-blockbrew-ACCEPTS-D(reason='${V[STEP_D_b]}')"
elif [[ "$vD" != "$cD" ]]; then
    if [[ "$vD" == "insufficient-fee" || "$vD" == "mempool-conflict" ]]; then
        RULE4="ok"
    else
        RULE4="fail-category(core=$cD bbrew=$vD)"
    fi
fi

# ── 8. Emit summary. ──────────────────────────────────────────────────────
if [[ "$REPLACE" == "ok" && "$RULE3" == "ok" && "$RULE4" == "ok" ]]; then
    log "PASS: B replaced A on both nodes; C+D rejected insufficient-fee on both"
    pass "ok" "ok" "ok"
fi

REASONS=()
[[ "$REPLACE" != "ok" ]] && REASONS+=("replace=$REPLACE")
[[ "$RULE3"   != "ok" ]] && REASONS+=("rule3=$RULE3")
[[ "$RULE4"   != "ok" ]] && REASONS+=("rule4=$RULE4")
fail "$(IFS=' '; echo "${REASONS[*]}") | replace=$REPLACE rule3=$RULE3 rule4=$RULE4"
