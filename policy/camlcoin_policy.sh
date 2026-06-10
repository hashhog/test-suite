#!/usr/bin/env bash
#
# camlcoin_policy.sh — self-contained MEMPOOL/POLICY reject-parity test.
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
# ── GENUINE-FLOOR FRAMING (the key design decision) ────────────────────────
#   The box's Bitcoin Core is v31.99, which RELAXED two classic standardness
#   rules to default-ACCEPT: bare multisig is now relayed by default
#   (DEFAULT_PERMIT_BAREMULTISIG=true) and the OP_RETURN cap rose from 80 B to
#   MAX_STANDARD_TX_WEIGHT/4 (100 000 B). So a default-flag Core ACCEPTS
#   bare-multisig + an oversize OP_RETURN — they only reject under the strict
#   knobs (-permitbaremultisig=0 -datacarriersize=80).
#
#   Therefore this harness asserts the GENUINE must-reject FLOOR — the set of
#   violations a DEFAULT, out-of-the-box Core ALSO rejects (verified empirically
#   on this box, 2026-06-04, via a strict + default dual-oracle run; see the
#   forensic table in the commit message / handoff):
#
#       GENUINE FLOOR = { dust, bad-version, below-min-relay }   (must REJECT)
#       valid-control                                            (must ACCEPT)
#
#   bare-multisig + oversize-op_return are "match-default-Core" cases: a default
#   Core ACCEPTS them, so camlcoin ACCEPTING them is parity-with-default-Core
#   (a missing strict CONFIG KNOB, NOT a standardness defect). The harness marks
#   them ok-default and does NOT fail on them.
#
#   A GENUINE HOLE — camlcoin ACCEPTS a genuine-floor violation (dust /
#   bad-version / below-min-relay) — IS a real policy gap and FAILs the harness
#   loudly (never masked).
#
# CORPUS (each is the valid signed spend with ONE rule violated):
#   - valid-control      : the clean 1-in/1-out p2wpkh spend          -> ACCEPT
#   - dust               : a 1-sat p2wpkh output on a fee-paying tx   -> "dust"        [FLOOR]
#   - bare-multisig      : a bare (non-P2SH) 1-of-1 multisig output   -> default ACCEPT (strict-only)
#   - oversize-op_return : an 83-byte OP_RETURN payload (>80)         -> default ACCEPT (strict-only)
#   - bad-version        : nVersion=4 (outside standard {1,2,3})      -> "version"      [FLOOR]
#   - below-min-relay    : a zero-fee tx (below the min-relay floor)  -> "min relay..." [FLOOR]
#
# CORE ORACLE (canonical reject categories — hardcoded; verified on this box's
#   real v31.99 bitcoind, so the harness does NOT need to spin up a Core regtest
#   to run, keeping it fast + dependency-light):
#     valid-control      -> ACCEPT
#     dust               -> "dust"                  (genuine floor: default Core rejects)
#     bad-version        -> "version"               (genuine floor: default Core rejects)
#     below-min-relay    -> "min relay fee not met" (genuine floor: default Core rejects)
#     bare-multisig      -> default Core ACCEPTS    (strict-flag-only -> ACCEPT-ok)
#     oversize-op_return -> default Core ACCEPTS    (strict-flag-only -> ACCEPT-ok)
#
# NORMALIZATION: reject-reason strings are compared by CATEGORY. Core emits the
#   bare reject token ("dust", "version", "min relay fee not met"). camlcoin is
#   Core-faithful on the always-on gates but uses its own, more verbose phrasing:
#       Core "dust"                  -> camlcoin "tx with dust output must be 0-fee"
#                                       (its ephemeral-dust 0-fee gate: a single
#                                        dust output on a FEE-paying tx)
#       Core "version"               -> camlcoin "Non-standard transaction version"
#       Core "min relay fee not met" -> camlcoin "Fee below minimum relay fee"
#   A case PASSES when impl and Core map to the SAME category via classify().
#   EXACT vs NORMALIZED is reported (camlcoin is NORMALIZED on all three floor
#   gates: it never emits the bare Core token).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/spend/camlcoin_spend.sh): no
#   required args, idempotent, trap cleanup, scratch datadir + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: POLICY camlcoin: PASS dust=ok version=ok min-relay=ok control=accept bare-multisig=ok-default op_return=ok-default
#   FAIL: POLICY camlcoin: FAIL <short reason> [dust=.. version=.. ...]
#
# Touches ONLY /tmp/policyfleet-camlcoin/ and ports 21845 (RPC) / 21865 (P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

CC_DATADIR="/tmp/policyfleet-camlcoin"
CC_RPC=21845
CC_P2P=21865
CC_LOG="$CC_DATADIR/node.log"

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=101            # mine to maturity: height-1 coinbase (50 BTC) spendable at tip 101

CC_PID=""
CC_COOKIE=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[policy:camlcoin] $*" >&2; }

# ── Cleanup: kill node + wipe scratch on any exit. ────────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CC_PID" ]] && kill -0 "$CC_PID" 2>/dev/null; then
        kill "$CC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CC_PID" 2>/dev/null || true
    fi
    rm -rf "$CC_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <dust> <version> <minrelay> <control> <bare> <opret>
pass() {
    echo "POLICY camlcoin: PASS dust=$1 version=$2 min-relay=$3 control=$4 bare-multisig=$5 op_return=$6"
    exit 0
}
fail() {
    echo "POLICY camlcoin: FAIL $*"
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
        *"min relay fee"*|*min-relay*|*"minimum relay fee"*|*"mempool min fee"*|*"fee not met"*|*"fee below minimum"*|*"fee below"*) echo "min-relay" ;;
        version*|*"tx version"*|*nversion*|*"version range"*|*"transaction version"*) echo "version" ;;
        *)                                                   echo "other:$s" ;;
    esac
}

# ── Core oracle (hardcoded; verified empirically on this box's real v31.99). ─
# Per-case: the canonical Core reject CATEGORY, plus whether a DEFAULT
# (out-of-the-box) Core rejects it. "GENUINE FLOOR" = default Core ALSO rejects.
#   ORACLE_CAT[case]      -> expected reject category ("accept" for the control)
#   ORACLE_DEFAULT[case]  -> "reject" if a default-flag Core rejects (floor),
#                            "accept" if a default-flag Core accepts (strict-only)
declare -A ORACLE_CAT ORACLE_DEFAULT
ORACLE_CAT[valid-control]=accept       ; ORACLE_DEFAULT[valid-control]=accept
ORACLE_CAT[dust]=dust                  ; ORACLE_DEFAULT[dust]=reject          # FLOOR
ORACLE_CAT[bad-version]=version        ; ORACLE_DEFAULT[bad-version]=reject    # FLOOR
ORACLE_CAT[below-min-relay]=min-relay  ; ORACLE_DEFAULT[below-min-relay]=reject # FLOOR
ORACLE_CAT[bare-multisig]=bare-multisig    ; ORACLE_DEFAULT[bare-multisig]=accept       # strict-only
ORACLE_CAT[oversize-op_return]=datacarrier ; ORACLE_DEFAULT[oversize-op_return]=accept   # strict-only

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state ($CC_DATADIR, ports $CC_RPC/$CC_P2P)"
pkill -f "policyfleet-camlcoin" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}) "; then
    fail "port ${CC_RPC}/${CC_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$CC_DATADIR"
mkdir -p "$CC_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "camlcoin binary not found at $NODE_BIN (run dune build)"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || fail "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the corpus-builder Python helper. ────────────────────────────
# It connects to camlcoin's RPC, mines a coinbase to the fixed key, reads
# camlcoin's OWN height-1 coinbase, builds + SIGNS (in Python, via BIP143
# SegwitV0SignatureHash — NO wallet dependency) every corpus variant against it,
# runs testmempoolaccept, and prints one tab-separated line per case:
#   CASE <name> <allowed:true|false> <reject-reason>
HELPER="$CC_DATADIR/policy_corpus.py"
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

# ── 3. Launch camlcoin on regtest. ────────────────────────────────────────
log "launching camlcoin (regtest) rpc=:$CC_RPC p2p=:$CC_P2P -> $CC_LOG"
"$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
    --port "$CC_P2P" --rpcport "$CC_RPC" >"$CC_LOG" 2>&1 &
CC_PID=$!
log "camlcoin pid=$CC_PID"
cc_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < cc_deadline )); do
    if [[ -z "$CC_COOKIE" && -f "$CC_DATADIR/.cookie" ]]; then
        CC_COOKIE=$(cat "$CC_DATADIR/.cookie")
    fi
    if [[ -n "$CC_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$CC_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$CC_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$CC_PID" 2>/dev/null || { tail -n 20 "$CC_LOG" >&2 2>/dev/null || true; fail "camlcoin exited during startup (see $CC_LOG)"; }
    sleep 1
done
[[ -n "$CC_COOKIE" ]] || fail "camlcoin cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$CC_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$CC_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "camlcoin RPC never responded within 60s"
log "camlcoin RPC ready"

# ── 4. Run the corpus against camlcoin. ───────────────────────────────────
log "running corpus against camlcoin"
CC_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CC_RPC/" "$CC_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CC_LOG")
[[ -n "$CC_OUT" ]] || { tail -n 30 "$CC_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for camlcoin"; }

# ── 5. Parse camlcoin results into name -> allowed / reason. ──────────────
declare -A CC_ALLOWED CC_REASON
while IFS=$'\t' read -r tag name allowed reason; do
    [[ "$tag" == "CASE" ]] || continue
    CC_ALLOWED["$name"]="$allowed"; CC_REASON["$name"]="$reason"
done <<< "$CC_OUT"

CASES=(valid-control dust bare-multisig oversize-op_return bad-version below-min-relay)
for c in "${CASES[@]}"; do
    [[ -n "${CC_ALLOWED[$c]:-}" ]] || fail "camlcoin missing result for case '$c' (helper output incomplete)"
done

# ── 6. Compare per case against the hardcoded Core oracle + genuine floor. ─
# Per-case status token:
#   ok          camlcoin matches Core (accept==accept for the control, or both
#               reject the SAME category for a floor case) — full reject-parity.
#   ok-default  Core rejects only under STRICT flags; a DEFAULT Core ACCEPTS,
#               and camlcoin ACCEPTS -> parity-with-default-Core (missing strict
#               config knob, NOT a standardness defect). PASS-able.
#   HOLE        a GENUINE-FLOOR violation (default Core rejects) that camlcoin
#               ACCEPTS -> real policy gap. Highest-value finding; FAILs loudly.
#   over        Core accepts but camlcoin rejects (impl too strict).
#   mism        both reject but the reject CATEGORY differs.
log "=== POLICY REJECT-PARITY  (genuine-floor framing; Core v31.99 default-relay oracle) ==="
log "  GENUINE FLOOR (must reject) = dust, bad-version, below-min-relay   + valid-control must accept"
log "  strict-only (default Core accepts -> ACCEPT-ok) = bare-multisig, oversize-op_return"
printf '%-20s | %-12s %-6s | %-6s %-44s | %s\n' \
    "case" "oracle-cat" "floor" "caml" "camlcoin-reason" "verdict" >&2

declare -A STATUS
HOLES=()        # genuine-floor violations camlcoin accepts
OKDEF=()        # strict-only divergences (camlcoin == default Core)
NORMALIZED_ANY=0
for c in "${CASES[@]}"; do
    ocat="${ORACLE_CAT[$c]}"
    floor="${ORACLE_DEFAULT[$c]}"               # reject | accept  (does default Core reject?)
    ia="${CC_ALLOWED[$c]}"; ir="${CC_REASON[$c]}"
    icat=$(classify "$ir")
    local_status=""
    if [[ "$ocat" == "accept" ]]; then
        # The valid control: Core accepts -> camlcoin must accept.
        if [[ "$ia" == "true" ]]; then local_status="ok"; else local_status="over"; fi
    elif [[ "$ia" == "false" ]]; then
        # Core rejects, camlcoin rejects -> categories must match.
        if [[ "$icat" == "$ocat" ]]; then
            local_status="ok"
            [[ "$icat" == "$ir" ]] || NORMALIZED_ANY=1   # rejected via verbose phrasing
        else
            local_status="mism"
        fi
    else
        # Core rejects (under some flags), camlcoin ACCEPTS. Split on the floor.
        if [[ "$floor" == "reject" ]]; then
            local_status="HOLE"   # default Core ALSO rejects -> genuine-floor hole
            HOLES+=("$c")
        else
            local_status="ok-default"   # default Core accepts -> strict-flag-only
            OKDEF+=("$c")
        fi
    fi
    STATUS["$c"]="$local_status"
    printf '%-20s | %-12s %-6s | %-6s %-44s | %s\n' \
        "$c" "$ocat" "$floor" "$ia" "${ir:- (accepted)}" "$local_status" >&2
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
# The valid-control MUST be accepted by camlcoin (the funded input reaches the
# gate and the clean spend is relayable) — otherwise the harness itself is
# broken (e.g. sighash/funding wrong) and nothing else is trustworthy.
if [[ "$CTRL_S" != "ok" ]]; then
    fail "valid-control not accepted by camlcoin (control=${CC_REASON[valid-control]:-rejected}); harness funding/signing broken — investigate before trusting other cases"
fi

# A GENUINE-FLOOR HOLE (default Core rejects, camlcoin accepts) is a real policy
# gap. Per the brief we FAIL loudly + report it (never mask a hole to force green).
if [[ "${#HOLES[@]}" -gt 0 ]]; then
    log "GENUINE POLICY HOLES (default Core rejects, camlcoin ACCEPTS):"
    for c in "${HOLES[@]}"; do
        log "  HOLE $c: Core(strict & default)='${ORACLE_CAT[$c]}'  camlcoin=ACCEPTED"
    done
    fail "camlcoin accepts $(IFS=,; echo "${HOLES[*]}") that even DEFAULT Core rejects | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any category mismatch (both reject, different category) is a failure.
MISM=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "mism" ]] && MISM+=("$c"); done
if [[ "${#MISM[@]}" -gt 0 ]]; then
    fail "reject-category mismatch on $(IFS=,; echo "${MISM[*]}") | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any over-rejection (Core accepts, camlcoin rejects) is a failure.
OVER=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "over" ]] && OVER+=("$c"); done
if [[ "${#OVER[@]}" -gt 0 ]]; then
    fail "camlcoin over-rejects $(IFS=,; echo "${OVER[*]}") that Core accepts | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# No genuine-floor holes, no mismatches, no over-rejections, control accepted.
[[ "$NORMALIZED_ANY" -eq 1 ]] && log "note: some floor cases matched via NORMALIZATION (category-level), not byte-exact Core strings"
[[ "${#OKDEF[@]}" -gt 0 ]] && log "note: ${#OKDEF[@]} strict-only case(s) pass as parity-with-default-Core (missing config knob, not a hole): ${OKDEF[*]}"
log "PASS: camlcoin rejects the genuine floor (dust+version+min-relay, normalized to Core's category) and accepts the valid control; no genuine policy holes"
pass "$DUST_T" "$VER_T" "$RELAY_T" accept "$BARE_T" "$OPRET_T"
