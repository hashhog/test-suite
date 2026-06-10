#!/usr/bin/env bash
#
# clearbit_policy.sh — self-contained MEMPOOL/POLICY reject-parity test.
#
# The consensus-adjacent successor to the wallet harnesses (recovery / spend /
# history / import). Where those proved the wallet round-trip, this proves the
# *mempool standardness gate*: a transaction that violates a relay-policy rule
# must be rejected with the SAME reject-reason CATEGORY Bitcoin Core emits via
# testmempoolaccept.
#
# Why a new harness (the existing test-suite/mempool_tests.py is permissive):
#   The old suite spends OP_TRUE anyone-can-spend coinbases, so every submitted
#   tx fails at *input-existence* and NEVER reaches the standardness gate — it
#   can't tell "policy rejected" from "input missing", and never asserts the
#   reject STRING. This harness fixes that: it builds a REAL, SIGNED p2wpkh
#   spend of a mature coinbase (so the tx PASSES input-existence and REACHES
#   the policy gate), then derives one variant per standardness rule.
#
#   The corpus is built as RAW SIGNED HEX in Python (Core's test_framework
#   key/script/messages, BIP143 SegwitV0SignatureHash) — NEVER via clearbit's
#   createrawtransaction (historically buggy: it stuffed an address string into
#   the scriptPubKey). The same raw hex is submitted to every oracle.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core v31.99) on a SEPARATE
#   regtest instance (own scratch datadir + ports). For each corpus case the
#   SAME corpus is rebuilt + submitted to Core's testmempoolaccept and Core's
#   exact reject-reason is recorded. clearbit is compared against that oracle.
#
#   GENUINE-FLOOR FRAMING — TWO Core oracles run side by side:
#     * STRICT  (-permitbaremultisig=0 -datacarriersize=80): the classic
#       relay-policy floor. Every corpus violation rejects deterministically
#       here. PRIMARY oracle.
#     * DEFAULT (no policy flags): Bitcoin Core v31.99 RELAXED two classic
#       rules — bare multisig is relayed by default (DEFAULT_PERMIT_BAREMULTISIG
#       =true) and the OP_RETURN cap rose from 80 B to MAX_STANDARD_TX_WEIGHT/4
#       (100 000). So bare-multisig + an 83-byte OP_RETURN only reject on STRICT
#       Core; DEFAULT Core ACCEPTS them.
#
#   The GENUINE must-reject FLOOR = {dust, bad-version, below-min-relay} —
#   rejected by BOTH strict AND default Core — plus the valid-control which
#   MUST be ACCEPTED. bare-multisig + oversize-op_return are strict-flag-only:
#   matching DEFAULT Core (ACCEPT) on them is PARITY, NOT a hole, and does NOT
#   fail the harness.
#
# CORPUS (each is the valid signed spend with ONE rule violated):
#   - valid-control      : the clean 1-in/1-out p2wpkh spend          -> ACCEPT
#   - dust               : a 1-sat p2wpkh output on a fee-paying tx   -> "dust"
#   - bare-multisig      : a bare (non-P2SH) 1-of-1 multisig output   -> "bare-multisig"
#   - oversize-op_return : an 83-byte OP_RETURN payload (>80)         -> "datacarrier"
#   - bad-version        : nVersion=4 (outside standard {1,2,3})      -> "version"
#   - below-min-relay    : a zero-fee tx (below the min-relay floor)  -> "min relay fee not met"
#
# NORMALIZATION: reject-reason strings are compared by CATEGORY via classify().
#   Core emits the bare token ("dust", "version", "min relay fee not met").
#   clearbit emits Core-faithful tokens ("dust", "version", "min relay fee not
#   met"). A case PASSES when impl and Core map to the SAME category. EXACT vs
#   NORMALIZED is reported.
#
# POLICY HOLE = a case where clearbit ACCEPTS a tx Core REJECTS. The default
#   oracle annotates each hole as either:
#       BUG-HOLE : DEFAULT Core ALSO rejects  -> a real, config-independent
#                  standardness bug (a GENUINE-FLOOR violation). FAILs loudly.
#       KNOB-GAP : only STRICT Core rejects   -> clearbit matches modern default
#                  Core but lacks the strict knob (-datacarriersize /
#                  -permitbaremultisig). NOT a genuine-floor violation; treated
#                  as parity-with-default and does NOT fail the harness.
#   Per the brief a genuine hole is never masked to force green.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/spend/clearbit_spend.sh + the
#   hotbuns_policy.sh / camlcoin_policy.sh references): no required args,
#   idempotent, trap cleanup, scratch datadirs + UNIQUE ports, ONE clean summary
#   line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: POLICY clearbit: PASS dust=ok version=ok min-relay=ok control=accept bare-multisig=ok-default op_return=ok-default
#   FAIL: POLICY clearbit: FAIL <short reason> [dust=.. version=.. ...]
#
# Touches ONLY /tmp/policyfleet-clearbit/ + /tmp/policyfleet-core-{strict,def}/
#   and ports 21847/21867 (clearbit RPC/P2P), 21848/21868 (strict Core RPC/P2P),
#   21849/21869 (default Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

CB_DATADIR="/tmp/policyfleet-clearbit"
CB_NETDIR="$CB_DATADIR/regtest"                    # clearbit appends the network subdir
CB_RPC=21847
CB_P2P=21867
CB_LOG="$CB_DATADIR/node.log"

# NOTE on P2P port spacing: bitcoind also opens a localhost "onion" listener on
# <p2p>+1 (its Tor control port). If two Core P2P ports were adjacent (e.g.
# 21868 + 21869) the second node would fail to bind because the first node's
# <p2p>+1 already holds the slot. We therefore space the three P2P ports by 4
# so no <p2p>+1 ever collides with another node's listen port.
CORE_DATADIR="/tmp/policyfleet-core-strict"
CORE_RPC=21848
CORE_P2P=21871
CORE_LOG="$CORE_DATADIR/core.log"

CORE_DEF_DATADIR="/tmp/policyfleet-core-def"
CORE_DEF_RPC=21849
CORE_DEF_P2P=21875
CORE_DEF_LOG="$CORE_DEF_DATADIR/core.log"

# Strict-policy flags so EVERY corpus violation rejects on the primary oracle.
CORE_STRICT_FLAGS=(-permitbaremultisig=0 -datacarriersize=80)

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=101            # mine to maturity: height-1 coinbase (50 BTC) spendable at tip 101

CB_PID=""
CB_COOKIE=""
CORE_BG=""
CORE_DEF_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[policy:clearbit] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CB_PID" ]] && kill -0 "$CB_PID" 2>/dev/null; then
        kill "$CB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CB_PID" 2>/dev/null || true
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
    rm -rf "$CB_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <dust> <version> <minrelay> <bare> <opret>
pass() {
    echo "POLICY clearbit: PASS dust=$1 version=$2 min-relay=$3 control=accept bare-multisig=$4 op_return=$5"
    exit 0
}
fail() {
    echo "POLICY clearbit: FAIL $*"
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
        *"min relay fee"*|*min-relay*|*"minimum relay fee"*|*"mempool min fee"*|*"fee not met"*|*"fee below minimum"*|*"insufficient fee"*) echo "min-relay" ;;
        version*|*"tx version"*|*nversion*|*"version range"*|*"transaction version"*|*"non-standard version"*) echo "version" ;;
        *)                                                   echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "policyfleet-clearbit" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${CB_RPC}|${CB_P2P}|${CORE_RPC}|${CORE_P2P}|${CORE_DEF_RPC}|${CORE_DEF_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${CB_RPC}|${CB_P2P}|${CORE_RPC}|${CORE_P2P}|${CORE_DEF_RPC}|${CORE_DEF_P2P}) "; then
    fail "port ${CB_RPC}/${CB_P2P}/${CORE_RPC}/${CORE_P2P}/${CORE_DEF_RPC}/${CORE_DEF_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$CB_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"
mkdir -p "$CB_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "clearbit binary not found at $NODE_BIN (build: zig build -Doptimize=ReleaseFast)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || fail "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the corpus-builder Python helper. ────────────────────────────
# It connects to ONE node's RPC, mines a coinbase to the fixed key, reads that
# node's OWN height-1 coinbase (coinbase txids differ per impl), builds + SIGNS
# (in Python, via BIP143 SegwitV0SignatureHash — NO wallet dependency, NO
# clearbit createrawtransaction) every corpus variant against it, runs
# testmempoolaccept, and prints one
#   CASE <name> <allowed:true|false> <reject-reason>
# tab-separated line per case to stdout. Driven once per node (3 oracles).
HELPER="$CB_DATADIR/policy_corpus.py"
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

# ── Wait helper: block until a Core regtest oracle's RPC answers. ─────────
# usage: wait_core <datadir> <rpcport> <logfile> <bg-pid>
# The bitcoind MUST be launched by the CALLER directly in the main shell (NOT
# inside a command substitution) so it is never SIGHUP'd when a subshell exits.
wait_core() {
    local dd="$1" rpc="$2" lf="$3" bg="$4"
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$bg" 2>/dev/null || { tail -n 20 "$lf" >&2 2>/dev/null || true; return 1; }
        sleep 1
    done
    return 1
}

# ── 3. Launch the STRICT Core oracle. ─────────────────────────────────────
# Launched directly in this shell (not via $(...)) so the background PID is a
# child of the main process group and survives until cleanup() stops it.
log "launching STRICT Core oracle rpc=:$CORE_RPC flags=${CORE_STRICT_FLAGS[*]}"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -fallbackfee=0.0002 "${CORE_STRICT_FLAGS[@]}" >"$CORE_LOG" 2>&1 &
CORE_BG=$!
wait_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_LOG" "$CORE_BG" \
    || fail "STRICT Core oracle failed to start within 90s (see $CORE_LOG)"
log "STRICT Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "STRICT Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch the DEFAULT Core oracle (no policy flags). ──────────────────
log "launching DEFAULT Core oracle rpc=:$CORE_DEF_RPC (no policy flags)"
"$CORE_BIN" -regtest -datadir="$CORE_DEF_DATADIR" -rpcport="$CORE_DEF_RPC" -port="$CORE_DEF_P2P" \
    -fallbackfee=0.0002 >"$CORE_DEF_LOG" 2>&1 &
CORE_DEF_BG=$!
wait_core "$CORE_DEF_DATADIR" "$CORE_DEF_RPC" "$CORE_DEF_LOG" "$CORE_DEF_BG" \
    || fail "DEFAULT Core oracle failed to start within 90s (see $CORE_DEF_LOG)"
log "DEFAULT Core oracle ready (pid=$CORE_DEF_BG)"
CORE_DEF_COOKIE=$(cat "$CORE_DEF_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_DEF_COOKIE" ]] || fail "DEFAULT Core cookie not found at $CORE_DEF_DATADIR/regtest/.cookie"

# ── 5. Launch clearbit on regtest. ────────────────────────────────────────
log "launching clearbit (regtest) rpc=:$CB_RPC p2p=:$CB_P2P -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" \
    --port="$CB_P2P" --rpcport="$CB_RPC" >"$CB_LOG" 2>&1 &
CB_PID=$!
log "clearbit pid=$CB_PID"
cb_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < cb_deadline )); do
    if [[ -z "$CB_COOKIE" ]]; then
        for c in "$CB_NETDIR/.cookie" "$CB_DATADIR/.cookie"; do
            [[ -f "$c" ]] && CB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$CB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$CB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$CB_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$CB_PID" 2>/dev/null || { tail -n 20 "$CB_LOG" >&2 2>/dev/null || true; fail "clearbit exited during startup (see $CB_LOG)"; }
    sleep 1
done
[[ -n "$CB_COOKIE" ]] || fail "clearbit cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$CB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$CB_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "clearbit RPC never responded within 60s"
log "clearbit RPC ready"

# ── 6. Run the corpus against all three nodes. ────────────────────────────
log "running corpus against STRICT Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for STRICT Core oracle"; }

log "running corpus against DEFAULT Core oracle"
CORE_DEF_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_DEF_RPC/" "$CORE_DEF_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_DEF_LOG")
[[ -n "$CORE_DEF_OUT" ]] || { tail -n 30 "$CORE_DEF_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for DEFAULT Core oracle"; }

log "running corpus against clearbit"
CB_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CB_RPC/" "$CB_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CB_LOG")
[[ -n "$CB_OUT" ]] || { tail -n 30 "$CB_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for clearbit"; }

# ── 7. Parse all result sets into name -> allowed / reason. ───────────────
declare -A CORE_ALLOWED CORE_REASON DEF_ALLOWED DEF_REASON CB_ALLOWED CB_REASON
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
    CB_ALLOWED["$name"]="$allowed"; CB_REASON["$name"]="$reason"
done <<< "$CB_OUT"

CASES=(valid-control dust bare-multisig oversize-op_return bad-version below-min-relay)
for c in "${CASES[@]}"; do
    [[ -n "${CORE_ALLOWED[$c]:-}" ]] || fail "STRICT Core oracle missing result for case '$c' (helper output incomplete)"
    [[ -n "${DEF_ALLOWED[$c]:-}"  ]] || fail "DEFAULT Core oracle missing result for case '$c'"
    [[ -n "${CB_ALLOWED[$c]:-}"   ]] || fail "clearbit missing result for case '$c' (helper output incomplete)"
done

# ── 8. Compare per case. Emit a forensic table + collect verdicts. ────────
# Per-case status token:
#   ok        impl matches STRICT Core (accept==accept, or both reject same category)
#   BUG-HOLE  STRICT Core rejects, DEFAULT Core ALSO rejects, but impl ACCEPTS
#             -> a real, config-independent standardness bug (GENUINE FLOOR).
#   KNOB-GAP  STRICT Core rejects, DEFAULT Core ACCEPTS, impl ACCEPTS
#             -> impl matches modern default Core; merely lacks the strict knob.
#             NOT a genuine-floor violation; parity-with-default (PASS-able).
#   over      STRICT Core accepts but impl rejects (impl too strict)
#   mism      both reject but different category
log "=== POLICY REJECT-PARITY  (primary oracle: STRICT -permitbaremultisig=0 -datacarriersize=80) ==="
log "  GENUINE FLOOR = {dust, bad-version, below-min-relay} + valid-control=ACCEPT"
printf '%-20s | %-7s %-26s | %-7s | %-7s %-40s | %s\n' \
    "case" "Core" "Core-reason" "CoreDef" "clrbit" "clearbit-reason" "verdict" >&2

declare -A STATUS
GENUINE_HOLES=()   # BUG-HOLE: default Core ALSO rejects -> genuine floor breach
KNOB_GAPS=()       # KNOB-GAP: strict-only -> parity-with-default
NORMALIZED_ANY=0
for c in "${CASES[@]}"; do
    ca="${CORE_ALLOWED[$c]}"; cr="${CORE_REASON[$c]}"
    da="${DEF_ALLOWED[$c]}"
    ia="${CB_ALLOWED[$c]}";   ir="${CB_REASON[$c]}"
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
            local_status="BUG-HOLE"   # default Core ALSO rejects -> genuine floor breach
            GENUINE_HOLES+=("$c")
        else
            local_status="KNOB-GAP"   # only strict rejects -> parity-with-default
            KNOB_GAPS+=("$c")
        fi
    else
        local_status="over"          # Core accepts, impl rejects
    fi
    STATUS["$c"]="$local_status"
    printf '%-20s | %-7s %-26s | %-7s | %-7s %-40s | %s\n' \
        "$c" "$ca" "${cr:- (accepted)}" "$da" "$ia" "${ir:- (accepted)}" "$local_status" >&2
done

# ── 9. Map case -> summary token. ─────────────────────────────────────────
tok() {  # tok <case>
    local s="${STATUS[$1]}"
    case "$s" in
        ok)        echo "ok" ;;
        KNOB-GAP)  echo "ok-default" ;;     # parity-with-default Core (strict-flag-only)
        BUG-HOLE)  echo "HOLE-accepts" ;;
        over)      echo "over-rejects" ;;
        mism)      echo "mismatch" ;;
        *)         echo "$s" ;;
    esac
}
DUST_T=$(tok dust)
VER_T=$(tok bad-version)
RELAY_T=$(tok below-min-relay)
BARE_T=$(tok bare-multisig)
OPRET_T=$(tok oversize-op_return)
CTRL_S="${STATUS[valid-control]}"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
# The valid-control MUST be accepted by clearbit (the funded input reaches the
# gate and the clean spend is relayable) — otherwise the harness itself is
# broken (e.g. sighash/funding wrong) and nothing else is trustworthy.
if [[ "$CTRL_S" != "ok" ]]; then
    fail "valid-control not accepted by clearbit (control=${CB_REASON[valid-control]:-rejected}); harness funding/signing broken — investigate before trusting other cases"
fi

# Report KNOB-GAPs (strict-only divergence; parity with default Core). These are
# NOT genuine-floor violations and do NOT fail the harness.
if [[ "${#KNOB_GAPS[@]}" -gt 0 ]]; then
    log "strict-flag-only divergences (clearbit matches DEFAULT Core; reject only under strict knobs): ${KNOB_GAPS[*]}"
    for c in "${KNOB_GAPS[@]}"; do
        log "  KNOB-GAP $c: STRICT-Core='${CORE_REASON[$c]}'  DEFAULT-Core=ACCEPT  clearbit=ACCEPT"
    done
fi

# A GENUINE HOLE (default Core ALSO rejects, clearbit accepts) is a real
# standardness bug on the must-reject floor. Per the brief we FAIL loudly +
# report it (never mask a hole to force green).
if [[ "${#GENUINE_HOLES[@]}" -gt 0 ]]; then
    log "GENUINE POLICY HOLES (STRICT & DEFAULT Core reject, clearbit ACCEPTS):"
    for c in "${GENUINE_HOLES[@]}"; do
        log "  BUG-HOLE $c: Core(strict & default)='${CORE_REASON[$c]}'  clearbit=ACCEPTED"
    done
    fail "clearbit accepts $(IFS=,; echo "${GENUINE_HOLES[*]}") that even DEFAULT Core rejects | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any category mismatch (both reject, different category) is also a failure.
MISM=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "mism" ]] && MISM+=("$c"); done
if [[ "${#MISM[@]}" -gt 0 ]]; then
    fail "reject-category mismatch on $(IFS=,; echo "${MISM[*]}") | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any over-rejection (Core accepts, clearbit rejects) is a failure too.
OVER=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "over" ]] && OVER+=("$c"); done
if [[ "${#OVER[@]}" -gt 0 ]]; then
    fail "clearbit over-rejects $(IFS=,; echo "${OVER[*]}") that Core accepts | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# No genuine holes, no mismatches, no over-rejections, control accepted.
[[ "$NORMALIZED_ANY" -eq 1 ]] && log "note: some cases matched via NORMALIZATION (category-level), not byte-exact strings"
[[ "${#KNOB_GAPS[@]}" -gt 0 ]] && log "note: ${#KNOB_GAPS[@]} case(s) pass as parity-with-default-Core (strict-flag-only gates)"
log "PASS: genuine floor {dust,version,min-relay} rejected + valid-control accepted; no genuine policy holes"
pass "$DUST_T" "$VER_T" "$RELAY_T" "$BARE_T" "$OPRET_T"
