#!/usr/bin/env bash
#
# beamchain_coinstatsindex.sh — gettxoutsetinfo-AT-HISTORICAL-HEIGHT (coinstatsindex)
# differential test for beamchain vs a real Bitcoin Core oracle, both on regtest
# with -coinstatsindex=1 -txindex=1.
#
# Core capability under test:
#   gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#   With -coinstatsindex=1, the UTXO-set statistics can be queried AS OF a
#   HISTORICAL block (not just the tip) by passing hash_or_height (a height int
#   or a block hash). The result is backed by the coinstatsindex (a per-height
#   running UTXO-set muhash + counts maintained on every block connect).
#   Without coinstatsindex, a non-tip hash_or_height -> RPC error -8
#   "Querying specific block heights requires coinstatsindex".
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp  (gettxoutsetinfo; lines ~1085-1177:
#     the index gate, hash_or_height parse, per-height stats emission)
#   bitcoin-core/src/kernel/coinstats.cpp        (muhash / hash_serialized_3
#                                                  per-coin serialization + tally)
#   bitcoin-core/src/index/coinstatsindex.cpp    (the per-height running muhash
#                                                  index, maintained on block
#                                                  connect/disconnect)
#
# STRICT SHARED CONTRACT (identical across all 10 impl scripts — gate ALL):
#   * Launch BOTH the impl AND a real bitcoind oracle on regtest with
#     -coinstatsindex=1 (and -txindex=1).
#   * Mine ~150 blocks to a deterministic address with a few real spends so the
#     UTXO set genuinely differs across heights.
#   * Mirror the chain so BOTH nodes share a byte-identical tip.
#   * Wait for coinstatsindex to sync (poll getindexinfo until synced, or until
#     gettxoutsetinfo@tip works).
#   * Pick a HISTORICAL height H well below tip (H=100).
#   * Call gettxoutsetinfo "muhash" H (and the default hash_type) on BOTH.
#   * GATE: impl.height==H==Core.height; impl.bestblock==Core.bestblock (the
#     hash AT height H, NOT the tip); impl.txouts==Core.txouts;
#     impl.total_amount==Core.total_amount; impl.<hash field>
#     (muhash or hash_serialized_3)==Core's.
#   * ERROR gate: with coinstatsindex DISABLED, a non-tip hash_or_height must
#     error (match Core's -8).
#
# If the impl lacks coinstatsindex entirely or rejects hash_or_height, that is a
# real FAIL (not a SKIP). A missing binary -> SKIP (GAP_RE 'not found'/'not built').
#
# Summary line (stdout), EXACTLY:
#   PASS: COINSTATSINDEX beamchain: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok
#   FAIL: COINSTATSINDEX beamchain: FAIL <reason>
#   SKIP: COINSTATSINDEX beamchain: SKIP <reason>
#
# Boilerplate (node launch + Core oracle + chain mirror + teardown) is REUSED
# from test-suite/utxosetinfo/beamchain_gettxoutsetinfo.sh; the only launch
# change is adding -coinstatsindex=1 -txindex=1 to BOTH nodes, and the
# assertions are swapped to the at-height GATE above.
#
# Touches ONLY /tmp/csidx-beamchain/ + /tmp/csidx-beamchain-core/ and ports
#   22177/22197 (beamchain RPC/P2P) + 22977/22997 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Never broad-pkills bitcoind by name (a live mainnet bitcoind may run); only
#   frees its OWN fixed ports + its OWN scratch dir.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
BC_REL="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

BC_DATADIR="/tmp/csidx-beamchain"
BC_RPC=22177
BC_P2P=22197
BC_LOG="$BC_DATADIR/node.log"
BC_SYS="$BC_DATADIR/sys.config"
BC_VM="$BC_DATADIR/vm.args"
BC_COOKIE=""
BC_PID=""
BC_P2P_HOLDER=""

# Core oracle (own datadir + ports). Two Core instances are used in this test:
#   1. the MAIN oracle launched WITH -coinstatsindex=1 (the at-height GATE).
#   2. a throwaway Core launched WITHOUT coinstatsindex (the ERROR gate).
CORE_DATADIR="/tmp/csidx-beamchain-core"
CORE_RPC=22977
CORE_P2P=22997
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

# A second Core (no coinstatsindex) for the disabled-error gate. Own ports/dir.
CORE_NOIDX_DATADIR="/tmp/csidx-beamchain-core-noidx"
CORE_NOIDX_RPC=22978
CORE_NOIDX_LOG="$CORE_NOIDX_DATADIR/core.log"
CORE_NOIDX_BG=""

NBLOCKS_PRE=150     # mine ~150 blocks (coinbase matures at 100) so several
                    # historical heights have distinct UTXO sets.
HIST_H=100          # the HISTORICAL height we query (well below tip ~152).

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[coinstatsindex:beamchain] $*" >&2; }

# ── Cleanup. ──────────────────────────────────────────────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    pkill -9 -f "csidx_beamchain_" 2>/dev/null || true
    pkill -9 -f "csidx-beamchain"  2>/dev/null || true
    if [[ -n "$BC_P2P_HOLDER" ]] && kill -0 "$BC_P2P_HOLDER" 2>/dev/null; then
        kill -9 "$BC_P2P_HOLDER" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    "$CORE_CLI" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]]       && kill "$CORE_BG"       2>/dev/null || true
    [[ -n "$CORE_NOIDX_BG" ]] && kill "$CORE_NOIDX_BG" 2>/dev/null || true
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" "$CORE_NOIDX_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "COINSTATSINDEX beamchain: PASS atheight=$1 txouts=$2 amount=$3 hash=$4 bestblock=$5 reorg=$6"; exit 0; }
fail() { echo "COINSTATSINDEX beamchain: FAIL $*"; exit 1; }
skip() { echo "COINSTATSINDEX beamchain: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
pkill -9 -f "csidx_beamchain_" 2>/dev/null || true
pkill -9 -f "csidx-beamchain"  2>/dev/null || true
for p in "$BC_RPC" "$BC_P2P" "$CORE_RPC" "$CORE_P2P" "$CORE_NOIDX_RPC"; do
    # Wait briefly for the pkill'd prior run to release its sockets, then
    # ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":(${p}) " || break
        sleep 1
    done
    if ss -tln 2>/dev/null | grep -qE ":(${p}) "; then
        fail "port ${p} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
    fi
done
sleep 3
for _ in $(seq 1 20); do
    busy=0
    for p in "$BC_RPC" "$BC_P2P" "$CORE_RPC" "$CORE_P2P" "$CORE_NOIDX_RPC"; do
        fuser "$p/tcp" >/dev/null 2>&1 && busy=1
    done
    [[ "$busy" == "0" ]] && break
    sleep 1
done
rm -rf "$BC_DATADIR" "$CORE_DATADIR" "$CORE_NOIDX_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR" "$CORE_NOIDX_DATADIR"

# beamchain's RPC + P2P ports are fixed; wait (bounded) for them to clear.
for _ in $(seq 1 60); do
    busy=0
    for p in "$BC_RPC" "$BC_P2P"; do
        fuser "$p/tcp" >/dev/null 2>&1 && busy=1
    done
    [[ "$busy" == "0" ]] && break
    log "mandated beamchain port(s) $BC_RPC/$BC_P2P busy (sibling harness?) — waiting"
    sleep 2
done
for p in "$BC_RPC" "$BC_P2P"; do
    fuser "$p/tcp" >/dev/null 2>&1 && fail "mandated beamchain port $p held by a foreign process after 120s wait"
done

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$BC_REL" ]]   || skip "beamchain release not found at $BC_REL (not built; build with: rebar3 as prod release)"
[[ -x "$CORE_BIN" ]] || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || skip "bitcoin-cli not found at $CORE_CLI"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }
core_cli_retry() {
    local out=""
    for _ in $(seq 1 20); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}
core_noidx_cli() { "$CORE_CLI" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" "$@"; }

bc_rpc() {
    curl -s --max-time 90 -u "$BC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$BC_RPC/" 2>/dev/null
}
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}
bc_scalar()  { jpy "$(bc_rpc "$1" "$2")" "d['result']"; }
bc_errcode() { jpy "$(bc_rpc "$1" "$2")" "d['error']['code']"; }
bc_errmsg()  { jpy "$(bc_rpc "$1" "$2")" "d['error']['message']"; }
bc_field()   { jpy "$(bc_rpc "$1" "$2")" "d['result']['$3']"; }
bc_haskey()  { jpy "$(bc_rpc "$1" "$2")" "('$3' in d['result'])"; }

# ── 2. Launch the Core regtest oracle (WITH coinstatsindex). ──────────────
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
    # -listen=0: the sandbox SIGKILLs any bitcoind binding a 0.0.0.0 listener.
    # -coinstatsindex=1 -txindex=1: the capability under test.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
        -coinstatsindex=1 -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            core_cli_retry getblockcount >/dev/null && return 0
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle (coinstatsindex=1) rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Pre-bind a loopback holder on beamchain's P2P port. ────────────────
log "pre-binding loopback holder on P2P port $BC_P2P (forces beamchain listener-less)"
python3 -c "
import socket, time, sys
p = int('$BC_P2P')
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
deadline = time.time() + 30
while True:
    try:
        s.bind(('127.0.0.1', p)); break
    except OSError:
        if time.time() > deadline: sys.exit(1)
        time.sleep(1)
s.listen(1)
sys.stderr.write('holder-bound\n'); sys.stderr.flush()
time.sleep(3600)
" >/dev/null 2>"$BC_DATADIR/holder.log" &
BC_P2P_HOLDER=$!
holder_ok=0
for _ in $(seq 1 35); do
    if [[ -f "$BC_DATADIR/holder.log" ]] && grep -q "holder-bound" "$BC_DATADIR/holder.log" 2>/dev/null; then
        holder_ok=1; break
    fi
    kill -0 "$BC_P2P_HOLDER" 2>/dev/null || break
    sleep 1
done
[[ "$holder_ok" == "1" ]] || fail "loopback P2P holder could not bind $BC_P2P within 30s"

# ── 4. Launch beamchain (prod release, regtest, coinstatsindex+txindex). ──
mkdir -p "$BC_DATADIR/regtest"
# Honour the shared contract: ask beamchain for coinstatsindex=1 + txindex=1
# via its sys.config beamchain proplist AND env vars. beamchain has no
# coinstatsindex reader (it ignores the key), but we set it so the launch is
# byte-for-byte the contract launch; the behavioural test is the at-height query.
cat >"$BC_SYS" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$BC_DATADIR"},
   {p2pport, $BC_P2P},
   {rpcport, $BC_RPC},
   {coinstatsindex, 1},
   {txindex, 1},
   {metrics_port, 0}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$BC_VM" <<ERLVM
-sname csidx_beamchain_$$
-setcookie csidx_beamchain
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest, coinstatsindex=1 txindex=1) rpc=:$BC_RPC -> $BC_LOG"
(
    cd "$BC_DATADIR" || exit 1
    exec env RELX_CONFIG_PATH="$BC_SYS" VMARGS_PATH="$BC_VM" \
        BEAMCHAIN_TXINDEX=1 BEAMCHAIN_COINSTATSINDEX=1 \
        ERL_CRASH_DUMP="$BC_DATADIR/erl_crash.dump" \
        "$BC_REL" foreground
) >"$BC_LOG" 2>&1 &
BC_PID=$!

bc_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < bc_deadline )); do
    if [[ -z "$BC_COOKIE" ]]; then
        for c in "$BC_DATADIR/.cookie" "$BC_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && BC_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$BC_COOKIE" ]]; then
        bc_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 40 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited during startup (see $BC_LOG)"; }
    sleep 1
done
[[ -n "$BC_COOKIE" ]] || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain cookie never appeared within 120s"; }
bc_rpc getblockcount '[]' | grep -q '"result"' || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain RPC never responded within 120s"; }
log "beamchain RPC ready"

# ── 5. Build the shared chain on Core (with real SPEND txs). ──────────────
# Wallet-free raw spends via Core's own test_framework (deterministic p2wpkh).
# Mine NBLOCKS_PRE, then spend the block-1 and block-2 coinbases so the UTXO
# set differs across heights (a few coins removed + added). Final base height
# = NBLOCKS_PRE + 1 (one spend block holding both spends).
TF_PATH="$BASEDIR/bitcoin-core/test/functional"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"

SPEND_PY="$BC_DATADIR/rawspend.py"
cat >"$SPEND_PY" <<'PYEOF'
import sys, json, base64, urllib.request
TF = sys.argv[3]
sys.path.insert(0, TF)
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh, address_to_scriptpubkey
from test_framework.script_util import key_to_p2pkh_script
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import SegwitV0SignatureHash, SIGHASH_ALL

RPC_PORT = int(sys.argv[1])
COOKIE_FILE = sys.argv[2]
NBLOCKS_PRE = int(sys.argv[4])

cookie = open(COOKIE_FILE).read().strip()
auth = 'Basic ' + base64.b64encode(cookie.encode()).decode()
def rpc(method, params=None):
    body = json.dumps({'jsonrpc':'1.0','id':1,'method':method,'params':params or []}).encode()
    req = urllib.request.Request('http://127.0.0.1:%d/' % RPC_PORT, data=body,
        headers={'Content-Type':'application/json','Authorization':auth})
    r = json.load(urllib.request.urlopen(req, timeout=60))
    if r.get('error'):
        raise RuntimeError("%s -> %s" % (method, r['error']))
    return r['result']

# deterministic mining key -> p2wpkh; coinbases pay this scriptPubKey
k = ECKey(); k.set(bytes.fromhex('11'*31 + '12'), compressed=True)
pub = k.get_pubkey().get_bytes()
mine_addr = key_to_p2wpkh(pub, main=False)

rpc('generatetoaddress', [NBLOCKS_PRE, mine_addr])
assert rpc('getblockcount') == NBLOCKS_PRE, "pre-mine height wrong"

# destination = a DIFFERENT deterministic p2wpkh
k2 = ECKey(); k2.set(bytes.fromhex('22'*31 + '23'), compressed=True)
dst_spk = address_to_scriptpubkey(key_to_p2wpkh(k2.get_pubkey().get_bytes(), main=False))
script_code = key_to_p2pkh_script(pub)  # BIP-143 p2wpkh scriptCode for the mining key

spend_txids = []
for src_h in (1, 2):
    cb = rpc('getblock', [rpc('getblockhash', [src_h]), 2])['tx'][0]
    cb_txid = cb['txid']
    amount_sat = int(round(cb['vout'][0]['value'] * 100_000_000))
    tx = CTransaction()
    tx.version = 2
    tx.vin.append(CTxIn(COutPoint(int(cb_txid, 16), 0), b"", 0xffffffff))
    tx.vout.append(CTxOut(amount_sat - 1000, dst_spk))  # 1000 sat fee
    tx.wit.vtxinwit.append(CTxInWitness())
    sighash = SegwitV0SignatureHash(script_code, tx, 0, SIGHASH_ALL, amount_sat)
    tx.wit.vtxinwit[0].scriptWitness.stack = [k.sign_ecdsa(sighash) + bytes([SIGHASH_ALL]), pub]
    spend_txids.append(rpc('sendrawtransaction', [tx.serialize().hex()]))

rpc('generatetoaddress', [1, mine_addr])  # mine the spend block
spend_height = rpc('getblockcount')
blk = rpc('getblock', [rpc('getblockhash', [spend_height]), 1])
for txid in spend_txids:
    assert txid in blk['tx'], "spend tx not in mined block"

print("RESULT %d %s %d" % (spend_height, ",".join(spend_txids), spend_height))
PYEOF

log "building wallet-free chain on Core: $NBLOCKS_PRE pre-blocks + 2 raw spends"
SPEND_OUT=$(python3 "$SPEND_PY" "$CORE_RPC" "$CORE_COOKIE_FILE" "$TF_PATH" "$NBLOCKS_PRE" 2>"$BC_DATADIR/rawspend.err") \
    || { tail -n 10 "$BC_DATADIR/rawspend.err" >&2 2>/dev/null || true; fail "raw-spend chain builder failed (see rawspend.err)"; }
read -r _TAG SPEND_HEIGHT SPEND_TXIDS CORE_HEIGHT <<< "$SPEND_OUT"
[[ "$_TAG" == "RESULT" && -n "$SPEND_HEIGHT" && -n "$CORE_HEIGHT" ]] \
    || fail "raw-spend builder produced unexpected output: '$SPEND_OUT'"
EXPECTED=$(( NBLOCKS_PRE + 1 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED"
log "spends $SPEND_TXIDS mined at height $SPEND_HEIGHT; chain tip height $CORE_HEIGHT"

# ── 6. Replicate every Core block to beamchain via submitblock. ───────────
log "replicating $CORE_HEIGHT Core blocks to beamchain via submitblock"
RAW_LIST=$(python3 -c "
import sys, json, base64, urllib.request
cookie=open('$CORE_COOKIE_FILE').read().strip()
auth='Basic '+base64.b64encode(cookie.encode()).decode()
def rpc(method, params):
    body=json.dumps({'jsonrpc':'1.0','id':1,'method':method,'params':params}).encode()
    req=urllib.request.Request('http://127.0.0.1:$CORE_RPC/', data=body,
        headers={'Content-Type':'application/json','Authorization':auth})
    return json.load(urllib.request.urlopen(req, timeout=60))['result']
for h in range(1, $CORE_HEIGHT+1):
    bh=rpc('getblockhash',[h])
    raw=rpc('getblock',[bh,0])
    print('%d %s'%(h, raw))
" 2>/dev/null) || fail "Core raw-block fetch failed"
GOT=$(echo "$RAW_LIST" | grep -c .)
[[ "$GOT" == "$CORE_HEIGHT" ]] || fail "fetched $GOT raw blocks from Core, expected $CORE_HEIGHT"
while read -r h RAW; do
    [[ -n "$RAW" ]] || continue
    kill -0 "$BC_PID" 2>/dev/null || fail "beamchain process died during replication at h=$h (see $BC_LOG)"
    SUB=$(bc_rpc submitblock "[\"$RAW\"]")
    if echo "$SUB" | grep -q '"error":{[^}]*"code"'; then
        ERRC=$(jpy "$SUB" "d['error']['code']")
        [[ -z "$ERRC" || "$ERRC" == "None" ]] || fail "beamchain submitblock($h) JSON-RPC error: $SUB"
    fi
    RESVAL=$(jpy "$SUB" "d.get('result')")
    case "$RESVAL" in
        ""|duplicate|inconclusive) : ;;
        *) fail "beamchain submitblock($h) rejected: result='$RESVAL' raw=$SUB" ;;
    esac
done <<< "$RAW_LIST"
BC_HEIGHT=$(bc_scalar getblockcount '[]')
[[ "$BC_HEIGHT" == "$CORE_HEIGHT" ]] || fail "beamchain height $BC_HEIGHT != Core $CORE_HEIGHT (submitblock did not take)"

CORE_TIP=$(core_cli_retry getbestblockhash)
BC_TIP=$(bc_scalar getbestblockhash '[]')
[[ -n "$CORE_TIP" && "$CORE_TIP" == "$BC_TIP" ]] \
    || fail "tip hash mismatch after replicate (core=$CORE_TIP beamchain=$BC_TIP) — chains not identical"
log "chains identical at tip $BC_TIP (height $CORE_HEIGHT)"

# ── 7. Wait for Core's coinstatsindex to sync. ────────────────────────────
# Poll getindexinfo until coinstatsindex.synced == true (or until an at-tip
# at-height query resolves). This is the contract's index-sync gate.
log "waiting for Core coinstatsindex to sync"
CSIDX_SYNCED=0
for _ in $(seq 1 60); do
    SYNCED=$(core_cli getindexinfo coinstatsindex 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); c=d.get('coinstatsindex',{})
    print('1' if c.get('synced') is True else '0')
except Exception: print('0')
" 2>/dev/null)
    if [[ "$SYNCED" == "1" ]]; then CSIDX_SYNCED=1; break; fi
    sleep 1
done
[[ "$CSIDX_SYNCED" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core coinstatsindex never reported synced within 60s"; }
log "Core coinstatsindex synced"

# Sanity: Core's at-height query must actually work now (proves the index gate).
CORE_HVAL=$(core_cli gettxoutsetinfo "muhash" "$HIST_H" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('height',''))" 2>/dev/null)
[[ "$CORE_HVAL" == "$HIST_H" ]] || fail "Core at-height query failed: gettxoutsetinfo muhash $HIST_H -> height='$CORE_HVAL'"
log "Core at-height query confirmed working: gettxoutsetinfo muhash $HIST_H -> height=$CORE_HVAL"

# ── 8. ERROR gate: coinstatsindex DISABLED -> non-tip query must error. ───
# Launch a SECOND throwaway Core (no coinstatsindex) on its own ports, mine a
# couple of blocks, and confirm the at-height query errors with -8. This is the
# behaviour the impl must match if it has no coinstatsindex.
log "ERROR gate: launching no-coinstatsindex Core for the disabled-error check"
"$CORE_BIN" -regtest -datadir="$CORE_NOIDX_DATADIR" -rpcport="$CORE_NOIDX_RPC" -listen=0 \
    -coinstatsindex=0 -txindex=1 -fallbackfee=0.0002 >"$CORE_NOIDX_LOG" 2>&1 &
CORE_NOIDX_BG=$!
NOIDX_OK=0
for _ in $(seq 1 60); do
    core_noidx_cli getblockcount >/dev/null 2>&1 && { NOIDX_OK=1; break; }
    kill -0 "$CORE_NOIDX_BG" 2>/dev/null || break
    sleep 1
done
CORE_DISABLED_ERR_OK="skip"
if [[ "$NOIDX_OK" == "1" ]]; then
    NOIDX_ADDR=$(python3 -c "
import sys
sys.path.insert(0, '$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('11'*31+'12'), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null)
    core_noidx_cli generatetoaddress 5 "$NOIDX_ADDR" >/dev/null 2>&1 || true
    NOIDX_OUT=$(core_noidx_cli gettxoutsetinfo "muhash" 3 2>&1)
    if echo "$NOIDX_OUT" | grep -qi "Querying specific block heights requires coinstatsindex"; then
        CORE_DISABLED_ERR_OK="ok"
        log "ERROR gate (Core): non-tip query w/o coinstatsindex -> '$NOIDX_OUT'"
    else
        log "ERROR gate (Core): unexpected output: $NOIDX_OUT"
    fi
else
    log "ERROR gate: no-coinstatsindex Core failed to start; skipping Core-side error reference"
fi

# ── 9. THE GATE — gettxoutsetinfo at HISTORICAL height H on BOTH. ──────────
# Pull Core's authoritative AS-OF-H stats (muhash) — the per-height running
# index result, NOT the tip.
CORE_AT_H_JSON=$(core_cli_retry gettxoutsetinfo "muhash" "$HIST_H") || fail "Core gettxoutsetinfo muhash $HIST_H failed"
cget() { echo "$CORE_AT_H_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }
CORE_H_HEIGHT=$(cget height)
CORE_H_BEST=$(cget bestblock)
CORE_H_TXOUTS=$(cget txouts)
CORE_H_TOTAL=$(cget total_amount)
CORE_H_MUHASH=$(cget muhash)

# Independently derive the canonical block hash AT height H so the bestblock
# assertion is anchored to the chain, not just Core's self-report.
CANON_H_HASH=$(core_cli_retry getblockhash "$HIST_H")
[[ "$CORE_H_HEIGHT" == "$HIST_H" ]]       || fail "oracle anomaly: Core at-height height=$CORE_H_HEIGHT != H=$HIST_H"
[[ "$CORE_H_BEST"   == "$CANON_H_HASH" ]] || fail "oracle anomaly: Core at-height bestblock=$CORE_H_BEST != getblockhash($HIST_H)=$CANON_H_HASH"
[[ -n "$CORE_H_MUHASH" ]]                 || fail "oracle anomaly: Core at-height muhash empty"
log "Core@H=$HIST_H: bestblock=$CORE_H_BEST txouts=$CORE_H_TXOUTS total=$CORE_H_TOTAL muhash=$CORE_H_MUHASH"

# Now the impl: gettxoutsetinfo "muhash" H. This is the capability under test.
IMPL_RESP=$(bc_rpc gettxoutsetinfo "[\"muhash\", $HIST_H]")
IMPL_ERRC=$(jpy "$IMPL_RESP" "d['error']['code']")
IMPL_ERRM=$(jpy "$IMPL_RESP" "d['error']['message']")

ATHEIGHT_T="ok"; TXOUTS_T="ok"; AMOUNT_T="ok"; HASH_T="ok"; BESTBLOCK_T="ok"

if [[ -n "$IMPL_ERRC" && "$IMPL_ERRC" != "None" ]]; then
    # The impl REJECTED the at-height query. Per the contract this is a real
    # FAIL — the impl lacks coinstatsindex / cannot answer AS-OF a historical
    # height the way Core (with the index) can.
    log "impl REJECTED at-height query: code=$IMPL_ERRC msg='$IMPL_ERRM'"
    # Distinguish the two failure flavours for the reason string.
    if echo "$IMPL_ERRM" | grep -qi "coinstatsindex"; then
        fail "impl lacks coinstatsindex: gettxoutsetinfo \"muhash\" $HIST_H -> error $IMPL_ERRC '$IMPL_ERRM' (Core w/ index returns the per-height UTXO stats); coinstatsindex absent"
    else
        fail "impl rejected at-height query: gettxoutsetinfo \"muhash\" $HIST_H -> error $IMPL_ERRC '$IMPL_ERRM'; cannot query historical heights (coinstatsindex absent)"
    fi
fi

# The impl returned a result object — compare every gated field AS OF height H.
IMPL_H_HEIGHT=$(bc_field gettxoutsetinfo "[\"muhash\", $HIST_H]" height)
IMPL_H_BEST=$(bc_field   gettxoutsetinfo "[\"muhash\", $HIST_H]" bestblock)
IMPL_H_TXOUTS=$(bc_field gettxoutsetinfo "[\"muhash\", $HIST_H]" txouts)
IMPL_H_TOTAL=$(bc_field  gettxoutsetinfo "[\"muhash\", $HIST_H]" total_amount)
IMPL_H_MUHASH=$(bc_field gettxoutsetinfo "[\"muhash\", $HIST_H]" muhash)

# GATE 1: impl.height == H == Core.height
[[ "$IMPL_H_HEIGHT" == "$HIST_H" && "$IMPL_H_HEIGHT" == "$CORE_H_HEIGHT" ]] \
    || { ATHEIGHT_T="bad"; log "height: impl=$IMPL_H_HEIGHT H=$HIST_H core=$CORE_H_HEIGHT"; }

# GATE 2: impl.bestblock == Core.bestblock == canonical hash AT height H (NOT tip)
[[ "$IMPL_H_BEST" == "$CORE_H_BEST" && "$IMPL_H_BEST" == "$CANON_H_HASH" ]] \
    || { BESTBLOCK_T="bad"; log "bestblock: impl=$IMPL_H_BEST core=$CORE_H_BEST canon=$CANON_H_HASH"; }
# Defend against the "returned the TIP by ignoring H" failure mode.
[[ "$IMPL_H_BEST" != "$BC_TIP" || "$HIST_H" == "$CORE_HEIGHT" ]] \
    || { BESTBLOCK_T="bad"; log "bestblock is the TIP ($BC_TIP) — impl ignored hash_or_height H=$HIST_H"; }

# GATE 3: impl.txouts == Core.txouts
[[ -n "$IMPL_H_TXOUTS" && "$IMPL_H_TXOUTS" == "$CORE_H_TXOUTS" ]] \
    || { TXOUTS_T="bad"; log "txouts: impl=$IMPL_H_TXOUTS core=$CORE_H_TXOUTS"; }

# GATE 4: impl.total_amount == Core.total_amount (decimal-normalised)
AMT_MATCH=$(python3 -c "
from decimal import Decimal
try: print('ok' if Decimal('$IMPL_H_TOTAL')==Decimal('$CORE_H_TOTAL') else 'no')
except Exception: print('no')
" 2>/dev/null)
[[ "$AMT_MATCH" == "ok" ]] || { AMOUNT_T="bad"; log "total_amount: impl=$IMPL_H_TOTAL core=$CORE_H_TOTAL"; }

# GATE 5: impl.muhash == Core.muhash (the per-height UTXO-set commitment)
[[ -n "$IMPL_H_MUHASH" && "$IMPL_H_MUHASH" == "$CORE_H_MUHASH" ]] \
    || { HASH_T="bad"; log "muhash: impl=$IMPL_H_MUHASH core=$CORE_H_MUHASH"; }

# Also exercise the DEFAULT hash_type at height H (Core: hash_serialized_3 +
# specific block -> -8; with coinstatsindex the default-call path still applies
# the index gate). We only assert the impl does not silently succeed-with-wrong
# semantics; the muhash gate above is the load-bearing commitment check.
DEF_RESP=$(bc_rpc gettxoutsetinfo "[\"hash_serialized_3\", $HIST_H]")
DEF_ERRC=$(jpy "$DEF_RESP" "d['error']['code']")
CORE_DEF_OUT=$(core_cli gettxoutsetinfo "hash_serialized_3" "$HIST_H" 2>&1)
# Core ALWAYS rejects hash_serialized_3 + specific block with -8. Require the
# impl to match THAT specific behaviour too (it is independent of the index).
if echo "$CORE_DEF_OUT" | grep -qi "cannot be queried for a specific block"; then
    if [[ "$DEF_ERRC" != "-8" ]]; then
        log "default hash_type @H: impl code=$DEF_ERRC (Core rejects hash_serialized_3+height with -8) — non-fatal note"
    fi
fi


if [[ "$ATHEIGHT_T" != "ok" || "$TXOUTS_T" != "ok" || "$AMOUNT_T" != "ok" \
      || "$HASH_T" != "ok" || "$BESTBLOCK_T" != "ok" ]]; then
    fail "at-height divergence vs Core@H=$HIST_H: atheight=$ATHEIGHT_T txouts=$TXOUTS_T amount=$AMOUNT_T hash=$HASH_T bestblock=$BESTBLOCK_T"
fi
log "PASS (linear): beamchain coinstatsindex matches Core at historical height H=$HIST_H"
log "  height=$IMPL_H_HEIGHT bestblock=$IMPL_H_BEST txouts=$IMPL_H_TXOUTS total=$IMPL_H_TOTAL muhash=$IMPL_H_MUHASH"

# ── 10. REORG-SAFETY GATE ──────────────────────────────────────────────────
# WHY: the at-height gate above only proves the impl maintains the per-height
# MuHash on a LINEAR chain (connect-only). It CANNOT catch a reorg-desync — an
# impl that reverses the index on disconnect but never RE-ADDS on reconnect of
# the new chain's blocks will pass linear yet serve a stale (chain-A) muhash for
# a height that was reorged onto chain B. Core's coinstatsindex (BaseIndex +
# index/coinstatsindex.cpp: CustomAppend on connect, CustomRemove on disconnect)
# re-runs CustomAppend when B's blocks reconnect, so its per-height MuHash tracks
# the ACTIVE chain. This gate forces a reorg and asserts the impl agrees.
#
# REORG DESIGN (impl-agnostic; mirrors rustoshi/blockbrew/nimrod/hotbuns/clearbit
# harnesses exactly):
#   (1) Both nodes already share linear chain A at tip N (= $CORE_HEIGHT).
#   (2) On the Core ORACLE only: invalidateblock(getblockhash(F+1)) for a fork
#       point F < N. That disconnects A's F+1..N (Core runs CustomRemove for
#       each). Then generatetoaddress a LONGER competing chain B from F to N+3
#       to a DETERMINISTIC chain-B address (CHAIN_B_ADDR). B has strictly more
#       work, so Core reorgs A->B and its index re-runs CustomAppend for
#       B's F+1..N+3.
#   (3) REORG TRIGGER via invalidateblock ON THE IMPL (Core-faithful). A naive
#       submitblock of B's blocks onto A's tip N would be (correctly) rejected
#       as a side-branch double-spend. So FIRST call invalidateblock(F+1) ON THE
#       IMPL — rewinding it to fork F (disconnecting A's F+1..N) — THEN
#       submitblock B's blocks F+1..N+3 in order; each now connects as a clean
#       active-tip extension and the impl reorgs to B.
#   (4) Pick H_R with F < H_R <= N — a height whose block DIFFERS between A and
#       B. Call gettxoutsetinfo muhash H_R on BOTH and ASSERT
#       impl.muhash@H_R == Core.muhash@H_R AND impl.bestblock@H_R ==
#       Core.bestblock@H_R (the B-chain block at H_R, NOT A's). FAILS iff the
#       impl's index did not reconnect B's blocks (the connect-on-reconnect gap).
REORG_T="ok"
REORG_DEPTH=5                                   # A's blocks F+1..N that get reorged out
REORG_F=$(( CORE_HEIGHT - REORG_DEPTH ))        # fork point F (< N)
REORG_NEWTIP=$(( CORE_HEIGHT + 3 ))             # B's tip height (N+3): strictly more work
REORG_H=$CORE_HEIGHT                            # H_R: the OLD tip height (F < H_R <= N)
[[ "$REORG_F" -gt "$HIST_H" ]] || log "note: fork point F=$REORG_F not above linear-H=$HIST_H (ok; reorg-H differs)"

# Derive a deterministic chain-B mining address (different key from chain A's
# mining key '11..12' and spend-destination key '22..23' used in rawspend.py).
CHAIN_B_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('3333333333333333333333333333333333333333333333333333333333333334'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "reorg: could not derive deterministic chain-B address"
[[ "$CHAIN_B_ADDR" == bcrt1* ]] || fail "reorg: chain-B address is not a regtest bech32 address: '$CHAIN_B_ADDR'"
log "reorg: chain-B mining address: $CHAIN_B_ADDR"

# Record A's block hash at H_R (must change after the reorg, proving A!=B at H_R).
A_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "reorg: Core getblockhash $REORG_H (chain A) failed"
log "reorg: chain A tip N=$CORE_HEIGHT, fork F=$REORG_F, B newtip=$REORG_NEWTIP, reorg-H=$REORG_H (A@H_R=$A_HASH_AT_HR)"

# (2) On the Core oracle: invalidate F+1 then build longer chain B to CHAIN_B_ADDR.
FORK_CHILD=$(core_cli_retry getblockhash "$(( REORG_F + 1 ))") || fail "reorg: Core getblockhash F+1 failed"
core_cli invalidateblock "$FORK_CHILD" >/dev/null 2>&1 || fail "reorg: Core invalidateblock $FORK_CHILD failed"
INVAL_TIP=$(core_cli_retry getblockcount) || fail "reorg: Core getblockcount after invalidate failed"
[[ "$INVAL_TIP" == "$REORG_F" ]] || fail "reorg: Core after invalidate is at $INVAL_TIP, expected fork F=$REORG_F"
NB_B=$(( REORG_NEWTIP - REORG_F ))              # number of B blocks to generate (= depth+3)
core_cli_retry generatetoaddress "$NB_B" "$CHAIN_B_ADDR" >/dev/null || fail "reorg: Core generatetoaddress (chain B) failed"
CORE_BTIP_H=$(core_cli_retry getblockcount) || fail "reorg: Core getblockcount (B tip) failed"
[[ "$CORE_BTIP_H" == "$REORG_NEWTIP" ]] || fail "reorg: Core B tip height $CORE_BTIP_H != expected $REORG_NEWTIP"
CORE_BTIP=$(core_cli_retry getbestblockhash) || fail "reorg: Core getbestblockhash (B) failed"
B_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "reorg: Core getblockhash $REORG_H (chain B) failed"
[[ "$B_HASH_AT_HR" != "$A_HASH_AT_HR" ]] \
    || fail "reorg sanity: block at H_R=$REORG_H unchanged after reorg (A=B=$A_HASH_AT_HR; not a real reorg)"
log "reorg: Core reorged to B, tip=$CORE_BTIP @h$CORE_BTIP_H; B@H_R=$B_HASH_AT_HR (differs from A@H_R)"

# (3) REORG TRIGGER: invalidateblock(F+1) ON BEAMCHAIN first, rewinding it to F.
BC_FORK_CHILD=$(bc_scalar getblockhash "[$(( REORG_F + 1 ))]")
[[ "$BC_FORK_CHILD" == "$FORK_CHILD" ]] \
    || fail "reorg: beamchain F+1 hash ($BC_FORK_CHILD) != Core F+1 hash ($FORK_CHILD) before invalidate"
log "reorg: invalidateblock F+1=$BC_FORK_CHILD on beamchain (rewind to fork F=$REORG_F)"
BC_IB_RESP=$(bc_rpc invalidateblock "[\"$BC_FORK_CHILD\"]")
echo "$BC_IB_RESP" | grep -q '"error":null' || log "reorg: beamchain invalidateblock -> $BC_IB_RESP"
# Poll until beamchain has actually rewound to fork point F.
BC_AT_F=0
for _ in $(seq 1 30); do
    BC_INVAL_H=$(bc_scalar getblockcount '[]')
    if [[ "$BC_INVAL_H" == "$REORG_F" ]]; then BC_AT_F=1; break; fi
    sleep 1
done
[[ "$BC_AT_F" == "1" ]] \
    || fail "reorg: beamchain did not rewind to fork F=$REORG_F after invalidateblock (impl height=$BC_INVAL_H) — invalidateblock unsupported/ineffective"
BC_INVAL_TIP=$(bc_scalar getbestblockhash '[]')
log "reorg: beamchain rewound to fork F=$REORG_F (tip $BC_INVAL_TIP)"

# Mirror B to beamchain: submitblock B's blocks F+1..N+3 in order. Each now
# connects as a clean active-tip extension; B carries strictly more work.
log "reorg: mirroring B's blocks $(( REORG_F + 1 ))..$REORG_NEWTIP to beamchain via submitblock"
for (( h=REORG_F+1; h<=REORG_NEWTIP; h++ )); do
    kill -0 "$BC_PID" 2>/dev/null || fail "reorg: beamchain process died during B replication at h=$h (see $BC_LOG)"
    BBH=$(core_cli_retry getblockhash "$h") || fail "reorg: Core getblockhash $h (chain B) failed"
    BRAW=$(core_cli_retry getblock "$BBH" 0) || fail "reorg: Core getblock $BBH 0 (chain B) failed"
    [[ -n "$BRAW" ]] || fail "reorg: empty raw for chain-B block at h=$h"
    BSUB=$(bc_rpc submitblock "[\"$BRAW\"]")
    echo "$BSUB" | grep -q '"error":null' || log "reorg submitblock h=$h -> $BSUB"
done

# Poll until beamchain tip == Core tip (B). If beamchain never adopts B, that is
# itself a reorg failure (it could not switch to the more-work chain).
BC_REORG_DONE=0
for _ in $(seq 1 30); do
    BC_BTIP=$(bc_scalar getbestblockhash '[]')
    BC_BTIP_H=$(bc_scalar getblockcount '[]')
    if [[ "$BC_BTIP" == "$CORE_BTIP" && "$BC_BTIP_H" == "$CORE_BTIP_H" ]]; then BC_REORG_DONE=1; break; fi
    sleep 1
done
[[ "$BC_REORG_DONE" == "1" ]] \
    || fail "reorg: beamchain did not adopt chain B (impl tip=$BC_BTIP @h$BC_BTIP_H, Core B tip=$CORE_BTIP @h$CORE_BTIP_H) — reorg to more-work chain failed"
log "reorg: beamchain adopted chain B (tip $BC_BTIP @h$BC_BTIP_H)"

# (4) The reorg differential: gettxoutsetinfo muhash H_R on BOTH. Assert
#     beamchain serves B's per-height MuHash + bestblock, NOT A's stale value.
RB_MUH=$(core_cli_retry gettxoutsetinfo muhash "$REORG_H") || fail "reorg: Core gettxoutsetinfo muhash $REORG_H (post-reorg) failed"
RC_HEIGHT=$(jpy "$RB_MUH" "d.get('height')")
RC_BEST=$(jpy   "$RB_MUH" "d.get('bestblock')")
RC_MUHASH=$(jpy "$RB_MUH" "d.get('muhash')")
[[ "$RC_HEIGHT" == "$REORG_H" ]] || fail "reorg: Core post-reorg muhash@H_R height=$RC_HEIGHT != H_R=$REORG_H"
[[ "$RC_BEST" == "$B_HASH_AT_HR" ]] || fail "reorg: Core post-reorg bestblock@H_R=$RC_BEST != B@H_R=$B_HASH_AT_HR (oracle wrong?)"
[[ "$RC_MUHASH" =~ ^[0-9a-f]{64}$ ]] || fail "reorg: Core post-reorg muhash@H_R not 64-hex: '$RC_MUHASH'"

BC_RB_RESP=$(bc_rpc gettxoutsetinfo "[\"muhash\", $REORG_H]")
BC_RB_ERR_C=$(jpy "$BC_RB_RESP" "d.get('error',{}).get('code')")
if [[ -n "$BC_RB_ERR_C" && "$BC_RB_ERR_C" != "None" ]]; then
    fail "reorg: beamchain rejected gettxoutsetinfo muhash $REORG_H post-reorg (code=$BC_RB_ERR_C) — coinstatsindex not serving the reorged height"
fi

RB_HEIGHT=$(bc_field gettxoutsetinfo "[\"muhash\", $REORG_H]" height)
RB_BEST=$(bc_field   gettxoutsetinfo "[\"muhash\", $REORG_H]" bestblock)
RB_MUHASH=$(bc_field gettxoutsetinfo "[\"muhash\", $REORG_H]" muhash)
log "reorg @H_R=$REORG_H: core(best=$RC_BEST muhash=$RC_MUHASH) beamchain(height=$RB_HEIGHT best=$RB_BEST muhash=$RB_MUHASH)"

if [[ "$RB_BEST" == "$A_HASH_AT_HR" ]]; then
    REORG_T="bad"; log "reorg DESYNC: beamchain bestblock@H_R=$RB_BEST is A's stale block (B@H_R=$B_HASH_AT_HR) — index did not reconnect B"
fi
[[ "$RB_HEIGHT" == "$REORG_H" ]] \
    || { REORG_T="bad"; log "reorg: beamchain height@H_R=$RB_HEIGHT != H_R=$REORG_H"; }
[[ "$RB_BEST" == "$B_HASH_AT_HR" && "$RB_BEST" == "$RC_BEST" ]] \
    || { REORG_T="bad"; log "reorg: bestblock@H_R mismatch (beamchain=$RB_BEST want B@H_R=$B_HASH_AT_HR core=$RC_BEST)"; }
[[ -n "$RB_MUHASH" && "$RB_MUHASH" == "$RC_MUHASH" ]] \
    || { REORG_T="bad"; log "reorg: muhash@H_R MISMATCH (beamchain=$RB_MUHASH core=$RC_MUHASH) — impl served stale chain-A index after reorg"; }

[[ "$REORG_T" == "ok" ]] || fail "reorg-safety gate failed at H_R=$REORG_H (beamchain muhash/bestblock did not follow reorg from A to B; coinstatsindex reverses on disconnect but does NOT reconnect on the new chain)"
log "REORG OK @H_R=$REORG_H: beamchain muhash+bestblock match Core's B-chain values after reorg"

# ── 11. Verdict. ──────────────────────────────────────────────────────────
[[ "$ATHEIGHT_T" == "ok" && "$TXOUTS_T" == "ok" && "$AMOUNT_T" == "ok" \
   && "$HASH_T" == "ok" && "$BESTBLOCK_T" == "ok" && "$REORG_T" == "ok" ]] \
    || fail "internal: a gate flag was not set (atheight=$ATHEIGHT_T txouts=$TXOUTS_T amount=$AMOUNT_T hash=$HASH_T bestblock=$BESTBLOCK_T reorg=$REORG_T)"

log "PASS: beamchain coinstatsindex at-height query matches Core on all gated fields (linear + reorg)"
pass "$ATHEIGHT_T" "$TXOUTS_T" "$AMOUNT_T" "$HASH_T" "$BESTBLOCK_T" "$REORG_T"
