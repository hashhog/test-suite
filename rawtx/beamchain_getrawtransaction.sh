#!/usr/bin/env bash
#
# beamchain_getrawtransaction.sh — self-contained getrawtransaction DIFFERENTIAL test.
#
# The next RPC-surface/indexing green-cell after getindexinfo (the flagged
# follow-up "txindex on but getrawtransaction fails"). getrawtransaction is a
# block-explorer keystone: it must match Bitcoin Core EXACTLY on the raw-hex
# serialization (verbosity 0) and on the load-bearing decoded fields
# (verbosity 1), and must reproduce Core's error contract (-5 for the
# genesis coinbase + unknown txids).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (own scratch datadir + RPC-only ports, -listen=0 -txindex=1).
#
# WHY a differential works byte-exact here: on a FRESH regtest chain, two
#   independent nodes mining EMPTY blocks to the SAME address produce
#   byte-identical coinbase transactions (the coinbase carries the BIP34
#   height + the fixed miner output + the all-zero witness reserved value;
#   no wall-clock enters the coinbase tx itself). Verified empirically: the
#   height-1 coinbase txid + raw hex are identical across two cold Core
#   regtest nodes. So a tx that SPENDS the height-1 coinbase, built + signed
#   deterministically (Core test_framework, no wallet needed — this bitcoind
#   has "no wallet support compiled in"), is byte-identical on both chains
#   and can be injected into BOTH mempools via sendrawtransaction.
#
# The four sub-checks (mirroring the cell brief):
#   1. MEMPOOL  : getrawtransaction <txid> 0  (hex byte-EXACT vs Core)
#                 getrawtransaction <txid> 1  (decoded — txid, hash, version,
#                 size, vsize, weight, locktime, vin{txid,vout,sequence,
#                 scriptSig.hex}, vout{value,n,scriptPubKey.hex,.type,
#                 .address?}, top-level hex ALL EXACT; asm/desc PRESENT but
#                 NOT required byte-equal).
#   2. CONFIRMED via blockhash arg: mine the tx, then
#                 getrawtransaction <txid> 1 <blockhash> — blockhash matches,
#                 confirmations >= 1, in_active_chain == true, time/blocktime
#                 present.
#   3. ERRORS   : a random 32-byte txid -> -5; the genesis-coinbase txid -> -5.
#   4. TXINDEX  : (beamchain defaults txindex ON) getrawtransaction <txid> 1
#                 with NO blockhash on a CONFIRMED tx -> succeeds.
#
# Core semantics codified here (rpc/rawtransaction.cpp + core_io.cpp TxToUniv):
#   - verbosity 0 -> EncodeHexTx (TX_WITH_WITNESS) hex string
#   - verbosity 1 -> {txid, hash(wtxid), version, size, vsize, weight,
#     locktime, vin[], vout[], hex, +blockhash/confirmations/time/blocktime
#     when confirmed, +in_active_chain when a blockhash arg was given}
#   - genesis-block coinbase txid (== genesis merkle root) -> RPC -5 with a
#     dedicated message ("not considered an ordinary transaction")
#   - unknown txid -> RPC -5 ("No such mempool ... transaction")
#   - bad blockhash arg -> RPC -5 ("Block hash not found")
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/beamchain_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETRAWTRANSACTION beamchain: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   FAIL: GETRAWTRANSACTION beamchain: FAIL <short reason>
#
# Touches ONLY /tmp/grt-beamchain{,-core}/ and ports 22016/22036 (beamchain
#   RPC/P2P) + 22018/22038 (Core RPC/P2P). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx/sign)

BC_DATADIR="/tmp/grt-beamchain"
BC_RPC=22016
BC_P2P=22036
BC_LOG="$BC_DATADIR/node.log"

CORE_DATADIR="/tmp/grt-beamchain-core"
CORE_RPC=22018
CORE_P2P=22038
CORE_LOG="$CORE_DATADIR/core.log"

# Fixed deterministic test secret -> one p2wpkh regtest address the coinbases
# are mined to on BOTH nodes (so the coinbase txs are byte-identical), and the
# key that signs the spend.
SECRET="2222222222222222222222222222222222222222222222222222222222222222"

NBLOCKS=101            # mine 101 blocks so the height-1 coinbase is mature
# Spend nearly the whole coinbase, leaving a SMALL fee (1000 sats). A large fee
# would trip Core's default maxfeerate (0.10 BTC/kvB ~= 1920 sats for this
# ~192-vB tx) and be rejected with max-fee-exceeded. SPEND_SATS is derived from
# the actual coinbase value at runtime (see section 5).
FEE_SATS=1000

BC_PID=""
BC_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getrawtransaction:beamchain] $*" >&2; }

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
# NB: Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.
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
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <decoded> <confirmed> <errors>
pass() {
    echo "GETRAWTRANSACTION beamchain: PASS hex=$1 decoded=$2 confirmed=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION beamchain: FAIL $*"
    exit 1
}

# ── JSON helpers (jq-free: pure python3, deterministic). ──────────────────
# jget <json> <key>  -> top-level value of a {result:...} or bare object, or ""
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
# Abort if our fixed ports are still LISTENING (port-kills banned — 2026-06-10 incident).
log "resetting scratch state"
if ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BC_RPC}/${BC_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "beamchain release binary not found at $NODE_BIN (run rebar3 as prod release)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# Derive the shared regtest p2wpkh mining address from the fixed secret.
ADDR=$(python3 - "$TF_PATH" "$SECRET" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k = ECKey(); k.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
PYEOF
) || fail "failed to derive regtest address from test_framework"
[[ -n "$ADDR" ]] || fail "derived empty regtest address"
log "mining/spend address: $ADDR"

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

# ── 2. Launch the Core regtest oracle (loopback P2P bind, txindex on). ────
# The sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener ~2s after
# load; a LOOPBACK bind (127.0.0.1) is fine (this is the proven recipe used by
# the sibling chaintxstats harness). We still pass -txindex=1 so the Core
# oracle can serve getrawtransaction without a blockhash arg. Launch is wrapped
# in a small retry loop (mirrors haskoin_chaintxstats.sh) to ride out a
# transient sandbox kill at startup.
launch_core_once() {
    # PID-scoped stop of OUR previous attempt (port-kill removed: 2026-06-10 fuser incident).
    if [[ -n "${CORE_BG:-}" ]]; then
        kill "$CORE_BG" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CORE_BG" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_BG" 2>/dev/null || true
    fi
    for __hp in "${CORE_RPC}" "${CORE_P2P}"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -bind="127.0.0.1:$CORE_P2P" -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    wait_core_ready "$CORE_DATADIR" "$CORE_RPC" "$CORE_BG" "$CORE_LOG"
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=127.0.0.1:$CORE_P2P (txindex=1, attempt $attempt)"
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
-sname beamchain_grtref_$$
-setcookie beamchain_grtref
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
    curl -s --max-time 90 -u "$BC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$BC_RPC/" 2>/dev/null
}
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>/dev/null; }

# ── 4. Build ONE shared chain: beamchain mines, Core ingests via submitblock.
# Core and beamchain have DIFFERENT coinbase miners (beamchain mines a
# legacy single-output coinbase; Core mines a segwit coinbase with a witness
# commitment), so two independently-mined chains never share a coinbase. To
# get a tx that is byte-identical AND spendable on BOTH nodes, we make the two
# nodes share the EXACT SAME chain: beamchain mines $NBLOCKS blocks to $ADDR
# (a p2wpkh we hold the key for), then each raw block is replayed into Core via
# submitblock. Regtest PoW is trivial and the blocks are fully valid, so Core
# accepts beamchain's chain verbatim — identical coinbases + identical UTXOs.
log "mining $NBLOCKS blocks to $ADDR on beamchain (the authoritative miner)"
mr=$(bc_rpc generatetoaddress "[$NBLOCKS, \"$ADDR\"]")
echo "$mr" | grep -q '"result"' || fail "beamchain generatetoaddress failed: $mr"
BC_H=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('result',''))" <<<"$(bc_rpc getblockcount)")
[[ "$BC_H" == "$NBLOCKS" ]] || fail "beamchain height $BC_H != expected $NBLOCKS"

# The replay runs in ONE python process (talking directly to both RPC sockets)
# to avoid spawning ~4 subprocesses per block over $NBLOCKS iterations — the
# bash-loop version churned enough short-lived python/curl procs to trip the
# sandbox's resource killer mid-run.
log "replaying beamchain's $NBLOCKS blocks into Core via submitblock (single pass)"
REPLAY_OUT=$(python3 - "$BC_RPC" "$BC_COOKIE" "$CORE_RPC" "$CORE_DATADIR" "$NBLOCKS" "$CORE_CLI" <<'PYEOF'
import sys, json, urllib.request, base64, subprocess, os
bc_rpc_port, bc_cookie, core_rpc, core_dd, nblocks, CORE_CLI = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6])
# CORE_CLI arrives as argv[6] on purpose. This heredoc is <<'PYEOF' (quoted), so
# the shell does NOT expand it -- a literal "${HASHHOG_ROOT}/..." written here is
# passed to subprocess verbatim and raises FileNotFoundError. Keep the quoting
# (Python must not be shell-expanded) and pass shell values as arguments.
if not os.path.isfile(CORE_CLI):
    print(f"REPLAY_FAIL bitcoin-cli not found at {CORE_CLI}")
    sys.exit(0)

def bc(method, params):
    body = json.dumps({"jsonrpc":"1.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{bc_rpc_port}/", data=body)
    tok = base64.b64encode(bc_cookie.encode()).decode()
    req.add_header("Authorization", f"Basic {tok}")
    with urllib.request.urlopen(req, timeout=90) as r:
        o = json.loads(r.read())
    if o.get("error"):
        raise RuntimeError(f"beamchain {method} error: {o['error']}")
    return o["result"]

def core(*args):
    return subprocess.run(
        [CORE_CLI, "-regtest", f"-datadir={core_dd}", f"-rpcport={core_rpc}", *args],
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
# The tips must now be the identical block hash.
CORE_TIP=$(core_cli getbestblockhash)
BC_TIP=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read())['result'])" <<<"$(bc_rpc getbestblockhash)")
[[ "$CORE_TIP" == "$BC_TIP" ]] \
    || fail "post-replay tip mismatch: Core=$CORE_TIP beam=$BC_TIP (replay did not converge)"
log "both nodes share the identical chain at height $NBLOCKS (tip $CORE_TIP)"

# ── 5. Resolve the height-1 coinbase (now identical on both nodes). ───────
H1_CORE=$(core_cli getblockhash 1)
H1_BC=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('result',''))" <<<"$(bc_rpc getblockhash "[1]")")
CB_TXID=$(core_cli getblock "$H1_CORE" | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])")
CB_TXID_BC=$(python3 -c "import sys,json; r=json.loads(sys.stdin.read())['result']; print(r['tx'][0])" <<<"$(bc_rpc getblock "[\"$H1_BC\",1]")")
log "height-1 coinbase txid: Core=$CB_TXID beam=$CB_TXID_BC"
[[ "$CB_TXID" == "$CB_TXID_BC" ]] \
    || fail "height-1 coinbase txid differs across nodes (Core=$CB_TXID beam=$CB_TXID_BC) — chain shape diverged"

# Coinbase output 0 value + scriptPubKey — read from Core. We MUST spend the
# exact output that the coinbase actually pays (beamchain's coinbase output 0).
CB_INFO=$(core_cli getrawtransaction "$CB_TXID" 1 "$H1_CORE")
CB_VALUE_SATS=$(python3 -c "import sys,json; o=json.load(sys.stdin)['vout'][0]['value']; print(round(o*1e8))" <<<"$CB_INFO")
CB_SPK_HEX=$(python3 -c "import sys,json; print(json.load(sys.stdin)['vout'][0]['scriptPubKey']['hex'])" <<<"$CB_INFO")
[[ -n "$CB_VALUE_SATS" ]] || fail "could not read coinbase output value"
SPEND_SATS=$(( CB_VALUE_SATS - FEE_SATS ))
(( SPEND_SATS > 0 )) || fail "computed non-positive spend amount"
log "coinbase[0] value = $CB_VALUE_SATS sats, scriptPubKey = $CB_SPK_HEX, spend=$SPEND_SATS (fee=$FEE_SATS)"

# ── 6. Build + sign a deterministic spend of the height-1 coinbase. ───────
# Spend coinbase output 0 (p2wpkh) -> a single p2wpkh output back to ADDR,
# leaving (CB_VALUE - SPEND_SATS) as fee. Signed with the fixed key via the
# Core test_framework (no wallet needed). Identical hex on both chains.
SIGNED_HEX=$(python3 - "$TF_PATH" "$SECRET" "$CB_TXID" "$CB_VALUE_SATS" "$SPEND_SATS" "$CB_SPK_HEX" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.messages import (CTransaction, CTxIn, CTxOut, COutPoint,
                                      CTxInWitness, COIN)
from test_framework.script import (CScript, SegwitV0SignatureHash, SIGHASH_ALL,
                                   hash160)
from test_framework.script_util import key_to_p2wpkh_script, key_to_p2pkh_script

secret    = bytes.fromhex(sys.argv[2])
cb_txid   = sys.argv[3]              # display-order hex
cb_value  = int(sys.argv[4])        # sats
spend_amt = int(sys.argv[5])        # sats
cb_spk    = sys.argv[6]             # coinbase out 0 scriptPubKey hex

k = ECKey(); k.set(secret, compressed=True)
pub = k.get_pubkey().get_bytes()

spk = key_to_p2wpkh_script(pub)     # the p2wpkh scriptPubKey we own (coinbase out 0)
# Guard: the coinbase output 0 we are spending MUST be our p2wpkh (mined to ADDR).
if spk.hex() != cb_spk:
    sys.stderr.write(f"coinbase out0 spk {cb_spk} != our p2wpkh {spk.hex()}\n")
    sys.exit(3)

tx = CTransaction()
tx.version = 2
# prevout: coinbase txid (display hex -> internal int), vout 0
prev_int = int(cb_txid, 16)
tx.vin = [CTxIn(COutPoint(prev_int, 0), CScript(), 0xffffffff)]
tx.vout = [CTxOut(spend_amt, key_to_p2wpkh_script(pub))]
tx.wit.vtxinwit = [CTxInWitness()]
tx.nLockTime = 0

# BIP143 scriptCode for p2wpkh = the classic p2pkh script of the pubkey hash.
script_code = key_to_p2pkh_script(pub)
sighash = SegwitV0SignatureHash(script_code, tx, 0, SIGHASH_ALL, cb_value)
sig = k.sign_ecdsa(sighash) + bytes([SIGHASH_ALL])
tx.wit.vtxinwit[0].scriptWitness.stack = [sig, pub]

print(tx.serialize_with_witness().hex())
PYEOF
) || fail "tx build/sign failed"
[[ -n "$SIGNED_HEX" ]] || fail "empty signed tx hex"
log "signed spend hex (${#SIGNED_HEX} chars)"

# The expected txid (from Core's decode) — both nodes will compute the same.
SPEND_TXID=$(core_cli decoderawtransaction "$SIGNED_HEX" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['txid'])")
[[ -n "$SPEND_TXID" ]] || fail "could not decode signed tx to obtain txid"
log "spend txid = $SPEND_TXID"

# ── 7. Inject the SAME tx into BOTH mempools. ─────────────────────────────
CORE_SENT=$(core_cli sendrawtransaction "$SIGNED_HEX")
[[ "$CORE_SENT" == "$SPEND_TXID" ]] \
    || fail "Core sendrawtransaction did not return expected txid (got '$CORE_SENT')"
BC_SENT_RAW=$(bc_rpc sendrawtransaction "[\"$SIGNED_HEX\"]")
BC_SENT=$(jresult "$BC_SENT_RAW")
[[ "$BC_SENT" == "$SPEND_TXID" ]] \
    || fail "beamchain sendrawtransaction did not accept the tx (got '$BC_SENT_RAW')"
log "tx in both mempools"

# ── 8. SUB-CHECK 1a: MEMPOOL verbosity 0 — hex byte-EXACT vs Core. ────────
HEX_T="ok"
CORE_HEX0=$(core_cli getrawtransaction "$SPEND_TXID" 0)
BC_HEX0=$(jresult "$(bc_rpc getrawtransaction "[\"$SPEND_TXID\", 0]")")
[[ -n "$CORE_HEX0" ]] || fail "Core verbosity-0 returned empty"
[[ -n "$BC_HEX0" ]]   || fail "beamchain verbosity-0 returned empty"
[[ "$BC_HEX0" == "$CORE_HEX0" ]] \
    || fail "verbosity-0 hex mismatch: beam=$BC_HEX0 core=$CORE_HEX0"
# And the v0 hex must equal the tx we actually broadcast.
[[ "$BC_HEX0" == "$SIGNED_HEX" ]] \
    || fail "verbosity-0 hex != broadcast hex (serialization drift)"
log "v0 hex byte-exact vs Core + matches broadcast"

# bool verbosity: getrawtransaction <txid> false must equal verbosity 0.
BC_HEX_FALSE=$(jresult "$(bc_rpc getrawtransaction "[\"$SPEND_TXID\", false]")")
[[ "$BC_HEX_FALSE" == "$CORE_HEX0" ]] \
    || fail "bool verbosity 'false' != verbosity 0 (got '$BC_HEX_FALSE')"
log "bool verbosity=false maps to hex"

# ── 9. SUB-CHECK 1b: MEMPOOL verbosity 1 — decoded fields EXACT vs Core. ──
DECODED_T="ok"
CORE_V1=$(core_cli getrawtransaction "$SPEND_TXID" 1)
BC_V1=$(bc_rpc getrawtransaction "[\"$SPEND_TXID\", 1]")
bc_ec=$(jerr "$BC_V1")
[[ -z "$bc_ec" ]] || fail "beamchain verbosity-1 errored (code $bc_ec): $BC_V1"

# Compare the load-bearing top-level scalar fields EXACTLY.
for fld in txid hash version size vsize weight locktime hex; do
    cv=$(jget "$CORE_V1" "$fld")
    bv=$(jget "$BC_V1" "$fld")
    [[ -n "$bv" ]] || fail "v1: field '$fld' missing on beamchain"
    [[ "$bv" == "$cv" ]] || fail "v1: field '$fld' mismatch: beam=$bv core=$cv"
done
# txid must be the tx we sent; hash (wtxid) must differ from txid (segwit tx).
[[ "$(jget "$BC_V1" txid)" == "$SPEND_TXID" ]] || fail "v1: txid != broadcast txid"
[[ "$(jget "$BC_V1" hash)" != "$SPEND_TXID" ]] || fail "v1: wtxid==txid for a segwit tx (witness not serialized into wtxid?)"
log "v1 top-level scalars (txid/hash/version/size/vsize/weight/locktime/hex) exact"

# Deep vin/vout field comparison via python (asm/desc treated as present-not-equal).
python3 - "$CORE_V1" "$BC_V1" <<'PYEOF' || exit 1
import sys, json

def unwrap(s):
    o = json.loads(s)
    if isinstance(o, dict) and "result" in o and o.get("error") is None:
        return o["result"]
    return o

core = unwrap(sys.argv[1])
beam = unwrap(sys.argv[2])

def die(msg):
    print(f"GETRAWTRANSACTION beamchain: FAIL v1-deep: {msg}")
    sys.exit(1)

# ---- vin ----
cvin, bvin = core["vin"], beam["vin"]
if len(cvin) != len(bvin):
    die(f"vin length {len(bvin)} != core {len(cvin)}")
for i, (c, b) in enumerate(zip(cvin, bvin)):
    for f in ("txid", "vout", "sequence"):
        if b.get(f) != c.get(f):
            die(f"vin[{i}].{f} beam={b.get(f)} core={c.get(f)}")
    # scriptSig.hex must match exactly (empty for a segwit spend, but shape-present)
    if b.get("scriptSig", {}).get("hex") != c.get("scriptSig", {}).get("hex"):
        die(f"vin[{i}].scriptSig.hex beam={b.get('scriptSig')} core={c.get('scriptSig')}")
    # scriptSig.asm must be PRESENT (not required byte-equal)
    if "asm" not in b.get("scriptSig", {}):
        die(f"vin[{i}].scriptSig.asm missing")
    # txinwitness must match exactly (the signature + pubkey stack)
    if b.get("txinwitness") != c.get("txinwitness"):
        die(f"vin[{i}].txinwitness beam={b.get('txinwitness')} core={c.get('txinwitness')}")

# ---- vout ----
cvout, bvout = core["vout"], beam["vout"]
if len(cvout) != len(bvout):
    die(f"vout length {len(bvout)} != core {len(cvout)}")
for i, (c, b) in enumerate(zip(cvout, bvout)):
    # value (BTC decimal) must match exactly
    if float(b.get("value")) != float(c.get("value")):
        die(f"vout[{i}].value beam={b.get('value')} core={c.get('value')}")
    if b.get("n") != c.get("n"):
        die(f"vout[{i}].n beam={b.get('n')} core={c.get('n')}")
    cspk, bspk = c.get("scriptPubKey", {}), b.get("scriptPubKey", {})
    if bspk.get("hex") != cspk.get("hex"):
        die(f"vout[{i}].scriptPubKey.hex beam={bspk.get('hex')} core={cspk.get('hex')}")
    if bspk.get("type") != cspk.get("type"):
        die(f"vout[{i}].scriptPubKey.type beam={bspk.get('type')} core={cspk.get('type')}")
    # address: if Core emits one, beamchain must emit the SAME one.
    if "address" in cspk:
        if bspk.get("address") != cspk.get("address"):
            die(f"vout[{i}].scriptPubKey.address beam={bspk.get('address')} core={cspk.get('address')}")
    # asm + desc must be PRESENT (not required byte-equal)
    for f in ("asm", "desc"):
        if f not in bspk:
            die(f"vout[{i}].scriptPubKey.{f} missing")
print("v1-deep-ok")
PYEOF
log "v1 vin/vout deep fields exact (asm/desc present-not-equal)"

# ── 10. SUB-CHECK 2: CONFIRMED via blockhash arg. ─────────────────────────
CONFIRMED_T="ok"
log "mining 1 block on each node to confirm the spend"
core_cli generatetoaddress 1 "$ADDR" >/dev/null || fail "Core confirm-block failed"
bcr=$(bc_rpc generatetoaddress "[1, \"$ADDR\"]")
echo "$bcr" | grep -q '"result"' || fail "beamchain confirm-block failed: $bcr"

CONF_BLOCK_CORE=$(core_cli getbestblockhash)
CONF_BLOCK_BC=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('result',''))" <<<"$(bc_rpc getbestblockhash)")
[[ -n "$CONF_BLOCK_BC" ]] || fail "beamchain getbestblockhash empty after confirm"

# getrawtransaction <txid> 1 <blockhash> on each node (its OWN block).
CORE_CONF=$(core_cli getrawtransaction "$SPEND_TXID" 1 "$CONF_BLOCK_CORE")
BC_CONF=$(bc_rpc getrawtransaction "[\"$SPEND_TXID\", 1, \"$CONF_BLOCK_BC\"]")
bc_ec=$(jerr "$BC_CONF")
[[ -z "$bc_ec" ]] || fail "beamchain confirmed-lookup errored (code $bc_ec): $BC_CONF"

# blockhash field must equal the blockhash arg we passed.
B_BH=$(jget "$BC_CONF" blockhash)
[[ "$B_BH" == "$CONF_BLOCK_BC" ]] \
    || fail "confirmed: blockhash=$B_BH != passed $CONF_BLOCK_BC"
# confirmations: present + integer + >= 1.
jhas "$BC_CONF" confirmations || fail "confirmed: confirmations field missing"
B_CONF=$(jget "$BC_CONF" confirmations)
[[ "$B_CONF" =~ ^[0-9]+$ ]] || fail "confirmed: confirmations not an int: $B_CONF"
(( B_CONF >= 1 )) || fail "confirmed: confirmations=$B_CONF < 1"
# Core agrees on confirmations (both are 1 block deep).
C_CONF=$(jget "$CORE_CONF" confirmations)
[[ "$B_CONF" == "$C_CONF" ]] \
    || fail "confirmed: confirmations beam=$B_CONF != core=$C_CONF"
# in_active_chain == true (a blockhash ARG was given).
B_IAC=$(jget "$BC_CONF" in_active_chain)
[[ "$B_IAC" == "true" ]] || fail "confirmed: in_active_chain=$B_IAC != true"
# time + blocktime present + equal each other (both = block nTime).
jhas "$BC_CONF" time      || fail "confirmed: time field missing"
jhas "$BC_CONF" blocktime || fail "confirmed: blocktime field missing"
B_TIME=$(jget "$BC_CONF" time); B_BT=$(jget "$BC_CONF" blocktime)
[[ "$B_TIME" == "$B_BT" ]] || fail "confirmed: time=$B_TIME != blocktime=$B_BT"
[[ "$B_TIME" =~ ^[0-9]+$ ]] || fail "confirmed: time not an int: $B_TIME"
(( B_TIME > 1230768000 )) || fail "confirmed: time=$B_TIME not a sane unix epoch"
# the confirmed v1 hex must STILL be byte-exact vs Core (and the broadcast hex).
[[ "$(jget "$BC_CONF" hex)" == "$SIGNED_HEX" ]] \
    || fail "confirmed: v1 hex != broadcast hex"
log "confirmed via blockhash: blockhash/confirmations/in_active_chain/time/blocktime all correct"

# ── 11. SUB-CHECK 4: TXINDEX — confirmed lookup with NO blockhash. ────────
# beamchain defaults txindex ON, so this MUST succeed.
TXINDEX_NOTE=""
BC_NOIDX=$(bc_rpc getrawtransaction "[\"$SPEND_TXID\", 1]")
ni_ec=$(jerr "$BC_NOIDX")
if [[ -n "$ni_ec" ]]; then
    fail "txindex: no-blockhash confirmed lookup errored (code $ni_ec): $BC_NOIDX (beamchain txindex defaults ON)"
fi
[[ "$(jget "$BC_NOIDX" txid)" == "$SPEND_TXID" ]] \
    || fail "txindex: no-blockhash lookup returned wrong txid"
# When NO blockhash arg given, in_active_chain must be ABSENT (Core contract).
if jhas "$BC_NOIDX" in_active_chain; then
    fail "txindex: in_active_chain present without a blockhash arg (violates Core contract)"
fi
# blockhash/confirmations still present (the tx is confirmed + found via index).
jhas "$BC_NOIDX" blockhash || fail "txindex: blockhash missing on confirmed no-arg lookup"
[[ "$(jget "$BC_NOIDX" hex)" == "$SIGNED_HEX" ]] \
    || fail "txindex: no-blockhash v1 hex != broadcast hex"
TXINDEX_NOTE=" (+txindex no-blockhash lookup ok)"
log "txindex no-blockhash confirmed lookup ok; in_active_chain correctly absent"

# ── 12. SUB-CHECK 3: ERRORS. ──────────────────────────────────────────────
ERRORS_T="ok"
# 3a. a random 32-byte txid -> -5 on both.
RAND_TXID="00000000000000000000000000000000000000000000000000000000deadbeef"
CORE_ERR=$(core_cli getrawtransaction "$RAND_TXID" 1 2>&1 || true)
BC_ERR=$(bc_rpc getrawtransaction "[\"$RAND_TXID\", 1]")
bc_err_ec=$(jerr "$BC_ERR")
[[ "$bc_err_ec" == "-5" ]] \
    || fail "errors: unknown txid -> beamchain code $bc_err_ec (Core uses -5)"
log "unknown txid -> -5"

# 3b. the genesis-block coinbase txid (== genesis merkle root) -> -5.
GENESIS_HASH=$(core_cli getblockhash 0)
GEN_MERKLE=$(core_cli getblock "$GENESIS_HASH" | python3 -c "import sys,json;print(json.load(sys.stdin)['merkleroot'])")
[[ -n "$GEN_MERKLE" ]] || fail "errors: could not read genesis merkleroot"
log "genesis merkle root (== genesis coinbase txid) = $GEN_MERKLE"
# Core: this throws -5 ("not considered an ordinary transaction").
GEN_BC=$(bc_rpc getrawtransaction "[\"$GEN_MERKLE\", 1]")
gen_ec=$(jerr "$GEN_BC")
[[ "$gen_ec" == "-5" ]] \
    || fail "errors: genesis-coinbase txid -> beamchain code $gen_ec (Core uses -5)"
# message should reference the genesis-coinbase special case (text need not be
# byte-identical, but should be the dedicated message, not a generic not-found).
GEN_MSG=$(python3 -c "import sys,json; e=json.loads(sys.stdin.read()).get('error') or {}; print((e.get('message') or '').lower())" <<<"$GEN_BC")
echo "$GEN_MSG" | grep -q "genesis" \
    || fail "errors: genesis-coinbase message did not mention 'genesis': $GEN_MSG"
log "genesis-coinbase txid -> -5 with dedicated genesis message"

# 3c. a bogus blockhash arg -> -5 ("Block hash not found").
BOGUS_BH="00000000000000000000000000000000000000000000000000000000cafebabe"
BAD_BH=$(bc_rpc getrawtransaction "[\"$SPEND_TXID\", 1, \"$BOGUS_BH\"]")
bad_bh_ec=$(jerr "$BAD_BH")
[[ "$bad_bh_ec" == "-5" ]] \
    || fail "errors: bad blockhash arg -> beamchain code $bad_bh_ec (Core uses -5)"
log "bad blockhash arg -> -5"

# ── 13. Verdict. ──────────────────────────────────────────────────────────
log "PASS: v0 hex byte-exact + v1 decoded fields exact vs Core + confirmed envelope correct + error contract (-5) matches$TXINDEX_NOTE"
pass "$HEX_T" "$DECODED_T" "$CONFIRMED_T" "$ERRORS_T"
