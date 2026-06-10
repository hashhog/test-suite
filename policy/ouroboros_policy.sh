#!/usr/bin/env bash
#
# ouroboros_policy.sh — self-contained MEMPOOL/POLICY reject-parity test.
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
#   the policy gate), then derives one variant per standardness rule, and runs
#   testmempoolaccept against ouroboros + a Bitcoin Core oracle.
#
# GENUINE-FLOOR FRAMING (the load-bearing design decision):
#   The box's Bitcoin Core is v31.99, which RELAXED two classic standardness
#   rules to default-ACCEPT: bare multisig (DEFAULT_PERMIT_BAREMULTISIG=true)
#   and OP_RETURN size (cap rose from 80 B to MAX_STANDARD_TX_WEIGHT/4). So a
#   DEFAULT-flag Core ACCEPTS bare-multisig + an 83-byte OP_RETURN. Only three
#   violations are rejected by BOTH a strict-flag AND a default-flag Core —
#   the GENUINE must-reject floor:
#       dust            -> "dust"
#       bad-version     -> "version"             (nVersion outside [1,3])
#       below-min-relay -> "min relay fee not met"
#   plus the valid-control, which MUST be ACCEPTED.
#
#   GREEN therefore means: ouroboros REJECTS {dust, bad-version, below-min-relay}
#   in the correct reject CATEGORY *and* ACCEPTS the valid-control. The two
#   strict-flag-only cases (bare-multisig, oversize-op_return) are "match
#   default Core" — ACCEPT is OK and is NOT a failure; the harness reports them
#   as ok-default. A GENUINE policy HOLE = ouroboros accepts one of the three
#   floor violations that EVEN A DEFAULT Core rejects -> FAIL loudly (never
#   masked).
#
# CORE ORACLE (two side-by-side regtest Cores own the ground truth):
#   * STRICT  (-permitbaremultisig=0 -datacarriersize=80): rejects ALL five
#     violations; the classic relay-policy floor. PRIMARY oracle.
#   * DEFAULT (no policy flags): out-of-the-box v31.99 relay policy; ACCEPTS
#     bare-multisig + oversize-op_return, REJECTS the three floor cases. Used to
#     classify any ouroboros accept-of-a-strict-reject as either a GENUINE hole
#     (default Core ALSO rejects) or a strict-flag-only knob gap (default Core
#     accepts -> ok-default, parity with modern Core).
#
# NORMALIZATION: reject-reason strings are compared by CATEGORY. Core emits the
#   bare token ("dust", "version", "min relay fee not met"); ouroboros is
#   Core-faithful but more verbose (e.g. "Non-standard version: 4",
#   "dust: tx with dust output ... must be 0-fee", "Below minimum relay fee:
#   ...). A case PASSES when impl and Core map to the SAME category via
#   classify() below. EXACT vs NORMALIZED is reported.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/spend/ouroboros_spend.sh + the
#   hotbuns_policy.sh / camlcoin_policy.sh references): no required args,
#   idempotent, trap cleanup, scratch datadirs + UNIQUE ports, ONE clean summary
#   line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: POLICY ouroboros: PASS dust=ok version=ok min-relay=ok control=accept bare-multisig=ok-default op_return=ok-default
#   FAIL: POLICY ouroboros: FAIL <short reason> [dust=.. version=.. ...]
#
# Touches ONLY /tmp/policyfleet-ouroboros/ + /tmp/policyfleet-core-{strict,def}/
#   and ports 21842/21862 (ouroboros RPC/P2P), 21843/21863 (strict Core),
#   21844/21864 (default Core).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

# Resolve the ouroboros checkout relative to this script:
# test-suite/policy/ -> repo root -> ouroboros/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

OU_DATADIR="/tmp/policyfleet-ouroboros"
OU_RPC=21842
OU_P2P=21862
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/policyfleet-core-strict"
CORE_RPC=21843
CORE_P2P=21865    # Core auto-binds P2P+1 (onion listener); keep all P2P ports
CORE_LOG="$CORE_DATADIR/core.log"   # >= 2 apart and clear of ouroboros 21862.

CORE_DEF_DATADIR="/tmp/policyfleet-core-def"
CORE_DEF_RPC=21844
CORE_DEF_P2P=21867    # P2P+1 = 21868; no collision with strict's 21865/21866.
CORE_DEF_LOG="$CORE_DEF_DATADIR/core.log"

# Strict-policy flags so EVERY corpus violation rejects on the primary oracle.
CORE_STRICT_FLAGS=(-permitbaremultisig=0 -datacarriersize=80)

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=101            # mine to maturity: height-1 coinbase (50 BTC) spendable at tip 101

OU_PID=""
OU_COOKIE=""
CORE_BG=""
CORE_DEF_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[policy:ouroboros] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
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
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <dust> <version> <minrelay> <bare> <opret>
pass() {
    echo "POLICY ouroboros: PASS dust=$1 version=$2 min-relay=$3 control=accept bare-multisig=$4 op_return=$5"
    exit 0
}
fail() {
    echo "POLICY ouroboros: FAIL $*"
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
        version*|*"tx version"*|*nversion*|*"version range"*|*"transaction version"*|*"standard version"*) echo "version" ;;
        *)                                                   echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "policyfleet-ouroboros" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))|${CORE_DEF_RPC}|${CORE_DEF_P2P}|$((CORE_DEF_P2P + 1))) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))|${CORE_DEF_RPC}|${CORE_DEF_P2P}|$((CORE_DEF_P2P + 1))) "; then
    fail "port ${OU_RPC}/${OU_P2P}/${CORE_RPC}/${CORE_P2P}/$((CORE_P2P + 1))/${CORE_DEF_RPC}/${CORE_DEF_P2P}/$((CORE_DEF_P2P + 1)) already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$OU_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"
mkdir -p "$OU_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1        || fail "python3 not found on PATH"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros checkout not found at $OURO_DIR"
[[ -x "$CORE_BIN" ]]                      || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                      || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]        || fail "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || fail "Core test_framework Python imports failed (need key/script/messages/address)"

OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"

# ── 2. Write the corpus-builder Python helper. ────────────────────────────
# It connects to ONE node's RPC, mines a coinbase to the fixed key, reads that
# node's OWN height-1 coinbase (coinbase txids differ per impl), builds + SIGNS
# (in Python, via BIP143 SegwitV0SignatureHash — NO wallet dependency) every
# corpus variant against it, runs testmempoolaccept, and prints one
#   CASE <name> <allowed:true|false> <reject-reason>
# tab-separated line per case to stdout. Driven once per node (3 oracles).
HELPER="$OU_DATADIR/policy_corpus.py"
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
# echoes the background PID on success; non-zero on startup error.
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

# ── 5. Launch ouroboros on regtest. ───────────────────────────────────────
# ouroboros is Python — the slowest-starting node in the fleet — so allow a
# generous (>=120s) RPC-startup wait.
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

# ── 6. Run the corpus against all three nodes. ────────────────────────────
log "running corpus against STRICT Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for STRICT Core oracle"; }

log "running corpus against DEFAULT Core oracle"
CORE_DEF_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_DEF_RPC/" "$CORE_DEF_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_DEF_LOG")
[[ -n "$CORE_DEF_OUT" ]] || { tail -n 30 "$CORE_DEF_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for DEFAULT Core oracle"; }

log "running corpus against ouroboros"
OU_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$OU_RPC/" "$OU_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$OU_LOG")
[[ -n "$OU_OUT" ]] || { tail -n 30 "$OU_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for ouroboros"; }

# ── 7. Parse all result sets into name -> allowed / reason. ───────────────
declare -A CORE_ALLOWED CORE_REASON DEF_ALLOWED DEF_REASON OU_ALLOWED OU_REASON
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
    OU_ALLOWED["$name"]="$allowed"; OU_REASON["$name"]="$reason"
done <<< "$OU_OUT"

CASES=(valid-control dust bare-multisig oversize-op_return bad-version below-min-relay)
for c in "${CASES[@]}"; do
    [[ -n "${CORE_ALLOWED[$c]:-}" ]] || fail "STRICT Core oracle missing result for case '$c' (helper output incomplete)"
    [[ -n "${DEF_ALLOWED[$c]:-}"  ]] || fail "DEFAULT Core oracle missing result for case '$c'"
    [[ -n "${OU_ALLOWED[$c]:-}"   ]] || fail "ouroboros missing result for case '$c' (helper output incomplete)"
done

# ── 8. Compare per case. Emit a forensic table + collect verdicts. ────────
# Per-case status token (GENUINE-FLOOR framing):
#   ok          impl matches STRICT Core (accept==accept, or both reject same
#               category) — full reject-parity. Floor cases want this.
#   ok-default  STRICT Core rejects, DEFAULT Core ACCEPTS, impl ACCEPTS — impl
#               tracks modern (v31.99) default relay policy; it merely lacks the
#               strict knob (-permitbaremultisig / -datacarriersize). NOT a hole;
#               PASS-able. Applies only to bare-multisig + oversize-op_return.
#   HOLE        DEFAULT Core REJECTS but impl ACCEPTS — a GENUINE, config-
#               independent policy gap below the must-reject floor. FAIL loudly.
#   over        STRICT Core accepts but impl rejects (impl too strict).
#   mism        both reject but the reject CATEGORY differs.
log "=== POLICY REJECT-PARITY  (GENUINE FLOOR = dust + version + min-relay) ==="
log "  primary oracle = STRICT Core (-permitbaremultisig=0 -datacarriersize=80)"
log "  secondary oracle = DEFAULT Core (out-of-the-box v31.99 relay policy)"
printf '%-20s | %-7s %-26s | %-7s | %-7s %-46s | %s\n' \
    "case" "C-strict" "C-strict-reason" "C-deflt" "ouro" "ouroboros-reason" "verdict" >&2

declare -A STATUS
HOLES=()          # GENUINE: default Core rejects, ouroboros accepts
OKDEFAULT=()      # strict-only divergence: ouroboros == default Core
NORMALIZED_ANY=0
for c in "${CASES[@]}"; do
    ca="${CORE_ALLOWED[$c]}"; cr="${CORE_REASON[$c]}"      # strict Core
    da="${DEF_ALLOWED[$c]}"                                # default Core (allowed)
    ia="${OU_ALLOWED[$c]}";   ir="${OU_REASON[$c]}"        # ouroboros
    ccat=$(classify "$cr"); icat=$(classify "$ir")
    local_status=""
    if [[ "$ca" == "true" && "$ia" == "true" ]]; then
        local_status="ok"                       # both accept (valid control)
    elif [[ "$ca" == "false" && "$ia" == "false" ]]; then
        if [[ "$ccat" == "$icat" ]]; then
            local_status="ok"
            [[ "$cr" != "$ir" ]] && NORMALIZED_ANY=1
        else
            local_status="mism"
        fi
    elif [[ "$ca" == "false" && "$ia" == "true" ]]; then
        # strict Core rejects, ouroboros accepts -> split on DEFAULT Core.
        if [[ "$da" == "false" ]]; then
            local_status="HOLE"                 # default Core ALSO rejects -> genuine hole
            HOLES+=("$c")
        else
            local_status="ok-default"           # default Core accepts -> parity-with-default
            OKDEFAULT+=("$c")
        fi
    else
        local_status="over"                     # Core accepts, ouroboros rejects
    fi
    STATUS["$c"]="$local_status"
    printf '%-20s | %-7s %-26s | %-7s | %-7s %-46s | %s\n' \
        "$c" "$ca" "${cr:- (accepted)}" "$da" "$ia" "${ir:- (accepted)}" "$local_status" >&2
done

# ── 9. Map case -> summary token. ─────────────────────────────────────────
tok() {  # tok <case>
    case "${STATUS[$1]}" in
        ok)         echo "ok" ;;
        ok-default) echo "ok-default" ;;
        HOLE)       echo "HOLE-accepts" ;;
        over)       echo "over-rejects" ;;
        mism)       echo "mismatch" ;;
        *)          echo "${STATUS[$1]}" ;;
    esac
}
DUST_T=$(tok dust)
VER_T=$(tok bad-version)
RELAY_T=$(tok below-min-relay)
BARE_T=$(tok bare-multisig)
OPRET_T=$(tok oversize-op_return)
CTRL_S="${STATUS[valid-control]}"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
# The valid-control MUST be accepted by ouroboros (the funded input reaches the
# gate and the clean spend is relayable) — otherwise the harness itself is
# broken (e.g. sighash/funding wrong) and nothing else is trustworthy.
if [[ "$CTRL_S" != "ok" ]]; then
    fail "valid-control not accepted by ouroboros (control=${OU_REASON[valid-control]:-rejected}); harness funding/signing broken — investigate before trusting other cases | dust=$DUST_T version=$VER_T min-relay=$RELAY_T bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Report strict-only divergences (parity with default Core — informational).
if [[ "${#OKDEFAULT[@]}" -gt 0 ]]; then
    log "strict-only divergences (ouroboros matches DEFAULT Core; reject only under non-default flags): ${OKDEFAULT[*]}"
    for c in "${OKDEFAULT[@]}"; do
        log "  ok-default $c: strict-Core='${CORE_REASON[$c]}'  default-Core=ACCEPT  ouroboros=ACCEPT"
    done
fi

# A GENUINE HOLE (default Core rejects, ouroboros accepts) — a real floor gap.
# Per the brief we FAIL loudly + report it (never mask a hole to force green).
if [[ "${#HOLES[@]}" -gt 0 ]]; then
    log "GENUINE POLICY HOLES (DEFAULT Core rejects, ouroboros ACCEPTS):"
    for c in "${HOLES[@]}"; do
        log "  HOLE $c: Core(strict & default)='${CORE_REASON[$c]}'  ouroboros=ACCEPTED"
    done
    fail "ouroboros accepts $(IFS=,; echo "${HOLES[*]}") below the genuine floor (even DEFAULT Core rejects) | dust=$DUST_T version=$VER_T min-relay=$RELAY_T bare-multisig=$BARE_T op_return=$OPRET_T control=accept"
fi

# Any category mismatch (both reject, different category) is also a failure.
MISM=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "mism" ]] && MISM+=("$c"); done
if [[ "${#MISM[@]}" -gt 0 ]]; then
    fail "reject-category mismatch on $(IFS=,; echo "${MISM[*]}") | dust=$DUST_T version=$VER_T min-relay=$RELAY_T bare-multisig=$BARE_T op_return=$OPRET_T control=accept"
fi

# Any over-rejection (Core accepts, ouroboros rejects) is a failure too.
OVER=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "over" ]] && OVER+=("$c"); done
if [[ "${#OVER[@]}" -gt 0 ]]; then
    fail "ouroboros over-rejects $(IFS=,; echo "${OVER[*]}") that Core accepts | dust=$DUST_T version=$VER_T min-relay=$RELAY_T bare-multisig=$BARE_T op_return=$OPRET_T control=accept"
fi

# Floor cases must reject in the right category (not ok-default). Guard against
# a floor case being mislabelled ok-default (would mean default Core accepted a
# floor violation, which cannot happen for dust/version/min-relay).
for fc in dust bad-version below-min-relay; do
    [[ "${STATUS[$fc]}" == "ok" ]] || fail "floor case '$fc' did not reach reject-parity (status=${STATUS[$fc]}) | dust=$DUST_T version=$VER_T min-relay=$RELAY_T"
done

# No genuine holes, no mismatches, no over-rejections, control accepted, floor
# fully rejected in-category.
[[ "$NORMALIZED_ANY" -eq 1 ]] && log "note: some cases matched via NORMALIZATION (category-level), not byte-exact strings"
[[ "${#OKDEFAULT[@]}" -gt 0 ]] && log "note: ${#OKDEFAULT[@]} case(s) pass as parity-with-default-Core (strict-flag-only gates)"
log "PASS: genuine floor (dust + version + min-relay) rejected in-category; valid-control accepted; no genuine policy holes"
pass "$DUST_T" "$VER_T" "$RELAY_T" "$BARE_T" "$OPRET_T"
