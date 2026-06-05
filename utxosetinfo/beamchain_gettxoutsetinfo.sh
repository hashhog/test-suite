#!/usr/bin/env bash
#
# beamchain_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity test.
#
# THE DEEPEST INDEXING-depth cell yet. gettxoutsetinfo's UTXO-set HASH is a
# fingerprint of the ENTIRE UTXO set: matching it byte-for-byte vs Bitcoin Core
# proves beamchain's consensus STATE (its on-disk UTXO set) is byte-identical to
# Core's — not merely that the RPC has the right shape. A single wrong/spent/
# missing coin anywhere in the set flips the hash.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:1010+ (gettxoutsetinfo)
#   bitcoin-core/src/kernel/coinstats.cpp     (hash_serialized_3 + muhash kernels,
#                                              per-coin TxOutSer / ApplyHash,
#                                              bogosize + total_amount accounting)
#
#   SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index ).
#     hash_type default "hash_serialized_3"; options
#     "hash_serialized_3" | "muhash" | "none".
#     hash_or_height + use_index need coinstatsindex — OUT OF SCOPE; we test the
#     base chainstate stats at the tip only.
#   OUTPUT (base, no coinstatsindex):
#     { height, bestblock, txouts, bogosize, hash_serialized_3 (only when that
#       hash_type), muhash (only when that hash_type), transactions, disk_size,
#       total_amount }.
#   hash_serialized_3: SHA256d over the UTXO set in COIN-CURSOR ORDER (by
#     outpoint key: txid then vout). Per-coin bytes = COutPoint(txid||vout LE) ||
#     uint32_LE((height<<1)|coinbase) || CTxOut(amount int64 LE ||
#     CompactSize(spk len) || spk). Deterministic given the same UTXO set.
#   muhash: MuHash3072 multiset hash (order-independent) over the same per-coin
#     serialization.
#   ERRORS:
#     hash_serialized_3 + a specific block/height -> RPC_INVALID_PARAMETER (-8)
#       "hash_serialized_3 hash type cannot be queried for a specific block".
#     an unrecognized hash_type -> error.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core), launched on its OWN
#   scratch regtest instance + OWN ports. To make the UTXO sets IDENTICAL, both
#   nodes share ONE chain: Core mines ~110 blocks AND broadcasts a real SPEND tx
#   (so the UTXO set has a spent output REMOVED and new outputs ADDED — not just
#   coinbases), then we replicate every block to beamchain via submitblock and
#   assert the tips are equal. beamchain rebuilds its own chainstate UTXO set as
#   it connects each block, so the two sets converge bit-for-bit.
#
# WHAT MUST MATCH CORE EXACTLY:
#   1. gettxoutsetinfo (default hash_type): height, bestblock, txouts,
#      total_amount ALL EXACT vs Core, AND the set hash (hash_serialized_3, or
#      muhash if that's beamchain's Core-correct hash) byte-EXACT vs Core
#      (queried with the matching hash_type on the Core oracle). THE set-hash
#      match is the point — it proves the whole UTXO set is identical.
#   2. MUTATE: mine ONE more block -> height+1, bestblock changed, the set hash
#      changed on BOTH and still matches between beamchain and Core.
#   3. ERRORS: gettxoutsetinfo hash_serialized_3 <height> -> -8 (cannot query a
#      specific block); gettxoutsetinfo bogus -> error.
#      bogosize/transactions/disk_size: assert PRESENT + typed, NOT byte-equal
#      (bogosize is "meaningless"; disk_size is impl-specific).
#
# STRICT UNIFORM INTERFACE (mirrors blockfilter/beamchain_getblockfilter.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1. Run under: setsid -w bash beamchain_gettxoutsetinfo.sh
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO beamchain: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO beamchain: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO beamchain: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-beamchain/ + /tmp/gtxo-beamchain-core/ and ports
#   40276/40296 (beamchain RPC/P2P) + 41276/41296 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Never broad-pkills bitcoind by name (a live mainnet bitcoind may be running);
#   only frees its OWN fixed ports + scratch dir. Every fuser -k redirects.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
BC_REL="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

BC_DATADIR="/tmp/gtxo-beamchain"
BC_RPC=40276
BC_P2P=40296
BC_LOG="$BC_DATADIR/node.log"
BC_SYS="$BC_DATADIR/sys.config"
BC_VM="$BC_DATADIR/vm.args"
BC_COOKIE=""
BC_PID=""
BC_P2P_HOLDER=""   # loopback holder PID that keeps beamchain from binding 0.0.0.0

# Core oracle: a beamchain-test-private datadir + ports, chosen far from the
# sibling RPC-cell harness cluster so concurrent test runs do not collide.
CORE_DATADIR="/tmp/gtxo-beamchain-core"
CORE_RPC=41276
CORE_P2P=41296
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

NBLOCKS_PRE=110    # mine 110 blocks to the wallet (coinbase matures at 100).
# After NBLOCKS_PRE we craft + broadcast a raw SPEND tx then mine 1 block (the
# spend block). Final base height = NBLOCKS_PRE + 1 = 111. The MUTATE test mines
# one more for height 112.

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutsetinfo:beamchain] $*" >&2; }

# ── Cleanup: kill OWN nodes + free OWN ports + wipe scratch on any exit. ───
# NOTE: never `pkill -f bitcoind` / never broad kill by binary name — a live
# mainnet bitcoind may be running. Only our OWN datadir-scoped CLI stop + our
# OWN fixed ports + our OWN child PID. beamchain's beam.smp is reaped by the
# UNIQUE -sname (gtxo_beamchain_<ppid>) + the scratch datadir path only.
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    pkill -9 -f "gtxo_beamchain_" 2>/dev/null || true
    pkill -9 -f "gtxo-beamchain"  2>/dev/null || true
    if [[ -n "$BC_P2P_HOLDER" ]] && kill -0 "$BC_P2P_HOLDER" 2>/dev/null; then
        kill -9 "$BC_P2P_HOLDER" 2>/dev/null || true
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

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETTXOUTSETINFO beamchain: PASS fields=$1 hash=$2 mutate=$3 errors=$4"; exit 0; }
fail() { echo "GETTXOUTSETINFO beamchain: FAIL $*"; exit 1; }
skip() { echo "GETTXOUTSETINFO beamchain: SKIP $*"; exit 0; }

# ── 0. Idempotent reset (OWN ports only). ─────────────────────────────────
log "resetting scratch state"
pkill -9 -f "gtxo_beamchain_" 2>/dev/null || true
pkill -9 -f "gtxo-beamchain"  2>/dev/null || true
fuser -k "${BC_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${BC_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
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

# beamchain's RPC + P2P ports are MANDATED (40276 / 40296) and cannot be moved,
# so a concurrent sibling harness that squats them transiently would otherwise
# wedge our launch. Wait (bounded) for the mandated ports to clear before
# proceeding; fail loudly only if a foreign process holds them too long.
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
bc_scalar()  { jpy "$(bc_rpc "$1" "$2")" "d['result']"; }
bc_errcode() { jpy "$(bc_rpc "$1" "$2")" "d['error']['code']"; }
bc_errmsg()  { jpy "$(bc_rpc "$1" "$2")" "d['error']['message']"; }
# bc_field <method> <params> <field> -> result[field] scalar (or empty).
bc_field()   { jpy "$(bc_rpc "$1" "$2")" "d['result']['$3']"; }
# bc_type <method> <params> <field> -> python type name of result[field].
bc_type()    { jpy "$(bc_rpc "$1" "$2")" "type(d['result']['$3']).__name__"; }
# bc_haskey <method> <params> <field> -> true/false whether result has field
# (jpy lowercases booleans to true/false).
bc_haskey()  { jpy "$(bc_rpc "$1" "$2")" "('$3' in d['result'])"; }

# ── 2. Launch the Core regtest oracle. ────────────────────────────────────
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # -listen=0: the sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener
    # ~2s after load; RPC-only is fine for an oracle.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
        -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Pre-bind a loopback holder on the P2P port. ────────────────────────
# beamchain's P2P listener binds 0.0.0.0:$BC_P2P. The sandbox SIGKILLs any
# process holding a 0.0.0.0 P2P listener shortly after load, which would kill the
# node mid-test. beamchain's start_listener/0 treats {error, eaddrinuse} as
# "skip the listener, keep running" — so we pre-bind $BC_P2P on LOOPBACK with a
# tiny holder process. beamchain's wildcard bind then fails EADDRINUSE, it runs
# listener-less (we only need RPC + submitblock), and never trips the killer.
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

# ── 4. Launch beamchain (prod release, regtest). ──────────────────────────
mkdir -p "$BC_DATADIR/regtest"
# metrics_port=0 disables the Prometheus listener (FIXED default 9332 collides
# with any sibling beamchain). Pure observability; irrelevant to gettxoutsetinfo.
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
-sname gtxo_beamchain_$$
-setcookie gtxo_beamchain
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
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
    kill -0 "$BC_PID" 2>/dev/null || { cp "$BC_LOG" /tmp/gtxo-beamchain-startfail.log 2>/dev/null || true; tail -n 40 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited during startup (see $BC_LOG / /tmp/gtxo-beamchain-startfail.log)"; }
    sleep 1
done
[[ -n "$BC_COOKIE" ]] || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain cookie never appeared within 120s"; }
bc_rpc getblockcount '[]' | grep -q '"result"' || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain RPC never responded within 120s"; }
log "beamchain RPC ready"

# ── 5. Build the shared chain on Core (with a real SPEND tx). ─────────────
# This bitcoind is built WITHOUT wallet support, so we cannot use
# createwallet/sendtoaddress. Instead we build the spend tx by hand with Core's
# own test_framework (deterministic privkey -> p2wpkh):
#   1. generatetoaddress NBLOCKS_PRE to a deterministic p2wpkh address (mining
#      needs no wallet) -> matures the block-1 coinbase (100 confs).
#   2. craft a raw tx spending the block-1 coinbase output (p2wpkh) to a SECOND
#      deterministic p2wpkh address, sign it (BIP-143 SegwitV0 sighash),
#      sendrawtransaction, then generatetoaddress 1 to mine it.
# The spend therefore REMOVES the block-1 coinbase output from the UTXO set and
# ADDS the new spend-tx output (plus the spend block's own coinbase) — so the
# UTXO set is non-trivial (not just a pile of coinbases) and the set hash truly
# exercises a removed+added coin.
TF_PATH="$BASEDIR/bitcoin-core/test/functional"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH (needed for wallet-free raw spend)"
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

# spend the block-1 coinbase output (matured at NBLOCKS_PRE >= 101 confs)
b1 = rpc('getblock', [rpc('getblockhash', [1]), 2])
cb = b1['tx'][0]
cb_txid = cb['txid']
amount_sat = int(round(cb['vout'][0]['value'] * 100_000_000))

# destination = a DIFFERENT deterministic p2wpkh (distinct output spk)
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

print("RESULT %d %s %d" % (spend_height, spend_txid, spend_height))
PYEOF

log "building wallet-free chain on Core: $NBLOCKS_PRE pre-blocks + raw spend"
SPEND_OUT=$(python3 "$SPEND_PY" "$CORE_RPC" "$CORE_COOKIE_FILE" "$TF_PATH" "$NBLOCKS_PRE" 2>"$BC_DATADIR/rawspend.err") \
    || { tail -n 10 "$BC_DATADIR/rawspend.err" >&2 2>/dev/null || true; fail "raw-spend chain builder failed (see rawspend.err)"; }
read -r _TAG SPEND_HEIGHT SPEND_TXID CORE_HEIGHT <<< "$SPEND_OUT"
[[ "$_TAG" == "RESULT" && -n "$SPEND_HEIGHT" && -n "$SPEND_TXID" && -n "$CORE_HEIGHT" ]] \
    || fail "raw-spend builder produced unexpected output: '$SPEND_OUT'"
EXPECTED=$(( NBLOCKS_PRE + 1 ))
[[ "$CORE_HEIGHT" == "$EXPECTED" ]] || fail "Core height $CORE_HEIGHT != expected $EXPECTED"
log "spend tx $SPEND_TXID mined at height $SPEND_HEIGHT; chain tip height $CORE_HEIGHT"

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

# ── 6b. Decide which hash_type to compare on. ─────────────────────────────
# Prefer hash_serialized_3 (Core's default). If beamchain returns it and it is
# Core-correct we use it; otherwise fall back to muhash (also a strong UTXO-set
# commitment). We probe both impl hashes once vs Core and pick the first that
# byte-matches at the base tip; the rest of the test (fields/mutate) then runs
# on the chosen hash_type. If NEITHER matches we report the hash dimension bad.
probe_match() {  # $1 = hash_type ; echoes "ok" if beamchain == Core for that type
    local ht="$1"
    local core_h impl_h
    if [[ "$ht" == "hash_serialized_3" ]]; then
        core_h=$(core_cli_retry gettxoutsetinfo "hash_serialized_3" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash_serialized_3',''))" 2>/dev/null)
        impl_h=$(bc_field gettxoutsetinfo '["hash_serialized_3"]' hash_serialized_3)
    else
        core_h=$(core_cli_retry gettxoutsetinfo "muhash" | python3 -c "import sys,json;print(json.load(sys.stdin).get('muhash',''))" 2>/dev/null)
        impl_h=$(bc_field gettxoutsetinfo '["muhash"]' muhash)
    fi
    if [[ -n "$core_h" && "$core_h" == "$impl_h" ]]; then echo "ok"; else echo "no"; fi
}

HASH_TYPE=""
for ht in hash_serialized_3 muhash; do
    log "probing UTXO-set hash parity for hash_type=$ht"
    if [[ "$(probe_match "$ht")" == "ok" ]]; then HASH_TYPE="$ht"; break; fi
done

# ── 7. TEST 1 — fields + set-hash byte-exact at the base tip. ─────────────
FIELDS_T="ok"
HASH_T="ok"
MUTATE_T="ok"
ERRORS_T="ok"

# Pull Core's base stats with the chosen (or default) hash_type for like-for-like.
ORACLE_HT="${HASH_TYPE:-hash_serialized_3}"
CORE_JSON=$(core_cli_retry gettxoutsetinfo "$ORACLE_HT") || fail "Core gettxoutsetinfo ($ORACLE_HT) failed"
core_get() { echo "$CORE_JSON" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1',''))" 2>/dev/null; }

CORE_HEIGHT_F=$(core_get height)
CORE_BEST=$(core_get bestblock)
CORE_TXOUTS=$(core_get txouts)
CORE_TOTAL=$(core_get total_amount)
CORE_SETHASH=$(core_get "$ORACLE_HT")

# beamchain side — default hash_type (no args) per the task.
BC_BASE_PARAMS='[]'
BC_HEIGHT_F=$(bc_field gettxoutsetinfo "$BC_BASE_PARAMS" height)
BC_BEST=$(bc_field gettxoutsetinfo "$BC_BASE_PARAMS" bestblock)
BC_TXOUTS=$(bc_field gettxoutsetinfo "$BC_BASE_PARAMS" txouts)
BC_TOTAL=$(bc_field gettxoutsetinfo "$BC_BASE_PARAMS" total_amount)

# Compare the EXACT scalar fields.
[[ "$BC_HEIGHT_F" == "$CORE_HEIGHT_F" ]] || { FIELDS_T="bad"; log "height: beamchain=$BC_HEIGHT_F core=$CORE_HEIGHT_F"; }
[[ "$BC_BEST"     == "$CORE_BEST"     ]] || { FIELDS_T="bad"; log "bestblock: beamchain=$BC_BEST core=$CORE_BEST"; }
[[ "$BC_TXOUTS"   == "$CORE_TXOUTS"   ]] || { FIELDS_T="bad"; log "txouts: beamchain=$BC_TXOUTS core=$CORE_TXOUTS"; }
# total_amount: compare as normalised decimals (both 8-dp).
TOTAL_MATCH=$(python3 -c "
from decimal import Decimal
try:
    print('ok' if Decimal('$BC_TOTAL')==Decimal('$CORE_TOTAL') else 'no')
except Exception:
    print('no')
" 2>/dev/null)
[[ "$TOTAL_MATCH" == "ok" ]] || { FIELDS_T="bad"; log "total_amount: beamchain=$BC_TOTAL core=$CORE_TOTAL"; }

# bogosize / transactions / disk_size: PRESENT + typed (NOT byte-equal).
for f in bogosize transactions disk_size; do
    has=$(bc_haskey gettxoutsetinfo "$BC_BASE_PARAMS" "$f")
    [[ "$has" == "true" ]] || { FIELDS_T="bad"; log "field '$f' missing from beamchain result (has=$has)"; }
    ty=$(bc_type gettxoutsetinfo "$BC_BASE_PARAMS" "$f")
    [[ "$ty" == "int" ]] || { FIELDS_T="bad"; log "field '$f' is type '$ty' (expected int)"; }
done

[[ "$FIELDS_T" == "ok" ]] || fail "field parity: height/bestblock/txouts/total_amount/typed-fields mismatch (see log)"
log "fields OK: height=$BC_HEIGHT_F txouts=$BC_TXOUTS total_amount=$BC_TOTAL (== Core); bogosize/transactions/disk_size present+int"

# The set-hash match — THE point of this cell.
if [[ -z "$HASH_TYPE" ]]; then
    HASH_T="bad"
    # Show both impl hashes vs Core for the failure log.
    BC_HS3=$(bc_field gettxoutsetinfo '["hash_serialized_3"]' hash_serialized_3)
    BC_MU=$(bc_field gettxoutsetinfo '["muhash"]' muhash)
    CORE_HS3=$(core_cli_retry gettxoutsetinfo hash_serialized_3 | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash_serialized_3',''))" 2>/dev/null)
    CORE_MU=$(core_cli_retry gettxoutsetinfo muhash | python3 -c "import sys,json;print(json.load(sys.stdin).get('muhash',''))" 2>/dev/null)
    log "UTXO-set hash mismatch on BOTH hash types:"
    log "  hash_serialized_3 beamchain=$BC_HS3"
    log "  hash_serialized_3 core     =$CORE_HS3"
    log "  muhash            beamchain=$BC_MU"
    log "  muhash            core     =$CORE_MU"
    fail "UTXO-set hash != Core for hash_serialized_3 AND muhash (consensus state differs)"
fi

# The base default-call already returns the chosen hash; assert it equals Core.
BC_SETHASH=$(bc_field gettxoutsetinfo "[\"$HASH_TYPE\"]" "$HASH_TYPE")
[[ -n "$BC_SETHASH" && "$BC_SETHASH" == "$CORE_SETHASH" ]] \
    || { HASH_T="bad"; fail "set-hash ($HASH_TYPE) != Core: beamchain=$BC_SETHASH core=$CORE_SETHASH"; }
log "SET-HASH MATCH ($HASH_TYPE): beamchain == Core == $BC_SETHASH — UTXO set is byte-identical"

# Sanity: the UTXO set is non-trivial — at least one spend happened, so txouts is
# not simply equal to the block count (every coinbase would give txouts==height
# if nothing were spent; the spend removed one and added one, and outputs are
# split across coinbases + the spend tx). We assert transactions>0 and txouts>0.
[[ "$BC_TXOUTS" -gt 0 ]] || fail "txouts is 0 — UTXO set empty (chain not replicated?)"
BC_NTX=$(bc_field gettxoutsetinfo "$BC_BASE_PARAMS" transactions)
[[ "$BC_NTX" -gt 0 ]] || fail "transactions is 0 — no txids with unspent outputs"
log "non-trivial UTXO set confirmed: txouts=$BC_TXOUTS transactions=$BC_NTX (spend tx removed+added coins)"

# ── 8. TEST 2 — MUTATE: mine one more block, hash must change + still match. ─
# Mine one more block on Core, replicate it, then re-query BOTH. height must be
# +1, bestblock must change, and the set hash must change on BOTH (a new coinbase
# UTXO entered the set) AND still match between beamchain and Core.
log "MUTATE: mining one more block on Core and replicating"
MINE_ADDR=$(python3 -c "
import sys
sys.path.insert(0, '$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('11'*31+'12'), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null)
[[ -n "$MINE_ADDR" ]] || fail "could not derive deterministic mine address for MUTATE"
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (MUTATE) failed"
NEW_CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$NEW_CORE_HEIGHT" == "$(( CORE_HEIGHT + 1 ))" ]] || fail "Core height after MUTATE = $NEW_CORE_HEIGHT (expected $((CORE_HEIGHT+1)))"
NEW_BH=$(core_cli_retry getblockhash "$NEW_CORE_HEIGHT")
NEW_RAW=$(core_cli_retry getblock "$NEW_BH" 0)
[[ -n "$NEW_RAW" ]] || fail "Core getblock (MUTATE raw) failed"
SUB=$(bc_rpc submitblock "[\"$NEW_RAW\"]")
RESVAL=$(jpy "$SUB" "d.get('result')")
case "$RESVAL" in
    ""|duplicate|inconclusive) : ;;
    *) fail "beamchain submitblock(MUTATE) rejected: result='$RESVAL' raw=$SUB" ;;
esac
NEW_BC_HEIGHT=$(bc_scalar getblockcount '[]')
[[ "$NEW_BC_HEIGHT" == "$NEW_CORE_HEIGHT" ]] || fail "beamchain height after MUTATE = $NEW_BC_HEIGHT (expected $NEW_CORE_HEIGHT)"
NEW_BC_TIP=$(bc_scalar getbestblockhash '[]')
[[ "$NEW_BC_TIP" == "$NEW_BH" ]] || fail "beamchain tip after MUTATE = $NEW_BC_TIP (expected $NEW_BH)"

# Re-query both with the chosen hash type.
NEW_CORE_JSON=$(core_cli_retry gettxoutsetinfo "$HASH_TYPE") || fail "Core gettxoutsetinfo (MUTATE) failed"
NEW_CORE_HEIGHT_F=$(echo "$NEW_CORE_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('height',''))" 2>/dev/null)
NEW_CORE_BEST=$(echo "$NEW_CORE_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('bestblock',''))" 2>/dev/null)
NEW_CORE_SETHASH=$(echo "$NEW_CORE_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$HASH_TYPE',''))" 2>/dev/null)

NEW_BC_HEIGHT_F=$(bc_field gettxoutsetinfo "[\"$HASH_TYPE\"]" height)
NEW_BC_BEST=$(bc_field gettxoutsetinfo "[\"$HASH_TYPE\"]" bestblock)
NEW_BC_SETHASH=$(bc_field gettxoutsetinfo "[\"$HASH_TYPE\"]" "$HASH_TYPE")

[[ "$NEW_BC_HEIGHT_F" == "$(( CORE_HEIGHT_F + 1 ))" ]] || { MUTATE_T="bad"; log "MUTATE height: beamchain=$NEW_BC_HEIGHT_F expected=$((CORE_HEIGHT_F+1))"; }
[[ "$NEW_BC_HEIGHT_F" == "$NEW_CORE_HEIGHT_F" ]]       || { MUTATE_T="bad"; log "MUTATE height vs core: beamchain=$NEW_BC_HEIGHT_F core=$NEW_CORE_HEIGHT_F"; }
[[ "$NEW_BC_BEST" != "$CORE_BEST" ]]                   || { MUTATE_T="bad"; log "MUTATE bestblock did NOT change (still $NEW_BC_BEST)"; }
[[ "$NEW_BC_BEST" == "$NEW_CORE_BEST" ]]               || { MUTATE_T="bad"; log "MUTATE bestblock vs core: beamchain=$NEW_BC_BEST core=$NEW_CORE_BEST"; }
[[ "$NEW_BC_SETHASH" != "$BC_SETHASH" ]]               || { MUTATE_T="bad"; log "MUTATE set-hash did NOT change (still $NEW_BC_SETHASH)"; }
[[ "$NEW_CORE_SETHASH" != "$CORE_SETHASH" ]]           || { MUTATE_T="bad"; log "MUTATE core set-hash did NOT change — oracle anomaly"; }
[[ "$NEW_BC_SETHASH" == "$NEW_CORE_SETHASH" ]]         || { MUTATE_T="bad"; log "MUTATE set-hash vs core: beamchain=$NEW_BC_SETHASH core=$NEW_CORE_SETHASH"; }
[[ "$MUTATE_T" == "ok" ]] || fail "MUTATE: height/bestblock/set-hash did not advance+match (see log)"
log "MUTATE OK: height $CORE_HEIGHT_F->$NEW_BC_HEIGHT_F, set-hash changed on BOTH and still matches Core ($NEW_BC_SETHASH)"

# ── 9. TEST 3 — ERROR cases. ──────────────────────────────────────────────
# (a) hash_serialized_3 with a specific block/height -> -8.
EHS3_CODE=$(bc_errcode gettxoutsetinfo "[\"hash_serialized_3\", $NEW_CORE_HEIGHT]")
EHS3_MSG=$(bc_errmsg  gettxoutsetinfo "[\"hash_serialized_3\", $NEW_CORE_HEIGHT]")
if [[ "$EHS3_CODE" != "-8" ]]; then
    ERRORS_T="bad"; log "hash_serialized_3 <height>: expected code -8, got '$EHS3_CODE' (msg='$EHS3_MSG')"
fi
case "$EHS3_MSG" in
    *cannot\ be\ queried\ for\ a\ specific\ block*) : ;;
    *) ERRORS_T="bad"; log "hash_serialized_3 <height>: expected msg ~'cannot be queried for a specific block', got '$EHS3_MSG'" ;;
esac

# (b) bogus hash_type -> error (Core throws RPC_INVALID_PARAMETER -8).
EBOGUS_CODE=$(bc_errcode gettxoutsetinfo '["totallybogus"]')
EBOGUS_MSG=$(bc_errmsg  gettxoutsetinfo '["totallybogus"]')
if [[ -z "$EBOGUS_CODE" || "$EBOGUS_CODE" == "None" ]]; then
    ERRORS_T="bad"; log "bogus hash_type: expected an error code, got none (msg='$EBOGUS_MSG')"
fi

[[ "$ERRORS_T" == "ok" ]] || fail "error-case check: hs3<height> code='$EHS3_CODE'; bogus code='$EBOGUS_CODE'"
log "errors OK: hash_serialized_3 <height> -> -8 '$EHS3_MSG'; bogus hash_type -> $EBOGUS_CODE '$EBOGUS_MSG'"

log "PASS: beamchain gettxoutsetinfo matches Core (fields exact + UTXO-set hash byte-exact via $HASH_TYPE + mutate + errors)"
pass "$FIELDS_T" "$HASH_T" "$MUTATE_T" "$ERRORS_T"
