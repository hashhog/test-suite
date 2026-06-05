#!/usr/bin/env bash
#
# beamchain_rbf.sh — self-contained RBF/BIP125 mempool-replacement parity test.
#
# The SECOND mempool-policy cell (after testmempoolaccept reject-parity in
# test-suite/policy/). Where the policy harness proved the standardness gate,
# this proves the *replace-by-fee subsystem*: an incoming tx that conflicts
# (spends an input already spent by a mempool tx) must be handled per BIP125 —
# either EVICT the conflict and ACCEPT the replacement (happy path), or REJECT
# with the SAME reject-reason CATEGORY Bitcoin Core emits (rules 3 + 4).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core, /home/work/hashhog/
#   bitcoin-core/build) on a SEPARATE regtest instance (own scratch datadir +
#   ports). For the SAME deterministic sequence of submits, Core's behaviour
#   (getrawmempool membership + sendrawtransaction/testmempoolaccept reject
#   strings) is the oracle. beamchain is driven through the IDENTICAL sequence
#   and compared.
#
# Both nodes default to full-rbf ON (Core v28+ default mempoolfullrbf=true;
# beamchain mempool_full_rbf() defaults true), but the test uses SIGNALING txs
# (nSequence 0xfffffffd) so Rule 1 is satisfied regardless of the full-rbf
# setting — the result is deterministic on any Core/beamchain config.
#
# SCENARIOS (each over its OWN distinct mature coinbase input, so order- and
#   state-independent — no mine-between-cases needed):
#   1. HAPPY PATH (replace):
#        submit A  (signals RBF, fee f1)            -> accepted (in getrawmempool)
#        submit B  (same input, fee f2 = f1*20, meets rules 3+4)
#                                                    -> REPLACES A:
#        getrawmempool contains B and NOT A on BOTH nodes.
#   2. RULE 3 (insufficient absolute fee):
#        submit A2 (signals RBF, fee f1)            -> accepted
#        submit C  (same input, fee f1/2 <= f1)     -> REJECTED
#        reject-reason category == "insufficient fee" on BOTH; A2 stays, C is
#        NOT in the mempool on either node.
#   3. RULE 4 (insufficient incremental fee to relay):
#        submit A3 (signals RBF, fee f1)            -> accepted
#        submit D  (same input, fee f1+1 sat: > f1 so Rule 3 PASSES, but the
#                   +1 sat delta is far below incrementalRelayFee*vsize)
#                                                    -> REJECTED
#        reject-reason category == "insufficient fee" on BOTH; A3 stays, D is
#        NOT in the mempool on either node.
#
# Rule 5 (>100 replacements) is explicitly OUT OF SCOPE for this cell (no 100-tx
# cluster is built) per the brief.
#
# NORMALIZATION (mirrors the policy chapter's classify()): reject-reason strings
#   are compared by CATEGORY. Core emits "insufficient fee, rejecting
#   replacement ..." / "txn-mempool-conflict"; beamchain surfaces the SAME
#   category via beamchain_rpc:format_mempool_error (rbf_insufficient_fee /
#   rbf_insufficient_additional_fee -> "insufficient fee"). A scenario PASSES
#   when impl and Core map to the SAME category.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/beamchain_policy.sh):
#   set -uo pipefail, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: RBF beamchain: PASS replace=ok rule3=ok rule4=ok
#   FAIL: RBF beamchain: FAIL <short reason>
#   SKIP: RBF beamchain: SKIP <build/raw-tx gap>
#
# Touches ONLY /tmp/rbf-beamchain{,-core}/ and ports 40196/40216 (beamchain
#   RPC/P2P), 40198/40218 (Core RPC/P2P). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node. Any `fuser -k` redirects stdout.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

BC_DATADIR="/tmp/rbf-beamchain"
BC_RPC=40196
BC_P2P=40216
BC_LOG="$BC_DATADIR/node.log"

# Core-oracle ports are deliberately placed in a DIFFERENT band (402xx) from
# the brief's beamchain ports (40196/40216) so a sibling RBF cell that also
# parks its Core oracle at 401xx (e.g. rbf-haskoin-core on :40198) never
# collides with — or gets fuser-killed by — this run. The Core datadir name is
# namespaced (-beamchain-) for the same reason.
CORE_DATADIR="/tmp/rbf-beamchain-core"
CORE_RPC=40296
CORE_P2P=40316
CORE_LOG="$CORE_DATADIR/core.log"

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="2222222222222222222222222222222222222222222222222222222222222223"

NBLOCKS=110            # mine well past maturity: gives several spendable coinbases

BC_PID=""
BC_COOKIE=""
CORE_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[rbf:beamchain] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${BC_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${BC_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <replace> <rule3> <rule4>
pass() { echo "RBF beamchain: PASS replace=$1 rule3=$2 rule4=$3"; exit 0; }
fail() { echo "RBF beamchain: FAIL $*"; exit 1; }
skip() { echo "RBF beamchain: SKIP $*"; exit 0; }

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Maps any impl/Core reject string to a canonical category token. Empty input
# (accepted) -> "accept". The two categories this cell asserts:
#   insufficient-fee  : RBF Rule 3 / Rule 4 (Core "insufficient fee ...";
#                       beamchain rbf_insufficient_fee / rbf_insufficient_
#                       additional_fee -> "insufficient fee").
#   mempool-conflict  : non-signaling conflict when RBF not allowed (Core
#                       "txn-mempool-conflict" / "bad-txns-spends-conflicting-
#                       tx"; beamchain rbf_not_signaled -> "txn-mempool-
#                       conflict").
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *"insufficient fee"*|*insufficient_fee*|*insufficient-fee*|*"not enough additional"*|*"less fees"*|*"replacement-failed"*|*replacement_failed*|*"does not improve"*) echo "insufficient-fee" ;;
        *txn-mempool-conflict*|*txn_mempool_conflict*|*"mempool conflict"*|*spends-conflicting*|*spends_conflicting*|*"conflicting tx"*|*rbf_not_signaled*) echo "mempool-conflict" ;;
        *) echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "rbf-beamchain" >/dev/null 2>&1 || true
fuser -k "${BC_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${BC_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
[[ -x "$NODE_BIN" ]]                 || skip "beamchain release binary not found at $NODE_BIN (run rebar3 as prod release)"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || skip "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || skip "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the RBF-sequence Python helper. ──────────────────────────────
# Connects to ONE node's RPC, mines coinbases to the fixed key, reads several
# of that node's OWN mature coinbases (coinbase txids differ per impl), then
# runs the 3 RBF scenarios — each over its own distinct coinbase input — via
# sendrawtransaction + testmempoolaccept + getrawmempool. Prints tab-separated
# result lines to stdout:
#   ACCEPT  <label>  <txid>            (sendrawtransaction returned this txid)
#   REJECT  <label>  <reject-reason>   (sendrawtransaction/tma rejected)
#   MEMPOOL <label>  <txid> <in:0|1>   (membership of txid in getrawmempool)
# These lines are the per-node observation set the bash driver compares.
HELPER="$BC_DATADIR/rbf_seq.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request, urllib.error
sys.path.insert(0, sys.argv[1])  # test_framework path
RPC_URL = sys.argv[2]
COOKIE  = sys.argv[3]            # "user:pass" form
SECRET  = sys.argv[4]
NBLOCKS = int(sys.argv[5])

from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import (CScript, OP_0, hash160, SegwitV0SignatureHash, SIGHASH_ALL,
    OP_DUP, OP_HASH160, OP_EQUALVERIFY, OP_CHECKSIG)
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
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        # Bitcoin Core returns a non-200 HTTP status (e.g. 500) with a
        # JSON-RPC error body when a call fails (e.g. sendrawtransaction
        # rejecting a tx). beamchain returns 200 + a JSON-RPC error body.
        # Read the error response so BOTH surface the same {"error":...}.
        raw = e.read()
        try:
            return json.loads(raw)
        except Exception:
            return {"error": {"code": e.code,
                              "message": raw.decode("utf-8", "replace")}}

def rpc_ok(method, params=None):
    d = rpc(method, params)
    if d.get("error"):
        raise RuntimeError(f"{method} rpc error: {d['error']}")
    return d["result"]

# Deterministic keypair -> p2wpkh address + scriptPubKey.
priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])                 # p2wpkh output
addr = key_to_p2wpkh(pub, main=False)       # bcrt1...

# Mine to maturity (this node's own coinbases).
rpc_ok("generatetoaddress", [NBLOCKS, addr])
if int(rpc_ok("getblockcount")) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)

# Collect several mature coinbase prevouts (one per scenario, all distinct).
# Use coinbases from low heights (1..) so they are well past the 100-block
# maturity at tip NBLOCKS.
def coinbase_at(height):
    bh  = rpc_ok("getblockhash", [height])
    blk = rpc_ok("getblock", [bh, 2])
    cb  = blk["tx"][0]
    txid = cb["txid"]
    val  = int(round(cb["vout"][0]["value"] * COIN))   # 50 BTC in sats
    return COutPoint(int(txid, 16), 0), val

# 3 scenarios -> 3 distinct inputs.
in_happy, val_h = coinbase_at(1)
in_rule3, val_3 = coinbase_at(2)
in_rule4, val_4 = coinbase_at(3)

SIGNAL_SEQ = 0xfffffffd   # BIP125 opt-in RBF signaling

def signed(prevout, prevval, fee, seq=SIGNAL_SEQ, version=2):
    """One-input (the given mature coinbase) one-output p2wpkh spend paying `fee`."""
    tx = CTransaction(); tx.version = version
    tx.vin  = [CTxIn(prevout, b"", seq)]
    tx.vout = [CTxOut(prevval - fee, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])  # BIP143 scriptCode
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, prevval)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    raw = tx.serialize_with_witness().hex()
    txid = tx.txid_hex   # display txid (hex, little-endian display form)
    return raw, txid

def send(raw):
    """sendrawtransaction; returns (ok, txid_or_reason)."""
    d = rpc("sendrawtransaction", [raw])
    if d.get("error"):
        msg = d["error"].get("message", "") or json.dumps(d["error"])
        return False, msg
    return True, d["result"]

def in_mempool(txid):
    mp = rpc_ok("getrawmempool")
    return txid in mp

def emit(*cols):
    safe = [str(c).replace("\t"," ").replace("\n"," ") for c in cols]
    print("\t".join(safe), flush=True)

# Fees (sats). f1 chosen well above the regtest min-relay floor for a ~110 vB tx.
F1 = 2000        # base fee for tx A
F2 = F1 * 20     # replacement fee for happy path: >> F1, easily meets rules 3+4
F_LT = F1 // 2   # rule 3: <= F1  -> insufficient absolute fee
F_TINY_DELTA = 1 # rule 4: F1 + 1 sat: > F1 (rule 3 passes) but +1 sat << incrementalRelayFee*vsize

import traceback

def scenario_happy():
    rawA, txidA = signed(in_happy, val_h, F1)
    okA, resA = send(rawA)
    emit("ACCEPT" if okA else "REJECT", "happy-A", resA)
    if okA:
        emit("MEMPOOL", "happy-A-before", txidA, "1" if in_mempool(txidA) else "0")
        rawB, txidB = signed(in_happy, val_h, F2)
        okB, resB = send(rawB)
        emit("ACCEPT" if okB else "REJECT", "happy-B", resB)
        if okB:
            emit("MEMPOOL", "happy-B", txidB, "1" if in_mempool(txidB) else "0")
            emit("MEMPOOL", "happy-A-after", txidA, "1" if in_mempool(txidA) else "0")

def scenario_rule3():
    rawA2, txidA2 = signed(in_rule3, val_3, F1)
    okA2, resA2 = send(rawA2)
    emit("ACCEPT" if okA2 else "REJECT", "rule3-A", resA2)
    if okA2:
        rawC, txidC = signed(in_rule3, val_3, F_LT)
        okC, resC = send(rawC)
        emit("ACCEPT" if okC else "REJECT", "rule3-C", resC)
        emit("MEMPOOL", "rule3-C", txidC, "1" if in_mempool(txidC) else "0")
        emit("MEMPOOL", "rule3-A-after", txidA2, "1" if in_mempool(txidA2) else "0")

def scenario_rule4():
    rawA3, txidA3 = signed(in_rule4, val_4, F1)
    okA3, resA3 = send(rawA3)
    emit("ACCEPT" if okA3 else "REJECT", "rule4-A", resA3)
    if okA3:
        rawD, txidD = signed(in_rule4, val_4, F1 + F_TINY_DELTA)
        okD, resD = send(rawD)
        emit("ACCEPT" if okD else "REJECT", "rule4-D", resD)
        emit("MEMPOOL", "rule4-D", txidD, "1" if in_mempool(txidD) else "0")
        emit("MEMPOOL", "rule4-A-after", txidA3, "1" if in_mempool(txidA3) else "0")

# Run each scenario independently — a fault in one must not lose the others'
# already-flushed observations (and is surfaced as a traceback on stderr).
for fn in (scenario_happy, scenario_rule3, scenario_rule4):
    try:
        fn()
    except Exception:
        traceback.print_exc(file=sys.stderr)
PYEOF
[[ -s "$HELPER" ]] || fail "failed to write rbf-sequence helper"

# ── Readiness poll for the Core regtest oracle. ───────────────────────────
wait_core_ready() {
    local dd="$1" rpc="$2" pid="$3" lf="$4"
    local deadline=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || { tail -n 20 "$lf" >&2 2>/dev/null || true; return 1; }
        sleep 1
    done
    tail -n 20 "$lf" >&2 2>/dev/null || true
    return 1
}

# ── 3. Launch the Core oracle (DEFAULT policy; full-rbf default ON). ───────
# No policy flags: matches modern default Core. -listen=0 disables the inbound
# P2P listener entirely (a standalone oracle needs no peers). NB: Core rejects
# -bind together with -listen=0, so we do NOT pass -bind here.
log "launching Core oracle rpc=:$CORE_RPC (default policy, full-rbf default, listen=0)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
wait_core_ready "$CORE_DATADIR" "$CORE_RPC" "$CORE_BG" "$CORE_LOG" \
    || fail "Core oracle failed to start within 120s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch beamchain on regtest (release binary, foreground). ──────────
cat >"$BC_DATADIR/sys.config" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$BC_DATADIR"},
   {p2pport, $BC_P2P},
   {rpcport, $BC_RPC}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$BC_DATADIR/vm.args" <<ERLVM
-sname beamchain_rbfref_$$
-setcookie beamchain_rbfref
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
RELX_CONFIG_PATH="$BC_DATADIR/sys.config" VMARGS_PATH="$BC_DATADIR/vm.args" \
    "$NODE_BIN" foreground >"$BC_LOG" 2>&1 &
BC_PID=$!
log "beamchain pid=$BC_PID"
bc_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < bc_deadline )); do
    if [[ -z "$BC_COOKIE" ]]; then
        for c in "$BC_DATADIR/regtest/.cookie" "$BC_DATADIR/.cookie"; do
            [[ -f "$c" ]] && BC_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$BC_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BC_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$BC_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 20 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited during startup (see $BC_LOG)"; }
    sleep 1
done
[[ -n "$BC_COOKIE" ]] || fail "beamchain cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$BC_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$BC_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "beamchain RPC never responded within 90s"
log "beamchain RPC ready"

# ── 5. Run the RBF sequence against both nodes. ───────────────────────────
log "running RBF sequence against Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>"$BC_DATADIR/core-helper.err")
[[ -n "$CORE_OUT" ]] || { cat "$BC_DATADIR/core-helper.err" >&2 2>/dev/null || true; fail "rbf helper produced no output for Core oracle"; }
[[ -s "$BC_DATADIR/core-helper.err" ]] && { log "Core helper stderr:"; cat "$BC_DATADIR/core-helper.err" >&2; }

log "running RBF sequence against beamchain"
BC_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$BC_RPC/" "$BC_COOKIE" "$SECRET" "$NBLOCKS" 2>"$BC_DATADIR/bc-helper.err")
[[ -n "$BC_OUT" ]] || { cat "$BC_DATADIR/bc-helper.err" >&2 2>/dev/null || true; fail "rbf helper produced no output for beamchain"; }
[[ -s "$BC_DATADIR/bc-helper.err" ]] && { log "beamchain helper stderr:"; cat "$BC_DATADIR/bc-helper.err" >&2; }

# ── 6. Parse result sets into label -> (type, payload). ───────────────────
# For ACCEPT/REJECT lines: store the action verb + reason. For MEMPOOL lines:
# store the in:0|1 membership flag.
declare -A CORE_ACT CORE_REASON CORE_MEM BC_ACT BC_REASON BC_MEM
parse_into() {
    local out="$1" prefix="$2"
    while IFS=$'\t' read -r kind label a b; do
        case "$kind" in
            ACCEPT) eval "${prefix}_ACT[\$label]=accept";  eval "${prefix}_REASON[\$label]=\"\$a\"" ;;
            REJECT) eval "${prefix}_ACT[\$label]=reject";  eval "${prefix}_REASON[\$label]=\"\$a\"" ;;
            MEMPOOL) eval "${prefix}_MEM[\$label]=\"\$b\"" ;;   # b = in:0|1
        esac
    done <<< "$out"
}
parse_into "$CORE_OUT" CORE
parse_into "$BC_OUT"   BC

log "=== RBF/BIP125 PARITY  (signaling nSequence=0xfffffffd; both nodes full-rbf default) ==="
log "--- Core observations ---"
while IFS= read -r ln; do log "  CORE  $ln"; done <<< "$CORE_OUT"
log "--- beamchain observations ---"
while IFS= read -r ln; do log "  BEAM  $ln"; done <<< "$BC_OUT"

# ── 7. Evaluate the three scenarios. ──────────────────────────────────────
REPLACE_T="?"
RULE3_T="?"
RULE4_T="?"
FAILMSG=""

req() {  # req <assoc_name> <key>  -> echoes value or empty
    local an="$1" k="$2"; eval "echo \"\${${an}[\$k]:-}\""
}

# --- Scenario 1: HAPPY PATH (replace) ---
# Expect: A accepted on both; B accepted on both; after B, mempool has B and
# NOT A on both.
c_A=$(req CORE_ACT happy-A);   b_A=$(req BC_ACT happy-A)
c_B=$(req CORE_ACT happy-B);   b_B=$(req BC_ACT happy-B)
c_Bin=$(req CORE_MEM happy-B); b_Bin=$(req BC_MEM happy-B)
c_Aaf=$(req CORE_MEM happy-A-after); b_Aaf=$(req BC_MEM happy-A-after)
if [[ "$c_A" != "accept" ]]; then
    REPLACE_T="core-A-rejected"; FAILMSG="${FAILMSG} replace:core-rejected-A(${CORE_REASON[happy-A]:-?})"
elif [[ "$b_A" != "accept" ]]; then
    REPLACE_T="beam-A-rejected"; FAILMSG="${FAILMSG} replace:beam-rejected-A(${BC_REASON[happy-A]:-?})"
elif [[ "$c_B" != "accept" || "$c_Bin" != "1" || "$c_Aaf" != "0" ]]; then
    # Core itself didn't perform the replacement -> harness/oracle problem.
    REPLACE_T="core-no-replace"; FAILMSG="${FAILMSG} replace:core-did-not-replace(B=$c_B Bin=$c_Bin Aafter=$c_Aaf)"
elif [[ "$b_B" == "accept" && "$b_Bin" == "1" && "$b_Aaf" == "0" ]]; then
    REPLACE_T="ok"
else
    REPLACE_T="beam-no-replace"
    FAILMSG="${FAILMSG} replace:beamchain-did-not-replace(B-action=$b_B B-in-mempool=$b_Bin A-after=$b_Aaf reason=${BC_REASON[happy-B]:-none})"
fi

# --- Scenario 2: RULE 3 (insufficient absolute fee) ---
# Expect: A2 accepted on both; C rejected on both with category insufficient-fee;
# C NOT in mempool; A2 still in mempool on both.
c_A2=$(req CORE_ACT rule3-A); b_A2=$(req BC_ACT rule3-A)
c_C=$(req CORE_ACT rule3-C);  b_C=$(req BC_ACT rule3-C)
c_Cr=$(req CORE_REASON rule3-C); b_Cr=$(req BC_REASON rule3-C)
c_Cin=$(req CORE_MEM rule3-C); b_Cin=$(req BC_MEM rule3-C)
c_A2af=$(req CORE_MEM rule3-A-after); b_A2af=$(req BC_MEM rule3-A-after)
ccat3=$(classify "$c_Cr"); bcat3=$(classify "$b_Cr")
if [[ "$c_A2" != "accept" || "$b_A2" != "accept" ]]; then
    RULE3_T="setup-failed"; FAILMSG="${FAILMSG} rule3:setup-A-not-accepted(core=$c_A2 beam=$b_A2)"
elif [[ "$c_C" != "reject" || "$ccat3" != "insufficient-fee" || "$c_Cin" == "1" ]]; then
    RULE3_T="core-unexpected"; FAILMSG="${FAILMSG} rule3:core-did-not-reject-as-insufficient-fee(C=$c_C cat=$ccat3 Cin=$c_Cin reason='$c_Cr')"
elif [[ "$b_C" == "reject" && "$bcat3" == "insufficient-fee" && "$b_Cin" != "1" && "$b_A2af" == "1" ]]; then
    RULE3_T="ok"
else
    RULE3_T="beam-mismatch"
    FAILMSG="${FAILMSG} rule3:beamchain-mismatch(C-action=$b_C cat=$bcat3 C-in-mempool=$b_Cin A-after=$b_A2af reason='$b_Cr' [core-cat=$ccat3])"
fi

# --- Scenario 3: RULE 4 (insufficient incremental relay fee) ---
c_A3=$(req CORE_ACT rule4-A); b_A3=$(req BC_ACT rule4-A)
c_D=$(req CORE_ACT rule4-D);  b_D=$(req BC_ACT rule4-D)
c_Dr=$(req CORE_REASON rule4-D); b_Dr=$(req BC_REASON rule4-D)
c_Din=$(req CORE_MEM rule4-D); b_Din=$(req BC_MEM rule4-D)
c_A3af=$(req CORE_MEM rule4-A-after); b_A3af=$(req BC_MEM rule4-A-after)
ccat4=$(classify "$c_Dr"); bcat4=$(classify "$b_Dr")
if [[ "$c_A3" != "accept" || "$b_A3" != "accept" ]]; then
    RULE4_T="setup-failed"; FAILMSG="${FAILMSG} rule4:setup-A-not-accepted(core=$c_A3 beam=$b_A3)"
elif [[ "$c_D" != "reject" || "$ccat4" != "insufficient-fee" || "$c_Din" == "1" ]]; then
    RULE4_T="core-unexpected"; FAILMSG="${FAILMSG} rule4:core-did-not-reject-as-insufficient-fee(D=$c_D cat=$ccat4 Din=$c_Din reason='$c_Dr')"
elif [[ "$b_D" == "reject" && "$bcat4" == "insufficient-fee" && "$b_Din" != "1" && "$b_A3af" == "1" ]]; then
    RULE4_T="ok"
else
    RULE4_T="beam-mismatch"
    FAILMSG="${FAILMSG} rule4:beamchain-mismatch(D-action=$b_D cat=$bcat4 D-in-mempool=$b_Din A-after=$b_A3af reason='$b_Dr' [core-cat=$ccat4])"
fi

# ── 8. Verdict. ───────────────────────────────────────────────────────────
if [[ "$REPLACE_T" == "ok" && "$RULE3_T" == "ok" && "$RULE4_T" == "ok" ]]; then
    log "PASS: RBF replace + rule3 + rule4 all match Core categorically"
    pass ok ok ok
fi

# Distinguish a Core-side / harness problem from a beamchain divergence: if any
# scenario's Core observation was itself unexpected, the oracle/harness is the
# blocker, report SKIP rather than blaming beamchain.
if [[ "$REPLACE_T" == "core-no-replace" || "$REPLACE_T" == "core-A-rejected" \
   || "$RULE3_T" == "core-unexpected"   || "$RULE4_T" == "core-unexpected" ]]; then
    skip "Core oracle behaved unexpectedly (harness/oracle issue, not beamchain):${FAILMSG} | replace=$REPLACE_T rule3=$RULE3_T rule4=$RULE4_T"
fi

fail "beamchain diverged from Core:${FAILMSG} | replace=$REPLACE_T rule3=$RULE3_T rule4=$RULE4_T"
