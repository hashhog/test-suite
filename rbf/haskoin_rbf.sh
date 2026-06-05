#!/usr/bin/env bash
#
# haskoin_rbf.sh — self-contained RBF (BIP-125) replacement + fee-rule
#   DIFFERENTIAL parity test (the SECOND mempool-policy cell, after the
#   testmempoolaccept reject-parity policy chapter).
#
# WHAT THIS PROVES (consensus-ADJACENT: relay policy, not consensus):
#   haskoin's mempool replaces an RBF-signaling transaction with a higher-fee
#   conflict (the happy path) AND rejects under-paying replacements with the
#   SAME reject-reason CATEGORY Bitcoin Core emits.  Where the policy chapter
#   proved the standardness GATE, this proves the REPLACEMENT subsystem:
#     * Rule 1 (signaling): tx A signals replaceability (nSequence 0xfffffffd)
#       so the test is deterministic regardless of the -mempoolfullrbf setting.
#     * Rule 3 (absolute fee): replacement abs-fee >= sum of replaced fees,
#       else "insufficient fee" ("less fees than conflicting txs").
#     * Rule 4 (own bandwidth): (repl_fee - replaced_fee) >=
#       incrementalRelayFee * repl_vsize, else "insufficient fee"
#       ("not enough additional fees to relay").
#   Rule 2 (no new unconfirmed inputs) and Rule 5 (<=100 replacements) are out
#   of scope for this cell.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core v31.99) on its own
#   regtest scratch datadir + ports, launched -listen=0.  For each step the
#   SAME raw tx is submitted to Core and to haskoin and the decisions compared.
#
# PORTABLE CONSTRUCTION (no wallet, no createrawtransaction dependency — the
#   raw-tx machinery has known per-impl bugs, so we sidestep it entirely the
#   way test-suite/policy/haskoin_policy.sh does): mine 101 blocks to a
#   deterministic p2wpkh address derived from a fixed secret on EACH node, then
#   build conflicting txs that spend the block-1 coinbase directly, signing
#   with the same fixed key via Core's test_framework.  The input is fixed; the
#   single output amount sets the fee exactly.
#
# THE CONFLICTS (all spend the SAME coinbase prevout, nSequence 0xfffffffd):
#   input value = 50 BTC = 5_000_000_000 sat; vsize ~110 vB.
#   incrementalRelayFee = 100 sat/kvB = 0.1 sat/vB  ->  rule-4 floor ~11 sat.
#     A : fee 1000  -> signals RBF, the original.                    ACCEPT
#     B : fee 5000  -> abs-fee >> A, delta 4000 >> floor.            REPLACES A
#     C : fee 800   -> abs-fee < A  (rule 3 fail).                   REJECT "insufficient fee"
#     D : fee 1005  -> abs-fee > A but delta 5 < ~11 (rule 4 fail).  REJECT "insufficient fee"
#
# ASSERTIONS (haskoin must match Core for the SAME submit sequence):
#   1. HAPPY PATH (replace): submit A -> in getrawmempool on both. submit B ->
#      getrawmempool now contains B and NOT A on both.
#   2. RULE 3: with A back in the pool, testmempoolaccept C -> rejected with
#      category "insufficient fee" on both (C does not enter the mempool).
#   3. RULE 4: testmempoolaccept D -> rejected category "insufficient fee" on both.
#
# NORMALIZATION: reject-reason strings compared by CATEGORY (impls phrase the
#   detail differently).  The categories that must agree here are
#   "insufficient fee" (rules 3/4) and the mempool-conflict family.  classify()
#   maps any impl/Core string to a canonical token.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/rustoshi_policy.sh): no
#   required args, idempotent, trap cleanup, scratch /tmp + unique ports, ONE
#   summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: RBF haskoin: PASS replace=ok rule3=ok rule4=ok
#   FAIL: RBF haskoin: FAIL <short reason>
#   SKIP: RBF haskoin: SKIP <build/raw-tx gap>
#
# Touches ONLY /tmp/rbf-haskoin/ + /tmp/rbf-haskoin-core/ and ports
#   40199/40219 (haskoin RPC/P2P), 40198/40218 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$(find "$BASEDIR/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

export haskoin_datadir="$BASEDIR/haskoin"

HK_DATADIR="/tmp/rbf-haskoin"
HK_RPC=40199
HK_P2P=40219
HK_LOG="$HK_DATADIR/node.log"
HK_URL="http://127.0.0.1:${HK_RPC}"
HK_COOKIE=""

CORE_DATADIR="/tmp/rbf-haskoin-core"
CORE_RPC=40198
CORE_P2P=40218
CORE_LOG="$CORE_DATADIR/core.log"

SECRET="1111111111111111111111111111111111111111111111111111111111111112"
NBLOCKS=101            # mine to maturity: block-1 coinbase (50 BTC) spendable at tip 101

HK_PID=""
CORE_BG=""
HELPER=""

log() { echo "[rbf:haskoin] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$HK_PID" ]] && kill -0 "$HK_PID" 2>/dev/null; then
        kill "$HK_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HK_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HK_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${HK_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${HK_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$HK_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "RBF haskoin: PASS replace=$1 rule3=$2 rule4=$3"
    exit 0
}
fail() {
    echo "RBF haskoin: FAIL $*"
    exit 1
}
skip() {
    echo "RBF haskoin: SKIP $*"
    exit 0
}

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Empty input (accepted) -> "accept".  Anything unmatched -> "other:<verbatim>".
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *"insufficient fee"*|*insufficient-fee*|*"not enough additional fees"*|*"less fees than"*|*"replacement-adds"*) echo "insufficient-fee" ;;
        *"txn-mempool-conflict"*|*"mempool-conflict"*|*"spends-conflicting"*|*"already spent"*|*"already in mempool"*) echo "mempool-conflict" ;;
        *"min relay fee"*|*min-relay*|*"min-fee"*|*"fee not met"*|*"fee below"*) echo "min-relay" ;;
        *) echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "rbf-haskoin" 2>/dev/null || true
fuser -k "${HK_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${HK_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$HK_DATADIR" "$CORE_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || skip "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || skip "curl not found on PATH"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || skip "haskoin binary not found (build with: cabal build exe:haskoin)"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || skip "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || skip "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the RBF-driver Python helper. ────────────────────────────────
# One driver runs the WHOLE submit sequence against a single node and prints a
# machine-readable transcript of decisions.  The caller runs it once per node
# and diffs the transcripts.
HELPER="$HK_DATADIR/rbf_driver.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request
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
    with urllib.request.urlopen(req, timeout=90) as r:
        d = json.loads(r.read())
    return d  # caller inspects error/result

def rpc_ok(method, params=None):
    d = rpc(method, params)
    if d.get("error"):
        raise RuntimeError(f"{method} rpc error: {d['error']}")
    return d["result"]

priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])
addr = key_to_p2wpkh(pub, main=False)

# Mine to maturity on THIS node (each node has its own independent regtest chain
# but the deterministic key + fixed block-1 coinbase make the spend identical).
rpc_ok("generatetoaddress", [NBLOCKS, addr])
if int(rpc_ok("getblockcount")) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)

bh  = rpc_ok("getblockhash", [1])
blk = rpc_ok("getblock", [bh, 2])
cb  = blk["tx"][0]
cb_txid = cb["txid"]
val = int(round(cb["vout"][0]["value"] * COIN))
prevout = COutPoint(int(cb_txid, 16), 0)

# Signaling sequence (BIP-125): 0xfffffffd <= MAX_BIP125_RBF_SEQUENCE.
RBF_SEQ = 0xfffffffd

def build(fee):
    """1-in/1-out p2wpkh spend of the block-1 coinbase, signaling RBF."""
    tx = CTransaction(); tx.version = 2
    tx.vin  = [CTxIn(prevout, b"", RBF_SEQ)]
    tx.vout = [CTxOut(val - fee, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx.serialize_with_witness().hex()

# Fee schedule (see header).  ALL spend the SAME block-1 coinbase prevout, so
# A is the single incumbent for the rule-3 / rule-4 corners AND the tx that B
# replaces in the happy path.  Block 1's coinbase is mature at tip 101
# (101 - 1 = 100 >= COINBASE_MATURITY), spendable in the next block.
A = build(1000)    # original, signals RBF, fee 1000
B = build(5000)    # replacement: abs-fee 5000 >> 1000, delta 4000 >> rule-4 floor
C = build(800)     # rule-3 corner: abs-fee 800 < 1000  -> "insufficient fee"
D = build(1005)    # rule-4 corner: abs-fee 1005 > 1000 but delta 5 < ~11 floor

def in_mempool(txid):
    res = rpc_ok("getrawmempool", [])
    return txid in res

def txid_of(rawhex):
    # decoderawtransaction is universally supported; fall back to local compute
    d = rpc("decoderawtransaction", [rawhex])
    if not d.get("error"):
        return d["result"]["txid"]
    from test_framework.messages import tx_from_hex
    t = tx_from_hex(rawhex)
    t.rehash()
    return t.hash

def send(rawhex):
    # maxfeerate=0 disables the per-call fee ceiling on BOTH nodes so the test
    # isolates RBF behavior (these tiny-vsize regtest spends carry a very high
    # sat/vB rate that would otherwise trip the default maxfeerate guard).
    d = rpc("sendrawtransaction", [rawhex, 0])
    if d.get("error"):
        return False, (d["error"].get("message") or "rejected")
    return True, ""

def tma(rawhex):
    r = rpc_ok("testmempoolaccept", [[rawhex]])[0]
    allowed = bool(r.get("allowed"))
    reason  = "" if allowed else (r.get("reject-reason") or "rejected")
    return allowed, reason

tA = txid_of(A); tB = txid_of(B)

def emit(tag, *fields):
    safe = [str(f).replace("\t", " ").replace("\n", " ") for f in fields]
    print("RES\t" + tag + "\t" + "\t".join(safe))

# ── Establish incumbent A (signals RBF, fee 1000). ────────────────────────
okA, rA = send(A)
emit("sendA", "true" if okA else "false", rA)
emit("A_in", "true" if in_mempool(tA) else "false")

# ── RULE 3 (absolute fee): C under-pays the incumbent A -> reject. ────────
# testmempoolaccept so the conflict is evaluated WITHOUT mutating the pool.
aC, rC = tma(C)
emit("tmaC", "true" if aC else "false", rC)

# ── RULE 4 (own bandwidth): D pays slightly MORE absolute fee than A (1005 >
# 1000, passes rule 3) but the delta (5 sat) is below the incremental-relay
# floor (~11 sat) -> reject "insufficient fee". ───────────────────────────
aD, rD = tma(D)
emit("tmaD", "true" if aD else "false", rD)

# A must still be the sole incumbent (testmempoolaccept never mutates).
emit("A_still", "true" if in_mempool(tA) else "false")

# ── HAPPY PATH (replace): B (fee 5000) replaces A. ────────────────────────
okB, rB = send(B)
emit("sendB", "true" if okB else "false", rB)
emit("B_in", "true" if in_mempool(tB) else "false")
emit("A_gone", "true" if not in_mempool(tA) else "false")
PYEOF
[[ -s "$HELPER" ]] || skip "failed to write RBF driver helper"

# ── 3. Launch the Core regtest oracle (-listen=0). ────────────────────────
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -> $CORE_LOG"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 120 ))
core_ready=0
while (( $(date +%s) < core_deadline )); do
    if "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
        core_ready=1; break
    fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" -eq 1 ]] || fail "Core oracle never became ready within 120s (see $CORE_LOG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch haskoin on regtest (RPC-only; generous >=90s startup wait). ─
log "launching haskoin (regtest) rpc=:$HK_RPC p2p=:$HK_P2P -> $HK_LOG"
"$NODE_BIN" --network Regtest --datadir "$HK_DATADIR" node \
    --rpcport "$HK_RPC" --port "$HK_P2P" --listen False --metricsport 0 \
    >"$HK_LOG" 2>&1 &
HK_PID=$!
log "haskoin pid=$HK_PID"
hk_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$HK_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "$HK_URL/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$HK_PID" 2>/dev/null || { tail -n 30 "$HK_LOG" >&2 2>/dev/null || true; fail "haskoin exited during startup (see $HK_LOG)"; }
    sleep 1
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 120s"
r=$(curl -s --max-time 5 -u "$HK_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$HK_URL/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "haskoin RPC never responded within 120s"
log "haskoin RPC ready"

# ── 5. Run the driver against both nodes. ─────────────────────────────────
log "running RBF driver against Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "RBF driver produced no output for Core oracle"; }

log "running RBF driver against haskoin"
HK_OUT=$(python3 "$HELPER" "$TF_PATH" "$HK_URL/" "$HK_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$HK_LOG")
[[ -n "$HK_OUT" ]] || { tail -n 30 "$HK_LOG" >&2 2>/dev/null || true; fail "RBF driver produced no output for haskoin"; }

# ── 6. Parse transcripts.  RES is column 1; key is column 2; v1/v2 follow. ─
declare -A CORE_K HK_K
parse() {
    local -n out=$1; local txt="$2"
    while IFS=$'\t' read -r tag key val1 val2; do
        [[ "$tag" == "RES" ]] || continue
        out["$key"]="$val1"$'\t'"$val2"
    done <<< "$txt"
}
parse CORE_K "$CORE_OUT"
parse HK_K "$HK_OUT"

# helper: first value of a key
v1() { local s="${1:-}"; echo "${s%%$'\t'*}"; }
v2() { local s="${1:-}"; echo "${s#*$'\t'}"; }

KEYS=(sendA A_in tmaC tmaD A_still sendB B_in A_gone)
for k in "${KEYS[@]}"; do
    [[ -n "${CORE_K[$k]:-}" ]] || fail "Core transcript missing key '$k'"
    [[ -n "${HK_K[$k]:-}"   ]] || fail "haskoin transcript missing key '$k'"
done

# ── 7. Forensic table. ────────────────────────────────────────────────────
log "=== RBF DIFFERENTIAL (Core oracle vs haskoin) ==="
printf '%-10s | %-30s | %-30s\n' "step" "Core" "haskoin" >&2
for k in "${KEYS[@]}"; do
    printf '%-10s | %-30s | %-30s\n' "$k" "${CORE_K[$k]//$'\t'/ }" "${HK_K[$k]//$'\t'/ }" >&2
done

# ── 8. Assertion 2: RULE 3 (absolute fee). C under-pays incumbent A. ──────
# Both nodes must REJECT with category "insufficient fee".  (Numbered first so
# rule-3/4 are checked against the pristine A-only pool, before the B replace.)
RULE3="ok"
[[ "$(v1 "${CORE_K[sendA]}")" == "true" ]] || fail "Core did not accept A (rA=$(v2 "${CORE_K[sendA]}"))"
[[ "$(v1 "${CORE_K[A_in]}")"  == "true" ]] || fail "Core: A not in mempool after submit"
[[ "$(v1 "${HK_K[sendA]}")"   == "true" ]] || fail "haskoin did not accept A (rA=$(v2 "${HK_K[sendA]}"))"
[[ "$(v1 "${HK_K[A_in]}")"    == "true" ]] || fail "haskoin: A not in mempool after submit"

cC=$(classify "$(v2 "${CORE_K[tmaC]}")")
iC=$(classify "$(v2 "${HK_K[tmaC]}")")
[[ "$(v1 "${CORE_K[tmaC]}")" == "false" ]] || fail "Core unexpectedly ACCEPTED C (under-fee) — oracle baseline wrong"
[[ "$cC" == "insufficient-fee" ]] || fail "Core rule-3 category unexpected (core=$cC, reason='$(v2 "${CORE_K[tmaC]}")')"
if [[ "$(v1 "${HK_K[tmaC]}")" != "false" ]]; then
    RULE3="haskoin-accepts-C"
elif [[ "$iC" != "$cC" ]]; then
    RULE3="cat-mismatch(core=$cC,hask=$iC)"
fi
[[ "$RULE3" == "ok" ]] || fail "rule-3 (absolute fee) mismatch: $RULE3 | replace=? rule3=$RULE3"

# ── 9. Assertion 3: RULE 4 (own bandwidth / incremental relay). ───────────
# D pays MORE absolute fee than incumbent A (passes rule 3) but the delta is
# below the incremental-relay floor -> rule-4 reject "insufficient fee" on both.
RULE4="ok"
cD=$(classify "$(v2 "${CORE_K[tmaD]}")")
iD=$(classify "$(v2 "${HK_K[tmaD]}")")
[[ "$(v1 "${CORE_K[tmaD]}")" == "false" ]] || fail "Core unexpectedly ACCEPTED D (rule-4 corner) — oracle baseline wrong"
[[ "$cD" == "insufficient-fee" ]] || fail "Core rule-4 category not insufficient-fee (core=$cD, reason='$(v2 "${CORE_K[tmaD]}")')"
if [[ "$(v1 "${HK_K[tmaD]}")" != "false" ]]; then
    RULE4="haskoin-accepts-D"
elif [[ "$iD" != "$cD" ]]; then
    RULE4="cat-mismatch(core=$cD,hask=$iD)"
fi
[[ "$RULE4" == "ok" ]] || fail "rule-4 (incremental relay) mismatch: $RULE4 | replace=? rule3=$RULE3 rule4=$RULE4"

# Sanity: testmempoolaccept must not have mutated the pool — A still present.
[[ "$(v1 "${CORE_K[A_still]}")" == "true" ]] || fail "Core: A vanished after testmempoolaccept (oracle anomaly)"
[[ "$(v1 "${HK_K[A_still]}")"   == "true" ]] || fail "haskoin: testmempoolaccept mutated the pool (A vanished)"

# ── 10. Assertion 1: HAPPY PATH (replace). B (fee 5000) replaces A. ───────
REPLACE="ok"
[[ "$(v1 "${CORE_K[sendB]}")"  == "true" ]] || fail "Core did not accept replacement B (rB=$(v2 "${CORE_K[sendB]}"))"
[[ "$(v1 "${CORE_K[B_in]}")"   == "true" ]] || fail "Core: replacement B not in mempool"
[[ "$(v1 "${CORE_K[A_gone]}")" == "true" ]] || fail "Core: original A still in mempool after replacement"
if [[ "$(v1 "${HK_K[sendB]}")" != "true" ]]; then
    REPLACE="haskoin-rejected-B:$(v2 "${HK_K[sendB]}")"
elif [[ "$(v1 "${HK_K[B_in]}")" != "true" ]]; then
    REPLACE="haskoin-B-not-in-pool"
elif [[ "$(v1 "${HK_K[A_gone]}")" != "true" ]]; then
    REPLACE="haskoin-A-not-evicted"
fi
[[ "$REPLACE" == "ok" ]] || fail "happy-path replace mismatch: $REPLACE | replace=$REPLACE rule3=$RULE3 rule4=$RULE4"

log "PASS: happy-path replace + rule-3 (abs fee) + rule-4 (incremental relay) all match Core category"
pass "$REPLACE" "$RULE3" "$RULE4"
