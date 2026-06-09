#!/usr/bin/env bash
#
# beamchain_gettxout.sh — self-contained gettxout Core-parity differential.
#
# gettxout queries the live UTXO set for ONE output (txid, vout); existing coin
# -> { bestblock, confirmations(=tip-coin_height+1), value, scriptPubKey{asm,hex,
# type,address}, coinbase }; spent/nonexistent -> JSON null.
# Core ref: bitcoin-core/src/rpc/blockchain.cpp (gettxout).
#
# beamchain is the authoritative MINER here: it mines block 1 to a FIXED address
# + 5 maturity blocks to a sink, and each raw block is REPLAYED into the Core
# oracle via submitblock so both nodes carry the identical UTXO set + tip.
#
# NOTE (W61): beamchain's gettxout currently omits bestblock and reports
#   confirmations=0 — this arm GATES both, so it FAILs until that lands. That is
#   the intended regression-detecting behavior, not a harness bug.
#
# Summary line (stdout):
#   PASS: GETTXOUT beamchain: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok
#   FAIL: GETTXOUT beamchain: FAIL <short reason>

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SINK_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

BC_DATADIR="/tmp/gto-beamchain"
BC_RPC=40620
BC_P2P=40640
BC_LOG="$BC_DATADIR/node.log"

CORE_DATADIR="/tmp/gto-beamchain-core"
CORE_RPC=40622
CORE_P2P=40642
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=6
COIN_HEIGHT=1
EXP_CONFS=6

BC_PID=""
BC_COOKIE=""
CORE_BG=""

log() { echo "[gettxout:beamchain] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
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

pass() {
    echo "GETTXOUT beamchain: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok"
    exit 0
}
fail() {
    echo "GETTXOUT beamchain: FAIL $*"
    exit 1
}

# ── JSON helpers ──────────────────────────────────────────────────────────
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('null')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gto-beamchain" 2>/dev/null || true
fuser -k "${BC_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${BC_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "beamchain release binary not found at $NODE_BIN (run rebar3 as prod release)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

derive_p2wpkh() {
    python3 - "$TF_PATH" "$1" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k = ECKey(); k.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
PYEOF
}
MINE_ADDR=$(derive_p2wpkh "$SECRET")   || fail "could not derive mining address (test_framework import failed)"
[[ "$MINE_ADDR" == bcrt1* ]] || fail "mining address not regtest bech32: '$MINE_ADDR'"
SINK_ADDR=$(derive_p2wpkh "$SINK_SECRET") || fail "could not derive sink address"
[[ "$SINK_ADDR" == bcrt1* ]] || fail "sink address not regtest bech32: '$SINK_ADDR'"
log "mine=$MINE_ADDR sink=$SINK_ADDR"

# ── 2. Launch the Core regtest oracle (loopback P2P bind). ────────────────
wait_core_ready() {
    local pid="$1" lf="$2"
    local deadline=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || { tail -n 20 "$lf" >&2 2>/dev/null || true; return 1; }
        sleep 1
    done
    tail -n 20 "$lf" >&2 2>/dev/null || true
    return 1
}
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -bind="127.0.0.1:$CORE_P2P" -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    wait_core_ready "$CORE_BG" "$CORE_LOG"
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=127.0.0.1:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || fail "Core oracle failed to start after 3 attempts (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>/dev/null; }

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
-sname beamchain_gtoref_$$
-setcookie beamchain_gtoref
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
RELX_CONFIG_PATH="$BC_DATADIR/sys.config" VMARGS_PATH="$BC_DATADIR/vm.args" \
    BEAMCHAIN_TXINDEX=1 \
    "$NODE_BIN" foreground >"$BC_LOG" 2>&1 &
BC_PID=$!
bc_deadline=$(( $(date +%s) + 90 ))
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

bc_rpc() {  # bc_rpc <method> [params-json]
    local method="$1" params="${2:-[]}"
    curl -s --max-time 300 -u "$BC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$BC_RPC/" 2>/dev/null
}

# ── 4. beamchain mines block 1 -> MINE_ADDR + 5 maturity -> SINK; replay into
#       Core via submitblock. Both nodes converge on the identical chain. ─────
log "mining 1 block to $MINE_ADDR on beamchain"
mr=$(bc_rpc generatetoaddress "[1, \"$MINE_ADDR\"]")
echo "$mr" | grep -q '"result"' || fail "beamchain generatetoaddress (funding) failed: $mr"
log "mining 5 maturity blocks to $SINK_ADDR on beamchain"
mr=$(bc_rpc generatetoaddress "[5, \"$SINK_ADDR\"]")
echo "$mr" | grep -q '"result"' || fail "beamchain generatetoaddress (maturity) failed: $mr"
BC_H=$(jpy "$(bc_rpc getblockcount)" "d['result']")
[[ "$BC_H" == "$NBLOCKS" ]] || fail "beamchain height $BC_H != expected $NBLOCKS"

log "replaying beamchain's $NBLOCKS blocks into Core via submitblock"
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
BC_TIP=$(jpy "$(bc_rpc getbestblockhash)" "d['result']")
[[ "$CORE_TIP" == "$BC_TIP" ]] || fail "post-replay tip mismatch: Core=$CORE_TIP beam=$BC_TIP (replay did not converge)"
log "both at identical tip $CORE_TIP (height $NBLOCKS)"

# The block-1 coinbase txid is the gettxout target (coinbase=true, vout 0).
COIN_BH=$(bc_rpc getblockhash "[$COIN_HEIGHT]" | jpy "$(cat)" "d['result']")
[[ -z "$COIN_BH" ]] && COIN_BH=$(core_cli getblockhash "$COIN_HEIGHT")
COIN_TXID=$(core_cli getblock "$COIN_BH" 1 | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ -n "$COIN_TXID" && "${#COIN_TXID}" == "64" ]] || fail "could not resolve block-1 coinbase txid (got '$COIN_TXID')"
log "coinbase txid=$COIN_TXID expected_confs=$EXP_CONFS"

core_gettxout() { core_cli gettxout "$1" "$2" true; }
bc_gettxout() {
    local resp; resp=$(bc_rpc gettxout "[\"$1\", $2, true]")
    echo "$resp" | grep -q '"result"' || { echo "<ERR>$resp"; return 0; }
    jpy "$resp" "json.dumps(d['result'])"
}

# ════════════════════════════════════════════════════════════════════════
# CHECK 1 — existing UTXO: full-shape parity for the coinbase coin.
# ════════════════════════════════════════════════════════════════════════
EXIST_T="ok"; NULL_T="ok"; BEST_T="ok"; CONF_T="ok"; CB_T="ok"

CORE_GTO=$(core_gettxout "$COIN_TXID" 0) || fail "Core gettxout failed (see $CORE_LOG)"
[[ -n "$CORE_GTO" && "$CORE_GTO" != "null" ]] || fail "Core gettxout returned null for an UNSPENT coinbase (oracle anomaly)"
BC_GTO=$(bc_gettxout "$COIN_TXID" 0)
case "$BC_GTO" in "<ERR>"*) fail "beamchain gettxout errored: ${BC_GTO#<ERR>}";; esac
[[ -n "$BC_GTO" && "$BC_GTO" != "null" ]] || { EXIST_T="bad"; log "beamchain gettxout returned null for an UNSPENT coinbase"; }

log "Core:      $CORE_GTO"
log "beamchain: $BC_GTO"

CORE_BEST=$(jpy "$CORE_GTO" "d['bestblock']")
BC_BEST=$(jpy "$BC_GTO"   "d.get('bestblock','')")
[[ "$CORE_BEST" == "$CORE_TIP" ]] || fail "Core bestblock != tip (oracle anomaly): '$CORE_BEST'"
[[ "$BC_BEST" == "$CORE_BEST" ]] || { BEST_T="bad"; log "bestblock mismatch: impl='$BC_BEST' core='$CORE_BEST'"; }

CORE_CONF=$(jpy "$CORE_GTO" "d['confirmations']")
BC_CONF=$(jpy "$BC_GTO"   "d.get('confirmations')")
[[ "$CORE_CONF" == "$EXP_CONFS" ]] || fail "Core confirmations != $EXP_CONFS (oracle anomaly): '$CORE_CONF'"
[[ "$BC_CONF" == "$CORE_CONF" ]] || { CONF_T="bad"; log "confirmations mismatch: impl='$BC_CONF' core='$CORE_CONF'"; }

CORE_VAL=$(jpy "$CORE_GTO" "format(float(d['value']),'.8f')")
BC_VAL=$(jpy "$BC_GTO"   "format(float(d.get('value',0)),'.8f')")
[[ "$BC_VAL" == "$CORE_VAL" ]] || { EXIST_T="bad"; log "value mismatch: impl='$BC_VAL' core='$CORE_VAL'"; }

for f in asm hex type; do
    CV=$(jpy "$CORE_GTO" "d['scriptPubKey'].get('$f','')")
    IV=$(jpy "$BC_GTO"   "d.get('scriptPubKey',{}).get('$f','')")
    [[ "$IV" == "$CV" ]] || { EXIST_T="bad"; log "scriptPubKey.$f mismatch: impl='$IV' core='$CV'"; }
done
CORE_HASADDR=$(jpy "$CORE_GTO" "'address' in d['scriptPubKey']")
if [[ "$CORE_HASADDR" == "true" ]]; then
    BC_HASADDR=$(jpy "$BC_GTO" "'address' in d.get('scriptPubKey',{})")
    [[ "$BC_HASADDR" == "true" ]] || { EXIST_T="bad"; log "beamchain scriptPubKey missing 'address' (Core emits one)"; }
fi

CORE_CB=$(jpy "$CORE_GTO" "d['coinbase']")
BC_CB=$(jpy "$BC_GTO"   "d.get('coinbase')")
[[ "$CORE_CB" == "true" ]] || fail "Core coinbase flag not true for a coinbase coin (oracle anomaly): '$CORE_CB'"
[[ "$BC_CB" == "$CORE_CB" ]] || { CB_T="bad"; log "coinbase flag mismatch: impl='$BC_CB' core='$CORE_CB'"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — spent/nonexistent output -> JSON null on BOTH nodes.
# ════════════════════════════════════════════════════════════════════════
CORE_NULL=$(core_gettxout "$COIN_TXID" 9)
BC_NULL=$(bc_gettxout "$COIN_TXID" 9)
case "$BC_NULL" in "<ERR>"*) fail "beamchain gettxout(null-case) errored: ${BC_NULL#<ERR>}";; esac
[[ -z "$CORE_NULL" || "$CORE_NULL" == "null" ]] || fail "Core gettxout(absent vout) not null (oracle anomaly): '$CORE_NULL'"
[[ -z "$BC_NULL" || "$BC_NULL" == "null" ]] || { NULL_T="bad"; log "beamchain gettxout(absent vout) not null: '$BC_NULL'"; }

ABSENT_TXID="0000000000000000000000000000000000000000000000000000000000000001"
CORE_NULL2=$(core_gettxout "$ABSENT_TXID" 0)
BC_NULL2=$(bc_gettxout "$ABSENT_TXID" 0)
case "$BC_NULL2" in "<ERR>"*) fail "beamchain gettxout(absent txid) errored: ${BC_NULL2#<ERR>}";; esac
[[ -z "$CORE_NULL2" || "$CORE_NULL2" == "null" ]] || fail "Core gettxout(absent txid) not null (oracle anomaly): '$CORE_NULL2'"
[[ -z "$BC_NULL2" || "$BC_NULL2" == "null" ]] || { NULL_T="bad"; log "beamchain gettxout(absent txid) not null: '$BC_NULL2'"; }

# ── Verdict. ──────────────────────────────────────────────────────────────
if [[ "$EXIST_T" == "ok" && "$NULL_T" == "ok" && "$BEST_T" == "ok" && "$CONF_T" == "ok" && "$CB_T" == "ok" ]]; then
    log "PASS: beamchain gettxout matches Core on existing coin + bestblock + confs + coinbase + null"
    pass
fi

REASON=""
[[ "$EXIST_T" != "ok" ]] && REASON+="existing-UTXO shape diverges from Core; "
[[ "$BEST_T"  != "ok" ]] && REASON+="bestblock diverges from Core; "
[[ "$CONF_T"  != "ok" ]] && REASON+="confirmations diverges from Core; "
[[ "$CB_T"    != "ok" ]] && REASON+="coinbase flag diverges from Core; "
[[ "$NULL_T"  != "ok" ]] && REASON+="spent/nonexistent output not null; "
fail "${REASON% }"
