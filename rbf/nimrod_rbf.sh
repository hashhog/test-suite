#!/usr/bin/env bash
#
# nimrod_rbf.sh — self-contained RBF (Replace-By-Fee / BIP125) DIFFERENTIAL test.
#
# The SECOND mempool-policy cell (after testmempoolaccept reject-parity in
# test-suite/policy/nimrod_policy.sh).  Where the policy cell proved the
# *standardness gate*, this proves the *mempool REPLACEMENT subsystem*: a tx
# that conflicts with an in-mempool tx over the SAME input must be handled
# exactly as Bitcoin Core handles it —
#   * a sufficiently-higher-fee replacement EVICTS the conflict and ACCEPTS,
#   * a replacement that fails BIP125 Rule #3 (abs-fee >= replaced) or Rule #4
#     (pays its own bandwidth at incrementalRelayFee) is REJECTED with the
#     "insufficient fee" reject-reason CATEGORY,
# and the reject-reason / sendrawtransaction error surfaces that category.
#
# Consensus-ADJACENT (relay policy, not consensus).  BIP125 rules covered:
#   Rule 1 (signaling) — deterministic by construction: every replaceable tx
#                        carries nSequence 0xfffffffd on its input, so both
#                        BIP125-only and full-rbf Core treat it as replaceable
#                        regardless of the mempoolfullrbf setting.
#   Rule 3 (abs fee)   — replacement absolute fee >= sum of replaced fees,
#                        else reject category "insufficient fee".
#   Rule 4 (bandwidth) — (replacement_fee - replaced_fee) >=
#                        incrementalRelayFee * replacement_vsize,
#                        else reject category "insufficient fee".
#   Rule 5 (<=100 replaced) is OUT OF SCOPE for this cell (no 100-tx cluster).
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on a SEPARATE regtest
#   instance (own scratch datadir + ports, -listen=0).  The SAME submit
#   sequence is replayed against Core and against nimrod; nimrod's per-step
#   accept/reject decision (and reject CATEGORY) must agree with Core's.
#
# PORTABLE TX CONSTRUCTION (no wallet / no createrawtransaction dependency):
#   The helper mines NBLOCKS to a fixed deterministic p2wpkh key (this node's
#   OWN height-1 coinbase — coinbase txids differ per impl), then builds every
#   tx by hand over that coinbase's vout 0, signs it in Python via BIP143
#   (SegwitV0SignatureHash) and submits via sendrawtransaction.  This sidesteps
#   the known raw-tx machinery bugs in some impls (object-vs-array outputs;
#   address-as-script; zeroed witness program) because the wire bytes are
#   built directly and never round-trip through the node's createrawtransaction.
#
# SEQUENCE (per node, all over the SAME coinbase prevout, nSequence=0xfffffffd):
#   A  = output (val - FEE_A)             -> ACCEPT, A in mempool
#   B  = output (val - FEE_B), FEE_B >> A -> REPLACE: mempool has B, NOT A
#   (reset to a clean tip+coinbase between scenarios so each is independent)
#   A' = re-submit A                      -> ACCEPT
#   C  = output (val - FEE_C), FEE_C <= A -> REJECT "insufficient fee" (Rule 3)
#   (reset)
#   A''= re-submit A                      -> ACCEPT
#   D  = output (val - FEE_D), FEE_D only a hair above A (delta <
#        incrementalRelayFee * vsize)     -> REJECT "insufficient fee" (Rule 4)
#
#   Each scenario runs on its OWN freshly-mined coinbase (the helper mines a new
#   block to the key and uses that block's coinbase) so the three scenarios do
#   not interfere and the mempool starts empty for each.
#
# NORMALIZATION: reject-reason strings compared by CATEGORY via classify().
#   Core's ReplacementChecks emits reject-reason TOKEN "insufficient fee" for
#   BOTH Rule 3 and Rule 4 (validation.cpp:1013-1014); nimrod (after this cell's
#   fix) leads the same failures with "insufficient fee, rejecting replacement,
#   ...".  A step PASSES when impl and Core map to the SAME category.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/nimrod_policy.sh):
#   no required args, set -uo pipefail, idempotent, trap cleanup, scratch
#   datadirs under /tmp + UNIQUE ports, ONE clean summary line on stdout, all
#   noise -> stderr / logfile, exit 0/1.  Run under: setsid -w bash <script>.
#
# Summary line (stdout):
#   PASS: RBF nimrod: PASS replace=ok rule3=ok rule4=ok
#   FAIL: RBF nimrod: FAIL <short reason> [replace=.. rule3=.. rule4=..]
#   SKIP: RBF nimrod: SKIP <build/raw-tx gap>
#
# Touches ONLY /tmp/rbf-nimrod/ + /tmp/rbf-nimrod-core/ and ports
#   22091/22111 (nimrod RPC/P2P) + 22092/22112 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework

NM_DATADIR="/tmp/rbf-nimrod"
NM_RPC=22091
NM_P2P=22111
NM_LOG="$NM_DATADIR/node.log"
NM_COOKIE_FILE="$NM_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/rbf-nimrod-core"
CORE_RPC=22092
CORE_P2P=22112
CORE_LOG="$CORE_DATADIR/core.log"

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair.
SECRET="2222222222222222222222222222222222222222222222222222222222222223"

NBLOCKS=110            # mature several coinbases (one per scenario, all spendable)

NM_PID=""
NM_COOKIE=""
CORE_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[rbf:nimrod] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$NM_PID" ]] && kill -0 "$NM_PID" 2>/dev/null; then
        kill "$NM_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NM_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NM_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$NM_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <replace> <rule3> <rule4>
pass() {
    echo "RBF nimrod: PASS replace=$1 rule3=$2 rule4=$3"
    exit 0
}
fail() {
    echo "RBF nimrod: FAIL $*"
    exit 1
}
skip() {
    echo "RBF nimrod: SKIP $*"
    exit 0
}

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Empty input (accepted) -> "accept".  Anything unmatched -> "other:<verbatim>".
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *"insufficient fee"*|*"less fees than conflicting"*|*"not enough additional fees"*|*"insufficient feerate"*|*"replacement-failed"*) echo "insufficient-fee" ;;
        *"bad-txns-spends-conflicting-tx"*|*"spends conflicting"*)              echo "spends-conflicting" ;;
        *"txn-mempool-conflict"*|*"bip125-replacement-disallowed"*)             echo "mempool-conflict" ;;
        *"too many potential replacements"*)                                    echo "too-many-replacements" ;;
        *)                                                                      echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "rbf-nimrod" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${NM_RPC}|${NM_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${NM_RPC}|${NM_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${NM_RPC}/${NM_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$NM_DATADIR" "$CORE_DATADIR"
mkdir -p "$NM_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || skip "nimrod binary not found at $NODE_BIN (run: cd nimrod && nimble build -d:release -y)"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || skip "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || skip "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the RBF-sequence Python helper. ──────────────────────────────
# Connects to ONE node's RPC, mines to maturity with the fixed key, then runs
# THREE independent RBF scenarios (replace / rule3 / rule4), each over its own
# freshly-mined coinbase so the mempool starts empty per scenario.  Emits one
# tab-separated line per assertion to stdout:
#   STEP <name> <result>   where result is "accept" / "<reject-reason>" /
#                          "replaced" / "not-replaced" / "still-present"
# Driven once per node (nimrod + Core).
HELPER="$NM_DATADIR/rbf_seq.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request
sys.path.insert(0, sys.argv[1])  # test_framework path
RPC_URL = sys.argv[2]
COOKIE  = sys.argv[3]            # "user:pass" form
SECRET  = sys.argv[4]
NBLOCKS = int(sys.argv[5])

from test_framework.key import ECKey
from test_framework.messages import (CTransaction, CTxIn, CTxOut, COutPoint,
                                      CTxInWitness, COIN)
from test_framework.script import (CScript, OP_0, hash160, SegwitV0SignatureHash,
                                   SIGHASH_ALL, OP_DUP, OP_HASH160, OP_EQUALVERIFY,
                                   OP_CHECKSIG)
from test_framework.address import key_to_p2wpkh

AUTH = "Basic " + base64.b64encode(COOKIE.encode()).decode()
_id = [0]
def rpc(method, params=None):
    _id[0] += 1
    body = json.dumps({"jsonrpc":"1.0","id":_id[0],"method":method,
                       "params":params or []}).encode()
    req = urllib.request.Request(RPC_URL, data=body,
        headers={"Authorization":AUTH, "Content-Type":"application/json"})
    # Bitcoin Core returns HTTP 500 (with a JSON-RPC error body) for an RPC
    # error such as a rejected sendrawtransaction; urllib raises HTTPError on
    # 500 before we can read the body, so catch it and parse the error JSON.
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return json.loads(raw)
        except Exception:
            return {"error": {"code": e.code, "message": raw.decode("utf-8", "replace")}}

def rpc_ok(method, params=None):
    d = rpc(method, params)
    if d.get("error"):
        raise RuntimeError(f"{method} rpc error: {d['error']}")
    return d["result"]

# Deterministic keypair -> p2wpkh.
priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])                 # p2wpkh output script
addr = key_to_p2wpkh(pub, main=False)       # bcrt1...
SCRIPTCODE = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])

RBF_SEQ = 0xfffffffd                         # signal opt-in BIP125 replaceability

# Mine to maturity.
rpc_ok("generatetoaddress", [NBLOCKS, addr])
if int(rpc_ok("getblockcount")) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)

def fresh_coinbase(height):
    """Return (COutPoint, value_sat) for the coinbase at the given block height."""
    bh  = rpc_ok("getblockhash", [height])
    blk = rpc_ok("getblock", [bh, 2])
    cb  = blk["tx"][0]
    val = int(round(cb["vout"][0]["value"] * COIN))
    return COutPoint(int(cb["txid"], 16), 0), val

def build(prevout, val, fee, seq=RBF_SEQ):
    """One-in/one-out p2wpkh spend of `prevout`, paying `fee`, signaling RBF."""
    tx = CTransaction(); tx.version = 2
    tx.vin  = [CTxIn(prevout, b"", seq)]
    tx.vout = [CTxOut(val - fee, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sh = SegwitV0SignatureHash(SCRIPTCODE, tx, 0, SIGHASH_ALL, val)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    # txid_hex is a @property returning the txid (no-witness hash) as a
    # big-endian hex string, matching the form getrawmempool returns; older
    # test_framework exposed rehash()/hash, this build exposes the property.
    return tx, tx.serialize_with_witness().hex(), tx.txid_hex

def send(rawhex):
    """sendrawtransaction; return ("accept","") or ("reject", reason)."""
    d = rpc("sendrawtransaction", [rawhex])
    if d.get("error"):
        return "reject", (d["error"].get("message") or "rejected")
    return "accept", ""

def tma_reason(rawhex):
    """testmempoolaccept reject-reason for a single tx (for cross-check)."""
    try:
        r = rpc_ok("testmempoolaccept", [[rawhex]])[0]
        if r.get("allowed"):
            return ""
        return r.get("reject-reason") or "rejected"
    except Exception:
        return "tma-error"

def in_mempool(txid):
    pool = rpc_ok("getrawmempool")
    return txid in pool

steps = []
def emit(name, result):
    safe = str(result).replace("\t", " ").replace("\n", " ")
    steps.append((name, safe))

# Pick three distinct mature coinbases (one per scenario), avoiding the very
# last few which may not be deep enough for descendant scenarios; coinbase
# maturity is 100, so heights 1, 2, 3 are all spendable at tip NBLOCKS(>=110).
cb1 = fresh_coinbase(1)
cb2 = fresh_coinbase(2)
cb3 = fresh_coinbase(3)

# Fee schedule (sats).  Control vsize for a 1-in/1-out p2wpkh spend ~= 110 vB.
# incrementalRelayFee default = 1000 sat/kvB = 1 sat/vB -> Rule4 needs the
# delta to be >= ~110 sat for this tx shape.
FEE_A = 1000      # ~9 sat/vB: comfortably above the min-relay floor
FEE_B = 5000      # >> A and delta(4000) >> incrementalRelayFee*vsize -> REPLACE
# Rule 3: C must be a DIFFERENT tx (else it is just "already in mempool"), so we
# LOWER its fee (raises its single output value -> distinct wire bytes/txid) to
# below A's fee.  replacement_fee(800) < original_fee(1000) -> Rule 3 reject.
FEE_C = FEE_A - 200
FEE_D = FEE_A + 10  # +10 sat: delta(10) < incrementalRelayFee*~110 -> Rule 4 reject

# ── Scenario REPLACE: A then B (higher fee) ───────────────────────────────
(prev1, val1) = cb1
_, hexA1, txidA1 = build(prev1, val1, FEE_A)
res, _ = send(hexA1)
emit("replace.A.submit", res)            # expect accept
emit("replace.A.inpool", "yes" if in_mempool(txidA1) else "no")
_, hexB, txidB = build(prev1, val1, FEE_B)
res, reason = send(hexB)
emit("replace.B.submit", res if res == "accept" else reason)  # expect accept (replaces)
emit("replace.B.inpool", "yes" if in_mempool(txidB) else "no")
emit("replace.A.evicted", "yes" if not in_mempool(txidA1) else "no")
# clean the mempool for the next scenario (mine it away)
rpc_ok("generatetoaddress", [1, addr])

# ── Scenario RULE3: A then C (fee <= A) ───────────────────────────────────
(prev2, val2) = cb2
_, hexA2, txidA2 = build(prev2, val2, FEE_A)
res, _ = send(hexA2)
emit("rule3.A.submit", res)              # expect accept
_, hexC, txidC = build(prev2, val2, FEE_C)
res, reason = send(hexC)
# expect reject; capture both sendraw reason AND tma reason (should agree)
emit("rule3.C.submit", "accept" if res == "accept" else reason)
emit("rule3.C.tma", tma_reason(hexC))
emit("rule3.C.inpool", "yes" if in_mempool(txidC) else "no")
emit("rule3.A.present", "yes" if in_mempool(txidA2) else "no")  # A must survive
rpc_ok("generatetoaddress", [1, addr])

# ── Scenario RULE4: A then D (delta < incrementalRelayFee*vsize) ──────────
(prev3, val3) = cb3
_, hexA3, txidA3 = build(prev3, val3, FEE_A)
res, _ = send(hexA3)
emit("rule4.A.submit", res)              # expect accept
_, hexD, txidD = build(prev3, val3, FEE_D)
res, reason = send(hexD)
emit("rule4.D.submit", "accept" if res == "accept" else reason)
emit("rule4.D.tma", tma_reason(hexD))
emit("rule4.D.inpool", "yes" if in_mempool(txidD) else "no")
emit("rule4.A.present", "yes" if in_mempool(txidA3) else "no")  # A must survive

for name, result in steps:
    print(f"STEP\t{name}\t{result}")
PYEOF
[[ -s "$HELPER" ]] || fail "failed to write RBF helper"

# ── Launch helper for the Core regtest oracle. ────────────────────────────
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

# ── 3. Launch the Core oracle (default policy = mempoolfullrbf on by default
#       in modern Core, but our txs SIGNAL anyway so it is deterministic). ──
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -> $CORE_LOG"
CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$CORE_LOG") \
    || fail "Core oracle failed to start within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch nimrod on regtest. ──────────────────────────────────────────
log "launching nimrod (regtest) rpc=:$NM_RPC p2p=:$NM_P2P -> $NM_LOG"
"$NODE_BIN" --network=regtest --datadir="$NM_DATADIR" \
    --port="$NM_P2P" --rpcport="$NM_RPC" start >"$NM_LOG" 2>&1 &
NM_PID=$!
log "nimrod pid=$NM_PID"
nm_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < nm_deadline )); do
    if [[ -z "$NM_COOKIE" && -f "$NM_COOKIE_FILE" ]]; then
        NM_COOKIE=$(cat "$NM_COOKIE_FILE")
    fi
    if [[ -n "$NM_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$NM_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$NM_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$NM_PID" 2>/dev/null || { tail -n 20 "$NM_LOG" >&2 2>/dev/null || true; fail "nimrod exited during startup (see $NM_LOG)"; }
    sleep 1
done
[[ -n "$NM_COOKIE" ]] || fail "nimrod cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$NM_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$NM_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "nimrod RPC never responded within 90s"
log "nimrod RPC ready"

# ── 5. Run the RBF sequence against both nodes. ───────────────────────────
log "running RBF sequence against Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "RBF helper produced no output for Core oracle"; }

log "running RBF sequence against nimrod"
NM_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$NM_RPC/" "$NM_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$NM_LOG")
[[ -n "$NM_OUT" ]] || { tail -n 30 "$NM_LOG" >&2 2>/dev/null || true; fail "RBF helper produced no output for nimrod"; }

# ── 6. Parse both result sets into name -> value. ─────────────────────────
declare -A CORE_R NM_R
while IFS=$'\t' read -r tag name val; do
    [[ "$tag" == "STEP" ]] || continue
    CORE_R["$name"]="$val"
done <<< "$CORE_OUT"
while IFS=$'\t' read -r tag name val; do
    [[ "$tag" == "STEP" ]] || continue
    NM_R["$name"]="$val"
done <<< "$NM_OUT"

STEPS=(
    replace.A.submit replace.A.inpool replace.B.submit replace.B.inpool replace.A.evicted
    rule3.A.submit rule3.C.submit rule3.C.tma rule3.C.inpool rule3.A.present
    rule4.A.submit rule4.D.submit rule4.D.tma rule4.D.inpool rule4.A.present
)
for s in "${STEPS[@]}"; do
    [[ -n "${CORE_R[$s]:-}" ]] || fail "Core oracle missing step '$s' (helper output incomplete)"
    [[ -n "${NM_R[$s]:-}"   ]] || fail "nimrod missing step '$s' (helper output incomplete)"
done

# ── 7. Forensic table. ────────────────────────────────────────────────────
log "=== RBF / BIP125 DIFFERENTIAL  (Core oracle vs nimrod) ==="
printf '%-22s | %-30s | %-30s | %s\n' "step" "Core" "nimrod" "verdict" >&2
cmp_step() {  # cmp_step <name> <category-compare:0|1>
    local name="$1" catcmp="$2"
    local cv="${CORE_R[$name]}" nv="${NM_R[$name]}"
    local ok=1 verdict
    if [[ "$catcmp" -eq 1 ]]; then
        local cc nc
        cc=$(classify "$cv"); nc=$(classify "$nv")
        if [[ "$cc" == "$nc" ]]; then ok=1; verdict="ok($cc)"; else ok=0; verdict="MISMATCH ($cc vs $nc)"; fi
    else
        if [[ "$cv" == "$nv" ]]; then ok=1; verdict="ok"; else ok=0; verdict="MISMATCH"; fi
    fi
    printf '%-22s | %-30s | %-30s | %s\n' "$name" "$cv" "$nv" "$verdict" >&2
    return $(( 1 - ok ))
}

# ── 8. Evaluate the three sub-results. ────────────────────────────────────
# REPLACE: A accepted+inpool, B accepted+inpool, A evicted — exact match.
REPLACE_OK=1
cmp_step replace.A.submit  0 || REPLACE_OK=0
cmp_step replace.A.inpool  0 || REPLACE_OK=0
cmp_step replace.B.submit  0 || REPLACE_OK=0
cmp_step replace.B.inpool  0 || REPLACE_OK=0
cmp_step replace.A.evicted 0 || REPLACE_OK=0
# Independently assert the absolute expected truth (not just agreement):
[[ "${NM_R[replace.A.submit]}"  == "accept" ]] || REPLACE_OK=0
[[ "${NM_R[replace.B.submit]}"  == "accept" ]] || REPLACE_OK=0
[[ "${NM_R[replace.B.inpool]}"  == "yes"    ]] || REPLACE_OK=0
[[ "${NM_R[replace.A.evicted]}" == "yes"    ]] || REPLACE_OK=0

# RULE3: C rejected with "insufficient fee" category (sendraw + tma), A survives.
RULE3_OK=1
cmp_step rule3.A.submit  0 || RULE3_OK=0
cmp_step rule3.C.submit  1 || RULE3_OK=0
cmp_step rule3.C.tma     1 || RULE3_OK=0
cmp_step rule3.C.inpool  0 || RULE3_OK=0
cmp_step rule3.A.present 0 || RULE3_OK=0
[[ "$(classify "${NM_R[rule3.C.submit]}")" == "insufficient-fee" ]] || RULE3_OK=0
[[ "${NM_R[rule3.C.inpool]}"  == "no"  ]] || RULE3_OK=0
[[ "${NM_R[rule3.A.present]}" == "yes" ]] || RULE3_OK=0

# RULE4: D rejected with "insufficient fee" category (sendraw + tma), A survives.
RULE4_OK=1
cmp_step rule4.A.submit  0 || RULE4_OK=0
cmp_step rule4.D.submit  1 || RULE4_OK=0
cmp_step rule4.D.tma     1 || RULE4_OK=0
cmp_step rule4.D.inpool  0 || RULE4_OK=0
cmp_step rule4.A.present 0 || RULE4_OK=0
[[ "$(classify "${NM_R[rule4.D.submit]}")" == "insufficient-fee" ]] || RULE4_OK=0
[[ "${NM_R[rule4.D.inpool]}"  == "no"  ]] || RULE4_OK=0
[[ "${NM_R[rule4.A.present]}" == "yes" ]] || RULE4_OK=0

REPLACE_T=$([[ "$REPLACE_OK" -eq 1 ]] && echo ok || echo FAIL)
RULE3_T=$([[ "$RULE3_OK"   -eq 1 ]] && echo ok || echo FAIL)
RULE4_T=$([[ "$RULE4_OK"   -eq 1 ]] && echo ok || echo FAIL)

# ── 9. Verdict. ──────────────────────────────────────────────────────────
# Sanity: Core itself MUST exhibit the canonical RBF behavior, else the
# oracle/harness is broken and nothing downstream is trustworthy.
if [[ "${CORE_R[replace.B.submit]}" != "accept" || "${CORE_R[replace.A.evicted]}" != "yes" ]]; then
    fail "Core oracle did not perform the happy-path replacement (oracle/harness broken: B=${CORE_R[replace.B.submit]} A.evicted=${CORE_R[replace.A.evicted]})"
fi
if [[ "$(classify "${CORE_R[rule3.C.submit]}")" != "insufficient-fee" ]]; then
    fail "Core oracle did not reject Rule3 with insufficient-fee (oracle broken: ${CORE_R[rule3.C.submit]})"
fi
if [[ "$(classify "${CORE_R[rule4.D.submit]}")" != "insufficient-fee" ]]; then
    fail "Core oracle did not reject Rule4 with insufficient-fee (oracle broken: ${CORE_R[rule4.D.submit]})"
fi

if [[ "$REPLACE_OK" -eq 1 && "$RULE3_OK" -eq 1 && "$RULE4_OK" -eq 1 ]]; then
    log "PASS: RBF happy-path replacement + Rule3 + Rule4 reject-parity all green vs Core"
    pass "$REPLACE_T" "$RULE3_T" "$RULE4_T"
fi

fail "RBF parity gap vs Core | replace=$REPLACE_T rule3=$RULE3_T rule4=$RULE4_T"
