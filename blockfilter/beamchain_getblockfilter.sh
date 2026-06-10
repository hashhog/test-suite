#!/usr/bin/env bash
#
# beamchain_getblockfilter.sh — self-contained getblockfilter Core-parity test.
#
# A SUBSTANTIVE indexing green-cell. getblockfilter serves BIP-157/158 compact
# block filters to SPV clients. Unlike getindexinfo (which only reports index
# *status*), this proves beamchain computes the BIP-158 BASIC filter (type 0x00)
# + the BIP-157 filter-header chain BYTE-IDENTICALLY to Bitcoin Core.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:2956-3031 (getblockfilter)
#   bitcoin-core/src/blockfilter.{h,cpp}            (BlockFilter / GCSFilter)
#   BIP-158 (basic filter element set + GCS encoding), BIP-157 (header chain).
#
#   SIGNATURE: getblockfilter "blockhash" ( "filtertype" ).  filtertype "basic".
#   OUTPUT: { "filter": <hex GCS>, "header": <hex 32-byte filter header> }.
#   ERRORS:
#     unknown filtertype       -> RPC_INVALID_ADDRESS_OR_KEY (-5) "Unknown filtertype"
#     filter index not enabled -> RPC_MISC_ERROR (-1) "Index is not enabled ..."
#     block not found          -> RPC_INVALID_ADDRESS_OR_KEY (-5) "Block not found"
#
# BIP-158 BASIC FILTER (must match Core byte-for-byte):
#   ELEMENTS: every output scriptPubKey EXCEPT empty + OP_RETURN; PLUS for every
#     non-coinbase input, the scriptPubKey of the prevout it spends (from undo
#     data). Dedup identical elements.
#   GCS: P=19, M=784931. SipHash-2-4 key = first 16 bytes of the block HASH
#     (k0=bytes0..8 LE, k1=bytes8..16 LE). element -> 64-bit value mapped into
#     [0,N*M) via (hash*range)>>64. Sort ascending, Golomb-Rice the diffs (P=19).
#   ENCODED FILTER: CompactSize(N) || GCS bitstream, hex-encoded.
#   HEADER: SHA256d( SHA256d(rawFilterBytes) || prevBlockFilterHeader ), chained;
#     prev for genesis's parent is all-zero.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core), launched on its OWN
#   scratch regtest instance + OWN ports, with -blockfilterindex=basic. To make
#   the filters/headers BYTE-EXACT across nodes, both nodes must share the
#   IDENTICAL chain: Core (which has a full wallet) mines the chain INCLUDING a
#   real SPEND tx (so the spend block's filter has BOTH an output scriptPubKey
#   AND a spent-prevout scriptPubKey — a genuine multi-element filter), then we
#   REPLICATE every block to beamchain via submitblock(getblock(h,0)). beamchain
#   rebuilds its own UTXO/undo set as it connects each block, so its spent-
#   prevout elements are populated identically. beamchain runs with its basic
#   block filter index enabled (BEAMCHAIN_BLOCKFILTERINDEX=1).
#
# WHAT MUST MATCH CORE EXACTLY:
#   1. filter hex byte-EXACT + header hex byte-EXACT for:
#        - a coinbase-only block (1-element filter)
#        - the spend block (multi-element filter: output spk + spent prevout spk)
#   2. HEADER CHAINING: header @N must chain from @N-1 across >=3 consecutive
#      blocks (byte-equal to Core each height — catches a wrong prev-header link).
#   3. ERRORS: bogus filtertype -> -5 "Unknown filtertype";
#              unknown blockhash -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors blockfilter/blockbrew_getblockfilter.sh +
#   blockheader/beamchain_getblockheader.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1. Run under: setsid -w bash beamchain_getblockfilter.sh
#
# Summary line (stdout):
#   PASS: GETBLOCKFILTER beamchain: PASS filter=ok header=ok chain=ok errors=ok
#   FAIL: GETBLOCKFILTER beamchain: FAIL <short reason>
#   SKIP: GETBLOCKFILTER beamchain: SKIP <no filter index>
#
# Touches ONLY /tmp/gbf-beamchain/ + /tmp/gbf-beamchain-core/ and ports
#   22136/22156 (beamchain RPC/P2P) + 22936/22956 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Never broad-pkills bitcoind by name (a live mainnet bitcoind may be running);
#   only frees its OWN fixed ports + scratch dir.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
BC_REL="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

BC_DATADIR="/tmp/gbf-beamchain"
BC_RPC=22136
BC_P2P=22156
BC_LOG="$BC_DATADIR/node.log"
BC_SYS="$BC_DATADIR/sys.config"
BC_VM="$BC_DATADIR/vm.args"
BC_COOKIE=""
BC_PID=""
BC_P2P_HOLDER=""   # loopback holder PID that keeps beamchain from binding 0.0.0.0

# Core oracle: a beamchain-test-private datadir + ports, chosen far from the
# sibling RPC-cell harness cluster so concurrent test runs do not collide.
CORE_DATADIR="/tmp/gbf-beamchain-core"
CORE_RPC=22936
CORE_P2P=22956
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

NBLOCKS_PRE=110    # mine 110 blocks to the wallet (coinbase matures at 100).
# After NBLOCKS_PRE we sendtoaddress (spend) then mine 1 block (the spend block),
# then 3 trailing blocks. Final height = NBLOCKS_PRE + 1 + 3 = 114.

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockfilter:beamchain] $*" >&2; }

# ── Cleanup: kill OWN nodes + free OWN ports + wipe scratch on any exit. ───
# NOTE: never `pkill -f bitcoind` / never broad kill by binary name — a live
# mainnet bitcoind may be running. Only our OWN datadir-scoped CLI stop + our
# OWN fixed ports + our OWN child PID. beamchain's beam.smp is reaped by the
# UNIQUE -sname (gbf_beamchain_<ppid>) + the scratch datadir path only.
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    pkill -9 -f "gbf_beamchain_" 2>/dev/null || true
    pkill -9 -f "gbf-beamchain"  2>/dev/null || true
    if [[ -n "$BC_P2P_HOLDER" ]] && kill -0 "$BC_P2P_HOLDER" 2>/dev/null; then
        kill -9 "$BC_P2P_HOLDER" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETBLOCKFILTER beamchain: PASS filter=$1 header=$2 chain=$3 errors=$4"; exit 0; }
fail() { echo "GETBLOCKFILTER beamchain: FAIL $*"; exit 1; }
skip() { echo "GETBLOCKFILTER beamchain: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
pkill -9 -f "gbf_beamchain_" 2>/dev/null || true
pkill -9 -f "gbf-beamchain"  2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BC_RPC}/${BC_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
# Wait for the RPC/P2P ports to actually release (a SIGKILLed beam VM can hold
# the socket in TIME_WAIT/CLOSING briefly) before we relaunch on them.
for _ in $(seq 1 20); do
    busy=0
    for p in "$BC_RPC" "$BC_P2P" "$CORE_RPC" "$CORE_P2P"; do
        fuser "$p/tcp" >/dev/null 2>&1 && busy=1
    done
    [[ "$busy" == "0" ]] && break
    sleep 1
done
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# beamchain's RPC + P2P ports are MANDATED (22136 / 22156) and cannot be moved,
# so a concurrent sibling RPC-cell harness that squats them transiently would
# otherwise wedge our launch. Wait (bounded) for the mandated ports to clear
# before proceeding; fail loudly only if a foreign process holds them too long.
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
[[ -x "$BC_REL" ]]   || fail "beamchain release not found at $BC_REL (build with: rebar3 as prod release)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"

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
bc_result() { jpy "$(bc_rpc "$1" "$2")" "json.dumps(d['result'])"; }
bc_scalar() { jpy "$(bc_rpc "$1" "$2")" "d['result']"; }
bc_errcode() { jpy "$(bc_rpc "$1" "$2")" "d['error']['code']"; }
bc_errmsg()  { jpy "$(bc_rpc "$1" "$2")" "d['error']['message']"; }
# bc_field <method> <params> <field> -> result[field] scalar (or empty).
bc_field() { jpy "$(bc_rpc "$1" "$2")" "d['result']['$3']"; }

# ── 2. Launch the Core regtest oracle with -blockfilterindex=basic. ───────
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
    # -listen=0: the sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener
    # ~2s after load; RPC-only is fine for an oracle.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
        -blockfilterindex=basic -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle (-blockfilterindex=basic) rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Pre-bind a loopback holder on the P2P port. ────────────────────────
# beamchain's P2P listener binds 0.0.0.0:$BC_P2P (no {ip,...} option in
# start_listener/0). The sandbox SIGKILLs any process holding a 0.0.0.0 P2P
# listener shortly after load, which would kill the node mid-test. beamchain's
# start_listener/0 treats {error, eaddrinuse} as "skip the listener, keep
# running" — so we pre-bind $BC_P2P on LOOPBACK with a tiny holder process.
# beamchain's wildcard bind then fails EADDRINUSE, it runs listener-less (we
# only need RPC + submitblock), and it never trips the sandbox killer.
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
    kill -0 "$BC_P2P_HOLDER" 2>/dev/null || break   # exited (bind failed) -> stop waiting
    sleep 1
done
[[ "$holder_ok" == "1" ]] || fail "loopback P2P holder could not bind $BC_P2P within 30s (port held by a foreign process?)"

# ── 4. Launch beamchain (prod release, regtest, WITH the basic filter index). ─
# Enable the basic block filter index via a Core-style beamchain.conf in the
# NETWORK datadir (<datadir>/regtest/beamchain.conf). beamchain_config:init/1
# loads `blockfilterindex=1` into its config table BEFORE node_sup decides
# whether to start the beamchain_blockfilter_index gen_server. NOTE: the
# BEAMCHAIN_BLOCKFILTERINDEX env var is NOT used — the relx `foreground`
# launcher does not propagate process-env vars into the spawned beam VM, so the
# conf-file path is the reliable opt-in. The regtest datadir subdir is created
# up front so the conf is present at first read.
mkdir -p "$BC_DATADIR/regtest"
cat >"$BC_DATADIR/regtest/beamchain.conf" <<BCCONF
blockfilterindex=1
BCCONF
# metrics_port=0 disables the Prometheus listener. The default metrics port
# (9332) is FIXED and collides with any sibling beamchain (this fleet runs
# concurrent RPC-cell harnesses + a possible live node). node_sup uses a
# rest_for_one strategy with beamchain_metrics ordered BEFORE the filter index,
# so a metrics listener that crash-loops on eaddrinuse blocks the filter index
# from ever starting. Disabling metrics removes that ordering hazard; it is
# pure observability and irrelevant to getblockfilter parity.
cat >"$BC_SYS" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$BC_DATADIR"},
   {p2pport, $BC_P2P},
   {rpcport, $BC_RPC},
   {metrics_port, 0}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$BC_VM" <<ERLVM
-sname gbf_beamchain_$$
-setcookie gbf_beamchain
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest, blockfilterindex via conf) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
(
    cd "$BC_DATADIR" || exit 1
    exec env RELX_CONFIG_PATH="$BC_SYS" VMARGS_PATH="$BC_VM" \
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
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited during startup (see $BC_LOG)"; }
    sleep 1
done
[[ -n "$BC_COOKIE" ]] || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain cookie never appeared within 120s"; }
bc_rpc getblockcount '[]' | grep -q '"result"' || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain RPC never responded within 120s"; }
log "beamchain RPC ready"

# Early SKIP: if beamchain's filter index is not running, getblockfilter on the
# genesis hash returns the "Index is not enabled" RPC_MISC_ERROR (-1).
GEN_HASH=$(core_cli_retry getblockhash 0) || fail "Core getblockhash 0 failed"
BC_GEN_PROBE=$(bc_errcode getblockfilter "[\"$GEN_HASH\", \"basic\"]")
if [[ "$BC_GEN_PROBE" == "-1" ]]; then
    skip "beamchain basic block filter index not enabled (getblockfilter -> -1 'Index is not enabled')"
fi

# ── 5. Build the shared chain on Core (with a real SPEND tx). ─────────────
# This bitcoind is built WITHOUT wallet support ("No wallet support compiled
# in!"), so we cannot use createwallet/sendtoaddress. Instead we build the spend
# tx by hand with Core's own test_framework (deterministic privkey -> p2wpkh):
#   1. generatetoaddress NBLOCKS_PRE to a deterministic p2wpkh address (mining
#      needs no wallet) -> matures the block-1 coinbase (100 confs).
#   2. craft a raw tx spending the block-1 coinbase output (p2wpkh) to a SECOND
#      deterministic p2wpkh address, sign it (BIP-143 SegwitV0 sighash),
#      sendrawtransaction, then generatetoaddress 1 to mine it.
#   3. 3 trailing blocks for the chaining checks.
# The spend block therefore carries: the new spend-tx output spk + the coinbase
# output spk (both filter "output" elements) AND the spent block-1 coinbase spk
# (a "spent prevout" element from undo data) -> a genuine multi-element filter.
TF_PATH="$BASEDIR/bitcoin-core/test/functional"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH (needed for wallet-free raw spend)"
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"

# Embed the raw-spend builder as a scratch python file (self-contained; wiped on
# cleanup). It mines, crafts+signs+broadcasts the spend, mines it + 3 trailing
# blocks, and prints "RESULT <spend_height> <spend_txid> <final_height>".
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

# spend the block-1 coinbase output (matured at NBLOCKS_PRE >= 101 confs)
b1 = rpc('getblock', [rpc('getblockhash', [1]), 2])
cb = b1['tx'][0]
cb_txid = cb['txid']
amount_sat = int(round(cb['vout'][0]['value'] * 100_000_000))

# destination = a DIFFERENT deterministic p2wpkh (distinct output spk element)
k2 = ECKey(); k2.set(bytes.fromhex('22'*31 + '23'), compressed=True)
dst_spk = address_to_scriptpubkey(key_to_p2wpkh(k2.get_pubkey().get_bytes(), main=False))

tx = CTransaction()
tx.version = 2
tx.vin.append(CTxIn(COutPoint(int(cb_txid, 16), 0), b"", 0xffffffff))
tx.vout.append(CTxOut(amount_sat - 1000, dst_spk))   # 1000 sat fee
tx.wit.vtxinwit.append(CTxInWitness())
script_code = key_to_p2pkh_script(pub)                # BIP-143 p2wpkh scriptCode
sighash = SegwitV0SignatureHash(script_code, tx, 0, SIGHASH_ALL, amount_sat)
tx.wit.vtxinwit[0].scriptWitness.stack = [k.sign_ecdsa(sighash) + bytes([SIGHASH_ALL]), pub]
spend_txid = rpc('sendrawtransaction', [tx.serialize().hex()])

rpc('generatetoaddress', [1, mine_addr])             # mine the spend block
spend_height = rpc('getblockcount')
blk = rpc('getblock', [rpc('getblockhash', [spend_height]), 1])
assert spend_txid in blk['tx'], "spend tx not in mined block"

rpc('generatetoaddress', [3, mine_addr])             # 3 trailing blocks
final_height = rpc('getblockcount')
print("RESULT %d %s %d" % (spend_height, spend_txid, final_height))
PYEOF

log "building wallet-free chain on Core: $NBLOCKS_PRE pre-blocks + raw spend + 3 tail"
SPEND_OUT=$(python3 "$SPEND_PY" "$CORE_RPC" "$CORE_COOKIE_FILE" "$TF_PATH" "$NBLOCKS_PRE" 2>"$BC_DATADIR/rawspend.err") \
    || { tail -n 10 "$BC_DATADIR/rawspend.err" >&2 2>/dev/null || true; fail "raw-spend chain builder failed (see rawspend.err)"; }
read -r _TAG SPEND_HEIGHT SPEND_TXID CORE_HEIGHT <<< "$SPEND_OUT"
[[ "$_TAG" == "RESULT" && -n "$SPEND_HEIGHT" && -n "$SPEND_TXID" && -n "$CORE_HEIGHT" ]] \
    || fail "raw-spend builder produced unexpected output: '$SPEND_OUT'"
EXPECTED=$(( NBLOCKS_PRE + 1 + 3 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED"
log "spend tx $SPEND_TXID mined at height $SPEND_HEIGHT; chain tip height $CORE_HEIGHT"

# Sanity: the spend block must actually contain the spend tx.
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$SPEND_HEIGHT") || fail "Core getblockhash spend failed"
HASTX=$(core_cli_retry getblock "$SPEND_BLOCKHASH" 1 | python3 -c "
import sys,json
b=json.load(sys.stdin); print('$SPEND_TXID' in b['tx'])
" 2>/dev/null)
[[ "$HASTX" == "True" ]] || fail "spend tx $SPEND_TXID not found in block @h$SPEND_HEIGHT (chain shape wrong)"
log "spend confirmed in block @h$SPEND_HEIGHT ($SPEND_BLOCKHASH)"

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
" 2>/dev/null) || fail "Core raw-block fetch (python JSON-RPC) failed"
GOT=$(echo "$RAW_LIST" | grep -c .)
[[ "$GOT" == "$CORE_HEIGHT" ]] || fail "fetched $GOT raw blocks from Core, expected $CORE_HEIGHT"
while read -r h RAW; do
    [[ -n "$RAW" ]] || continue
    kill -0 "$BC_PID" 2>/dev/null || fail "beamchain process died during replication at h=$h (see $BC_LOG)"
    SUB=$(bc_rpc submitblock "[\"$RAW\"]")
    # BIP-22: success is result:null; "duplicate"/"inconclusive" are also fine.
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

# Give beamchain's block filter index time to catch up to tip. It indexes on
# connect during submitblock (the chainstate connect path calls
# beamchain_blockfilter_index:add_block synchronously), but allow a generous
# settle window per the ouroboros/haskoin guidance.
for _ in $(seq 1 90); do
    BC_TIPFILT=$(bc_errcode getblockfilter "[\"$BC_TIP\", \"basic\"]")
    [[ -z "$BC_TIPFILT" ]] && break   # no error => filter present
    sleep 1
done

# ── 7. assert_block <height> <label> -> compares filter+header byte-exact. ─
# Sets global FAILREASON on mismatch (returns 1). Logs both sides on diff.
assert_block() {
    local h="$1" label="$2"
    local bh corF corH bcF bcH
    bh=$(core_cli_retry getblockhash "$h") || { FAILREASON="getblockhash $h failed"; return 1; }

    # Core side via its getblockfilter (the oracle).
    local CJSON
    CJSON=$(core_cli_retry getblockfilter "$bh" basic) || { FAILREASON="Core getblockfilter @h$h failed"; return 1; }
    corF=$(echo "$CJSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['filter'])" 2>/dev/null)
    corH=$(echo "$CJSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['header'])" 2>/dev/null)
    [[ -n "$corF" && -n "$corH" ]] || { FAILREASON="Core filter/header empty @h$h"; return 1; }

    # beamchain side.
    bcF=$(bc_field getblockfilter "[\"$bh\", \"basic\"]" filter)
    bcH=$(bc_field getblockfilter "[\"$bh\", \"basic\"]" header)
    [[ -n "$bcF" && -n "$bcH" ]] || { FAILREASON="beamchain filter/header empty @h$h ($label)"; return 1; }

    if [[ "$bcF" != "$corF" ]]; then
        log "FILTER MISMATCH @h$h ($label):"
        log "  core: $corF"
        log "  bc  : $bcF"
        FAILREASON="filter hex != Core @h$h ($label)"
        return 1
    fi
    if [[ "$bcH" != "$corH" ]]; then
        log "HEADER MISMATCH @h$h ($label):"
        log "  core: $corH"
        log "  bc  : $bcH"
        FAILREASON="filter header hex != Core @h$h ($label)"
        return 1
    fi
    log "MATCH @h$h ($label): filter(${#bcF} hex) + header byte-exact vs Core"
    return 0
}

FAILREASON=""
FILTER_T="ok"
HEADER_T="ok"

# ── 8. TEST 1 — coinbase-only block (1-element filter) byte-exact. ────────
# A block well before the spend has only the coinbase output (a single
# non-OP_RETURN scriptPubKey) -> a 1-element filter.
COINBASE_ONLY_H=50
assert_block "$COINBASE_ONLY_H" "coinbase-only/1-element" || { FILTER_T="bad"; HEADER_T="bad"; fail "$FAILREASON"; }

# ── 9. TEST 2 — spend block (multi-element filter) byte-exact. ────────────
# Must have BOTH an output scriptPubKey AND a spent-prevout scriptPubKey, so the
# element set is >1 and exercises the undo-data prevout-script path.
assert_block "$SPEND_HEIGHT" "spend/multi-element" || { FILTER_T="bad"; HEADER_T="bad"; fail "$FAILREASON"; }

# Cross-check: the spend block's filter really is multi-element (N>1). Decode the
# CompactSize element count from the leading byte(s) of the filter and assert >1.
SBH=$(core_cli_retry getblockhash "$SPEND_HEIGHT")
SPEND_FILTER=$(bc_field getblockfilter "[\"$SBH\", \"basic\"]" filter)
SPEND_N=$(python3 -c "
f=bytes.fromhex('$SPEND_FILTER')
# CompactSize decode (regtest filters are tiny; first byte suffices for N<253).
if not f: print(0)
else:
    b=f[0]
    if b<253: print(b)
    elif b==253: print(int.from_bytes(f[1:3],'little'))
    elif b==254: print(int.from_bytes(f[1:5],'little'))
    else: print(int.from_bytes(f[1:9],'little'))
" 2>/dev/null)
[[ -n "$SPEND_N" && "$SPEND_N" -gt 1 ]] \
    || fail "spend block filter is not multi-element (N=$SPEND_N) — spent-prevout spk likely missing"
log "spend block filter element count N=$SPEND_N (multi-element confirmed)"

# ── 10. TEST 3 — HEADER CHAINING across >=3 consecutive blocks. ──────────
# Verify the header bytes match Core for SPEND_HEIGHT-1, SPEND_HEIGHT,
# SPEND_HEIGHT+1, SPEND_HEIGHT+2 (4 consecutive). A wrong prev-header link would
# diverge from Core at the first chained block even if a single filter matched.
CHAIN_T="ok"
for h in $(seq $((SPEND_HEIGHT-1)) $((SPEND_HEIGHT+2))); do
    assert_block "$h" "chain" || { CHAIN_T="bad"; fail "$FAILREASON"; }
done

# Local-consistency cross-check: beamchain's own header @N must equal
# SHA256d( SHA256d(filterBytes@N) || header@N-1 ) using beamchain's own filter
# and parent header — catches a chain that matches Core but isn't internally
# self-consistent (e.g. a stored-but-not-recomputed header).
CH1=$(core_cli_retry getblockhash $((SPEND_HEIGHT)))
CH0=$(core_cli_retry getblockhash $((SPEND_HEIGHT-1)))
FILT_N=$(bc_field getblockfilter "[\"$CH1\", \"basic\"]" filter)
HDR_N=$(bc_field getblockfilter "[\"$CH1\", \"basic\"]" header)
HDR_PREV=$(bc_field getblockfilter "[\"$CH0\", \"basic\"]" header)
RECOMPUTED=$(python3 -c "
import hashlib
def d256(b): return hashlib.sha256(hashlib.sha256(b).digest()).digest()
filt=bytes.fromhex('$FILT_N')
# header field is displayed big-endian (Core's uint256.GetHex()); the raw
# 32-byte value used in the chain hash is little-endian (internal). Reverse.
prev=bytes.fromhex('$HDR_PREV')[::-1]
fh=d256(filt)
hdr=d256(fh+prev)
print(hdr[::-1].hex())
" 2>/dev/null)
[[ -n "$RECOMPUTED" && "$RECOMPUTED" == "$HDR_N" ]] \
    || fail "header self-consistency: recomputed=$RECOMPUTED stored=$HDR_N (chain link not SHA256d(SHA256d(filter)||prevHeader))"
log "header self-consistency @h$SPEND_HEIGHT OK (SHA256d(SHA256d(filter)||prevHeader))"

# ── 11. TEST 4 — ERROR cases. ────────────────────────────────────────────
ERRORS_T="ok"

# bogus filtertype -> -5 "Unknown filtertype"
EBOGUS_CODE=$(bc_errcode getblockfilter "[\"$BC_TIP\", \"bogustype\"]")
EBOGUS_MSG=$(bc_errmsg  getblockfilter "[\"$BC_TIP\", \"bogustype\"]")
if [[ "$EBOGUS_CODE" != "-5" ]]; then
    ERRORS_T="bad"; log "bogus filtertype: expected code -5, got '$EBOGUS_CODE'"
fi
case "$EBOGUS_MSG" in
    *Unknown\ filtertype*) : ;;
    *) ERRORS_T="bad"; log "bogus filtertype: expected msg ~'Unknown filtertype', got '$EBOGUS_MSG'" ;;
esac

# unknown blockhash -> -5
ERR_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
EUNK_CODE=$(bc_errcode getblockfilter "[\"$ERR_HASH\", \"basic\"]")
if [[ "$EUNK_CODE" != "-5" ]]; then
    ERRORS_T="bad"; log "unknown blockhash: expected code -5, got '$EUNK_CODE'"
fi
[[ "$ERRORS_T" == "ok" ]] || fail "error-code check: bogus-type code='$EBOGUS_CODE' msg='$EBOGUS_MSG'; unknown-hash code='$EUNK_CODE'"

log "PASS: beamchain getblockfilter matches Core (filter+header byte-exact for 1-element + multi-element + 4-block chain + errors)"
pass "$FILTER_T" "$HEADER_T" "$CHAIN_T" "$ERRORS_T"
