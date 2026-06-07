#!/usr/bin/env bash
#
# beamchain_scantxoutset.sh — self-contained scantxoutset DIFFERENTIAL test.
#
# scantxoutset scans the CURRENT UTXO set for outputs matching one or more
# output descriptors and returns a deterministic snapshot of the matches. This
# harness pins beamchain's scantxoutset against Bitcoin Core (the box's REAL
# bitcoind) running on its own regtest oracle, sharing the IDENTICAL chain so
# the UTXO set — and therefore every matched unspent — is byte-for-byte the
# same on both nodes.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (own scratch datadir + RPC-only ports, -listen=0 via loopback
#   bind). The chain is built by beamchain (the authoritative miner) and
#   replayed into Core via submitblock so BOTH nodes have the identical UTXO
#   set. This is the same proven launch + oracle-convergence recipe as
#   test-suite/rawtx/beamchain_getrawtransaction.sh.
#
# WHY a differential is deterministic here: scantxoutset reads the FLUSHED
#   UTXO set at the current tip. Two nodes sharing the exact same chain have
#   the exact same UTXO set, so a scan for addr(<ADDR>) returns the same
#   coinbase outputs with the same txid/vout/amount and the same total_amount
#   on both. No wall-clock or per-node nondeterminism enters the result.
#
# Core semantics codified here (rpc/blockchain.cpp scantxoutset):
#   action='start' with scanobjects=[{"desc":"addr(<addr>)"}] or ["addr(<addr>)"]
#   -> OBJECT { success(bool), txouts(int total UTXOs scanned), height(int tip),
#      bestblock(hex), unspents(array of {txid,vout,scriptPubKey,desc,amount,
#      coinbase,height,blockhash,confirmations}), total_amount(BTC) }.
#   action='status' -> null when idle. action='abort' -> bool.
#
# The five sub-checks (mirroring the cell brief):
#   1. desc  : fund a known address (mine 101 coinbases to it), then
#              scantxoutset start [addr(<addr>)] on BOTH nodes; assert the
#              matched unspent SET (txid,vout,amount) is EQUAL to Core's.
#   2. amount: assert total_amount EQUALS Core's (8-decimal BTC string).
#   3. shape : result object has success + total_amount + unspents whose
#              members carry Core's per-unspent keys (txid,vout,scriptPubKey,
#              amount,coinbase,height present; any key Core emits that beamchain
#              omits is reported as a divergence, not papered over).
#   4. empty : scantxoutset start for an UNFUNDED address -> total_amount 0,
#              empty unspents, success=true on BOTH nodes.
#   5. status/abort: action='status' -> null; action='abort' -> bool (sanity).
#
# STRICT UNIFORM INTERFACE (mirrors the sibling getrawtransaction harness):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: SCANTXOUTSET beamchain: PASS desc=ok amount=ok shape=ok empty=ok
#   FAIL: SCANTXOUTSET beamchain: FAIL <short reason>
#   SKIP: SCANTXOUTSET beamchain: FAIL beamchain release binary not found ...
#         (GAP_RE-compatible 'not found' so the runner can SKIP a missing impl)
#
# Touches ONLY /tmp/scan-beamchain{,-core}/ and ports 40216/40236 (beamchain
#   RPC/P2P) + 40218/40238 (Core RPC/P2P). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr)

BC_DATADIR="/tmp/scan-beamchain"
BC_RPC=40216
BC_P2P=40236
BC_LOG="$BC_DATADIR/node.log"

CORE_DATADIR="/tmp/scan-beamchain-core"
CORE_RPC=40218
CORE_P2P=40238
CORE_LOG="$CORE_DATADIR/core.log"

# Fixed deterministic test secret -> one p2wpkh regtest address the coinbases
# are mined to on BOTH nodes (so the coinbase txs — and the resulting UTXOs —
# are byte-identical).
SECRET="3333333333333333333333333333333333333333333333333333333333333333"
# A SECOND, never-funded secret -> the "empty scan" address.
SECRET2="4444444444444444444444444444444444444444444444444444444444444444"

NBLOCKS=101            # mine 101 blocks; coinbase[0..100] all pay ADDR

BC_PID=""
BC_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[scantxoutset:beamchain] $*" >&2; }

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
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
# pass <desc> <amount> <shape> <empty>
pass() {
    echo "SCANTXOUTSET beamchain: PASS desc=$1 amount=$2 shape=$3 empty=$4"
    exit 0
}
fail() {
    echo "SCANTXOUTSET beamchain: FAIL $*"
    exit 1
}

# ── JSON helpers (jq-free: pure python3, deterministic). ──────────────────
# unwrap a {result:..} envelope OR a bare value to the inner result.
# jget <json> <key>  -> top-level value of the result object, or ""
jget() {
    python3 - "$1" "$2" <<'PYEOF'
import sys, json
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
if isinstance(obj, dict) and "result" in obj and obj.get("error") is None:
    obj = obj["result"]
k = sys.argv[2]
if isinstance(obj, dict) and k in obj and obj[k] is not None:
    v = obj[k]
    print("true" if v is True else "false" if v is False else v)
PYEOF
}
# jhas <json> <key>  -> exit 0 if key present + non-null
jhas() {
    python3 - "$1" "$2" <<'PYEOF'
import sys, json
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
if isinstance(obj, dict) and "result" in obj and obj.get("error") is None:
    obj = obj["result"]
k = sys.argv[2]
sys.exit(0 if (isinstance(obj, dict) and k in obj and obj[k] is not None) else 1)
PYEOF
}
# jerr <json>  -> prints JSON-RPC error code (int) or "" if no error
jerr() {
    python3 - "$1" <<'PYEOF'
import sys, json
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
e = obj.get("error") if isinstance(obj, dict) else None
if isinstance(e, dict) and "code" in e:
    print(e["code"])
PYEOF
}
# jresult <json>  -> the bare result value (string), or "" if error/none
jresult() {
    python3 - "$1" <<'PYEOF'
import sys, json
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
if isinstance(obj, dict) and obj.get("error") is not None:
    sys.exit(0)
r = obj.get("result") if isinstance(obj, dict) else None
if r is None:
    sys.exit(0)
print(r if isinstance(r, str) else json.dumps(r))
PYEOF
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
fuser -k "${BC_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${BC_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
# GAP_RE-compatible 'not found' message lets the runner SKIP a missing impl.
[[ -x "$NODE_BIN" ]]                 || fail "beamchain release binary not found at $NODE_BIN (run rebar3 as prod release)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# Derive the two regtest p2wpkh addresses from the fixed secrets.
ADDR=$(python3 - "$TF_PATH" "$SECRET" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k = ECKey(); k.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
PYEOF
) || fail "failed to derive funded regtest address from test_framework"
[[ -n "$ADDR" ]] || fail "derived empty funded regtest address"

ADDR_EMPTY=$(python3 - "$TF_PATH" "$SECRET2" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k = ECKey(); k.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
PYEOF
) || fail "failed to derive empty regtest address from test_framework"
[[ -n "$ADDR_EMPTY" ]] || fail "derived empty unfunded regtest address"
[[ "$ADDR" != "$ADDR_EMPTY" ]] || fail "funded and empty addresses collided"
log "funded address: $ADDR ; empty address: $ADDR_EMPTY"

# ── Core readiness poll. ───────────────────────────────────────────────────
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

# ── 2. Launch the Core regtest oracle (loopback P2P bind). ────────────────
# The sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener ~2s after
# load; a LOOPBACK bind (127.0.0.1) is fine. Wrapped in a small retry loop to
# ride out a transient sandbox kill at startup.
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -bind="127.0.0.1:$CORE_P2P" -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    wait_core_ready "$CORE_DATADIR" "$CORE_RPC" "$CORE_BG" "$CORE_LOG"
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=127.0.0.1:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || fail "Core oracle failed to start after 3 attempts (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch beamchain on regtest (release binary, foreground). ──────────
cat >"$BC_DATADIR/sys.config" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$BC_DATADIR"},
   {p2pport, $BC_P2P},
   {rpcport, $BC_RPC},
   {txindex, "1"}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$BC_DATADIR/vm.args" <<ERLVM
-sname beamchain_scanref_$$
-setcookie beamchain_scanref
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
RELX_CONFIG_PATH="$BC_DATADIR/sys.config" VMARGS_PATH="$BC_DATADIR/vm.args" \
    BEAMCHAIN_TXINDEX=1 \
    "$NODE_BIN" foreground >"$BC_LOG" 2>&1 &
BC_PID=$!
log "beamchain pid=$BC_PID"
bc_deadline=$(( $(date +%s) + 90 ))   # generous startup wait
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

# ── RPC helpers. ───────────────────────────────────────────────────────────
bc_rpc() {  # bc_rpc <method> [params-json]
    local method="$1" params="${2:-[]}"
    curl -s --max-time 300 -u "$BC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$BC_RPC/" 2>/dev/null
}
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>/dev/null; }

# ── 4. Build ONE shared chain: beamchain mines, Core ingests via submitblock.
# beamchain mines $NBLOCKS blocks to $ADDR (a p2wpkh), each raw block replayed
# into Core via submitblock. Both nodes converge on the identical chain ->
# identical UTXO set -> identical scantxoutset results.
log "mining $NBLOCKS blocks to $ADDR on beamchain (the authoritative miner)"
mr=$(bc_rpc generatetoaddress "[$NBLOCKS, \"$ADDR\"]")
echo "$mr" | grep -q '"result"' || fail "beamchain generatetoaddress failed: $mr"
BC_H=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('result',''))" <<<"$(bc_rpc getblockcount)")
[[ "$BC_H" == "$NBLOCKS" ]] || fail "beamchain height $BC_H != expected $NBLOCKS"

log "replaying beamchain's $NBLOCKS blocks into Core via submitblock (single pass)"
REPLAY_OUT=$(python3 - "$BC_RPC" "$BC_COOKIE" "$CORE_RPC" "$CORE_DATADIR" "$NBLOCKS" "$CORE_CLI" <<'PYEOF'
import sys, json, urllib.request, base64, subprocess
bc_rpc_port, bc_cookie, core_rpc, core_dd, nblocks, core_cli = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6])

def bc(method, params):
    body = json.dumps({"jsonrpc":"1.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{bc_rpc_port}/", data=body)
    tok = base64.b64encode(bc_cookie.encode()).decode()
    req.add_header("Authorization", f"Basic {tok}")
    with urllib.request.urlopen(req, timeout=120) as r:
        o = json.loads(r.read())
    if o.get("error"):
        raise RuntimeError(f"beamchain {method} error: {o['error']}")
    return o["result"]

def core(*args):
    return subprocess.run(
        [core_cli, "-regtest", f"-datadir={core_dd}", f"-rpcport={core_rpc}", *args],
        capture_output=True, text=True)

for h in range(1, nblocks + 1):
    bh = bc("getblockhash", [h])
    raw = bc("getblock", [bh, 0])
    if not raw:
        print(f"ERR empty raw at height {h}"); sys.exit(1)
    res = core("submitblock", raw)
    out = (res.stdout or "").strip()
    if out and out not in ("null", "duplicate"):
        print(f"ERR Core rejected block {h} ({bh}): '{out}' stderr={res.stderr.strip()}")
        sys.exit(1)
print("REPLAY_OK")
PYEOF
)
echo "$REPLAY_OUT" | grep -q "REPLAY_OK" || fail "block replay failed: $REPLAY_OUT"
CORE_H=$(core_cli getblockcount)
[[ "$CORE_H" == "$NBLOCKS" ]] || fail "Core height $CORE_H != expected $NBLOCKS after replay"
CORE_TIP=$(core_cli getbestblockhash)
BC_TIP=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read())['result'])" <<<"$(bc_rpc getbestblockhash)")
[[ "$CORE_TIP" == "$BC_TIP" ]] \
    || fail "post-replay tip mismatch: Core=$CORE_TIP beam=$BC_TIP (replay did not converge)"
log "both nodes share the identical chain at height $NBLOCKS (tip $CORE_TIP)"

# ── 5. Run scantxoutset start [addr(ADDR)] on BOTH nodes. ─────────────────
DESC="addr($ADDR)"
log "scanning UTXO set for descriptor: $DESC"

# Core: scanobjects passed as a JSON array of descriptor strings.
CORE_SCAN=$(core_cli scantxoutset start "[\"$DESC\"]")
[[ -n "$CORE_SCAN" ]] || fail "Core scantxoutset returned empty"
# beamchain: same param shape over JSON-RPC.
BC_SCAN=$(bc_rpc scantxoutset "[\"start\", [\"$DESC\"]]")
bc_ec=$(jerr "$BC_SCAN")
[[ -z "$bc_ec" ]] || fail "beamchain scantxoutset errored (code $bc_ec): $BC_SCAN"

# Both must report success=true.
[[ "$(jget "$BC_SCAN" success)" == "true" ]] || fail "beamchain scan success != true"
# Core CLI returns the bare object (no envelope).
CORE_SUCCESS=$(python3 -c "import sys,json;print(json.load(sys.stdin).get('success'))" <<<"$CORE_SCAN")
[[ "$CORE_SUCCESS" == "True" ]] || fail "Core scan success != true (got $CORE_SUCCESS)"

# ── 6. SUB-CHECK 2 (amount): total_amount EQUALS Core's, exactly. ─────────
AMOUNT_T="ok"
CORE_TOTAL=$(python3 -c "import sys,json;print(json.load(sys.stdin)['total_amount'])" <<<"$CORE_SCAN")
BC_TOTAL=$(jget "$BC_SCAN" total_amount)
[[ -n "$BC_TOTAL" ]] || fail "beamchain scan missing total_amount"
# Compare as floats AND as the canonical 8-decimal string. The coinbase reward
# is 50 BTC/block on regtest pre-halving; 101 coinbases all pay ADDR.
python3 - "$CORE_TOTAL" "$BC_TOTAL" <<'PYEOF' || fail "total_amount mismatch: beam=$BC_TOTAL core=$CORE_TOTAL"
import sys
c, b = sys.argv[1], sys.argv[2]
if abs(float(c) - float(b)) > 1e-9:
    sys.exit(1)
# also require Core's exact 8-decimal string form (sentinel parity)
if f"{float(c):.8f}" != f"{float(b):.8f}":
    sys.exit(1)
PYEOF
log "total_amount byte-exact vs Core: $BC_TOTAL"

# ── 7. SUB-CHECK 1 (desc): matched unspent SET (txid,vout,amount) == Core. ─
DESC_T="ok"
SET_RESULT=$(python3 - "$CORE_SCAN" "$BC_SCAN" <<'PYEOF'
import sys, json

def unwrap(s):
    o = json.loads(s)
    if isinstance(o, dict) and "result" in o and o.get("error") is None:
        return o["result"]
    return o

core = unwrap(sys.argv[1])
beam = unwrap(sys.argv[2])

cu = core.get("unspents") or []
bu = beam.get("unspents") or []

if len(cu) != len(bu):
    print(f"FAIL unspents length beam={len(bu)} core={len(cu)}")
    sys.exit(0)
if len(cu) == 0:
    print("FAIL core scan matched zero unspents (test would be vacuous)")
    sys.exit(0)

def key(u):
    # canonicalize amount to 8-decimal BTC string to dodge float/str drift
    amt = u.get("amount")
    try:
        amt = f"{float(amt):.8f}"
    except Exception:
        amt = str(amt)
    return (u.get("txid"), u.get("vout"), amt)

cset = sorted(key(u) for u in cu)
bset = sorted(key(u) for u in bu)
if cset != bset:
    # find the first divergent member for a precise message
    cs, bs = set(cset), set(bset)
    only_core = sorted(cs - bs)[:3]
    only_beam = sorted(bs - cs)[:3]
    print(f"FAIL unspent (txid,vout,amount) set differs; only_core={only_core} only_beam={only_beam}")
    sys.exit(0)

# also: every matched unspent's scriptPubKey must equal Core's for the same outpoint
cmap = {(u.get("txid"), u.get("vout")): u for u in cu}
for u in bu:
    k = (u.get("txid"), u.get("vout"))
    cspk = cmap[k].get("scriptPubKey")
    bspk = u.get("scriptPubKey")
    if cspk != bspk:
        print(f"FAIL scriptPubKey mismatch at {k}: beam={bspk} core={cspk}")
        sys.exit(0)
    # coinbase + height must agree too (load-bearing for a coinbase scan)
    if u.get("coinbase") != cmap[k].get("coinbase"):
        print(f"FAIL coinbase flag mismatch at {k}: beam={u.get('coinbase')} core={cmap[k].get('coinbase')}")
        sys.exit(0)
    if u.get("height") != cmap[k].get("height"):
        print(f"FAIL height mismatch at {k}: beam={u.get('height')} core={cmap[k].get('height')}")
        sys.exit(0)
print(f"OK matched={len(bu)}")
PYEOF
)
case "$SET_RESULT" in
    OK*)   log "matched unspent set (txid,vout,amount,scriptPubKey,coinbase,height) == Core ($SET_RESULT)" ;;
    *)     fail "unspent set: ${SET_RESULT#FAIL }" ;;
esac

# ── 8. SUB-CHECK 3 (shape): top-level + per-unspent keys vs Core. ─────────
SHAPE_T="ok"
# Top-level keys Core emits for action=start.
for fld in success txouts height bestblock unspents total_amount; do
    jhas "$BC_SCAN" "$fld" || fail "shape: top-level field '$fld' missing on beamchain"
done
# bestblock must equal the shared tip; height must equal NBLOCKS.
[[ "$(jget "$BC_SCAN" bestblock)" == "$CORE_TIP" ]] || fail "shape: bestblock != shared tip"
[[ "$(jget "$BC_SCAN" height)" == "$NBLOCKS" ]] || fail "shape: height != $NBLOCKS"
# txouts must be a positive int (total UTXOs scanned; >= matched count).
BC_TXOUTS=$(jget "$BC_SCAN" txouts)
[[ "$BC_TXOUTS" =~ ^[0-9]+$ ]] || fail "shape: txouts not an int: $BC_TXOUTS"
(( BC_TXOUTS >= 1 )) || fail "shape: txouts=$BC_TXOUTS not positive"

# Per-unspent keys: assert beamchain carries the Core keys we depend on, and
# REPORT (do not paper over) any Core per-unspent key that beamchain omits.
SHAPE_RESULT=$(python3 - "$CORE_SCAN" "$BC_SCAN" <<'PYEOF'
import sys, json

def unwrap(s):
    o = json.loads(s)
    if isinstance(o, dict) and "result" in o and o.get("error") is None:
        return o["result"]
    return o

core = unwrap(sys.argv[1])
beam = unwrap(sys.argv[2])

# Core's per-unspent keys (rpc/blockchain.cpp): blockhash/confirmations are
# present on every match; desc is a specialized inferred descriptor string.
CORE_REQUIRED = {"txid", "vout", "scriptPubKey", "amount", "coinbase", "height"}

cu0 = (core.get("unspents") or [None])[0]
bu0 = (beam.get("unspents") or [None])[0]
if cu0 is None or bu0 is None:
    print("FAIL no unspents to shape-check"); sys.exit(0)

ckeys, bkeys = set(cu0.keys()), set(bu0.keys())

# 1) beamchain must carry the load-bearing keys.
missing_required = sorted(CORE_REQUIRED - bkeys)
if missing_required:
    print(f"FAIL beamchain unspent missing required key(s): {missing_required}")
    sys.exit(0)

# 2) report (as a hard FAIL — this is a real shape divergence) any key Core
#    emits per-unspent that beamchain does NOT. The brief says "unspents with
#    Core's keys"; a missing Core key is a genuine finding.
core_extra = sorted(ckeys - bkeys)
if core_extra:
    print(f"DIVERGENCE beamchain omits Core per-unspent key(s): {core_extra} ; "
          f"beam_keys={sorted(bkeys)} core_keys={sorted(ckeys)}")
    sys.exit(0)

print(f"OK keys={sorted(bkeys)}")
PYEOF
)
case "$SHAPE_RESULT" in
    OK*)         log "per-unspent shape == Core ($SHAPE_RESULT)" ;;
    DIVERGENCE*) fail "shape divergence: ${SHAPE_RESULT#DIVERGENCE }" ;;
    *)           fail "shape: ${SHAPE_RESULT#FAIL }" ;;
esac

# ── 9. SUB-CHECK 4 (empty): unfunded address -> 0 / [] on BOTH nodes. ─────
EMPTY_T="ok"
DESC_EMPTY="addr($ADDR_EMPTY)"
log "scanning UTXO set for UNFUNDED descriptor: $DESC_EMPTY"
CORE_EMPTY=$(core_cli scantxoutset start "[\"$DESC_EMPTY\"]")
BC_EMPTY=$(bc_rpc scantxoutset "[\"start\", [\"$DESC_EMPTY\"]]")
bc_ec=$(jerr "$BC_EMPTY")
[[ -z "$bc_ec" ]] || fail "empty: beamchain scan errored (code $bc_ec): $BC_EMPTY"

# Core: total_amount 0, empty unspents, success true.
CORE_E_TOTAL=$(python3 -c "import sys,json;o=json.load(sys.stdin);print(o['total_amount'])" <<<"$CORE_EMPTY")
CORE_E_LEN=$(python3 -c "import sys,json;o=json.load(sys.stdin);print(len(o.get('unspents') or []))" <<<"$CORE_EMPTY")
[[ "$(python3 -c "print(abs(float('$CORE_E_TOTAL'))<1e-9)")" == "True" ]] || fail "empty: Core total_amount != 0 (got $CORE_E_TOTAL)"
[[ "$CORE_E_LEN" == "0" ]] || fail "empty: Core unspents not empty (len=$CORE_E_LEN)"

# beamchain: same.
[[ "$(jget "$BC_EMPTY" success)" == "true" ]] || fail "empty: beamchain success != true"
BC_E_TOTAL=$(jget "$BC_EMPTY" total_amount)
[[ "$(python3 -c "print(abs(float('$BC_E_TOTAL'))<1e-9)")" == "True" ]] || fail "empty: beamchain total_amount != 0 (got $BC_E_TOTAL)"
BC_E_LEN=$(python3 - "$BC_EMPTY" <<'PYEOF'
import sys, json
o = json.loads(sys.argv[1])
if isinstance(o, dict) and "result" in o and o.get("error") is None:
    o = o["result"]
print(len(o.get("unspents") or []))
PYEOF
)
[[ "$BC_E_LEN" == "0" ]] || fail "empty: beamchain unspents not empty (len=$BC_E_LEN)"
log "empty scan: both nodes -> total_amount 0, empty unspents, success=true"

# ── 10. SUB-CHECK 5 (status/abort sanity): status->null, abort->bool. ─────
# Core: status is null when idle; abort returns a bool. Mirror on beamchain.
CORE_STATUS=$(core_cli scantxoutset status)
# bitcoin-cli prints an empty line for a JSON null result.
[[ -z "$CORE_STATUS" || "$CORE_STATUS" == "null" ]] || fail "status: Core idle status not null (got '$CORE_STATUS')"
BC_STATUS=$(bc_rpc scantxoutset "[\"status\"]")
BC_STATUS_R=$(python3 - "$BC_STATUS" <<'PYEOF'
import sys, json
o = json.loads(sys.argv[1])
if isinstance(o, dict) and "result" in o and o.get("error") is None:
    print("null" if o["result"] is None else json.dumps(o["result"]))
PYEOF
)
[[ "$BC_STATUS_R" == "null" ]] || fail "status: beamchain idle status not null (got '$BC_STATUS_R')"

BC_ABORT=$(bc_rpc scantxoutset "[\"abort\"]")
BC_ABORT_R=$(python3 - "$BC_ABORT" <<'PYEOF'
import sys, json
o = json.loads(sys.argv[1])
r = o.get("result") if isinstance(o, dict) else None
print("true" if r is True else "false" if r is False else f"NONBOOL:{r}")
PYEOF
)
[[ "$BC_ABORT_R" == "true" || "$BC_ABORT_R" == "false" ]] \
    || fail "status: beamchain abort did not return a bool (got '$BC_ABORT_R')"
log "status->null + abort->bool sanity ok"

# ── 11. Verdict. ──────────────────────────────────────────────────────────
log "PASS: total_amount + matched unspent set (txid,vout,amount,scriptPubKey,coinbase,height) byte-exact vs Core; shape carries Core's load-bearing keys; empty scan -> 0/[] on both"
pass "$DESC_T" "$AMOUNT_T" "$SHAPE_T" "$EMPTY_T"
