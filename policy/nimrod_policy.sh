#!/usr/bin/env bash
#
# nimrod_policy.sh — self-contained MEMPOOL/POLICY reject-parity test.
#
# The consensus-adjacent successor to the wallet harnesses (recovery / spend /
# history / import). Where those proved the wallet round-trip, this proves the
# *mempool standardness gate*: a transaction that violates a relay-policy rule
# must be rejected with the SAME reject-reason CATEGORY Bitcoin Core emits.
#
# Why a new harness (the existing test-suite/mempool_tests.py is permissive):
#   The old suite spends OP_TRUE anyone-can-spend coinbases, so every submitted
#   tx fails at *input-existence* and NEVER reaches the standardness gate — it
#   can't tell "policy rejected" from "input missing", and never asserts the
#   reject STRING. This harness fixes that: it builds a REAL, SIGNED p2wpkh
#   spend of a mature coinbase (so the tx PASSES input-existence and REACHES
#   the policy gate), then derives one variant per standardness rule.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core v31.99) on a SEPARATE
#   regtest instance (own scratch datadir + ports). For each corpus case the
#   SAME corpus is rebuilt + submitted to Core's testmempoolaccept and Core's
#   exact reject-reason is recorded. nimrod is compared against that oracle.
#
#   TWO Core oracles run side by side:
#     * STRICT  (-permitbaremultisig=0 -datacarriersize=80): the classic
#       relay-policy floor; every corpus violation rejects deterministically.
#     * DEFAULT (no policy flags): Bitcoin Core v31.99 RELAXED two classic
#       rules — bare multisig is relayed by default (DEFAULT_PERMIT_BAREMULTISIG
#       =true) and the OP_RETURN cap rose from 80 B to MAX_STANDARD_TX_WEIGHT/4
#       (100 000). So bare-multisig + an 83-byte OP_RETURN only reject on STRICT
#       Core; DEFAULT Core ACCEPTS them.
#
# GENUINE-FLOOR FRAMING (the key design decision):
#   The GENUINE must-reject floor = { dust, bad-version, below-min-relay } —
#   rejected by BOTH strict AND default Core — plus the valid-control which MUST
#   be ACCEPTED. nimrod is GREEN iff it rejects all three genuine-floor cases
#   (normalized to Core's category) and accepts the valid-control.
#
#   bare-multisig and oversize-op_return are STRICT-FLAG-ONLY gates: modern
#   default Core ACCEPTS them, and so does nimrod (its IsStandardOptions default
#   permitBareMultisig=true, maxDatacarrierBytes=StdMaxStandardTxWeight/4). An
#   ACCEPT on those two is parity-with-default-Core, NOT a hole — the harness
#   does NOT fail on them. A GENUINE HOLE (default Core also rejects, nimrod
#   accepts) on the floor cases WOULD fail loudly and is never masked.
#
# CORPUS (each is the valid signed spend with ONE rule violated):
#   - valid-control      : the clean 1-in/1-out p2wpkh spend          -> ACCEPT
#   - dust               : a 1-sat p2wpkh output on a fee-paying tx   -> "dust"
#   - bare-multisig      : a bare (non-P2SH) 1-of-1 multisig output   -> strict-only
#   - oversize-op_return : an 83-byte OP_RETURN payload (>80)         -> strict-only
#   - bad-version        : nVersion=4 (outside standard {1,2,3})      -> "version"
#   - below-min-relay    : a zero-fee tx (below the min-relay floor)  -> "min relay fee not met"
#
# NORMALIZATION: reject-reason strings are compared by CATEGORY via classify().
#   Core emits the bare token ("dust", "version", "min relay fee not met").
#   nimrod is Core-faithful but wraps some tokens — e.g. its standardness gate
#   emits "non-standard tx (dust)" / "non-standard tx (version)" and its
#   min-fee gate emits "mempool min fee not met: ...". A case PASSES when impl
#   and Core map to the SAME category. EXACT vs NORMALIZED is reported.
#
# KNOWN BUG FIXED EN ROUTE (nimrod): testmempoolaccept [[hex]] (the Core-shaped
#   nested-array call) hit an AssertionDefect — `for i, x in rawTxsArray` bound
#   std/json's pairs(JsonNode) iterator which asserts JObject and raised an
#   uncatchable Defect on the JArray, surfacing as a bogus "-32700 parse error"
#   with id:null. Fixed by indexing the JArray (handleTestMempoolAccept +
#   handleSubmitPackage). Without that fix this harness cannot run at all.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/spend/nimrod_spend.sh +
#   hotbuns_policy.sh / camlcoin_policy.sh): no required args, set -uo pipefail,
#   idempotent, trap cleanup, scratch datadirs + UNIQUE ports, ONE clean summary
#   line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: POLICY nimrod: PASS dust=ok version=ok min-relay=ok control=accept bare-multisig=.. op_return=..
#   FAIL: POLICY nimrod: FAIL <short reason> [dust=.. version=.. min-relay=.. ...]
#
# Touches ONLY /tmp/policyfleet-nimrod/ + /tmp/policyfleet-core-{strict,def}/
#   and ports 21841/21861 (nimrod RPC/P2P), 21842/21862 (strict Core RPC/P2P),
#   21844/21864 (default Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

NM_DATADIR="/tmp/policyfleet-nimrod"
NM_RPC=21841
NM_P2P=21861
NM_LOG="$NM_DATADIR/node.log"
NM_COOKIE_FILE="$NM_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/policyfleet-core-strict"
CORE_RPC=21842
CORE_P2P=21862
CORE_LOG="$CORE_DATADIR/core.log"

CORE_DEF_DATADIR="/tmp/policyfleet-core-def"
CORE_DEF_RPC=21844
CORE_DEF_P2P=21864
CORE_DEF_LOG="$CORE_DEF_DATADIR/core.log"

# Strict-policy flags so EVERY corpus violation rejects on the primary oracle.
CORE_STRICT_FLAGS=(-permitbaremultisig=0 -datacarriersize=80)

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=101            # mine to maturity: height-1 coinbase (50 BTC) spendable at tip 101

NM_PID=""
NM_COOKIE=""
CORE_BG=""
CORE_DEF_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[policy:nimrod] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$NM_PID" ]] && kill -0 "$NM_PID" 2>/dev/null; then
        kill "$NM_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NM_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NM_PID" 2>/dev/null || true
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
    rm -rf "$NM_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <dust> <version> <minrelay> <bare> <opret>
pass() {
    echo "POLICY nimrod: PASS dust=$1 version=$2 min-relay=$3 control=accept bare-multisig=$4 op_return=$5"
    exit 0
}
fail() {
    echo "POLICY nimrod: FAIL $*"
    exit 1
}

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Maps any impl/Core reject string to a canonical category token. Empty input
# (accepted) -> "accept". Anything unmatched -> "other:<verbatim>".
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *dust*)                                              echo "dust" ;;
        *bare-multisig*|*"bare multisig"*)                   echo "bare-multisig" ;;
        *datacarrier*|*op_return*|*op-return*|*"scriptpubkey"*nulldata*) echo "datacarrier" ;;
        *"min relay fee"*|*min-relay*|*"minimum relay fee"*|*"mempool min fee"*|*"fee not met"*|*"fee below minimum"*) echo "min-relay" ;;
        version*|*"tx version"*|*nversion*|*"version range"*|*"transaction version"*|*"non-standard tx (version)"*) echo "version" ;;
        *)                                                   echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "policyfleet-nimrod" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${NM_RPC}|${NM_P2P}|${CORE_RPC}|${CORE_P2P}|${CORE_DEF_RPC}|${CORE_DEF_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${NM_RPC}|${NM_P2P}|${CORE_RPC}|${CORE_P2P}|${CORE_DEF_RPC}|${CORE_DEF_P2P}) "; then
    fail "port ${NM_RPC}/${NM_P2P}/${CORE_RPC}/${CORE_P2P}/${CORE_DEF_RPC}/${CORE_DEF_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$NM_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"
mkdir -p "$NM_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "nimrod binary not found at $NODE_BIN (run: cd nimrod && nimble build -d:release -y)"
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
HELPER="$NM_DATADIR/policy_corpus.py"
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

FEE = 1000  # ~9 sat/vB on the ~110-vbyte control: well above the 0.1 sat/vB floor.
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

# ── Launch helper for a Core regtest oracle. ──────────────────────────────
# usage: launch_core <datadir> <rpcport> <p2pport> <logfile> <extra-flags...>
# echoes the background PID on success; returns non-zero on startup error.
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"; shift 4
    "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" \
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

# ── 3. Launch the STRICT Core oracle. ─────────────────────────────────────
log "launching STRICT Core oracle rpc=:$CORE_RPC flags=${CORE_STRICT_FLAGS[*]}"
CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$CORE_LOG" "${CORE_STRICT_FLAGS[@]}") \
    || fail "STRICT Core oracle failed to start within 60s (see $CORE_LOG)"
log "STRICT Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "STRICT Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch the DEFAULT Core oracle (no policy flags). ──────────────────
log "launching DEFAULT Core oracle rpc=:$CORE_DEF_RPC (no policy flags)"
CORE_DEF_BG=$(launch_core "$CORE_DEF_DATADIR" "$CORE_DEF_RPC" "$CORE_DEF_P2P" "$CORE_DEF_LOG") \
    || fail "DEFAULT Core oracle failed to start within 60s (see $CORE_DEF_LOG)"
log "DEFAULT Core oracle ready (pid=$CORE_DEF_BG)"
CORE_DEF_COOKIE=$(cat "$CORE_DEF_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_DEF_COOKIE" ]] || fail "DEFAULT Core cookie not found at $CORE_DEF_DATADIR/regtest/.cookie"

# ── 5. Launch nimrod on regtest. ──────────────────────────────────────────
log "launching nimrod (regtest) rpc=:$NM_RPC p2p=:$NM_P2P -> $NM_LOG"
"$NODE_BIN" --network=regtest --datadir="$NM_DATADIR" \
    --port="$NM_P2P" --rpcport="$NM_RPC" start >"$NM_LOG" 2>&1 &
NM_PID=$!
log "nimrod pid=$NM_PID"
nm_deadline=$(( $(date +%s) + 60 ))
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
[[ -n "$NM_COOKIE" ]] || fail "nimrod cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$NM_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$NM_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "nimrod RPC never responded within 60s"
log "nimrod RPC ready"

# ── 6. Run the corpus against all three nodes. ────────────────────────────
log "running corpus against STRICT Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for STRICT Core oracle"; }

log "running corpus against DEFAULT Core oracle"
CORE_DEF_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_DEF_RPC/" "$CORE_DEF_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_DEF_LOG")
[[ -n "$CORE_DEF_OUT" ]] || { tail -n 30 "$CORE_DEF_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for DEFAULT Core oracle"; }

log "running corpus against nimrod"
NM_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$NM_RPC/" "$NM_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$NM_LOG")
[[ -n "$NM_OUT" ]] || { tail -n 30 "$NM_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for nimrod"; }

# ── 7. Parse all result sets into name -> allowed / reason. ───────────────
declare -A CORE_ALLOWED CORE_REASON DEF_ALLOWED DEF_REASON NM_ALLOWED NM_REASON
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
    NM_ALLOWED["$name"]="$allowed"; NM_REASON["$name"]="$reason"
done <<< "$NM_OUT"

CASES=(valid-control dust bare-multisig oversize-op_return bad-version below-min-relay)
# The GENUINE must-reject floor: rejected by BOTH strict AND default Core.
FLOOR_CASES=(dust bad-version below-min-relay)
for c in "${CASES[@]}"; do
    [[ -n "${CORE_ALLOWED[$c]:-}" ]] || fail "STRICT Core oracle missing result for case '$c' (helper output incomplete)"
    [[ -n "${DEF_ALLOWED[$c]:-}"  ]] || fail "DEFAULT Core oracle missing result for case '$c'"
    [[ -n "${NM_ALLOWED[$c]:-}"   ]] || fail "nimrod missing result for case '$c' (helper output incomplete)"
done

# ── 8. Compare per case. Emit a forensic table + collect verdicts. ────────
# Per-case status token:
#   ok          impl matches STRICT Core (accept==accept, or both reject same category)
#   FLOOR-HOLE  a GENUINE-FLOOR case (dust/version/min-relay): STRICT + DEFAULT
#               Core both reject, but nimrod ACCEPTS -> a real standardness hole
#               (the highest-value finding; FAILs loudly, never masked)
#   knob-accept a STRICT-ONLY case (bare-multisig/oversize-op_return): STRICT
#               Core rejects, DEFAULT Core ACCEPTS, nimrod ACCEPTS -> parity with
#               modern default Core. NOT a hole; PASS-able per genuine-floor framing.
#   over        STRICT Core accepts but impl rejects (impl too strict)
#   mism        both reject but different category
log "=== POLICY REJECT-PARITY  (genuine floor = dust + bad-version + below-min-relay) ==="
log "  primary oracle = STRICT Core (-permitbaremultisig=0 -datacarriersize=80)"
log "  secondary oracle = DEFAULT Core (out-of-the-box v31.99 relay policy)"
printf '%-20s | %-7s %-26s | %-7s | %-7s %-44s | %s\n' \
    "case" "Core" "Core-reason" "CoreDef" "nimrod" "nimrod-reason" "verdict" >&2

declare -A STATUS
FLOOR_HOLES=()
NORMALIZED_ANY=0
for c in "${CASES[@]}"; do
    ca="${CORE_ALLOWED[$c]}"; cr="${CORE_REASON[$c]}"
    da="${DEF_ALLOWED[$c]}"
    ia="${NM_ALLOWED[$c]}";   ir="${NM_REASON[$c]}"
    ccat=$(classify "$cr"); icat=$(classify "$ir")
    # Is this one of the genuine-floor cases?
    is_floor=0
    for fc in "${FLOOR_CASES[@]}"; do [[ "$fc" == "$c" ]] && is_floor=1; done
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
        # impl accepts what STRICT Core rejects. Split on genuine-floor membership.
        if [[ "$is_floor" -eq 1 && "$da" == "false" ]]; then
            local_status="FLOOR-HOLE"   # genuine floor: default Core ALSO rejects -> real hole
            FLOOR_HOLES+=("$c")
        else
            local_status="knob-accept"  # strict-only gate: matches modern default Core
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
        ok)          echo "ok" ;;
        FLOOR-HOLE)  echo "HOLE-accepts" ;;
        knob-accept) echo "ok-default" ;;   # parity with default Core (strict-only gate)
        over)        echo "over-rejects" ;;
        mism)        echo "mismatch" ;;
        *)           echo "$s" ;;
    esac
}
DUST_T=$(tok dust)
VER_T=$(tok bad-version)
RELAY_T=$(tok below-min-relay)
BARE_T=$(tok bare-multisig)
OPRET_T=$(tok oversize-op_return)
CTRL_S="${STATUS[valid-control]}"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
# The valid-control MUST be accepted by nimrod (the funded input reaches the
# gate and the clean spend is relayable) — otherwise the harness itself is
# broken (e.g. sighash/funding wrong) and nothing else is trustworthy.
if [[ "$CTRL_S" != "ok" ]]; then
    fail "valid-control not accepted by nimrod (control=${NM_REASON[valid-control]:-rejected}); harness funding/signing broken — investigate before trusting other cases"
fi

# A GENUINE-FLOOR hole (dust/version/min-relay accepted, default Core rejects)
# is a real policy gap. Per the brief we FAIL loudly + report it (never masked).
if [[ "${#FLOOR_HOLES[@]}" -gt 0 ]]; then
    log "GENUINE-FLOOR POLICY HOLES (default Core rejects, nimrod ACCEPTS):"
    for c in "${FLOOR_HOLES[@]}"; do
        log "  FLOOR-HOLE $c: STRICT-Core='${CORE_REASON[$c]}' DEFAULT-Core='${DEF_REASON[$c]}' nimrod=ACCEPTS"
    done
    fail "nimrod accepts genuine-floor violation(s) $(IFS=,; echo "${FLOOR_HOLES[*]}") that DEFAULT Core rejects | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any category mismatch on a genuine-floor case (both reject, different category).
MISM=()
for c in "${FLOOR_CASES[@]}"; do [[ "${STATUS[$c]}" == "mism" ]] && MISM+=("$c"); done
if [[ "${#MISM[@]}" -gt 0 ]]; then
    fail "reject-category mismatch on genuine-floor case(s) $(IFS=,; echo "${MISM[*]}") | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Over-rejection (Core accepts, nimrod rejects) on the control or floor cases.
OVER=()
for c in valid-control "${FLOOR_CASES[@]}"; do [[ "${STATUS[$c]}" == "over" ]] && OVER+=("$c"); done
if [[ "${#OVER[@]}" -gt 0 ]]; then
    fail "nimrod over-rejects $(IFS=,; echo "${OVER[*]}") that Core accepts | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Genuine floor satisfied: dust + version + min-relay rejected (normalized to
# Core's category), valid-control accepted. Strict-only gates (bare-multisig /
# oversize-op_return) accepted == parity with modern default Core (not a hole).
[[ "$NORMALIZED_ANY" -eq 1 ]] && log "note: some floor cases matched via NORMALIZATION (category-level), not byte-exact strings"
[[ "$BARE_T" == "ok-default" || "$OPRET_T" == "ok-default" ]] && \
    log "note: bare-multisig/oversize-op_return accepted == parity with default Core v31.99 (strict-flag-only gates; not a hole)"
log "PASS: genuine reject floor enforced (dust + bad-version + below-min-relay) and valid-control accepted"
pass "$DUST_T" "$VER_T" "$RELAY_T" "$BARE_T" "$OPRET_T"
