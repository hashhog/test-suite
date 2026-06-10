#!/usr/bin/env bash
#
# rustoshi_rbf.sh — self-contained RBF (Replace-By-Fee / BIP125) replacement +
# fee-rule reject-parity test, differential against a REAL bitcoind regtest
# oracle.
#
# The SECOND mempool-policy cell (after testmempoolaccept reject-parity in
# test-suite/policy/rustoshi_policy.sh). Where the policy harness proved the
# standardness GATE, this proves the mempool REPLACEMENT subsystem: when an
# incoming tx double-spends an input already spent by a mempool tx, rustoshi
# must (a) detect the conflict, (b) if the original signals replaceability,
# apply BIP125 rules 3+4, and (c) EVICT+ACCEPT the replacement when the rules
# pass / REJECT with Core's reject-reason CATEGORY when they fail.
#
# Consensus-ADJACENT (relay policy, not consensus). Mirrors the uniform
# interface of test-suite/policy/rustoshi_policy.sh.
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on a SEPARATE regtest
#   instance (own scratch datadir + ports). For each step the SAME sequence of
#   submits is replayed against Core and rustoshi, and decisions are compared.
#
# PORTABLE CONSTRUCTION (no wallet dependency — same trick as the policy
#   harness): a fixed deterministic p2wpkh key funds a coinbase via
#   generatetoaddress; the height-1 coinbase output is the SINGLE shared input
#   that every conflicting tx spends. Each conflict is built + SIGNED in Python
#   (BIP143 SegwitV0SignatureHash) at a different output amount = different fee.
#   nSequence is set to 0xfffffffd on the input so the original SIGNALS BIP125
#   replaceability — deterministic regardless of the node's mempoolfullrbf
#   setting (rustoshi defaults full_rbf=true, Core v28+ defaults true; signaling
#   removes that variable).
#
# THE THREE ASSERTIONS (each replayed identically on Core then rustoshi):
#   1. HAPPY PATH (replace): submit A (signals RBF, fee f1) -> accepted (in
#      getrawmempool). Submit B (same input, fee f2 >> f1, meets rules 3+4) ->
#      REPLACES A: getrawmempool now contains B and NOT A on BOTH nodes.
#   2. RULE 3 (insufficient absolute fee): reset, submit A again, then C (same
#      input, fee <= f1) -> testmempoolaccept rejects with category
#      "insufficient fee" on BOTH; the conflict does NOT enter the mempool.
#   3. RULE 4 (insufficient bandwidth fee): submit D (same input, fee slightly
#      > f1 but the delta < incrementalRelayFee*vsize) -> rejected
#      "insufficient fee" on BOTH.
#
# NORMALIZATION: reject-reason strings are compared by CATEGORY (Core says
#   "insufficient fee"; rustoshi's MempoolError Display says
#   "rbf: insufficient absolute fee (...)" / "rbf: insufficient bandwidth fee
#   (...)"). Both map to category "insufficient-fee" via classify(). A step
#   PASSES when impl and Core map to the same category.
#
# Rule 5 (<=100 replacements) is OUT OF SCOPE per the cell brief — no 100-tx
#   cluster is built.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/rustoshi_policy.sh): no
#   required args, idempotent, trap cleanup, scratch datadirs + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: RBF rustoshi: PASS replace=ok rule3=ok rule4=ok
#   FAIL: RBF rustoshi: FAIL <short reason>
#   SKIP: RBF rustoshi: SKIP <build/raw-tx gap>
#
# Touches ONLY /tmp/rbf-rustoshi/ (rustoshi) + /tmp/rbf-core/ (Core oracle)
#   and ports 22090/22110 (rustoshi RPC/P2P), 22092/22112 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

RS_DATADIR="/tmp/rbf-rustoshi"
RS_RPC=22090
RS_P2P=22110
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/rbf-core"
CORE_RPC=22092
CORE_P2P=22112
CORE_LOG="$CORE_DATADIR/core.log"

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="2222222222222222222222222222222222222222222222222222222222222223"

# Mine to height 102 so BOTH the height-1 AND height-2 coinbases are mature
# (ages 101 and 100 at tip 102; COINBASE_MATURITY=100). Phases 1-2 spend the
# height-1 coinbase; phase 3 (rule 4) spends the independent height-2 coinbase.
# (At tip 101 the height-2 coinbase has age 99 < 100 and rustoshi correctly
# rejects spending it — height 102 makes the second funding source mature too.)
NBLOCKS=102

RS_PID=""
RS_COOKIE=""
CORE_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[rbf:rustoshi] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$RS_PID" ]] && kill -0 "$RS_PID" 2>/dev/null; then
        kill "$RS_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$RS_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$RS_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$RS_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "RBF rustoshi: PASS replace=$1 rule3=$2 rule4=$3"; exit 0; }
fail() { echo "RBF rustoshi: FAIL $*"; exit 1; }
skip() { echo "RBF rustoshi: SKIP $*"; exit 0; }

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Maps any impl/Core reject string to a canonical category token. Empty input
# (accepted) -> "accept". The two RBF fee rules (Rule 3 + Rule 4) both fall
# under Core's "insufficient fee" umbrella; rustoshi phrases them as
# "rbf: insufficient absolute fee" / "rbf: insufficient bandwidth fee".
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *"insufficient fee"*|*"insufficient absolute fee"*|*"insufficient bandwidth fee"*|*"less fees than conflicting"*|*"not enough additional fees"*|*"insufficient feerate"*)
            echo "insufficient-fee" ;;
        *"txn-mempool-conflict"*|*"bad-txns-spends-conflicting"*|*"replacement-disallowed"*|*"bip125-replacement-disallowed"*|*"not signaling"*|*"replacement not signaling"*)
            echo "mempool-conflict" ;;
        *"replacement-adds-unconfirmed"*)
            echo "adds-unconfirmed" ;;
        *"too many potential replacements"*|*"too many replacements"*|*"too many conflicting"*)
            echo "too-many-replacements" ;;
        *)  echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "rbf-rustoshi" >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${RS_RPC}|${RS_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${RS_RPC}|${RS_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${RS_RPC}/${RS_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
# Settle: give a prior run's daemons time to release ports + datadir locks.
sleep 3
rm -rf "$RS_DATADIR" "$CORE_DATADIR"
mkdir -p "$RS_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || skip "python3 not found on PATH"
[[ -x "$NODE_BIN" ]]                 || skip "rustoshi binary not found at $NODE_BIN (build with: cargo build --release)"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || skip "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || skip "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the RBF-corpus Python helper. ────────────────────────────────
# Driven once per node. It connects to ONE node's RPC, mines a coinbase to the
# fixed key, reads that node's OWN height-1 coinbase (txids differ per impl),
# and replays the RBF sequence:
#   STEP submit-A   <allowed> <reason> <inmempool:A?>
#   STEP submit-B   <allowed> <reason> <inmempool:A?> <inmempool:B?>  (replace via sendrawtx)
#   STEP tma-C      <allowed> <reason>                               (Rule 3 via testmempoolaccept)
#   STEP tma-D      <allowed> <reason>                               (Rule 4 via testmempoolaccept)
# It prints tab-separated STEP lines to stdout. Fees are chosen so:
#   A: fee f1   (signals RBF via nSequence 0xfffffffd)
#   B: fee f2 = f1 + LARGE  (passes rule 3 AND rule 4 -> replaces A)
#   C: fee f1 (== A) actually LOWER absolute via larger output -> rule 3 reject
#   D: fee f1 + TINY (delta < incrementalRelayFee*vsize) -> rule 4 reject
HELPER="$RS_DATADIR/rbf_corpus.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request
sys.path.insert(0, sys.argv[1])  # test_framework path
RPC_URL   = sys.argv[2]
COOKIE    = sys.argv[3]          # "user:pass" form
SECRET    = sys.argv[4]
NBLOCKS   = int(sys.argv[5])

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
    return d.get("result"), d.get("error")

def rpc_ok(method, params=None):
    res, err = rpc(method, params)
    if err:
        raise RuntimeError(f"{method} rpc error: {err}")
    return res

# Deterministic keypair -> p2wpkh address + scriptPubKey.
priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])                 # p2wpkh output
addr = key_to_p2wpkh(pub, main=False)       # bcrt1...

# Mine to maturity (this node's own coinbase) and read the height-1 coinbase.
rpc_ok("generatetoaddress", [NBLOCKS, addr])
if int(rpc_ok("getblockcount")) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)
bh  = rpc_ok("getblockhash", [1])
blk = rpc_ok("getblock", [bh, 2])
cb  = blk["tx"][0]
cb_txid = cb["txid"]
val = int(round(cb["vout"][0]["value"] * COIN))      # 50 BTC in sats
prevout = COutPoint(int(cb_txid, 16), 0)

SEQ_RBF = 0xfffffffd   # signals BIP125 opt-in replaceability

def build(out_value, seq=SEQ_RBF, version=2):
    """Single-input (the mature coinbase) -> single p2wpkh output of out_value.
    fee = val - out_value. Signed BIP143."""
    tx = CTransaction(); tx.version = version
    tx.vin  = [CTxIn(prevout, b"", seq)]
    tx.vout = [CTxOut(out_value, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])  # BIP143 scriptCode
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    raw = tx.serialize_with_witness().hex()
    vsize = (len(tx.serialize_without_witness())*3 + len(tx.serialize_with_witness()) + 3)//4
    return raw, vsize, (val - out_value)

# Fee schedule (sats). The control spend is ~110 vbytes.
#   A: fee  1_000  (~9 sat/vB) — well above the 1 sat/vB floor, signals RBF.
#   B: fee 50_000  — huge bump: passes rule 3 (>= f1) AND rule 4 (delta huge).
#   C: fee    500  — LOWER absolute than A -> rule 3 reject (less fees).
#   D: fee  1_001  — delta over A is 1 sat << incrementalRelayFee*vsize (~11 sat
#                    at 100 sat/kvB * ~110 vB) -> rule 4 reject.
FEE_A = 1_000
FEE_B = 50_000
FEE_C = 500
FEE_D = 1_001

rawA, vsA, feeA = build(val - FEE_A)
rawB, vsB, feeB = build(val - FEE_B)
rawC, vsC, feeC = build(val - FEE_C)
rawD, vsD, feeD = build(val - FEE_D)

def txid_of(raw):
    from io import BytesIO
    t = CTransaction()
    t.deserialize(BytesIO(bytes.fromhex(raw)))
    # This Core build exposes txid_hex (display / big-endian) instead of the
    # older rehash()/.hash convention. getrawmempool returns the same form.
    return t.txid_hex

idA, idB, idC, idD = txid_of(rawA), txid_of(rawB), txid_of(rawC), txid_of(rawD)

def in_mempool(txid):
    mp = rpc_ok("getrawmempool")
    return "true" if txid in mp else "false"

def send(raw):
    res, err = rpc("sendrawtransaction", [raw])
    if err is None and res:
        return True, ""
    msg = ""
    if err:
        msg = err.get("message") if isinstance(err, dict) else str(err)
    return False, (msg or "rejected")

def tma(raw):
    res, err = rpc("testmempoolaccept", [[raw]])
    if err:
        # whole-call error (Core sometimes errors the array) -> treat as reject
        msg = err.get("message") if isinstance(err, dict) else str(err)
        return False, (msg or "rejected")
    r = res[0]
    allowed = bool(r.get("allowed"))
    reason  = "" if allowed else (r.get("reject-reason") or "rejected")
    return allowed, reason

def emit(step, allowed, reason, *extra):
    # Fields are joined with '|' (a non-whitespace separator) so that bash's
    # `read`/IFS splitting preserves EMPTY fields (an accepted tx has an empty
    # reason — a whitespace IFS would collapse the gap and shift later fields).
    safe = reason.replace("|", "/").replace("\t", " ").replace("\n", " ")
    parts = ['true' if allowed else 'false', safe] + list(extra)
    print(f"STEP\t{step}\t" + "|".join(parts))

# ── Phase 1: HAPPY-PATH REPLACE. ──────────────────────────────────────────
# Clean mempool: anything left over from a partial prior phase would taint
# this. (Fresh node so it is empty, but be defensive.)
okA, rA = send(rawA)
emit("submit-A", okA, rA, in_mempool(idA))

okB, rB = send(rawB)
# After B, A must be gone and B present (replacement).
emit("submit-B", okB, rB, in_mempool(idA), in_mempool(idB))

# ── Phase 2: RULE 3 (insufficient absolute fee). ──────────────────────────
# Mempool currently holds B (replacement of A). We need a fresh original that
# signals RBF so we can attempt a lower-fee conflict against IT. Reset by
# replacing B back down? No — instead test rule 3 via testmempoolaccept of C
# against the CURRENT mempool occupant (B, fee 50_000). C's fee (500) is far
# below B's -> rule 3 reject. testmempoolaccept does NOT mutate the mempool,
# so this is a pure read against the live conflict. C conflicts with B over the
# SAME coinbase input. category must be insufficient-fee on both.
allowedC, rC = tma(rawC)
emit("tma-C", allowedC, rC)

# ── Phase 3: RULE 4 (insufficient bandwidth fee). ─────────────────────────
# D conflicts with B (same input) but has fee 1_001 — far below B's 50_000, so
# against B it would actually fail rule 3, not rule 4. To isolate rule 4 we need
# the mempool occupant to be the LOW-fee original A again. So: replace B with a
# fresh low-fee A2 (signals RBF, fee just above B so it is a valid replacement),
# then test D against A2. Simpler + deterministic: drop the whole mempool by
# mining the current occupant away is heavy; instead build the rule-4 scenario
# on a SECOND independent input.
#
# Use coinbase at height 2 as a second independent funding source so phases do
# not interfere. occupant E (fee f1) over input#2; D2 (fee f1 + 1) over the
# same input#2 -> rule 4 reject (delta 1 sat << incremental*vsize).
bh2  = rpc_ok("getblockhash", [2])
blk2 = rpc_ok("getblock", [bh2, 2])
cb2  = blk2["tx"][0]
val2 = int(round(cb2["vout"][0]["value"] * COIN))
prevout2 = COutPoint(int(cb2["txid"], 16), 0)

def build2(out_value, seq=SEQ_RBF, version=2):
    tx = CTransaction(); tx.version = version
    tx.vin  = [CTxIn(prevout2, b"", seq)]
    tx.vout = [CTxOut(out_value, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val2)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx.serialize_with_witness().hex(), (val2 - out_value)

rawE, feeE = build2(val2 - FEE_A)     # occupant E: fee 1_000, signals RBF
rawD2, feeD2 = build2(val2 - (FEE_A + 1))  # D2: fee 1_001, delta = 1 sat over E

idE = txid_of(rawE)
okE, rE = send(rawE)
emit("submit-E", okE, rE, in_mempool(idE))

# D2 over the SAME input as E, delta 1 sat -> rule 4 (bandwidth) reject.
allowedD2, rD2 = tma(rawD2)
emit("tma-D", allowedD2, rD2)
PYEOF
[[ -s "$HELPER" ]] || fail "failed to write RBF corpus helper"

# ── Launch helper for the Core regtest oracle. ────────────────────────────
# Spawns bitcoind and waits for RPC. If the daemon dies fast (the classic
# port-bind race on a back-to-back run where a prior Core hasn't fully released
# the RPC port), it RETRIES up to 5 times, waiting for the port to free between
# attempts. This makes the harness robust against rapid re-invocation without
# relying on a single fixed settle sleep.
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"; shift 4
    local attempt
    for attempt in 1 2 3 4 5; do
        # Wait for the RPC port to be free before spawning (up to ~15s).
        local wait_n=0
        while fuser "${rpc}/tcp" >/dev/null 2>&1 && (( wait_n < 15 )); do
            sleep 1; wait_n=$((wait_n+1))
        done
        # NOTE: no -mempoolfullrbf flag — it was removed in Core v28+ (full-rbf
        # is now the default) and is rejected as unknown on this build. The
        # corpus uses SIGNALING originals (nSequence 0xfffffffd) so replacement
        # is allowed by BIP125 opt-in regardless of the full-rbf setting.
        "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" -listen=0 \
            -fallbackfee=0.0002 "$@" >"$lf" 2>&1 &
        local bg=$!
        local deadline=$(( $(date +%s) + 120 ))
        while (( $(date +%s) < deadline )); do
            if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
                echo "$bg"; return 0
            fi
            if ! kill -0 "$bg" 2>/dev/null; then
                # Daemon exited (likely a port-bind race). Log + retry.
                echo "[launch_core] attempt $attempt: bitcoind exited early; retrying" >&2
                tail -n 5 "$lf" >&2 2>/dev/null || true
                break
            fi
            sleep 1
        done
        # If we fell out because the deadline passed (not an early exit), bail.
        kill -0 "$bg" 2>/dev/null && { return 1; }
        sleep 2
    done
    tail -n 20 "$lf" >&2 2>/dev/null || true
    return 1
}

# ── 3. Launch the Core oracle. ────────────────────────────────────────────
log "launching Core oracle rpc=:$CORE_RPC (regtest, -listen=0; signaling-RBF corpus)"
CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$CORE_LOG") \
    || fail "Core oracle failed to start within 120s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch rustoshi on regtest. ────────────────────────────────────────
log "launching rustoshi (regtest) rpc=:$RS_RPC p2p=:$RS_P2P -> $RS_LOG"
"$NODE_BIN" --network=regtest --datadir="$RS_DATADIR" \
    --port="$RS_P2P" --rpcbind="127.0.0.1:$RS_RPC" >"$RS_LOG" 2>&1 &
RS_PID=$!
log "rustoshi pid=$RS_PID"
rs_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < rs_deadline )); do
    if [[ -z "$RS_COOKIE" ]]; then
        for c in "$RS_DATADIR/.cookie" "$RS_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && RS_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$RS_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$RS_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$RS_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$RS_PID" 2>/dev/null || { tail -n 20 "$RS_LOG" >&2 2>/dev/null || true; fail "rustoshi exited during startup (see $RS_LOG)"; }
    sleep 1
done
[[ -n "$RS_COOKIE" ]] || fail "rustoshi cookie never appeared within 120s"
r=$(curl -s --max-time 5 -u "$RS_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$RS_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "rustoshi RPC never responded within 120s"
log "rustoshi RPC ready"

# ── 5. Run the RBF corpus against both nodes. ─────────────────────────────
log "running RBF corpus against Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for Core oracle"; }

log "running RBF corpus against rustoshi"
RS_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$RS_RPC/" "$RS_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$RS_LOG")
[[ -n "$RS_OUT" ]] || { tail -n 30 "$RS_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for rustoshi"; }

# ── 6. Parse STEP lines into associative arrays. ──────────────────────────
# STEP lines have variable column counts; capture fields 3.. as a packed string.
declare -A CORE_STEP RS_STEP
while IFS=$'\t' read -r tag step rest; do
    [[ "$tag" == "STEP" ]] || continue
    CORE_STEP["$step"]="$rest"
done <<< "$CORE_OUT"
while IFS=$'\t' read -r tag step rest; do
    [[ "$tag" == "STEP" ]] || continue
    RS_STEP["$step"]="$rest"
done <<< "$RS_OUT"

for s in submit-A submit-B tma-C submit-E tma-D; do
    [[ -n "${CORE_STEP[$s]:-}" ]] || { log "CORE_OUT was:"; echo "$CORE_OUT" >&2; fail "Core oracle missing STEP '$s'"; }
    [[ -n "${RS_STEP[$s]:-}"   ]] || { log "RS_OUT was:"; echo "$RS_OUT" >&2; fail "rustoshi missing STEP '$s'"; }
done

# Helpers to pull packed fields out of "allowed|reason|extra...". The '|'
# separator (non-whitespace) makes bash preserve empty fields, so an accepted
# tx (empty reason) does not shift the in-mempool flags left.
fld() { local packed="$1" n="$2"; IFS='|' read -ra a <<< "$packed"; echo "${a[$((n-1))]:-}"; }

log "=== RBF REPLACEMENT + FEE-RULE PARITY (Core oracle vs rustoshi) ==="

# ── 7a. HAPPY PATH (replace). ─────────────────────────────────────────────
# Core
c_subA="${CORE_STEP[submit-A]}"; c_subB="${CORE_STEP[submit-B]}"
c_A_ok=$(fld "$c_subA" 1);   c_A_inmp=$(fld "$c_subA" 3)
c_B_ok=$(fld "$c_subB" 1);   c_B_Ain=$(fld "$c_subB" 3);  c_B_Bin=$(fld "$c_subB" 4)
# rustoshi
r_subA="${RS_STEP[submit-A]}"; r_subB="${RS_STEP[submit-B]}"
r_A_ok=$(fld "$r_subA" 1);   r_A_inmp=$(fld "$r_subA" 3)
r_B_ok=$(fld "$r_subB" 1);   r_B_Ain=$(fld "$r_subB" 3);  r_B_Bin=$(fld "$r_subB" 4)

log "happy-path Core:    A(ok=$c_A_ok in=$c_A_inmp)  B(ok=$c_B_ok A-still-in=$c_B_Ain B-in=$c_B_Bin)"
log "happy-path rustoshi:A(ok=$r_A_ok in=$r_A_inmp)  B(ok=$r_B_ok A-still-in=$r_B_Ain B-in=$r_B_Bin)"

# Core MUST behave as expected (oracle sanity).
[[ "$c_A_ok" == "true" && "$c_A_inmp" == "true" ]] || fail "Core oracle did not accept A into mempool (oracle broken)"
[[ "$c_B_ok" == "true" && "$c_B_Ain" == "false" && "$c_B_Bin" == "true" ]] \
    || fail "Core oracle did not perform the RBF replacement (A still=$c_B_Ain B=$c_B_Bin); oracle broken"

REPLACE="ok"
if [[ "$r_A_ok" != "true" || "$r_A_inmp" != "true" ]]; then
    fail "rustoshi did not accept signaling original A into mempool (ok=$r_A_ok in=$r_A_inmp) | replace=fail"
fi
if [[ "$r_B_ok" != "true" ]]; then
    fail "rustoshi rejected the valid RBF replacement B (reason='$(fld "$r_subB" 2)') | replace=fail rule3=? rule4=?"
fi
if [[ "$r_B_Ain" != "false" || "$r_B_Bin" != "true" ]]; then
    fail "rustoshi accepted B but did not EVICT A (A-still-in=$r_B_Ain B-in=$r_B_Bin) | replace=fail"
fi

# ── 7b. RULE 3 (insufficient absolute fee) via testmempoolaccept. ─────────
c_C="${CORE_STEP[tma-C]}"; r_C="${RS_STEP[tma-C]}"
c_C_ok=$(fld "$c_C" 1); c_C_re=$(fld "$c_C" 2)
r_C_ok=$(fld "$r_C" 1); r_C_re=$(fld "$r_C" 2)
c_C_cat=$(classify "$c_C_re"); r_C_cat=$(classify "$r_C_re")
log "rule3 Core:     allowed=$c_C_ok reason='$c_C_re' -> $c_C_cat"
log "rule3 rustoshi: allowed=$r_C_ok reason='$r_C_re' -> $r_C_cat"

# Core MUST reject C with the insufficient-fee category (oracle sanity).
[[ "$c_C_ok" == "false" && "$c_C_cat" == "insufficient-fee" ]] \
    || fail "Core oracle did not reject rule-3 case C as insufficient-fee (allowed=$c_C_ok cat=$c_C_cat); oracle broken"

RULE3="ok"
if [[ "$r_C_ok" == "true" ]]; then
    fail "rustoshi ACCEPTED a lower-absolute-fee conflict (rule 3 hole) | replace=$REPLACE rule3=HOLE-accepts rule4=?"
elif [[ "$r_C_cat" != "insufficient-fee" ]]; then
    fail "rustoshi rejected rule-3 case C but in the wrong category (rustoshi='$r_C_cat' Core='insufficient-fee' reason='$r_C_re') | replace=$REPLACE rule3=mismatch rule4=?"
fi

# ── 7c. RULE 4 (insufficient bandwidth fee) via testmempoolaccept. ────────
# First confirm occupant E entered both mempools (otherwise tma-D tests nothing).
c_E="${CORE_STEP[submit-E]}"; r_E="${RS_STEP[submit-E]}"
c_E_ok=$(fld "$c_E" 1); c_E_in=$(fld "$c_E" 3)
r_E_ok=$(fld "$r_E" 1); r_E_in=$(fld "$r_E" 3)
[[ "$c_E_ok" == "true" && "$c_E_in" == "true" ]] || fail "Core oracle did not seat rule-4 occupant E (oracle broken)"
if [[ "$r_E_ok" != "true" || "$r_E_in" != "true" ]]; then
    fail "rustoshi did not seat rule-4 occupant E (ok=$r_E_ok in=$r_E_in reason='$(fld "$r_E" 2)') | replace=$REPLACE rule3=$RULE3 rule4=fail"
fi

c_D="${CORE_STEP[tma-D]}"; r_D="${RS_STEP[tma-D]}"
c_D_ok=$(fld "$c_D" 1); c_D_re=$(fld "$c_D" 2)
r_D_ok=$(fld "$r_D" 1); r_D_re=$(fld "$r_D" 2)
c_D_cat=$(classify "$c_D_re"); r_D_cat=$(classify "$r_D_re")
log "rule4 Core:     allowed=$c_D_ok reason='$c_D_re' -> $c_D_cat"
log "rule4 rustoshi: allowed=$r_D_ok reason='$r_D_re' -> $r_D_cat"

[[ "$c_D_ok" == "false" && "$c_D_cat" == "insufficient-fee" ]] \
    || fail "Core oracle did not reject rule-4 case D as insufficient-fee (allowed=$c_D_ok cat=$c_D_cat); oracle broken"

RULE4="ok"
if [[ "$r_D_ok" == "true" ]]; then
    fail "rustoshi ACCEPTED a too-small-delta replacement (rule 4 hole) | replace=$REPLACE rule3=$RULE3 rule4=HOLE-accepts"
elif [[ "$r_D_cat" != "insufficient-fee" ]]; then
    fail "rustoshi rejected rule-4 case D but in the wrong category (rustoshi='$r_D_cat' Core='insufficient-fee' reason='$r_D_re') | replace=$REPLACE rule3=$RULE3 rule4=mismatch"
fi

log "PASS: rustoshi matches Core on RBF replacement (evict+accept), rule 3 (insufficient absolute fee), and rule 4 (insufficient bandwidth fee)"
pass "$REPLACE" "$RULE3" "$RULE4"
