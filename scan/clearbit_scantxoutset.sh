#!/usr/bin/env bash
#
# clearbit_scantxoutset.sh — self-contained scantxoutset DIFFERENTIAL test.
#
# scantxoutset is the wallet-recovery primitive: scan the CURRENT UTXO set for
# outputs matching one or more output descriptors. It must be shaped to Bitcoin
# Core's rpc/blockchain.cpp::scantxoutset (action='start', scanobjects=[...]),
# which returns an OBJECT:
#   { success(bool), txouts(int), height(int), bestblock(hex),
#     unspents:[{txid,vout,scriptPubKey,desc,amount,coinbase,height,
#                blockhash,confirmations}],
#     total_amount(BTC) }
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (separate scratch datadir + ports, -listen=0). To make the matched
#   set DETERMINISTIC and SINGLE (so total_amount is a known, exact number rather
#   than "every coinbase ever mined to the miner address"), each node:
#     1. mines NBLOCKS to a fixed miner address ($MINER) to get a mature coinbase;
#     2. SENDS a fixed amount ($PAYAMT) from that coinbase to a fresh, otherwise-
#        unused target address ($TARGET) — a regular p2wpkh output, NOT a coinbase;
#     3. mines 1 block to confirm the send.
#   $TARGET therefore owns exactly ONE UTXO of exactly $PAYAMT on BOTH nodes. The
#   send TXID differs per node (each spends its own distinct coinbase txid), but
#   the vout + amount + scriptPubKey of the matched output are IDENTICAL across
#   nodes because the spend is built deterministically (same key, same fee).
#
# DIFFERENTIAL CHECKS (run on BOTH impl and Core):
#   desc  : scantxoutset start [addr($TARGET)] returns EXACTLY ONE unspent on both;
#           the matched unspent's (vout,amount,scriptPubKey) is IDENTICAL across
#           nodes, and its txid equals THAT node's own send txid.
#   amount: impl total_amount == Core total_amount (byte-equal as 8-dp BTC), and
#           == the single matched output's amount == $PAYAMT.
#   shape : impl result object has success(bool) + total_amount + an unspents
#           array whose objects carry CORE'S KEYS. The keys Core emits per unspent
#           are discovered at runtime from Core's OWN scantxoutset output and the
#           impl is required to carry every one of them (a missing key is a real
#           shape divergence and FAILS — it is NOT papered over).
#   empty : an UNMATCHED address (a deterministic key never paid to) ->
#           total_amount 0 / empty unspents on BOTH nodes.
#
# A divergence (impl total_amount/amount != Core, or impl missing Core keys, or
# impl returns matches for the unmatched address) is a REAL finding -> FAIL with
# the divergence; it is never masked.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/rawtx/clearbit_getrawtransaction.sh):
#   no required args, set -uo pipefail, idempotent, trap cleanup, scratch /tmp +
#   UNIQUE ports, ONE clean summary line on stdout, all noise -> stderr/log,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: SCANTXOUTSET clearbit: PASS desc=ok amount=ok shape=ok empty=ok
#   FAIL: SCANTXOUTSET clearbit: FAIL <short reason>
#   SKIP: SCANTXOUTSET clearbit: SKIP clearbit binary not found ...  (GAP_RE)
#
# Touches ONLY /tmp/stxo-clearbit/ + /tmp/stxo-core/ and ports 40217/40237
#   (clearbit RPC/P2P) + 40218/40241 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Any fuser -k redirects stdout (it prints killed PIDs to STDOUT).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

CB_DATADIR="/tmp/stxo-clearbit"
CB_NETDIR="$CB_DATADIR/regtest"
CB_RPC=40217
CB_P2P=40237
CB_LOG="$CB_DATADIR/node.log"

CORE_DATADIR="/tmp/stxo-core"
CORE_RPC=40218
CORE_P2P=40241
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic regtest p2wpkh keys:
#   SECRET  -> $MINER : mined to (gives a mature coinbase to spend).
#   SECRET3 -> $TARGET: the fresh address the known PAYAMT is SENT to (the single
#             matched UTXO scantxoutset must find).
#   SECRET2 -> never paid to (the empty-result check).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SECRET2="2222222222222222222222222222222222222222222222222222222222222223"
SECRET3="3333333333333333333333333333333333333333333333333333333333333334"

NBLOCKS=101         # 101 blocks => block-1 coinbase is mature (spendable).
PAYAMT_SAT=1234500000   # 12.345 BTC sent to $TARGET (a known, exact amount).
FEE_SAT=1000

CB_PID=""
CB_COOKIE=""
CORE_BG=""

log() { echo "[stxo:clearbit] $*" >&2; }

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
    fuser -k "${CB_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CB_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "SCANTXOUTSET clearbit: PASS desc=ok amount=ok shape=ok empty=ok"
    exit 0
}
fail() {
    echo "SCANTXOUTSET clearbit: FAIL $*"
    exit 1
}
# GAP_RE-compatible SKIP (the runner greps for 'not found'/'not built' etc).
skip() {
    echo "SCANTXOUTSET clearbit: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "stxo-clearbit" >/dev/null 2>&1 || true
fuser -k "${CB_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CB_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$CB_DATADIR" "$CORE_DATADIR"
mkdir -p "$CB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
# Missing impl binary -> SKIP (GAP_RE) so the runner does not count it as FAIL.
[[ -x "$NODE_BIN" ]]                 || skip "clearbit binary not found at $NODE_BIN (build: zig build -Doptimize=ReleaseFast)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# Deterministic regtest p2wpkh addresses (Python; no wallet dependency).
derive_addr() {
    python3 - "$TF_PATH" "$1" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
p = ECKey(); p.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(p.get_pubkey().get_bytes(), main=False))
PYEOF
}
MINER=$(derive_addr "$SECRET")    || fail "could not derive miner regtest address"
TARGET=$(derive_addr "$SECRET3")  || fail "could not derive target regtest address"
ADDR2=$(derive_addr "$SECRET2")   || fail "could not derive unmatched regtest address"
[[ -n "$MINER" && -n "$TARGET" && -n "$ADDR2" ]] || fail "empty regtest address"
[[ "$MINER" != "$TARGET" && "$TARGET" != "$ADDR2" && "$MINER" != "$ADDR2" ]] \
    || fail "regtest addresses collided (miner=$MINER target=$TARGET empty=$ADDR2)"
log "miner address:     $MINER"
log "target address:    $TARGET (single matched UTXO)"
log "unmatched address: $ADDR2"

# ── 2. Launch Core oracle (RPC-only: -listen=0). ──────────────────────────
# NOTE: the sandbox occasionally SIGKILLs a freshly-launched bitcoind a few
# seconds after load. launch_core() is retriable; section 4's launch+mine is
# wrapped in a bounded retry so a transient Core death is recovered, not fatal.
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

launch_core() {
    log "launching Core oracle rpc=:$CORE_RPC (-listen=0)"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
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

# ── 3. Launch clearbit on regtest. ────────────────────────────────────────
log "launching clearbit (regtest) rpc=:$CB_RPC p2p=:$CB_P2P -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" \
    --port="$CB_P2P" --rpcport="$CB_RPC" >"$CB_LOG" 2>&1 &
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
    curl -s --max-time 60 -u "$CB_COOKIE" \
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

# ── 4. Mine NBLOCKS to $MINER on BOTH nodes (mature coinbase to spend). ───
# The miner-side flow is wrapped in a function so a single helper rebuilds the
# Core chain deterministically after a sandbox SIGKILL (regtest mining to a fixed
# address is reproducible). All Core mining/sending goes through core_rebuild
# below so any mid-run Core death is recovered, not fatal.
core_mine_miner() {
    core_cli generatetoaddress "$NBLOCKS" "$MINER" >/dev/null 2>&1 || return 1
    [[ "$(core_cli getblockcount 2>/dev/null)" == "$NBLOCKS" ]]
}

log "mining $NBLOCKS blocks on Core (retriable against sandbox SIGKILL)"
core_mined=""
for attempt in 1 2 3 4; do
    if ! core_alive; then
        log "Core not alive (attempt $attempt); relaunching on fresh datadir"
        [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
        rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
        launch_core || { sleep 2; continue; }
    fi
    if core_mine_miner; then core_mined=ok; break; fi
    log "Core mine attempt $attempt failed; retrying"
    sleep 2
done
[[ "$core_mined" == ok ]] || { tail -n 15 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core could not mine $NBLOCKS blocks after retries (sandbox kill?)"; }

log "mining $NBLOCKS blocks on clearbit"
cb_gen=$(cb_rpc generatetoaddress "[$NBLOCKS,\"$MINER\"]")
cb_height=$(echo "$(cb_rpc getblockcount '[]')" | cb_result 2>/dev/null)
[[ "$cb_height" == "$NBLOCKS" ]] || fail "clearbit height $cb_height != $NBLOCKS (gen: $cb_gen)"
log "both nodes at height $NBLOCKS"

# ── 5. Read each node's OWN block-1 coinbase (the input to the send). ─────
# Both nodes mined block 1 to $MINER (p2wpkh). Each spends its OWN block-1
# coinbase (distinct txid per node) -> a fresh p2wpkh output paying $PAYAMT to
# $TARGET. The output amount/scriptPubKey are deterministic and thus identical.
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

# ── 6. Build + sign a coinbase->p2wpkh($TARGET) spend for EACH node. ───────
# Python signs the segwit-v0 spend of the node's block-1 coinbase, paying exactly
# $PAYAMT_SAT to $TARGET and the change back to $MINER. The returned tx hex is
# deterministic given (coinbase value, fee, keys), so the $TARGET output is
# byte-identical across nodes (only the input-coinbase txid differs).
build_send_to_target() {
    # $1 = "txid vout valuesat spkhex"  -> prints signed tx hex
    python3 - "$TF_PATH" "$SECRET" "$SECRET3" "$1" "$PAYAMT_SAT" "$FEE_SAT" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import sign_input_segwitv0, SIGHASH_ALL
from test_framework.script_util import key_to_p2wpkh_script, keyhash_to_p2pkh_script

miner_secret  = bytes.fromhex(sys.argv[2])
target_secret = bytes.fromhex(sys.argv[3])
txid_s, vout_s, val_s, spk_hex = sys.argv[4].split()
in_txid  = txid_s
in_vout  = int(vout_s)
in_value = int(val_s)
in_spk   = bytes.fromhex(spk_hex)
payamt   = int(sys.argv[5])
fee      = int(sys.argv[6])

mkey = ECKey(); mkey.set(miner_secret,  compressed=True)
tkey = ECKey(); tkey.set(target_secret, compressed=True)
mpub = mkey.get_pubkey().get_bytes()
tpub = tkey.get_pubkey().get_bytes()

target_spk = key_to_p2wpkh_script(tpub)   # p2wpkh to $TARGET
change_spk = key_to_p2wpkh_script(mpub)   # change back to $MINER
change = in_value - payamt - fee
assert change > 0, "coinbase too small for payamt+fee"

tx = CTransaction()
tx.version = 2
tx.vin.append(CTxIn(COutPoint(int(in_txid, 16), in_vout), b"", 0xffffffff))
# Put $TARGET first (vout 0) so the matched output's vout is deterministic.
tx.vout.append(CTxOut(payamt, target_spk))
tx.vout.append(CTxOut(change, change_spk))
tx.wit.vtxinwit.append(CTxInWitness())

# BIP143 scriptCode for the p2wpkh coinbase input = P2PKH of its keyhash.
sc = keyhash_to_p2pkh_script(in_spk[2:])
tx.wit.vtxinwit[0].scriptWitness.stack = [mpub]
sign_input_segwitv0(tx, 0, sc, in_value, mkey, SIGHASH_ALL)
print(tx.serialize().hex())
PYEOF
}

# Core path (oracle): build + send + confirm, retriable against SIGKILL.
core_make_target_utxo() {
    local cb1 txhex sent
    cb1=$(read_cb1 core) || return 1
    [[ -n "$cb1" ]] || return 1
    txhex=$(build_send_to_target "$cb1") || return 1
    [[ -n "$txhex" ]] || return 1
    sent=$(core_cli sendrawtransaction "$txhex" 2>>"$CORE_LOG")
    [[ "${#sent}" == 64 ]] || return 1
    CORE_SEND_TXID="$sent"
    core_cli generatetoaddress 1 "$MINER" >/dev/null 2>&1 || return 1
    return 0
}

# Rebuild the entire Core chain (mine + target-UTXO) from scratch if Core died.
core_rebuild() {
    log "rebuilding Core chain from scratch (mine + target send)"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    for _ in 1 2 3; do launch_core && break; sleep 2; done
    core_alive || return 1
    core_mine_miner || return 1
    core_make_target_utxo || return 1
    return 0
}

CORE_SEND_TXID=""
if core_alive; then
    core_make_target_utxo || { log "Core target-UTXO build failed; rebuilding"; core_rebuild || fail "Core could not build the target UTXO"; }
else
    core_rebuild || fail "Core could not build the target UTXO (rebuild failed)"
fi
[[ "${#CORE_SEND_TXID}" == 64 ]] || fail "Core send txid invalid: $CORE_SEND_TXID"
log "Core   send txid: $CORE_SEND_TXID"

# clearbit path: same build, on its own block-1 coinbase.
CB_CB1=$(read_cb1 cb) || fail "could not read clearbit block-1 coinbase"
[[ -n "$CB_CB1" ]] || fail "empty clearbit block-1 coinbase read"
CB_TXHEX=$(build_send_to_target "$CB_CB1") || fail "could not build clearbit send tx"
[[ -n "$CB_TXHEX" ]] || fail "empty clearbit send tx hex"
CB_SEND=$(cb_rpc sendrawtransaction "[\"$CB_TXHEX\"]")
CB_SEND_TXID=$(echo "$CB_SEND" | cb_result 2>/dev/null) || fail "clearbit sendrawtransaction failed: $CB_SEND"
[[ "${#CB_SEND_TXID}" == 64 ]] || fail "clearbit sendrawtransaction did not return a txid: $CB_SEND"
cb_conf=$(cb_rpc generatetoaddress "[1,\"$MINER\"]")
echo "$cb_conf" | cb_result >/dev/null 2>&1 || fail "clearbit could not mine the confirming block: $cb_conf"
log "clearbit send txid: $CB_SEND_TXID"

# ── 7. scantxoutset start [addr($TARGET)] on BOTH nodes. ──────────────────
DESC="addr($TARGET)"
log "scantxoutset start with desc=$DESC on both nodes"

core_scan() {
    # $1 = descriptor string -> prints Core's scantxoutset result JSON
    core_cli scantxoutset start "[{\"desc\":\"$1\"}]"
}
if ! core_alive; then
    log "Core not alive before scan; rebuilding chain deterministically"
    core_rebuild || fail "Core oracle unavailable for scan (rebuild failed)"
fi
CORE_SCAN=$(core_scan "$DESC") || fail "Core scantxoutset start errored: $CORE_SCAN"
[[ -n "$CORE_SCAN" ]] || fail "Core scantxoutset returned empty"
log "Core scan: $CORE_SCAN"

CB_SCAN=$(echo "$(cb_rpc scantxoutset "[\"start\",[{\"desc\":\"$DESC\"}]]")" | cb_result 2>/dev/null) \
    || fail "clearbit scantxoutset start errored"
[[ -n "$CB_SCAN" ]] || fail "clearbit scantxoutset returned empty"
log "clearbit scan: $CB_SCAN"

# ── 8. Differential comparison: desc / amount / shape. ────────────────────
# Expected: each node returns EXACTLY ONE unspent (the $TARGET output), with
# vout/amount/scriptPubKey identical across nodes and txid == that node's send.
VERDICT=$(python3 - "$CB_SCAN" "$CORE_SCAN" \
                    "$CB_SEND_TXID" "$CORE_SEND_TXID" "$PAYAMT_SAT" <<'PYEOF'
import sys, json

cb   = json.loads(sys.argv[1])
core = json.loads(sys.argv[2])
cb_send_txid   = sys.argv[3]
core_send_txid = sys.argv[4]
payamt_btc     = int(sys.argv[5]) / 100_000_000.0

def f(reason):
    print("FAIL " + reason); sys.exit(0)

def amt8(x):
    return "%.8f" % float(x)

# --- top-level shape: success(bool) + total_amount + unspents present on impl ---
if "success" not in cb:        f("clearbit result missing 'success'")
if not isinstance(cb["success"], bool): f("clearbit 'success' not a bool: %r" % cb["success"])
if cb["success"] is not True:  f("clearbit 'success' is not true: %r" % cb["success"])
if "total_amount" not in cb:   f("clearbit result missing 'total_amount'")
if "unspents" not in cb:       f("clearbit result missing 'unspents'")
if not isinstance(cb["unspents"], list): f("clearbit 'unspents' not an array")

# Core oracle self-shape (the contract).
for k in ("success", "txouts", "height", "bestblock", "unspents", "total_amount"):
    if k not in core: f("Core scantxoutset missing %s (oracle changed?)" % k)

# Exactly one match expected on each node.
if len(core["unspents"]) != 1:
    f("Core found %d unspents for $TARGET (expected exactly 1; test setup broken)" % len(core["unspents"]))
if len(cb["unspents"]) != 1:
    f("clearbit found %d unspents for the target address (expected exactly 1)" % len(cb["unspents"]))

cb_match   = cb["unspents"][0]
core_match = core["unspents"][0]

# --- amount: total_amount byte-equal (8-dp BTC) and == $PAYAMT on both ---
if amt8(cb["total_amount"]) != amt8(core["total_amount"]):
    f("total_amount mismatch: clearbit=%s core=%s" % (amt8(cb["total_amount"]), amt8(core["total_amount"])))
if amt8(core["total_amount"]) != amt8(payamt_btc):
    f("Core total_amount=%s != expected payamt=%s (oracle/test broken)" % (amt8(core["total_amount"]), amt8(payamt_btc)))
if amt8(cb["total_amount"]) != amt8(payamt_btc):
    f("clearbit total_amount=%s != expected payamt=%s" % (amt8(cb["total_amount"]), amt8(payamt_btc)))

# --- desc: the matched unspent (txid/vout/amount) is correct + congruent ---
if cb_match.get("txid") != cb_send_txid:
    f("clearbit matched txid=%r != its send txid %r" % (cb_match.get("txid"), cb_send_txid))
if core_match.get("txid") != core_send_txid:
    f("Core matched txid=%r != its send txid %r (oracle)" % (core_match.get("txid"), core_send_txid))
# vout/amount/scriptPubKey identical across nodes (deterministic spend).
if cb_match.get("vout") != core_match.get("vout"):
    f("matched-unspent vout mismatch clearbit=%r core=%r" % (cb_match.get("vout"), core_match.get("vout")))
if amt8(cb_match.get("amount")) != amt8(core_match.get("amount")):
    f("matched-unspent amount mismatch clearbit=%s core=%s" % (amt8(cb_match.get("amount")), amt8(core_match.get("amount"))))
if amt8(cb_match.get("amount")) != amt8(payamt_btc):
    f("clearbit matched-unspent amount=%s != payamt=%s" % (amt8(cb_match.get("amount")), amt8(payamt_btc)))
if cb_match.get("scriptPubKey") != core_match.get("scriptPubKey"):
    f("matched-unspent scriptPubKey mismatch clearbit=%r core=%r" % (cb_match.get("scriptPubKey"), core_match.get("scriptPubKey")))

# The $TARGET output is a NORMAL (non-coinbase) output on both nodes.
if cb_match.get("coinbase") is not False:
    f("clearbit matched-unspent coinbase flag != false: %r" % cb_match.get("coinbase"))
if core_match.get("coinbase") is not False:
    f("Core matched-unspent coinbase flag != false (oracle): %r" % core_match.get("coinbase"))

# --- shape: impl unspent objects must carry CORE'S KEYS (discovered at runtime) ---
core_keys = set(core_match.keys())
cb_keys   = set(cb_match.keys())
missing   = core_keys - cb_keys
if missing:
    f("clearbit matched unspent MISSING Core keys: %s (core keys=%s, clearbit keys=%s)"
      % (sorted(missing), sorted(core_keys), sorted(cb_keys)))

print("OK")
PYEOF
) || fail "scan comparator crashed (cb=$CB_SCAN core=$CORE_SCAN)"
[[ "$VERDICT" == OK ]] || fail "${VERDICT#FAIL }"

# ── 9. empty: scantxoutset for the never-paid address -> 0 / [] on both. ──
DESC_EMPTY="addr($ADDR2)"
log "scantxoutset start with unmatched desc=$DESC_EMPTY on both nodes"

if ! core_alive; then
    log "Core not alive before empty-scan; rebuilding chain deterministically"
    core_rebuild || fail "Core oracle unavailable for empty-scan (rebuild failed)"
fi
CORE_EMPTY=$(core_scan "$DESC_EMPTY") || fail "Core scantxoutset (empty) errored: $CORE_EMPTY"
CB_EMPTY=$(echo "$(cb_rpc scantxoutset "[\"start\",[{\"desc\":\"$DESC_EMPTY\"}]]")" | cb_result 2>/dev/null) \
    || fail "clearbit scantxoutset (empty) errored"
[[ -n "$CORE_EMPTY" && -n "$CB_EMPTY" ]] || fail "empty-scan returned nothing (core=[$CORE_EMPTY] cb=[$CB_EMPTY])"

EMPTY_VERDICT=$(python3 - "$CB_EMPTY" "$CORE_EMPTY" <<'PYEOF'
import sys, json
cb   = json.loads(sys.argv[1])
core = json.loads(sys.argv[2])
def f(r): print("FAIL "+r); sys.exit(0)
def amt8(x): return "%.8f" % float(x)

# Core oracle must itself be empty for an unfunded address.
if core.get("unspents"):
    f("Core found unspents for an unmatched address (oracle/test broken): %r" % core["unspents"])
if amt8(core.get("total_amount", 0)) != "0.00000000":
    f("Core total_amount nonzero for unmatched address: %s" % amt8(core.get("total_amount")))

# clearbit must match: success true, empty unspents, total_amount 0.
if cb.get("success") is not True:
    f("clearbit empty-scan success not true: %r" % cb.get("success"))
if cb.get("unspents"):
    f("clearbit found unspents for an unmatched address: %r" % cb["unspents"])
if amt8(cb.get("total_amount", 0)) != "0.00000000":
    f("clearbit total_amount nonzero for unmatched address: %s" % amt8(cb.get("total_amount")))
print("OK")
PYEOF
) || fail "empty comparator crashed (cb=$CB_EMPTY core=$CORE_EMPTY)"
[[ "$EMPTY_VERDICT" == OK ]] || fail "${EMPTY_VERDICT#FAIL }"

log "all checks passed (desc/amount/shape/empty)"
pass
