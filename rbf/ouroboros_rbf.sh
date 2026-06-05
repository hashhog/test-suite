#!/usr/bin/env bash
#
# ouroboros_rbf.sh — self-contained RBF (Replace-By-Fee, BIP125) DIFFERENTIAL
# parity test for ouroboros vs a REAL bitcoind regtest oracle.
#
# The SECOND mempool-policy cell (after testmempoolaccept reject-parity in
# test-suite/policy/). Where the policy harness proves the STANDARDNESS gate
# (dust/version/min-relay reject in the right category), this one proves the
# MEMPOOL REPLACEMENT subsystem: a transaction that conflicts (spends an input
# already spent by a mempool tx) must be handled the SAME way Core handles it —
# evicted-and-replaced when the BIP125 fee rules pass, rejected in the SAME
# reject CATEGORY when they fail.
#
# Consensus-ADJACENT (relay policy, not consensus): RBF lives in
# policy/rbf.cpp + the ReplacementChecks block of validation.cpp. We test the
# four observable behaviours of a single-tx replacement (Rule 5's >100-tx
# cluster is explicitly OUT of scope for this cell):
#
#   HAPPY PATH (replace): submit A (signals RBF, low fee), then B over A's
#     EXACT input at a much higher fee that clears Rules 3+4. B must REPLACE A:
#     getrawmempool ends with B and NOT A on BOTH nodes.
#   RULE 3 (insufficient absolute fee): submit A, then C over the same input at
#     fee <= A's fee. The replacement must be REJECTED, category "insufficient
#     fee" (Core: PaysForRBF "less fees than conflicting txs"). A stays.
#   RULE 4 (insufficient incremental fee): submit A, then D over the same input
#     at a fee slightly above A but with delta < incrementalRelayFee*vsize. The
#     replacement must be REJECTED, category "insufficient fee" (Core:
#     PaysForRBF "not enough additional fees to relay"). A stays.
#
# DETERMINISM: every replacement-candidate SIGNALS BIP125 (nSequence
# 0xfffffffd) so Rule 1 passes regardless of the node's mempoolfullrbf setting
# (Core v28+ defaults full-rbf=true; ouroboros defaults full_rbf=true). This
# isolates the FEE rules (3+4) + the happy path, which is exactly this cell.
#
# CORE ORACLE: one regtest bitcoind (v31.99) launched on its own scratch +
# ports, -listen=0, owns ground truth. ouroboros runs the identical submit
# sequence; we diff decisions.
#
# PORTABLE TX CONSTRUCTION (no wallet / no raw-tx-RPC dependency): the harness
# builds + SIGNS every tx in Python via the Core test_framework's BIP143
# SegwitV0SignatureHash (the same proven approach as ouroboros_policy.sh). It
# spends a MATURE coinbase (height-1..4) of a deterministic p2wpkh key the node
# itself mined, so each tx PASSES input-existence and REACHES the RBF path.
# This sidesteps the createrawtransaction / signrawtransactionwithkey raw-tx
# bugs seen in other impls (object-vs-array outputs; address-as-script;
# zeroed-witness-program). A DIFFERENT coinbase funds each scenario so the four
# conflict sets are independent (no cross-contamination between scenarios).
#
# NORMALIZATION: reject-reason strings compared by CATEGORY (the policy chapter
# pattern). Core emits the bare token "insufficient fee"; ouroboros is
# Core-faithful but may phrase the detail differently. classify() maps both to
# the canonical category. EXACT-vs-NORMALIZED is reported, not failed.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/ouroboros_policy.sh):
#   set -uo pipefail, idempotent, trap cleanup, scratch /tmp + UNIQUE ports,
#   ONE summary line on stdout, all noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS:  RBF ouroboros: PASS replace=ok rule3=ok rule4=ok
#   FAIL:  RBF ouroboros: FAIL <short reason>
#   SKIP:  RBF ouroboros: SKIP <build/raw-tx gap>
#
# Touches ONLY /tmp/rbf-ouroboros/ + /tmp/rbf-core/ and ports 40192/40212
#   (ouroboros RPC/P2P) + 40193/40213 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

OU_DATADIR="/tmp/rbf-ouroboros"
OU_RPC=40192
OU_P2P=40212
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/rbf-core"
CORE_RPC=40193
CORE_P2P=40213
CORE_LOG="$CORE_DATADIR/core.log"

# Fixed deterministic 32-byte secret -> one p2wpkh keypair for the whole run.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
# Mine well past maturity. We spend the height-1..4 coinbases; a coinbase at
# height H is spendable once its depth >= COINBASE_MATURITY (100), i.e. once
# tip >= H + 99. With tip 110, coinbases 1..11 are all mature, so heights 1..4
# clear maturity with comfortable margin (mining 101 left coinbases 3/4 at
# depth 99 = premature-spend-of-coinbase, which masked Rules 4 as a maturity
# reject rather than the RBF fee reject).
NBLOCKS=110

OU_PID=""
OU_COOKIE=""
CORE_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[rbf:ouroboros] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "RBF ouroboros: PASS replace=$1 rule3=$2 rule4=$3"; exit 0; }
fail() { echo "RBF ouroboros: FAIL $*"; exit 1; }
skip() { echo "RBF ouroboros: SKIP $*"; exit 0; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${OU_RPC}/tcp"         >/dev/null 2>&1 || true
    fuser -k "${OU_P2P}/tcp"         >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp"       >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp"       >/dev/null 2>&1 || true
    fuser -k "$((CORE_P2P + 1))/tcp" >/dev/null 2>&1 || true   # Core onion listener (P2P+1)
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# accept -> "accept"; RBF fee-rule rejects -> "insufficient-fee"; a
# non-signaling / disallowed conflict -> "mempool-conflict". Anything else ->
# "other:<verbatim>".
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *"insufficient fee"*|*"less fees"*|*"not enough additional"*|*"incremental"*|*"does not improve"*|*"replacement-failed"*) echo "insufficient-fee" ;;
        *"txn-mempool-conflict"*|*"spends-conflicting"*|*"does not signal"*|*"not replaceable"*|*conflict*) echo "mempool-conflict" ;;
        *) echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "rbf-ouroboros"   2>/dev/null || true
pkill -f "ouroboros.cli.*${OU_RPC}" 2>/dev/null || true
fuser -k "${OU_RPC}/tcp"         >/dev/null 2>&1 || true
fuser -k "${OU_P2P}/tcp"         >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp"       >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp"       >/dev/null 2>&1 || true
fuser -k "$((CORE_P2P + 1))/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$OU_DATADIR" "$CORE_DATADIR"
mkdir -p "$OU_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1        || skip "python3 not found on PATH"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || skip "ouroboros checkout not found at $OURO_DIR"
[[ -x "$CORE_BIN" ]]                      || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                      || skip "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]        || skip "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || skip "Core test_framework Python imports failed (need key/script/messages/address)"

OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"

# ── 2. Write the RBF scenario-runner Python helper. ───────────────────────
# Connects to ONE node's RPC, mines NBLOCKS to a deterministic p2wpkh key, then
# runs the four RBF scenarios against that node's OWN mature coinbases and
# prints tab-separated result lines:
#   RES replace   <true|false>           # B in mempool && A gone
#   RES rule3     <true|false> <reason>  # C rejected (and not in mempool)
#   RES rule4     <true|false> <reason>  # D rejected (and not in mempool)
#   RES rule4ok   <true|false>           # boundary: delta == required -> accept
# A scenario "passes" locally when the node behaves; the bash layer DIFFS the
# node's reasons against Core's.
HELPER="$OU_DATADIR/rbf_runner.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request, urllib.error
sys.path.insert(0, sys.argv[1])  # test_framework path
RPC_URL = sys.argv[2]
COOKIE  = sys.argv[3]            # "user:pass"
SECRET  = sys.argv[4]
NBLOCKS = int(sys.argv[5])

from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import (CScript, OP_0, SegwitV0SignatureHash, SIGHASH_ALL,
    OP_DUP, OP_HASH160, OP_EQUALVERIFY, OP_CHECKSIG, hash160)
from test_framework.address import key_to_p2wpkh

AUTH = "Basic " + base64.b64encode(COOKIE.encode()).decode()
_id = [0]
def rpc(method, params=None):
    _id[0] += 1
    body = json.dumps({"jsonrpc":"1.0","id":_id[0],"method":method,"params":params or []}).encode()
    req = urllib.request.Request(RPC_URL, data=body,
        headers={"Authorization":AUTH, "Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            d = json.loads(e.read().decode())
        except Exception as ee:
            return {"__error__": {"message": f"http {e.code}: {ee}"}}
    if d.get("error"):
        return {"__error__": d["error"]}
    return d.get("result")

def err_msg(res):
    if isinstance(res, dict) and "__error__" in res:
        e = res["__error__"]
        return e.get("message", str(e)) if isinstance(e, dict) else str(e)
    return None

# Deterministic keypair -> p2wpkh address + scriptPubKey.
priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])
addr = key_to_p2wpkh(pub, main=False)

# Mine to maturity. (Idempotent across re-runs: extra height does not matter,
# we always read low-height coinbases that are long-since mature.)
rpc("generatetoaddress", [NBLOCKS, addr])
if int(rpc("getblockcount")) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)

SIGNAL = 0xfffffffd  # signals BIP125 opt-in RBF (deterministic vs full-rbf knob)

def coinbase_prevout(h):
    bh  = rpc("getblockhash", [h])
    blk = rpc("getblock", [bh, 2])
    cb  = blk["tx"][0]
    val = int(round(cb["vout"][0]["value"] * COIN))
    return COutPoint(int(cb["txid"], 16), 0), val

def build(prevout, val, fee, seq=SIGNAL):
    """Single-input p2wpkh spend of `prevout`, paying `val-fee` to spk."""
    tx = CTransaction(); tx.version = 2
    tx.vin  = [CTxIn(prevout, b"", seq)]
    tx.vout = [CTxOut(val - fee, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])  # BIP143 scriptCode
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx.serialize_with_witness().hex(), tx.txid_hex

def send(raw):
    return rpc("sendrawtransaction", [raw])

def tma(raw):
    r = rpc("testmempoolaccept", [[raw]])
    if isinstance(r, list) and r:
        e = r[0]
        return bool(e.get("allowed")), ("" if e.get("allowed") else (e.get("reject-reason") or "rejected"))
    em = err_msg(r)
    return False, (em or "rejected")

def in_mempool(txid):
    mp = rpc("getrawmempool")
    return isinstance(mp, list) and txid in mp

def out(tag, *fields):
    safe = [str(f).replace("\t", " ").replace("\n", " ") for f in fields]
    print("RES\t" + tag + "\t" + "\t".join(safe))

# ── Scenario 1: HAPPY PATH (coinbase #1). A (low fee) then B (>>fee). ──────
po1, v1 = coinbase_prevout(1)
rawA, A = build(po1, v1, 1000)
rawB, B = build(po1, v1, 50000)
rsA = send(rawA)
a_in = in_mempool(A)
rsB = send(rawB)
# Replace succeeds iff B is now in mempool and A is gone.
replaced = in_mempool(B) and not in_mempool(A) and a_in and (err_msg(rsA) is None)
out("replace", "true" if replaced else "false",
    f"A_sent={err_msg(rsA) or A[:12]} B_sent={err_msg(rsB) or B[:12]} A_in={a_in} B_in={in_mempool(B)} A_gone={not in_mempool(A)}")

# ── Scenario 2: RULE 3 (coinbase #2). C fee <= A fee -> reject. ───────────
po2, v2 = coinbase_prevout(2)
rawA2, A2 = build(po2, v2, 5000)
rawC,  C  = build(po2, v2, 4000)  # LOWER absolute fee
send(rawA2)
a2_in = in_mempool(A2)
c_allowed, c_reason = tma(rawC)
rsC = send(rawC)
c_send_err = err_msg(rsC)
# Rule 3 holds iff the replacement is rejected (tma reject) AND does not enter
# the mempool (A2 survives, C absent), and a reject reason is surfaced.
c_reject = (not c_allowed) and (c_send_err is not None) and in_mempool(A2) and (not in_mempool(C))
out("rule3", "true" if c_reject else "false", c_reason or c_send_err or "(no reason)")

# ── Scenario 3: RULE 4 (coinbase #3). D delta < incrementalRelayFee*vsize. ─
po3, v3 = coinbase_prevout(3)
rawA3, A3 = build(po3, v3, 5000)
# +9 sat delta: deliberately INSIDE the gap between the stripped-non-witness
# size cost (~8 sat, the value a vsize bug would compute) and the true
# sigop-adjusted-vsize cost (~11 sat = Core's CFeeRate::GetFee). A node that
# (a) uses the stripped size instead of vsize, or (b) floors instead of
# rounding up, would ACCEPT this replacement while Core REJECTS it. Picking the
# delta in that gap is what makes this scenario a real guard against the Rule-4
# vsize/rounding hole, not a tautology that any too-low fee would trip.
rawD,  D  = build(po3, v3, 5009)
send(rawA3)
a3_in = in_mempool(A3)
d_allowed, d_reason = tma(rawD)
rsD = send(rawD)
d_send_err = err_msg(rsD)
d_reject = (not d_allowed) and (d_send_err is not None) and in_mempool(A3) and (not in_mempool(D))
out("rule4", "true" if d_reject else "false", d_reason or d_send_err or "(no reason)")

# ── Scenario 4: RULE 4 BOUNDARY (coinbase #4). delta == required -> accept. ─
# Proves the gate is not over-strict: a replacement that exactly clears the
# incremental ceiling must REPLACE, matching Core. (Diagnostic; failure here is
# an over-rejection signal, reported but not the primary gate.)
po4, v4 = coinbase_prevout(4)
rawA4, A4 = build(po4, v4, 5000)
rawE,  E  = build(po4, v4, 5011)  # +11 sat: at/above the ceiling
send(rawA4)
e_allowed, e_reason = tma(rawE)
out("rule4ok", "true" if e_allowed else "false", e_reason or "(accepted)")
PYEOF
[[ -s "$HELPER" ]] || fail "failed to write RBF runner helper"

# ── Launch helper for the Core regtest oracle. ────────────────────────────
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"; shift 4
    "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" -listen=0 \
        -fallbackfee=0.0002 "$@" >"$lf" 2>&1 &
    local bg=$!
    local deadline=$(( $(date +%s) + 60 ))
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
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -listen=0"
CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$CORE_LOG") \
    || fail "Core oracle failed to start within 60s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch ouroboros on regtest (generous >=90s startup wait). ─────────
log "launching ouroboros (regtest) rpc=:$OU_RPC p2p=:$OU_P2P -> $OU_LOG"
(
    cd "$OURO_DIR" || exit 1
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$OU_DATADIR" \
        start --force --rpc-port "$OU_RPC" --p2p-port "$OU_P2P"
) >"$OU_LOG" 2>&1 &
OU_PID=$!
log "ouroboros pid=$OU_PID"
ou_deadline=$(( $(date +%s) + 150 ))
while (( $(date +%s) < ou_deadline )); do
    if [[ -z "$OU_COOKIE" ]]; then
        for c in "$OU_DATADIR/.cookie" "$OU_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && OU_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$OU_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$OU_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$OU_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$OU_PID" 2>/dev/null || { tail -n 20 "$OU_LOG" >&2 2>/dev/null || true; fail "ouroboros exited during startup (see $OU_LOG)"; }
    sleep 1
done
[[ -n "$OU_COOKIE" ]] || fail "ouroboros cookie never appeared within 150s"
r=$(curl -s --max-time 5 -u "$OU_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$OU_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "ouroboros RPC never responded within 150s"
log "ouroboros RPC ready"

# ── 5. Run the scenario set against both nodes. ───────────────────────────
log "running RBF scenarios against Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "RBF runner produced no output for Core oracle"; }

log "running RBF scenarios against ouroboros"
OU_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$OU_RPC/" "$OU_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$OU_LOG")
[[ -n "$OU_OUT" ]] || { tail -n 30 "$OU_LOG" >&2 2>/dev/null || true; fail "RBF runner produced no output for ouroboros"; }

# ── 6. Parse RES lines: tag -> outcome / reason. ──────────────────────────
declare -A CORE_OK CORE_R OU_OK OU_R
while IFS=$'\t' read -r tag name outcome reason; do
    [[ "$tag" == "RES" ]] || continue
    CORE_OK["$name"]="$outcome"; CORE_R["$name"]="$reason"
done <<< "$CORE_OUT"
while IFS=$'\t' read -r tag name outcome reason; do
    [[ "$tag" == "RES" ]] || continue
    OU_OK["$name"]="$outcome"; OU_R["$name"]="$reason"
done <<< "$OU_OUT"

for t in replace rule3 rule4 rule4ok; do
    [[ -n "${CORE_OK[$t]:-}" ]] || fail "Core oracle missing result for '$t' (runner output incomplete; see $CORE_LOG)"
    [[ -n "${OU_OK[$t]:-}"   ]] || fail "ouroboros missing result for '$t' (runner output incomplete; see $OU_LOG)"
done

# ── 7. Forensic table. ────────────────────────────────────────────────────
log "=== RBF / BIP125 REPLACEMENT PARITY  (signaling txs; rules 1-4 + happy path) ==="
printf '%-9s | %-6s %-40s | %-6s %-40s | %s\n' \
    "scenario" "Core" "Core-reason" "ouro" "ouroboros-reason" "verdict" >&2
verdict_of() {  # verdict_of <tag> <expect-reject:0|1>
    local t="$1" expect_reject="$2"
    local co="${CORE_OK[$t]}" cr="${CORE_R[$t]}" io="${OU_OK[$t]}" ir="${OU_R[$t]}"
    if [[ "$expect_reject" == "1" ]]; then
        # Reject-parity: both must have rejected (outcome true == "rejected
        # correctly") AND map to the same reject category.
        local ccat icat; ccat=$(classify "$cr"); icat=$(classify "$ir")
        if [[ "$co" == "true" && "$io" == "true" && "$ccat" == "$icat" ]]; then echo "ok"
        elif [[ "$co" == "true" && "$io" == "true" ]]; then echo "mism:$icat!=$ccat"
        elif [[ "$io" != "true" ]]; then echo "HOLE(ouro-did-not-reject)"
        else echo "core-anomaly"; fi
    else
        # Boolean-parity: both true (e.g. replace happened / boundary accepted).
        if [[ "$co" == "true" && "$io" == "true" ]]; then echo "ok"
        elif [[ "$io" != "true" && "$co" == "true" ]]; then echo "FAIL(ouro=$io)"
        else echo "core-anomaly(core=$co)"; fi
    fi
}

V_REPLACE=$(verdict_of replace 0)
V_RULE3=$(verdict_of rule3 1)
V_RULE4=$(verdict_of rule4 1)
V_RULE4OK=$(verdict_of rule4ok 0)

for row in \
    "replace|$V_REPLACE" "rule3|$V_RULE3" "rule4|$V_RULE4" "rule4ok|$V_RULE4OK"; do
    t="${row%%|*}"; v="${row##*|}"
    printf '%-9s | %-6s %-40s | %-6s %-40s | %s\n' \
        "$t" "${CORE_OK[$t]}" "${CORE_R[$t]:- }" "${OU_OK[$t]}" "${OU_R[$t]:- }" "$v" >&2
done

# ── 8. Verdict. ───────────────────────────────────────────────────────────
# Core sanity: the oracle must behave (replace ok, rules reject). If Core itself
# didn't replace / reject, the harness construction is wrong -> SKIP not FAIL.
[[ "${CORE_OK[replace]}" == "true" ]] || skip "Core oracle did not perform the happy-path replacement (harness tx-build issue; see $CORE_LOG)"
[[ "${CORE_OK[rule3]}"   == "true" ]] || skip "Core oracle did not reject the Rule-3 conflict (harness tx-build issue; see $CORE_LOG)"
[[ "${CORE_OK[rule4]}"   == "true" ]] || skip "Core oracle did not reject the Rule-4 conflict (harness tx-build issue; see $CORE_LOG)"

# Map verdicts to summary tokens.
tok() { case "$1" in ok) echo "ok" ;; HOLE*) echo "HOLE" ;; mism*) echo "mismatch" ;; FAIL*) echo "over-reject" ;; *) echo "$1" ;; esac; }
R_REPLACE=$(tok "$V_REPLACE"); R_RULE3=$(tok "$V_RULE3"); R_RULE4=$(tok "$V_RULE4"); R_RULE4OK=$(tok "$V_RULE4OK")

# Primary gates: replace + rule3 + rule4 must all be ok.
[[ "$V_REPLACE" == "ok" ]] || fail "happy-path replacement diverges from Core (replace=$R_REPLACE): ouroboros='${OU_R[replace]}' | replace=$R_REPLACE rule3=$R_RULE3 rule4=$R_RULE4"
[[ "$V_RULE3"   == "ok" ]] || fail "Rule 3 (insufficient absolute fee) diverges from Core (rule3=$R_RULE3): core='${CORE_R[rule3]}' ouro='${OU_R[rule3]}' | replace=$R_REPLACE rule3=$R_RULE3 rule4=$R_RULE4"
[[ "$V_RULE4"   == "ok" ]] || fail "Rule 4 (insufficient incremental fee) diverges from Core (rule4=$R_RULE4): core='${CORE_R[rule4]}' ouro='${OU_R[rule4]}' | replace=$R_REPLACE rule3=$R_RULE3 rule4=$R_RULE4"

# Diagnostic gate: the at-ceiling replacement should be accepted by ouroboros
# (matching Core). An over-rejection here means ouroboros's Rule-4 vsize/rounding
# is too strict — a parity bug in the other direction. Fail loudly.
[[ "$V_RULE4OK" == "ok" ]] || fail "Rule-4 boundary over-rejected (rule4ok=$R_RULE4OK): ouroboros='${OU_R[rule4ok]}' — replacement that exactly clears the incremental ceiling must be accepted as Core does | replace=$R_REPLACE rule3=$R_RULE3 rule4=$R_RULE4"

log "PASS: happy-path replace matches Core; Rule 3 + Rule 4 reject in-category; boundary replacement accepted"
pass "$R_REPLACE" "$R_RULE3" "$R_RULE4"
