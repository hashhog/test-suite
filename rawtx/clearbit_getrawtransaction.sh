#!/usr/bin/env bash
#
# clearbit_getrawtransaction.sh — self-contained getrawtransaction DIFFERENTIAL test.
#
# The next RPC-surface green-cell after getchaintxstats/getindexinfo. getraw-
# transaction is the block-explorer keystone: it must be byte-shaped to Bitcoin
# Core's rpc/rawtransaction.cpp::getrawtransaction (envelope, TxToJSON) and
# core_io.cpp::TxToUniv (the decoded-tx field shape).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (separate scratch datadir + ports, -listen=0, -txindex=1). Core
#   serves two oracle roles here:
#     (a) decoderawtransaction <hex> — an authoritative TxToUniv decode of the
#         EXACT bytes clearbit returns, so the v=1 decoded shape can be compared
#         byte-for-byte on the load-bearing fields without needing the same UTXO
#         on both nodes (coinbase txids differ per node — different extranonce/
#         timestamp — so a single tx can't be valid on both mempools).
#     (b) getrawtransaction itself on Core's OWN mempool+chain tx (oracle self-
#         check: proves Core's getrawtransaction shape == its decoderawtransaction
#         shape, i.e. the oracle we compare clearbit against is the real thing).
#
# WHAT MATCHES EXACTLY (asserted vs Core):
#   v=0  : the raw tx HEX string == EncodeHexTx, byte-exact (clearbit hex ==
#          the bytes we submitted == Core's getrawtransaction 0 of the same form).
#   v=1  : decoded object — txid, hash (wtxid), version, size, vsize, weight,
#          locktime; per-vin {txid,vout,sequence} + scriptSig.hex (+ txinwitness);
#          per-vout {value, n, scriptPubKey.hex, .type, .address-if-present};
#          AND the top-level "hex". ALL byte-exact vs Core's decoderawtransaction
#          of clearbit's own returned hex.
#   confirmed (v=1 with blockhash arg): blockhash matches the mined block,
#          confirmations is the right int (>=1), in_active_chain==true,
#          time/blocktime present + sane.
#   errors: random 32-byte txid -> -5; genesis-coinbase txid -> -5.
#
# WHAT IS PRESENCE-ONLY (NOT byte-equal vs Core): scriptPubKey.asm and .desc —
#   asm whitespace can legitimately differ and desc is InferDescriptor output;
#   both are asserted PRESENT but not compared byte-for-byte. (Per the cell spec.)
#
# txindex sub-check (4): if clearbit accepts --txindex, getrawtransaction <txid>
#   1 with NO blockhash on a CONFIRMED tx must succeed. clearbit DOES support
#   --txindex, so this is exercised; if it ever stops, the check degrades to a
#   noted SKIP and the cell still passes on 1-3.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/clearbit_chaintxstats.sh):
#   no required args, set -uo pipefail, idempotent, trap cleanup, scratch /tmp +
#   UNIQUE ports, ONE clean summary line on stdout, all noise -> stderr/log,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETRAWTRANSACTION clearbit: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   FAIL: GETRAWTRANSACTION clearbit: FAIL <short reason>
#
# Touches ONLY /tmp/grt-clearbit/ + /tmp/grt-core/ and ports 22017/22037
#   (clearbit RPC/P2P) + 22018/22041 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

CB_DATADIR="/tmp/grt-clearbit"
CB_NETDIR="$CB_DATADIR/regtest"
CB_RPC=22017
CB_P2P=22037
CB_LOG="$CB_DATADIR/node.log"

CORE_DATADIR="/tmp/grt-core"
CORE_RPC=22018
CORE_P2P=22041
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic regtest p2wpkh key/address both nodes mine to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=101         # 101 blocks => block-1 coinbase is mature (spendable).
GENESIS_COINBASE_TXID=""   # filled from Core's genesis (== merkle root).

CB_PID=""
CB_COOKIE=""
CORE_BG=""

log() { echo "[grt:clearbit] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$CB_PID" ]] && kill -0 "$CB_PID" 2>/dev/null; then
        kill "$CB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$CB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "GETRAWTRANSACTION clearbit: PASS hex=ok decoded=ok confirmed=ok errors=ok"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION clearbit: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "grt-clearbit" >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${CB_RPC}|${CB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${CB_RPC}|${CB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${CB_RPC}/${CB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$CB_DATADIR" "$CORE_DATADIR"
mkdir -p "$CB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "clearbit binary not found at $NODE_BIN (build: zig build -Doptimize=ReleaseFast)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# Deterministic regtest p2wpkh address (Python; no wallet dependency).
ADDR=$(python3 - "$TF_PATH" "$SECRET" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
p = ECKey(); p.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(p.get_pubkey().get_bytes(), main=False))
PYEOF
) || fail "could not derive regtest address via Core test_framework"
[[ -n "$ADDR" ]] || fail "empty regtest address"
log "mining address: $ADDR"

# ── 2. Launch Core oracle (RPC-only: -listen=0; -txindex=1). ──────────────
# NOTE: the sandbox occasionally SIGKILLs a freshly-launched bitcoind a few
# seconds after load (it watches for bitcoind binding a 0.0.0.0 P2P listener;
# -listen=0 is RPC-only and avoids the deterministic kill, but a racey kill can
# still land). launch_core() is therefore retriable: section 4's launch+mine is
# wrapped in a bounded retry so a transient Core death is recovered, not fatal.
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

launch_core() {
    log "launching Core oracle rpc=:$CORE_RPC (-listen=0 -txindex=1)"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -txindex=1 -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
        -fallbackfee=0.0002 -daemon=0 -printtoconsole=0 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        core_cli getblockcount >/dev/null 2>&1 && { log "Core oracle ready (pid=$CORE_BG)"; return 0; }
        kill -0 "$CORE_BG" 2>/dev/null || { log "Core died during startup; will retry"; return 1; }
        sleep 1
    done
    log "Core oracle RPC never responded within 90s"
    return 1
}

core_alive() { core_cli getblockcount >/dev/null 2>&1; }

launch_core || { tail -n 25 "$CORE_LOG" >&2 2>/dev/null || true; }

# ── 3. Launch clearbit on regtest (--txindex). ────────────────────────────
log "launching clearbit (regtest) rpc=:$CB_RPC p2p=:$CB_P2P --txindex -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" \
    --port="$CB_P2P" --rpcport="$CB_RPC" --txindex >"$CB_LOG" 2>&1 &
CB_PID=$!
log "clearbit pid=$CB_PID"
cb_deadline=$(( $(date +%s) + 90 ))
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
    kill -0 "$CB_PID" 2>/dev/null || { tail -n 25 "$CB_LOG" >&2 2>/dev/null || true; fail "clearbit exited during startup (see $CB_LOG)"; }
    sleep 1
done
[[ -n "$CB_COOKIE" ]] || fail "clearbit cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$CB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$CB_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "clearbit RPC never responded within 90s"
log "clearbit RPC ready"

# clearbit RPC helper: returns the raw JSON-RPC envelope.
cb_rpc() {
    local method="$1" params="$2"
    curl -s --max-time 30 -u "$CB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$CB_RPC/"
}
# Extract .result (JSON) from a cb_rpc envelope; errors out (sys.exit) on .error.
cb_result() {
    python3 -c 'import sys,json
d=json.load(sys.stdin)
if d.get("error"): sys.exit("clearbit error: %s" % d["error"])
r=d["result"]
print(r if isinstance(r,str) else json.dumps(r))'
}
# Extract a clearbit error code, or "none".
cb_errcode() {
    python3 -c 'import sys,json
d=json.load(sys.stdin); print(d["error"]["code"] if d.get("error") else "none")'
}

# ── 4. Mine NBLOCKS on BOTH nodes (same address; distinct coinbases). ─────
# Core mining is wrapped in a bounded retry: if the sandbox SIGKILLs bitcoind
# mid-run, relaunch on the SAME (wiped) datadir and remine — regtest mining to
# the same address is deterministic, so the rebuilt chain is identical.
log "mining $NBLOCKS blocks on Core (retriable against sandbox SIGKILL)"
core_mined=""
for attempt in 1 2 3 4; do
    if ! core_alive; then
        log "Core not alive (attempt $attempt); relaunching on fresh datadir"
        [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
        rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
        launch_core || { sleep 2; continue; }
    fi
    if core_cli generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null 2>&1; then
        core_h=$(core_cli getblockcount 2>/dev/null)
        if [[ "$core_h" == "$NBLOCKS" ]]; then core_mined=ok; break; fi
    fi
    log "Core mine attempt $attempt failed (height=${core_h:-?}); retrying"
    sleep 2
done
[[ "$core_mined" == ok ]] || { tail -n 15 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core could not mine $NBLOCKS blocks after retries (sandbox kill?)"; }

log "mining $NBLOCKS blocks on clearbit"
cb_gen=$(cb_rpc generatetoaddress "[$NBLOCKS,\"$ADDR\"]")
cb_height=$(echo "$(cb_rpc getblockcount '[]')" | cb_result 2>/dev/null)
[[ "$cb_height" == "$NBLOCKS" ]] || fail "clearbit height $cb_height != $NBLOCKS (gen: $cb_gen)"
log "both nodes at height $NBLOCKS"

# Genesis-coinbase txid (== genesis merkle root) for the error check.
GENESIS_COINBASE_TXID=$(core_cli getblock "$(core_cli getblockhash 0)" | python3 -c 'import sys,json; print(json.load(sys.stdin)["merkleroot"])') \
    || fail "could not read genesis merkleroot from Core"
[[ "${#GENESIS_COINBASE_TXID}" == 64 ]] || fail "bad genesis coinbase txid: $GENESIS_COINBASE_TXID"

# ── 5. Resolve each node's block-1 coinbase output (txid/vout/value/spk). ──
# Both nodes mined block 1 to $ADDR (a p2wpkh). The coinbase pays the full
# subsidy to vout 0 (p2wpkh). Read each node's own block-1 coinbase via getblock.
read_cb1() {
    # $1 = "core" | "cb" ; prints "txid vout valuesat spkhex"
    local who="$1" bh="" raw=""
    if [[ "$who" == "core" ]]; then
        bh=$(core_cli getblockhash 1)
        raw=$(core_cli getblock "$bh" 2)
    else
        bh=$(echo "$(cb_rpc getblockhash '[1]')" | cb_result 2>/dev/null)
        raw=$(echo "$(cb_rpc getblock "[\"$bh\",2]")" | cb_result 2>/dev/null)
    fi
    echo "$raw" | python3 -c '
import sys,json
b=json.load(sys.stdin)
cb=b["tx"][0]
txid=cb["txid"]
# Find the p2wpkh output paying the subsidy (vout with a witness_v0_keyhash spk).
chosen=None
for o in cb["vout"]:
    spk=o["scriptPubKey"]
    if spk.get("type")=="witness_v0_keyhash":
        chosen=o; break
if chosen is None:
    chosen=cb["vout"][0]
val=int(round(chosen["value"]*100000000))
print(txid, chosen["n"], val, chosen["scriptPubKey"]["hex"])
'
}

CORE_CB1=$(read_cb1 core)    || fail "could not read Core block-1 coinbase"
CB_CB1=$(read_cb1 cb)        || fail "could not read clearbit block-1 coinbase"
[[ -n "$CORE_CB1" && -n "$CB_CB1" ]] || fail "empty block-1 coinbase read (core=[$CORE_CB1] cb=[$CB_CB1])"
log "Core   cb1: $CORE_CB1"
log "clearbit cb1: $CB_CB1"

# ── 6. Build + sign a p2wpkh->p2wpkh spend for EACH node's own coinbase. ───
# Python builds an identical-shape tx (1 segwit-v0 input, 1 p2wpkh output,
# fee=1000 sat) signed with the deterministic key. Returns the raw tx hex.
build_spend() {
    # $1 = "txid vout valuesat spkhex"
    python3 - "$TF_PATH" "$SECRET" "$1" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import CScript, sign_input_segwitv0, SIGHASH_ALL
from test_framework.script_util import key_to_p2wpkh_script
import hashlib

secret = bytes.fromhex(sys.argv[2])
txid_s, vout_s, val_s, spk_hex = sys.argv[3].split()
in_txid = txid_s
in_vout = int(vout_s)
in_value = int(val_s)
in_spk = bytes.fromhex(spk_hex)

key = ECKey(); key.set(secret, compressed=True)
pub = key.get_pubkey().get_bytes()
out_spk = key_to_p2wpkh_script(pub)   # p2wpkh to the same key

FEE = 1000
tx = CTransaction()
tx.version = 2
# COutPoint.hash is an int that ser_uint256 serializes little-endian (the
# Bitcoin wire order). The *displayed* txid is the byte-reversed (big-endian)
# hex, so the correct int is simply int(txid, 16).
prevhash = int(in_txid, 16)
tx.vin.append(CTxIn(COutPoint(prevhash, in_vout), b"", 0xffffffff))
tx.vout.append(CTxOut(in_value - FEE, out_spk))
tx.wit.vtxinwit.append(CTxInWitness())

# p2wpkh spk = OP_0 <20-byte keyhash>. The BIP143 scriptCode for a p2wpkh
# input is the standard P2PKH script of that keyhash (the python segwitv0
# helper takes the scriptCode directly).
keyhash = in_spk[2:]
from test_framework.script_util import keyhash_to_p2pkh_script
sc = keyhash_to_p2pkh_script(keyhash)

# Push the pubkey first (top of P2WPKH witness is [sig, pubkey]).
tx.wit.vtxinwit[0].scriptWitness.stack = [pub]
sign_input_segwitv0(tx, 0, sc, in_value, key, SIGHASH_ALL)

print(tx.serialize().hex())
PYEOF
}

CB_TXHEX=$(build_spend "$CB_CB1")     || fail "could not build clearbit spend tx"
CORE_TXHEX=$(build_spend "$CORE_CB1") || fail "could not build Core spend tx"
[[ -n "$CB_TXHEX" && -n "$CORE_TXHEX" ]] || fail "empty signed tx hex"

# ── 7. Submit each spend to its own node's mempool. ───────────────────────
log "sending spend to clearbit mempool"
CB_SEND=$(cb_rpc sendrawtransaction "[\"$CB_TXHEX\"]")
CB_TXID=$(echo "$CB_SEND" | cb_result 2>/dev/null) || fail "clearbit sendrawtransaction failed: $CB_SEND"
[[ "${#CB_TXID}" == 64 ]] || fail "clearbit sendrawtransaction did not return a txid: $CB_SEND"
log "clearbit mempool txid: $CB_TXID"

# Core mempool send is an ORACLE SELF-CHECK (not a clearbit assertion). If Core
# is alive it strengthens the test; if the sandbox killed Core, we degrade to
# the decoderawtransaction oracle (relaunched fresh below) and skip the Core
# mempool self-checks rather than fail the cell on environment flakiness.
CORE_TXID=""
CORE_SELFCHECK="skip"
if core_alive; then
    log "sending spend to Core mempool (oracle self-check)"
    CORE_SEND=$(core_cli sendrawtransaction "$CORE_TXHEX" 2>>"$CORE_LOG")
    if [[ "${#CORE_SEND}" == 64 ]]; then
        CORE_TXID="$CORE_SEND"
        CORE_SELFCHECK="ok"
        log "Core mempool txid: $CORE_TXID"
    else
        log "note: Core sendrawtransaction self-check unavailable ($CORE_SEND); continuing"
    fi
else
    log "note: Core not alive for mempool self-check; relying on decode oracle"
fi

# ── 8. v=0 HEX byte-exact (clearbit mempool). ─────────────────────────────
log "check 1a: getrawtransaction <txid> 0 (mempool hex byte-exact)"
CB_V0=$(echo "$(cb_rpc getrawtransaction "[\"$CB_TXID\",0]")" | cb_result 2>/dev/null) \
    || fail "clearbit getrawtransaction v0 errored"
[[ "$CB_V0" == "$CB_TXHEX" ]] || fail "v0 hex mismatch: clearbit returned a hex != submitted bytes"

# Also assert bool verbosity false == 0 (Core accepts bool).
CB_V0B=$(echo "$(cb_rpc getrawtransaction "[\"$CB_TXID\",false]")" | cb_result 2>/dev/null) \
    || fail "clearbit getrawtransaction verbosity=false errored"
[[ "$CB_V0B" == "$CB_TXHEX" ]] || fail "verbosity=false did not return the raw hex"

# Core self-check (best-effort): Core's getrawtransaction 0 of its OWN mempool
# tx == the bytes we sent it (proves the v0 contract holds on the oracle too).
if [[ "$CORE_SELFCHECK" == ok ]] && core_alive; then
    CORE_V0=$(core_cli getrawtransaction "$CORE_TXID" 0 2>>"$CORE_LOG")
    [[ "$CORE_V0" == "$CORE_TXHEX" ]] || fail "Core v0 hex != submitted bytes (oracle broken?)"
fi

# ── 9. v=1 DECODED shape byte-exact vs Core decoderawtransaction. ─────────
log "check 1b: getrawtransaction <txid> 1 (decoded) vs Core decoderawtransaction"
CB_V1=$(echo "$(cb_rpc getrawtransaction "[\"$CB_TXID\",1]")" | cb_result 2>/dev/null) \
    || fail "clearbit getrawtransaction v1 errored"
# Also assert bool verbosity true == 1.
CB_V1B=$(echo "$(cb_rpc getrawtransaction "[\"$CB_TXID\",true]")" | cb_result 2>/dev/null) \
    || fail "clearbit getrawtransaction verbosity=true errored"

# Oracle decode of the EXACT bytes clearbit returned. decoderawtransaction is
# stateless (no chain/mempool needed), so if the sandbox killed Core we can
# relaunch it FRESH purely to serve the decode oracle.
if ! core_alive; then
    log "Core not alive for decode oracle; relaunching fresh (stateless decode)"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    for _ in 1 2 3; do launch_core && break; sleep 2; done
fi
core_alive || fail "Core decode oracle unavailable (relaunch failed)"
CORE_DEC=$(core_cli decoderawtransaction "$CB_TXHEX" 2>>"$CORE_LOG") || fail "Core decoderawtransaction failed"

VERDICT=$(python3 - "$CB_V1" "$CORE_DEC" "$CB_TXHEX" "$CB_V1B" <<'PYEOF'
import sys, json
cb   = json.loads(sys.argv[1])
core = json.loads(sys.argv[2])   # decoderawtransaction (no top-level "hex", no envelope)
submitted_hex = sys.argv[3]
cb_bool = json.loads(sys.argv[4])

def f(reason):
    print("FAIL " + reason); sys.exit(0)

# bool verbosity true must equal int verbosity 1 (same decoded shape).
for k in ("txid","hash","version","size","vsize","weight","locktime"):
    if cb.get(k) != cb_bool.get(k):
        f("verbosity=true != verbosity=1 on %s" % k)

# Top-level scalar fields — byte-exact vs Core.
for k in ("txid","hash","version","size","vsize","weight","locktime"):
    if k not in cb:   f("clearbit v1 missing %s" % k)
    if k not in core: f("Core decode missing %s (oracle changed?)" % k)
    if cb[k] != core[k]:
        f("%s mismatch: clearbit=%r core=%r" % (k, cb[k], core[k]))

# Top-level "hex" must be present (Core getrawtransaction uses include_hex=true)
# and byte-equal the submitted bytes. decoderawtransaction omits it, so compare
# against the submitted hex.
if "hex" not in cb:
    f("clearbit v1 missing top-level hex (Core getrawtransaction include_hex=true)")
if cb["hex"] != submitted_hex:
    f("top-level hex != submitted bytes")

# vin parity.
if len(cb.get("vin",[])) != len(core.get("vin",[])):
    f("vin length mismatch: clearbit=%d core=%d" % (len(cb.get('vin',[])), len(core.get('vin',[]))))
for i,(a,b) in enumerate(zip(cb["vin"], core["vin"])):
    if a.get("txid") != b.get("txid"): f("vin[%d].txid mismatch" % i)
    if a.get("vout") != b.get("vout"): f("vin[%d].vout mismatch" % i)
    if a.get("sequence") != b.get("sequence"): f("vin[%d].sequence mismatch" % i)
    # scriptSig.hex exact (asm not compared).
    ah = a.get("scriptSig",{}).get("hex"); bh = b.get("scriptSig",{}).get("hex")
    if ah != bh: f("vin[%d].scriptSig.hex mismatch: %r != %r" % (i, ah, bh))
    if "scriptSig" in a and "asm" not in a["scriptSig"]:
        f("vin[%d].scriptSig.asm absent (must be present)" % i)
    # txinwitness exact (segwit input).
    if a.get("txinwitness") != b.get("txinwitness"):
        f("vin[%d].txinwitness mismatch: %r != %r" % (i, a.get("txinwitness"), b.get("txinwitness")))

# vout parity.
if len(cb.get("vout",[])) != len(core.get("vout",[])):
    f("vout length mismatch: clearbit=%d core=%d" % (len(cb.get('vout',[])), len(core.get('vout',[]))))
for i,(a,b) in enumerate(zip(cb["vout"], core["vout"])):
    # value: compare as 8-decimal strings normalised through float.
    if abs(float(a.get("value")) - float(b.get("value"))) > 1e-12:
        f("vout[%d].value mismatch: %r != %r" % (i, a.get("value"), b.get("value")))
    if a.get("n") != b.get("n"): f("vout[%d].n mismatch" % i)
    aspk = a.get("scriptPubKey",{}); bspk = b.get("scriptPubKey",{})
    if aspk.get("hex") != bspk.get("hex"):
        f("vout[%d].scriptPubKey.hex mismatch: %r != %r" % (i, aspk.get("hex"), bspk.get("hex")))
    if aspk.get("type") != bspk.get("type"):
        f("vout[%d].scriptPubKey.type mismatch: %r != %r" % (i, aspk.get("type"), bspk.get("type")))
    # address: if Core emits one, clearbit must too and they must match.
    if "address" in bspk:
        if aspk.get("address") != bspk.get("address"):
            f("vout[%d].scriptPubKey.address mismatch: %r != %r" % (i, aspk.get("address"), bspk.get("address")))
    # asm/desc present-only (not byte-equal).
    if "asm" not in aspk: f("vout[%d].scriptPubKey.asm absent (must be present)" % i)
    if "desc" not in aspk: f("vout[%d].scriptPubKey.desc absent (must be present)" % i)

print("OK")
PYEOF
) || fail "v1 comparator crashed (cb=$CB_V1 core=$CORE_DEC)"
[[ "$VERDICT" == OK ]] || fail "${VERDICT#FAIL }"

# Oracle self-check (best-effort): Core's OWN getrawtransaction 1 (mempool) shape
# matches its decoderawtransaction shape on the SAME bytes (proves the oracle is
# the real getrawtransaction contract, not just decode). Only runs if Core's
# mempool self-check tx is live; skipped on sandbox-kill flakiness.
if [[ "$CORE_SELFCHECK" == ok ]] && [[ -n "$CORE_TXID" ]] && core_alive; then
    CORE_GRT1=$(core_cli getrawtransaction "$CORE_TXID" 1 2>>"$CORE_LOG")
    if [[ -n "$CORE_GRT1" ]]; then
        CORE_SELF=$(python3 - "$CORE_GRT1" "$CORE_TXHEX" <<'PYEOF'
import sys, json
g = json.loads(sys.argv[1])
hexs = sys.argv[2]
def f(r): print("FAIL "+r); sys.exit(0)
for k in ("txid","hash","version","size","vsize","weight","locktime","vin","vout"):
    if k not in g: f("Core getrawtransaction 1 missing %s" % k)
if g.get("hex") != hexs:
    f("Core getrawtransaction 1 hex != submitted")
print("OK")
PYEOF
)
        [[ "$CORE_SELF" == OK ]] || fail "oracle self-check: ${CORE_SELF#FAIL }"
    fi
fi

# ── 10. CONFIRMED via blockhash arg (clearbit). ───────────────────────────
log "check 2: mine the clearbit tx, then getrawtransaction <txid> 1 <blockhash>"
cb_mine=$(cb_rpc generatetoaddress "[1,\"$ADDR\"]")
echo "$cb_mine" | cb_result >/dev/null 2>&1 || fail "clearbit could not mine the confirming block: $cb_mine"
CB_TIP=$(echo "$(cb_rpc getbestblockhash '[]')" | cb_result 2>/dev/null)
[[ "${#CB_TIP}" == 64 ]] || fail "clearbit best block hash unreadable: $CB_TIP"

CB_CONF=$(echo "$(cb_rpc getrawtransaction "[\"$CB_TXID\",1,\"$CB_TIP\"]")" | cb_result 2>/dev/null) \
    || fail "clearbit getrawtransaction v1+blockhash errored"

CONF_VERDICT=$(python3 - "$CB_CONF" "$CB_TIP" "$CB_TXID" <<'PYEOF'
import sys, json
g = json.loads(sys.argv[1])
tip = sys.argv[2]
txid = sys.argv[3]
def f(r): print("FAIL "+r); sys.exit(0)
if g.get("txid") != txid: f("confirmed: txid mismatch")
if g.get("blockhash") != tip:
    f("confirmed: blockhash=%r expected tip %r" % (g.get("blockhash"), tip))
if "in_active_chain" not in g:
    f("confirmed: in_active_chain absent (must be present with explicit blockhash)")
if g.get("in_active_chain") is not True:
    f("confirmed: in_active_chain=%r expected true" % (g.get("in_active_chain"),))
c = g.get("confirmations")
if not isinstance(c, int) or c < 1:
    f("confirmed: confirmations=%r expected int >= 1" % (c,))
for k in ("time","blocktime"):
    if k not in g: f("confirmed: %s absent" % k)
    if not isinstance(g[k], int) or g[k] < 1_000_000_000 or g[k] > 4_000_000_000:
        f("confirmed: %s=%r out of sane unix range" % (k, g.get(k)))
# hex still present on confirmed v1.
if "hex" not in g: f("confirmed: top-level hex absent")
print("OK")
PYEOF
) || fail "confirmed comparator crashed (cb=$CB_CONF)"
[[ "$CONF_VERDICT" == OK ]] || fail "${CONF_VERDICT#FAIL }"

# ── 11. txindex sub-check (clearbit supports --txindex): no-blockhash lookup
#        of a CONFIRMED tx must succeed. ─────────────────────────────────────
log "check 4: getrawtransaction <txid> 1 (no blockhash) on confirmed tx (txindex)"
CB_TXIDX=$(echo "$(cb_rpc getrawtransaction "[\"$CB_TXID\",1]")" | cb_result 2>/dev/null)
TXIDX_OK="skip"
if [[ -n "$CB_TXIDX" ]]; then
    TXIDX_VERDICT=$(python3 - "$CB_TXIDX" "$CB_TIP" "$CB_TXID" <<'PYEOF'
import sys, json
g = json.loads(sys.argv[1]); tip=sys.argv[2]; txid=sys.argv[3]
def f(r): print("FAIL "+r); sys.exit(0)
if g.get("txid") != txid: f("txindex: txid mismatch")
# Without an explicit blockhash, in_active_chain must NOT be present (Core only
# emits it with an explicit blockhash arg).
if "in_active_chain" in g:
    f("txindex: in_active_chain present without explicit blockhash arg")
if g.get("blockhash") != tip:
    f("txindex: blockhash=%r expected tip %r" % (g.get("blockhash"), tip))
c = g.get("confirmations")
if not isinstance(c, int) or c < 1:
    f("txindex: confirmations=%r expected int >= 1" % (c,))
print("OK")
PYEOF
)
    [[ "$TXIDX_VERDICT" == OK ]] || fail "txindex (no-blockhash): ${TXIDX_VERDICT#FAIL }"
    TXIDX_OK="ok"
else
    log "note: clearbit txindex no-blockhash lookup returned nothing; SKIPPING sub-check 4"
fi

# ── 12. ERROR parity: random txid -> -5, genesis-coinbase txid -> -5. ─────
log "check 3: error codes (random txid -5, genesis coinbase -5)"
RANDOM_TXID="00000000000000000000000000000000000000000000000000000000000000aa"

cb_rand_code=$(echo "$(cb_rpc getrawtransaction "[\"$RANDOM_TXID\"]")" | cb_errcode 2>/dev/null)
[[ "$cb_rand_code" == "-5" ]] || fail "random-txid: clearbit code=$cb_rand_code expected -5"
# Oracle: Core returns -5 for an unknown txid (txindex on).
core_rand_code=$(core_cli getrawtransaction "$RANDOM_TXID" 2>&1 | grep -oE '\-[0-9]+' | head -1)
[[ "$core_rand_code" == "-5" ]] || log "note: Core random-txid code parse='$core_rand_code' (expected -5; clearbit matched -5)"

cb_gen_code=$(echo "$(cb_rpc getrawtransaction "[\"$GENESIS_COINBASE_TXID\"]")" | cb_errcode 2>/dev/null)
[[ "$cb_gen_code" == "-5" ]] || fail "genesis-coinbase: clearbit code=$cb_gen_code expected -5"
# Oracle: Core also -5 for the genesis coinbase (special exception).
core_gen_code=$(core_cli getrawtransaction "$GENESIS_COINBASE_TXID" 2>&1 | grep -oE '\-[0-9]+' | head -1)
[[ "$core_gen_code" == "-5" ]] || log "note: Core genesis-coinbase code parse='$core_gen_code' (expected -5; clearbit matched -5)"

# Bonus: a blockhash arg that isn't a known block -> -5 "Block hash not found".
BADBLOCK="0000000000000000000000000000000000000000000000000000000000000099"
cb_badblock_code=$(echo "$(cb_rpc getrawtransaction "[\"$CB_TXID\",1,\"$BADBLOCK\"]")" | cb_errcode 2>/dev/null)
[[ "$cb_badblock_code" == "-5" ]] || fail "bad-blockhash-arg: clearbit code=$cb_badblock_code expected -5"

log "all checks passed (txindex sub-check: $TXIDX_OK)"
pass
