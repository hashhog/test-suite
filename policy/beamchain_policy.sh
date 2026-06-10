#!/usr/bin/env bash
#
# beamchain_policy.sh — self-contained MEMPOOL/POLICY reject-parity test.
#
# The consensus-adjacent successor to the wallet harnesses (recovery / spend /
# history / import). Where those proved the wallet round-trip, this proves the
# *mempool standardness gate*: a transaction that violates a relay-policy rule
# must be rejected with the SAME reject-reason CATEGORY Bitcoin Core emits, and
# a clean spend must be ACCEPTED.
#
# Why a new harness (the existing test-suite/mempool_tests.py is permissive):
#   The old suite spends OP_TRUE anyone-can-spend coinbases, so every submitted
#   tx fails at *input-existence* and NEVER reaches the standardness gate — it
#   can't tell "policy rejected" from "input missing", and never asserts the
#   reject STRING. This harness fixes that: it builds a REAL, SIGNED p2wpkh
#   spend of a mature coinbase (so the tx PASSES input-existence and REACHES
#   the policy gate), then derives one variant per standardness rule.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core v31.99) on SEPARATE
#   regtest instances (own scratch datadir + ports). For each corpus case the
#   SAME corpus is rebuilt + submitted to Core's testmempoolaccept and Core's
#   exact reject-reason is recorded. beamchain is compared against that oracle.
#
#   TWO Core oracles run side by side:
#     * STRICT  (-permitbaremultisig=0 -datacarriersize=80): the classic
#       relay-policy floor. Every corpus violation rejects deterministically
#       here. PRIMARY oracle for category comparison.
#     * DEFAULT (no policy flags): Bitcoin Core v31.99 relaxed two classic
#       rules — bare multisig is relayed by default (DEFAULT_PERMIT_BAREMULTISIG
#       =true) and the OP_RETURN cap rose from 80 B to MAX_STANDARD_TX_WEIGHT/4.
#       So bare-multisig + an 83-byte OP_RETURN only reject on STRICT Core;
#       DEFAULT Core ACCEPTS them.
#
# GENUINE-FLOOR FRAMING (the key design decision):
#   The box's Core is v31.99 which RELAXED bare-multisig + OP_RETURN to
#   default-accept. So this harness asserts the GENUINE must-reject floor =
#   {dust, bad-version, below-min-relay} (rejected by BOTH strict AND default
#   Core) + the valid-control MUST be ACCEPTED. bare-multisig and
#   oversize-op_return are "match default Core" -> ACCEPT is OK (we do NOT fail
#   on them; they are strict-flag-only gates). The default oracle lets the
#   verdict separate a GENUINE hole (Core rejects on BOTH strict AND default)
#   from a strict-flag-only divergence (impl tracks modern default Core).
#
# CORPUS (each is the valid signed spend with ONE rule violated):
#   - valid-control      : the clean 1-in/1-out p2wpkh spend          -> ACCEPT
#   - dust               : a 1-sat p2wpkh output on a fee-paying tx   -> "dust"
#   - bare-multisig      : a bare (non-P2SH) 1-of-1 multisig output   -> strict-only
#   - oversize-op_return : an 83-byte OP_RETURN payload (>80)         -> strict-only
#   - bad-version        : nVersion=4 (outside standard {1,2,3})      -> "version"
#   - below-min-relay    : a zero-fee tx (below the min-relay floor)  -> "min relay fee not met"
#
# NORMALIZATION: reject-reason strings are compared by CATEGORY. Core emits the
#   bare reject token ("dust", "version", "min relay fee not met"). beamchain
#   wraps its reject reason as an Erlang term via io_lib:format("~p", [Reason]),
#   so an atom reason like 'mempool min fee not met' arrives quote-decorated.
#   classify() below maps any impl/Core reject string to a canonical category;
#   a case PASSES when impl and Core map to the SAME category. EXACT vs
#   NORMALIZED is reported.
#
# POLICY HOLE = a case where beamchain ACCEPTS a tx Core REJECTS on BOTH strict
#   AND default (the genuine floor). That is the highest-value finding; the
#   harness FAILs loudly on it (never masked).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/spend/beamchain_spend.sh): no
#   required args, idempotent, trap cleanup, scratch datadir + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: POLICY beamchain: PASS dust=ok version=ok min-relay=ok control=accept bare-multisig=ok-default op_return=ok-default
#   FAIL: POLICY beamchain: FAIL <short reason> [dust=.. version=.. ...]
#
# Touches ONLY /tmp/policyfleet-beamchain{,-core-strict,-core-def}/ and ports
#   21846/21866 (beamchain RPC/P2P), 21848/21868 (strict Core RPC/P2P),
#   21850/21870 (default Core RPC/P2P). Core dirs are namespaced to this harness
#   so a parallel sibling policy run never shares a scratch datadir.
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

BC_DATADIR="/tmp/policyfleet-beamchain"
BC_RPC=21846
BC_P2P=21866
BC_LOG="$BC_DATADIR/node.log"

# Core-oracle scratch dirs are namespaced to THIS harness (…-beamchain-…) so a
# sibling policy run (camlcoin/hotbuns/…) that uses /tmp/policyfleet-core-* does
# NOT share a datadir: an unscoped path lets one run's `rm -rf` wipe another's
# live regtest datadir mid-flight, racing both bitcoinds to a no-output failure.
# Ports are already per-harness unique (21848/21850).
CORE_DATADIR="/tmp/policyfleet-beamchain-core-strict"
CORE_RPC=21848
CORE_P2P=21868
CORE_LOG="$CORE_DATADIR/core.log"

CORE_DEF_DATADIR="/tmp/policyfleet-beamchain-core-def"
CORE_DEF_RPC=21850
CORE_DEF_P2P=21870
CORE_DEF_LOG="$CORE_DEF_DATADIR/core.log"

# Strict-policy flags so EVERY corpus violation rejects on the strict oracle.
CORE_STRICT_FLAGS=(-permitbaremultisig=0 -datacarriersize=80)

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=101            # mine to maturity: height-1 coinbase (50 BTC) spendable at tip 101

BC_PID=""
BC_COOKIE=""
CORE_BG=""
CORE_DEF_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[policy:beamchain] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    "$CORE_CLI" -regtest -datadir="$CORE_DEF_DATADIR" -rpcport="$CORE_DEF_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || "$CORE_CLI" -regtest -datadir="$CORE_DEF_DATADIR" -rpcport="$CORE_DEF_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    [[ -n "$CORE_DEF_BG" ]] && kill "$CORE_DEF_BG" 2>/dev/null || true
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <dust> <ver> <minrelay> <control> <bare> <opret>
pass() {
    echo "POLICY beamchain: PASS dust=$1 version=$2 min-relay=$3 control=$4 bare-multisig=$5 op_return=$6"
    exit 0
}
fail() {
    echo "POLICY beamchain: FAIL $*"
    exit 1
}

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Maps any impl/Core reject string to a canonical category token. Empty input
# (accepted) -> "accept". Anything unmatched -> "other:<verbatim>".
# beamchain reasons arrive as Erlang terms ("~p"), e.g. 'mempool min fee not
# met' (quote-decorated atom) or the bare atom dust / version / datacarrier.
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *dust*)                                              echo "dust" ;;
        *bare-multisig*|*"bare multisig"*)                   echo "bare-multisig" ;;
        *datacarrier*|*op_return*|*op-return*|*"scriptpubkey"*nulldata*) echo "datacarrier" ;;
        *"min relay fee"*|*min-relay*|*"minimum relay fee"*|*"mempool min fee"*|*"min fee not met"*|*"fee not met"*|*"fee below minimum"*) echo "min-relay" ;;
        version*|*"tx version"*|*nversion*|*"version range"*|*"transaction version"*|*"'version'"*) echo "version" ;;
        *)                                                   echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "policyfleet-beamchain" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}|${CORE_DEF_RPC}|${CORE_DEF_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}|${CORE_DEF_RPC}|${CORE_DEF_P2P}) "; then
    fail "port ${BC_RPC}/${BC_P2P}/${CORE_RPC}/${CORE_P2P}/${CORE_DEF_RPC}/${CORE_DEF_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$BC_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "beamchain release binary not found at $NODE_BIN (run rebar3 as prod release)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || fail "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the corpus-builder Python helper. ────────────────────────────
# It connects to ONE node's RPC, mines a coinbase to the fixed key, reads that
# node's OWN height-1 coinbase (coinbase txids differ per impl), builds + SIGNS
# (in Python, via BIP143 SegwitV0SignatureHash — NO wallet dependency) every
# corpus variant against it, runs testmempoolaccept, and prints one
#   CASE <name> <allowed:true|false> <reject-reason>
# tab-separated line per case to stdout. Driven once per node (3 oracles).
HELPER="$BC_DATADIR/policy_corpus.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request
sys.path.insert(0, sys.argv[1])  # test_framework path
RPC_URL   = sys.argv[2]
COOKIE    = sys.argv[3]          # "user:pass" form
SECRET    = sys.argv[4]
NBLOCKS   = int(sys.argv[5])

from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import (CScript, OP_0, OP_RETURN, OP_CHECKMULTISIG, OP_1, hash160,
    SegwitV0SignatureHash, SIGHASH_ALL, OP_DUP, OP_HASH160, OP_EQUALVERIFY, OP_CHECKSIG)
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
    if d.get("error"):
        raise RuntimeError(f"{method} rpc error: {d['error']}")
    return d["result"]

# Deterministic keypair -> p2wpkh address + scriptPubKey.
priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])                 # p2wpkh output
addr = key_to_p2wpkh(pub, main=False)       # bcrt1...

# Mine to maturity (this node's own coinbase) and read the height-1 coinbase.
rpc("generatetoaddress", [NBLOCKS, addr])
if int(rpc("getblockcount")) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)
bh  = rpc("getblockhash", [1])
blk = rpc("getblock", [bh, 2])
cb  = blk["tx"][0]
cb_txid = cb["txid"]
val = int(round(cb["vout"][0]["value"] * COIN))      # 50 BTC in sats
prevout = COutPoint(int(cb_txid, 16), 0)

def signed(outs, version=2):
    """outs = [(value_sat, CScript), ...]; single input = the mature coinbase."""
    tx = CTransaction(); tx.version = version
    tx.vin  = [CTxIn(prevout, b"", 0xffffffff)]
    tx.vout = [CTxOut(v, s) for (v, s) in outs]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])  # BIP143 scriptCode
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx.serialize_with_witness().hex()

def tma(rawhex):
    r = rpc("testmempoolaccept", [[rawhex]])[0]
    allowed = bool(r.get("allowed"))
    reason  = "" if allowed else (r.get("reject-reason") or "rejected")
    return allowed, reason

FEE = 1000  # ~9 sat/vB on the ~110-vbyte control: well above the 1 sat/vB floor.
ms  = CScript([OP_1, pub, OP_1, OP_CHECKMULTISIG])  # bare 1-of-1 multisig

corpus = [
    ("valid-control",      signed([(val - FEE, spk)], 2)),
    ("dust",               signed([(1, spk), (val - 1 - FEE, spk)], 2)),
    ("bare-multisig",      signed([(100000, ms), (val - 100000 - FEE, spk)], 2)),
    ("oversize-op_return", signed([(0, CScript([OP_RETURN, b"\xab" * 83])), (val - FEE, spk)], 2)),
    ("bad-version",        signed([(val - FEE, spk)], 4)),
    ("below-min-relay",    signed([(val, spk)], 2)),   # zero fee
]
for name, rawhex in corpus:
    allowed, reason = tma(rawhex)
    safe = reason.replace("\t", " ").replace("\n", " ")
    print(f"CASE\t{name}\t{'true' if allowed else 'false'}\t{safe}")
PYEOF
[[ -s "$HELPER" ]] || fail "failed to write corpus helper"

# ── Readiness poll for a Core regtest oracle. ─────────────────────────────
# usage: wait_core_ready <datadir> <rpcport> <pid> <logfile>
# Polls bitcoin-cli getblockcount until ready (return 0) or the pid exits /
# the 120s deadline elapses (return 1, tailing the log to stderr first).
#
# NB: bitcoind is launched DIRECTLY in the main shell (not via $(launch_core))
# so its PID is captured straight from $! into a global. Earlier this used a
# command-substitution wrapper that echoed the pid; under load the subshell's
# background job + a concurrently-written (null-byte) logfile raced, so the
# poll occasionally saw a transiently-unreadable cookie/RPC and reported a
# false "failed to start" even though Core had reached "Done loading".
wait_core_ready() {
    local dd="$1" rpc="$2" pid="$3" lf="$4"
    # 120s: the maxbox routinely runs a live mainnet bitcoind (IBD) + the
    # mainnet beamchain + sibling policy runs spawning their own regtest
    # bitcoinds, so cold-start can be slow under NVMe/CPU contention.
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

# ── 3. Launch the STRICT Core oracle. ─────────────────────────────────────
# -bind=127.0.0.1:<p2p> keeps the P2P listener on loopback only so two regtest
# oracles started back-to-back never race on a 0.0.0.0 bind alongside sibling
# runs.
log "launching STRICT Core oracle rpc=:$CORE_RPC flags=${CORE_STRICT_FLAGS[*]}"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -bind="127.0.0.1:$CORE_P2P" -fallbackfee=0.0002 "${CORE_STRICT_FLAGS[@]}" >"$CORE_LOG" 2>&1 &
CORE_BG=$!
wait_core_ready "$CORE_DATADIR" "$CORE_RPC" "$CORE_BG" "$CORE_LOG" \
    || fail "STRICT Core oracle failed to start within 120s (see $CORE_LOG)"
log "STRICT Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "STRICT Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch the DEFAULT Core oracle (no policy flags). ──────────────────
log "launching DEFAULT Core oracle rpc=:$CORE_DEF_RPC (no policy flags)"
"$CORE_BIN" -regtest -datadir="$CORE_DEF_DATADIR" -rpcport="$CORE_DEF_RPC" -port="$CORE_DEF_P2P" \
    -bind="127.0.0.1:$CORE_DEF_P2P" -fallbackfee=0.0002 >"$CORE_DEF_LOG" 2>&1 &
CORE_DEF_BG=$!
wait_core_ready "$CORE_DEF_DATADIR" "$CORE_DEF_RPC" "$CORE_DEF_BG" "$CORE_DEF_LOG" \
    || fail "DEFAULT Core oracle failed to start within 120s (see $CORE_DEF_LOG)"
log "DEFAULT Core oracle ready (pid=$CORE_DEF_BG)"
CORE_DEF_COOKIE=$(cat "$CORE_DEF_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_DEF_COOKIE" ]] || fail "DEFAULT Core cookie not found at $CORE_DEF_DATADIR/regtest/.cookie"

# ── 5. Launch beamchain on regtest (release binary, foreground). ──────────
# Mirrors test-suite/spend/beamchain_spend.sh exactly: sys.config + vm.args,
# foreground under this process group so cleanup() can SIGTERM it.
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
-sname beamchain_policyref_$$
-setcookie beamchain_policyref
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
RELX_CONFIG_PATH="$BC_DATADIR/sys.config" VMARGS_PATH="$BC_DATADIR/vm.args" \
    "$NODE_BIN" foreground >"$BC_LOG" 2>&1 &
BC_PID=$!
log "beamchain pid=$BC_PID"
bc_deadline=$(( $(date +%s) + 60 ))
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
[[ -n "$BC_COOKIE" ]] || fail "beamchain cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$BC_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$BC_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "beamchain RPC never responded within 60s"
log "beamchain RPC ready"

# ── 6. Run the corpus against all three nodes. ────────────────────────────
log "running corpus against STRICT Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for STRICT Core oracle"; }

log "running corpus against DEFAULT Core oracle"
CORE_DEF_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_DEF_RPC/" "$CORE_DEF_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_DEF_LOG")
[[ -n "$CORE_DEF_OUT" ]] || { tail -n 30 "$CORE_DEF_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for DEFAULT Core oracle"; }

log "running corpus against beamchain"
BC_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$BC_RPC/" "$BC_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$BC_LOG")
[[ -n "$BC_OUT" ]] || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for beamchain"; }

# ── 7. Parse all result sets into name -> allowed / reason. ───────────────
declare -A CORE_ALLOWED CORE_REASON DEF_ALLOWED DEF_REASON BC_ALLOWED BC_REASON
while IFS=$'\t' read -r tag name allowed reason; do
    [[ "$tag" == "CASE" ]] || continue
    CORE_ALLOWED["$name"]="$allowed"; CORE_REASON["$name"]="$reason"
done <<< "$CORE_OUT"
while IFS=$'\t' read -r tag name allowed reason; do
    [[ "$tag" == "CASE" ]] || continue
    DEF_ALLOWED["$name"]="$allowed"; DEF_REASON["$name"]="$reason"
done <<< "$CORE_DEF_OUT"
while IFS=$'\t' read -r tag name allowed reason; do
    [[ "$tag" == "CASE" ]] || continue
    BC_ALLOWED["$name"]="$allowed"; BC_REASON["$name"]="$reason"
done <<< "$BC_OUT"

CASES=(valid-control dust bare-multisig oversize-op_return bad-version below-min-relay)
for c in "${CASES[@]}"; do
    [[ -n "${CORE_ALLOWED[$c]:-}" ]] || fail "STRICT Core oracle missing result for case '$c' (helper output incomplete)"
    [[ -n "${DEF_ALLOWED[$c]:-}"  ]] || fail "DEFAULT Core oracle missing result for case '$c'"
    [[ -n "${BC_ALLOWED[$c]:-}"   ]] || fail "beamchain missing result for case '$c' (helper output incomplete)"
done

# ── 8. Compare per case. Emit a forensic table + collect verdicts. ────────
# GENUINE FLOOR = {dust, bad-version, below-min-relay}: rejected by BOTH strict
# AND default Core. The genuine must-reject set. beamchain MUST reject these.
# bare-multisig + oversize-op_return are strict-flag-only (DEFAULT Core accepts)
# -> beamchain ACCEPT is parity-with-default-Core, NOT a hole.
#
# Per-case status token:
#   ok        impl matches STRICT Core (accept==accept, or both reject same category)
#   ok-default impl ACCEPTS, STRICT Core rejects but DEFAULT Core ALSO ACCEPTS
#             -> parity with modern default Core (strict-flag-only gate). PASS-able.
#   HOLE      DEFAULT Core REJECTS (genuine floor) but impl ACCEPTS -> real hole.
#   over      STRICT Core accepts but impl rejects (impl too strict)
#   mism      both reject but different category
log "=== POLICY REJECT-PARITY  (genuine floor = dust|version|min-relay; strict oracle = -permitbaremultisig=0 -datacarriersize=80) ==="
printf '%-20s | %-7s %-26s | %-7s | %-7s %-44s | %s\n' \
    "case" "Core" "Core-reason" "CoreDef" "beam" "beamchain-reason" "verdict" >&2

declare -A STATUS
HOLES=()
NORMALIZED_ANY=0
for c in "${CASES[@]}"; do
    ca="${CORE_ALLOWED[$c]}"; cr="${CORE_REASON[$c]}"
    da="${DEF_ALLOWED[$c]}"
    ia="${BC_ALLOWED[$c]}";   ir="${BC_REASON[$c]}"
    ccat=$(classify "$cr"); icat=$(classify "$ir")
    local_status=""
    if [[ "$ca" == "true" && "$ia" == "true" ]]; then
        local_status="ok"            # both accept (the valid control)
    elif [[ "$ca" == "false" && "$ia" == "false" ]]; then
        if [[ "$ccat" == "$icat" ]]; then
            local_status="ok"
            [[ "$cr" != "$ir" ]] && NORMALIZED_ANY=1
        else
            local_status="mism"
        fi
    elif [[ "$ca" == "false" && "$ia" == "true" ]]; then
        # impl accepts what STRICT Core rejects. Classify via default oracle.
        if [[ "$da" == "false" ]]; then
            local_status="HOLE"        # default Core ALSO rejects -> genuine hole
            HOLES+=("$c")
        else
            local_status="ok-default"  # only strict rejects -> parity with default Core
        fi
    else
        local_status="over"          # Core accepts, impl rejects
    fi
    STATUS["$c"]="$local_status"
    printf '%-20s | %-7s %-26s | %-7s | %-7s %-44s | %s\n' \
        "$c" "$ca" "${cr:- (accepted)}" "$da" "$ia" "${ir:- (accepted)}" "$local_status" >&2
done

# ── 9. Map case -> summary token. ─────────────────────────────────────────
tok() {  # tok <case>
    local s="${STATUS[$1]}"
    case "$s" in
        ok)         echo "ok" ;;
        ok-default) echo "ok-default" ;;
        HOLE)       echo "HOLE-accepts" ;;
        over)       echo "over-rejects" ;;
        mism)       echo "mismatch" ;;
        *)          echo "$s" ;;
    esac
}
DUST_T=$(tok dust)
VER_T=$(tok bad-version)
RELAY_T=$(tok below-min-relay)
BARE_T=$(tok bare-multisig)
OPRET_T=$(tok oversize-op_return)
CTRL_S="${STATUS[valid-control]}"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
# The valid-control MUST be accepted by beamchain (the funded input reaches the
# gate and the clean spend is relayable) — otherwise the harness itself / the
# enforced min-relay floor is broken (e.g. minrelay 10000x too high) and nothing
# else is trustworthy.
if [[ "$CTRL_S" != "ok" ]]; then
    fail "valid-control not accepted by beamchain (control=${BC_REASON[valid-control]:-rejected}); enforced floor or harness funding/signing broken — investigate before trusting other cases | dust=$DUST_T version=$VER_T min-relay=$RELAY_T"
fi

# GENUINE FLOOR holes (DEFAULT Core rejects, beamchain accepts) are real policy
# gaps. Per the brief we FAIL loudly + report (never mask to force green).
if [[ "${#HOLES[@]}" -gt 0 ]]; then
    log "GENUINE POLICY HOLES (DEFAULT Core rejects, beamchain ACCEPTS):"
    for c in "${HOLES[@]}"; do
        log "  HOLE $c: STRICT-Core='${CORE_REASON[$c]}' DEFAULT-Core='${DEF_REASON[$c]}' beamchain=ACCEPTS"
    done
    fail "beamchain accepts $(IFS=,; echo "${HOLES[*]}") that even DEFAULT Core rejects | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any category mismatch on the genuine floor (both reject, different category).
MISM=()
for c in dust bad-version below-min-relay; do [[ "${STATUS[$c]}" == "mism" ]] && MISM+=("$c"); done
if [[ "${#MISM[@]}" -gt 0 ]]; then
    fail "reject-category mismatch on $(IFS=,; echo "${MISM[*]}") | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept"
fi

# Any over-rejection on the genuine floor cases (impl too strict where the
# valid spend should pass) — already covered by control; report bare/opret over
# only as informational (they are not part of the genuine floor).
OVER=()
for c in dust bad-version below-min-relay; do [[ "${STATUS[$c]}" == "over" ]] && OVER+=("$c"); done
if [[ "${#OVER[@]}" -gt 0 ]]; then
    fail "beamchain over-rejects genuine-floor case(s) $(IFS=,; echo "${OVER[*]}") | dust=$DUST_T version=$VER_T min-relay=$RELAY_T"
fi

# Genuine floor is GREEN: dust + version + min-relay all reject (category-match),
# control accepted. bare-multisig + op_return are reported as-is (ok or ok-default).
[[ "$NORMALIZED_ANY" -eq 1 ]] && log "note: some cases matched via NORMALIZATION (category-level), not byte-exact strings"
log "PASS: genuine floor GREEN (dust+version+min-relay reject Core-categorically; control accepted); bare-multisig=$BARE_T op_return=$OPRET_T track default Core"
pass "$DUST_T" "$VER_T" "$RELAY_T" accept "$BARE_T" "$OPRET_T"
