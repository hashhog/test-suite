#!/usr/bin/env bash
#
# hotbuns_policy.sh — self-contained MEMPOOL/POLICY reject-parity test
#                     (GENUINE-FLOOR framing).
#
# The consensus-adjacent successor to the wallet harnesses (recovery / spend /
# history / import). Where those proved the wallet round-trip, this proves the
# *mempool standardness gate*: a transaction that violates a relay-policy rule
# must be handled the SAME way Bitcoin Core handles it — rejected with the same
# reject-reason CATEGORY for the genuine must-reject floor, accepted where a
# default Core node accepts.
#
# Why a new harness (the existing test-suite/mempool_tests.py is permissive):
#   The old suite spends OP_TRUE anyone-can-spend coinbases, so every submitted
#   tx fails at *input-existence* and NEVER reaches the standardness gate — it
#   can't tell "policy rejected" from "input missing", and never asserts the
#   reject STRING. This harness fixes that: it builds a REAL, SIGNED p2wpkh
#   spend of a mature coinbase (so the tx PASSES input-existence and REACHES
#   the policy gate), then derives one variant per standardness rule and runs
#   it through testmempoolaccept.
#
# GENUINE-FLOOR FRAMING (the key design decision):
#   The box's Bitcoin Core is v31.99, which RELAXED two classic standardness
#   rules to default-ACCEPT: bare multisig (DEFAULT_PERMIT_BAREMULTISIG=true)
#   and the OP_RETURN/datacarrier cap (raised from 80 B to MAX_STANDARD_TX_
#   WEIGHT/4). So a default Core node ACCEPTS a bare-multisig output and an
#   83-byte OP_RETURN — those reject only under the non-default strict flags
#   (-permitbaremultisig=0 -datacarriersize=80).
#
#   Therefore the harness asserts the GENUINE must-reject floor — the set of
#   violations a DEFAULT Core node rejects out of the box, independent of any
#   strict knob:
#       valid-control      -> ACCEPT (allowed=true)         [the clean spend]
#       dust               -> "dust"                        [below dust thresh]
#       bad-version        -> "version"                     [nVersion outside 1..3]
#       below-min-relay    -> "min relay fee not met"       [zero / below floor]
#   These four are the PASS/FAIL axis. A hole on any of them (hotbuns ACCEPTS a
#   genuine-floor violation, or REJECTS the valid control) FAILs the harness.
#
#   bare-multisig and oversize-op_return are "match default Core" cases: a
#   default Core ACCEPTS them, so hotbuns ACCEPTING them is parity-with-default
#   (NOT a hole). They are observed and reported but do NOT fail the harness.
#
# CORE ORACLE (hardcoded canonical decisions — no live Core needed):
#   The default-Core decision for each corpus case is a known constant on this
#   box (verified by the strict/default dual-oracle reference harness):
#       valid-control      -> accept
#       dust               -> dust
#       bad-version        -> version
#       below-min-relay    -> min-relay
#       bare-multisig      -> accept   (default Core relaxed; strict-only reject)
#       oversize-op_return -> accept   (default Core relaxed; strict-only reject)
#   hotbuns is compared against this oracle. Only hotbuns is launched.
#
# NORMALIZATION (category-level; impls diverge in phrasing): each reject reason
#   is classified to {accept,dust,version,min-relay,bare-multisig,datacarrier,
#   other} by substring (classify() below). hotbuns is Core-faithful but
#   decorates the tokens — e.g. Core "version" vs hotbuns "version: tx version 4
#   out of standard range [1,3]"; Core "dust" vs hotbuns "tx with dust output
#   must be 0-fee" (its v31.99 ephemeral-dust 0-fee gate). A case PASSES when
#   the impl category == the Core category.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/spend/hotbuns_spend.sh): no
#   required args, idempotent, trap cleanup, scratch datadir + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: POLICY hotbuns: PASS dust=ok version=ok min-relay=ok control=accept bare-multisig=ok-default op_return=ok-default
#   FAIL: POLICY hotbuns: FAIL <short reason> [dust=.. version=.. min-relay=.. ...]
#
# Touches ONLY /tmp/policyfleet-hotbuns/ and ports 39944 (RPC) / 39964 (P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

HB_DATADIR="/tmp/policyfleet-hotbuns"
HB_RPC=39944
HB_P2P=39964
HB_LOG="$HB_DATADIR/node.log"

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=101            # mine to maturity: height-1 coinbase (50 BTC) spendable at tip 101

HB_PID=""
HB_COOKIE=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[policy:hotbuns] $*" >&2; }

# ── Cleanup: kill node + wipe scratch on any exit. ────────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
    fi
    fuser -k "${HB_RPC}/tcp" 2>/dev/null || true
    fuser -k "${HB_P2P}/tcp" 2>/dev/null || true
    rm -rf "$HB_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <dust> <ver> <minrelay> <control> <bare> <opret>
pass() {
    echo "POLICY hotbuns: PASS dust=$1 version=$2 min-relay=$3 control=$4 bare-multisig=$5 op_return=$6"
    exit 0
}
fail() {
    echo "POLICY hotbuns: FAIL $*"
    exit 1
}

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Maps any impl reject string to a canonical category token. Empty input
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
        version*|*"tx version"*|*nversion*|*"version range"*|*"transaction version"*) echo "version" ;;
        *)                                                   echo "other:$s" ;;
    esac
}

# ── Hardcoded Core oracle: case -> DEFAULT-Core category. ─────────────────
# accept|dust|version|min-relay are the genuine floor (default Core rejects the
# last three, accepts the control). bare-multisig + oversize-op_return are
# default-accept on v31.99 (strict-flag-only), so the oracle marks them accept.
declare -A ORACLE=(
    [valid-control]=accept
    [dust]=dust
    [bad-version]=version
    [below-min-relay]=min-relay
    [bare-multisig]=accept
    [oversize-op_return]=accept
)
# The genuine must-reject floor (a hole on any of these FAILs the harness).
FLOOR_CASES=(dust bad-version below-min-relay)

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "policyfleet-hotbuns" 2>/dev/null || true
fuser -k "${HB_RPC}/tcp" 2>/dev/null || true
fuser -k "${HB_P2P}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$HB_DATADIR"
mkdir -p "$HB_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v bun >/dev/null 2>&1     || fail "bun runtime not found on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"
[[ -f "$NODE_DIR/src/index.ts" ]]  || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || fail "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the corpus-builder Python helper. ────────────────────────────
# Connects to hotbuns' RPC, mines a coinbase to the fixed key, reads hotbuns'
# OWN height-1 coinbase, builds + SIGNS (BIP143 SegwitV0SignatureHash, in
# Python — NO wallet dependency) every corpus variant against it, runs
# testmempoolaccept, and prints one
#   CASE <name> <allowed:true|false> <reject-reason>
# tab-separated line per case to stdout.
HELPER="$HB_DATADIR/policy_corpus.py"
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

# ── 3. Launch hotbuns on regtest. ─────────────────────────────────────────
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P -> $HB_LOG"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC"
) >"$HB_LOG" 2>&1 &
HB_PID=$!
log "hotbuns pid=$HB_PID"
deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$HB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$HB_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 20 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG)"; }
    sleep 1
done
[[ -n "$HB_COOKIE" ]] || fail "hotbuns cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$HB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$HB_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "hotbuns RPC never responded within 60s"
log "hotbuns RPC ready"

# ── 4. Run the corpus against hotbuns. ────────────────────────────────────
log "running corpus against hotbuns"
HB_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$HB_RPC/" "$HB_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$HB_LOG")
[[ -n "$HB_OUT" ]] || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for hotbuns"; }

# ── 5. Parse results into name -> allowed / reason. ───────────────────────
declare -A HB_ALLOWED HB_REASON
while IFS=$'\t' read -r tag name allowed reason; do
    [[ "$tag" == "CASE" ]] || continue
    HB_ALLOWED["$name"]="$allowed"; HB_REASON["$name"]="$reason"
done <<< "$HB_OUT"

CASES=(valid-control dust bare-multisig oversize-op_return bad-version below-min-relay)
for c in "${CASES[@]}"; do
    [[ -n "${HB_ALLOWED[$c]:-}" ]] || fail "hotbuns missing result for case '$c' (helper output incomplete)"
done

# ── 6. Compare per case against the hardcoded Core oracle. ────────────────
# Per-case status token:
#   ok          impl category == oracle category (accept==accept, or both reject
#               same category) — reject-parity with default Core.
#   ok-default  oracle=accept and impl=accept on a strict-flag-only case
#               (bare-multisig / oversize-op_return): parity with default Core.
#   HOLE        oracle REJECTS (genuine floor) but impl ACCEPTS — a real policy
#               gap (impl more permissive than a default Core). FAILs loudly.
#   over        oracle accepts but impl rejects (impl too strict).
#   mism        both reject but different category.
log "=== POLICY REJECT-PARITY (GENUINE-FLOOR; oracle = DEFAULT Bitcoin Core v31.99) ==="
log "  genuine must-reject floor: dust, bad-version, below-min-relay (+ valid-control accept)"
log "  strict-flag-only (default-accept): bare-multisig, oversize-op_return"
printf '%-20s | %-9s | %-6s %-44s | %s\n' \
    "case" "oracle" "hot" "hotbuns-reason" "verdict" >&2

declare -A STATUS
NORMALIZED_ANY=0
for c in "${CASES[@]}"; do
    ocat="${ORACLE[$c]}"                        # default-Core category
    ha="${HB_ALLOWED[$c]}"; hr="${HB_REASON[$c]}"
    hcat=$(classify "$hr")
    local_status=""
    if [[ "$ocat" == "accept" ]]; then
        if [[ "$ha" == "true" ]]; then
            # parity with default-Core accept. ok for the control; ok-default
            # for the two strict-flag-only relaxed rules.
            if [[ "$c" == "valid-control" ]]; then local_status="ok"; else local_status="ok-default"; fi
        else
            local_status="over"                 # oracle accepts, impl rejects
        fi
    else
        # oracle REJECTS (genuine floor): dust / version / min-relay.
        if [[ "$ha" == "true" ]]; then
            local_status="HOLE"                 # impl accepts a genuine-floor violation
        elif [[ "$hcat" == "$ocat" ]]; then
            local_status="ok"                   # both reject, same category
            NORMALIZED_ANY=1                     # impl phrasing != bare Core token
        else
            local_status="mism"                 # both reject, different category
        fi
    fi
    STATUS["$c"]="$local_status"
    printf '%-20s | %-9s | %-6s %-44s | %s\n' \
        "$c" "$ocat" "$ha" "${hr:- (accepted)}" "$local_status" >&2
done

# ── 7. Map case -> summary token. ─────────────────────────────────────────
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

# ── 8. Verdict. ───────────────────────────────────────────────────────────
# The valid-control MUST be accepted by hotbuns (the funded input reaches the
# gate and the clean spend is relayable) — otherwise the harness itself is
# broken (e.g. sighash/funding wrong) and nothing else is trustworthy.
if [[ "$CTRL_S" != "ok" ]]; then
    fail "valid-control not accepted by hotbuns (control=${HB_REASON[valid-control]:-rejected}); harness funding/signing broken — investigate before trusting other cases | dust=$DUST_T version=$VER_T min-relay=$RELAY_T"
fi

# A GENUINE HOLE (default Core rejects the floor case, hotbuns accepts) is a
# real policy gap. Per the brief we FAIL loudly + report it (never mask).
HOLES=()
for c in "${FLOOR_CASES[@]}"; do [[ "${STATUS[$c]}" == "HOLE" ]] && HOLES+=("$c"); done
if [[ "${#HOLES[@]}" -gt 0 ]]; then
    log "GENUINE POLICY HOLES (DEFAULT Core rejects, hotbuns ACCEPTS): ${HOLES[*]}"
    for c in "${HOLES[@]}"; do
        log "  HOLE $c: default-Core category='${ORACLE[$c]}'  hotbuns=ACCEPTED"
    done
    fail "hotbuns accepts $(IFS=,; echo "${HOLES[*]}") that default Core rejects | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any category mismatch on a floor case (both reject, different category).
MISM=()
for c in "${FLOOR_CASES[@]}"; do [[ "${STATUS[$c]}" == "mism" ]] && MISM+=("$c"); done
if [[ "${#MISM[@]}" -gt 0 ]]; then
    fail "reject-category mismatch on $(IFS=,; echo "${MISM[*]}") | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any over-rejection (default Core accepts, hotbuns rejects). For the floor this
# is a fail; for the strict-only cases an over-reject means hotbuns is stricter
# than default Core (still a divergence from the default-accept oracle).
OVER=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "over" ]] && OVER+=("$c"); done
if [[ "${#OVER[@]}" -gt 0 ]]; then
    fail "hotbuns over-rejects $(IFS=,; echo "${OVER[*]}") that default Core accepts | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# No genuine holes, no floor mismatches, no over-rejections, control accepted.
[[ "$NORMALIZED_ANY" -eq 1 ]] && log "note: floor cases matched via NORMALIZATION (category-level), not byte-exact Core tokens"
log "PASS: genuine must-reject floor enforced (dust+version+min-relay rejected, control accepted); bare-multisig+op_return parity-with-default-Core"
pass "$DUST_T" "$VER_T" "$RELAY_T" accept "$BARE_T" "$OPRET_T"
