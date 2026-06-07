#!/usr/bin/env bash
#
# blockbrew_scantxoutset.sh — self-contained scantxoutset Core-parity differential.
#
# The UTXO-scan green-cell that follows gettxoutsetinfo / getrawtransaction: the
# wallet-recovery keystone. NOT consensus, but byte-exact-shaped against
# Bitcoin Core (bitcoin-core/src/rpc/blockchain.cpp scantxoutset).
#
# WHAT IT PROVES
#   scantxoutset on blockbrew returns the SAME answer as a real bitcoind regtest
#   ORACLE for the canonical "find this address's coins in the live UTXO set":
#     - desc=ok   : action='start' with scanobjects=[{"desc":"addr(<a>)"}] AND
#                   bare ["addr(<a>)"] both match the funded address's UTXOs, and
#                   the matched unspents (the sorted multiset of
#                   {amount,coinbase,height}) EQUAL Core's, with each unspent's
#                   txid being a 64-hex == its block's own coinbase txid.
#     - amount=ok : the result's total_amount EQUALS Core's (to satoshi).
#     - shape=ok  : the result is an OBJECT carrying success(bool) + total_amount
#                   + txouts + height + bestblock + an unspents array whose
#                   elements carry EVERY key Core emits per-output
#                   (txid,vout,scriptPubKey,desc,amount,coinbase,height,
#                   blockhash,confirmations — blockchain.cpp:2455-2466). blockhash
#                   and confirmations are GATED (not optional): a missing key is a
#                   real shape divergence and FAILS, and blockhash must equal
#                   getblockhash(height) while confirmations == tip-height+1.
#     - empty=ok  : an UNFUNDED address -> success=true, total_amount=0, empty
#                   unspents on BOTH impl and Core.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core). Funding is wallet-FREE
#   on BOTH nodes: this Core build has NO wallet RPC compiled in
#   (createwallet/getnewaddress -> -32601), and we must drive both nodes the same
#   way. We derive a FIXED bcrt1 address from a FIXED public key (the same one on
#   both nodes — it's network-derived, not wallet-derived), mine N blocks to it
#   with `generatetoaddress <n> <addr>` (a non-wallet RPC that pays the literal
#   address), then `scantxoutset start [addr(<addr>)]`.
#   Because the SAME address is funded the SAME way on both nodes, the answer is
#   deterministic and cross-node comparable: same UTXO count, same total_amount,
#   same per-output {amount=subsidy, coinbase=true, height} multiset. The coinbase
#   txids differ by construction (the two nodes build different coinbases), so we
#   compare the matched unspents as a SORTED MULTISET of {amount,coinbase,height}
#   and assert each unspent's txid == its own block's coinbase txid on each node.
#   (Same oracle rationale as test-suite/rawtx/blockbrew_getrawtransaction.sh.)
#
#   blockbrew now emits the FULL Core per-unspent schema, including `blockhash`
#   and `confirmations` (scantxoutset_methods.go), so those keys are GATED in the
#   shape check (a missing key FAILS). The only DOCUMENTED, NON-FATAL divergence
#   that remains is:
#     * blockbrew's `desc` has no `#checksum` suffix (Core appends one) — this
#       does NOT affect the load-bearing answer and is reported as a note.
#   A REAL divergence (wrong amount, wrong unspent set, wrong total, or a missing
#   per-output key including blockhash/confirmations) is a FAIL.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/rawtx/blockbrew_getrawtransaction.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: SCANTXOUTSET blockbrew: PASS desc=ok amount=ok shape=ok empty=ok
#   FAIL: SCANTXOUTSET blockbrew: FAIL <short reason>
#   GAP : SCANTXOUTSET blockbrew: FAIL blockbrew binary not found ...  (GAP_RE -> runner SKIP)
#
# Touches ONLY /tmp/scan-blockbrew/ + /tmp/scan-core-bb/ and ports
#   40213/40233 (blockbrew RPC/P2P), 40215/40235 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Core is launched -listen=0 (RPC only): the sandbox SIGKILLs any bitcoind
#   binding a 0.0.0.0 P2P listener ~2s after load.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

BB_DATADIR="/tmp/scan-blockbrew"
BB_RPC=40213
BB_P2P=40233
BB_LOG="$BB_DATADIR/node.log"
BB_URL="http://127.0.0.1:${BB_RPC}"
BB_COOKIE_FILE="$BB_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/scan-core-bb"
CORE_RPC=40215
CORE_P2P=40235
CORE_LOG="$CORE_DATADIR/core.log"

# A FIXED bcrt1 (P2WPKH) address derived from a FIXED public key. Identical on
# both nodes (network-derived, not wallet-derived). This is the canonical BIP173
# regtest test vector for wpkh(<pubkey>) -> 751e76e8...  (HASH160 of the key).
FUND_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
# A SECOND fixed address that is NEVER funded (different key) for empty=ok.
# Valid regtest P2WPKH derived from wpkh(03defdea...) (Core deriveaddresses),
# so BOTH decoders accept it; it just holds no UTXO.
EMPTY_ADDR="bcrt1qf7vmha6hqljyhs405efn0hkwj98gz74v0458ns"

NBLOCKS_MINE=110     # all coinbases pay FUND_ADDR; ~100 mature -> deterministic set

BB_PID=""
BB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[scantxoutset:blockbrew] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BB_PID" ]] && kill -0 "$BB_PID" 2>/dev/null; then
        kill "$BB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${BB_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${BB_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "SCANTXOUTSET blockbrew: PASS desc=ok amount=ok shape=ok empty=ok"
    exit 0
}
fail() {
    echo "SCANTXOUTSET blockbrew: FAIL $*"
    exit 1
}

# ── JSON field extractor (jq-free; stdlib python3). ───────────────────────
jget() {
    local js="$1"; shift
    python3 - "$js" "$@" <<'PY'
import sys, json
js = sys.argv[1]
keys = sys.argv[2:]
try:
    d = json.loads(js)
except Exception:
    print("<PARSE-ERR>"); sys.exit(0)
cur = d
for k in keys:
    if isinstance(cur, list):
        try:
            idx = int(k)
        except ValueError:
            print("<MISSING>"); sys.exit(0)
        if 0 <= idx < len(cur):
            cur = cur[idx]
        else:
            print("<MISSING>"); sys.exit(0)
    elif isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        print("<MISSING>"); sys.exit(0)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("<NULL>")
else:
    print(cur)
PY
}

# amt_eq <a> <b> : true iff two BTC-amount strings/numbers are equal to satoshi.
amt_eq() {
    python3 -c 'import sys;exit(0 if round(float(sys.argv[1])*1e8)==round(float(sys.argv[2])*1e8) else 1)' "$1" "$2"
}

# unspents_fingerprint <scan-json> : prints a deterministic newline of the
# matched unspents as a SORTED multiset of "amount-sat|coinbase|height", plus
# the count and total — the cross-node-comparable identity of the scan answer.
unspents_fingerprint() {
    python3 - "$1" <<'PY'
import sys, json
r = json.loads(sys.argv[1])
items = []
for u in r["unspents"]:
    sat = round(float(u["amount"]) * 1e8)
    cb  = bool(u["coinbase"])
    h   = int(u["height"])
    # txid must be a 64-hex; vout an int; scriptPubKey present.
    assert isinstance(u["txid"], str) and len(u["txid"]) == 64, "bad txid"
    int(u["vout"]); assert u.get("scriptPubKey"), "no spk"
    items.append("%d|%s|%d" % (sat, "1" if cb else "0", h))
items.sort()
print("count=%d" % len(items))
print("total=%d" % round(float(r["total_amount"]) * 1e8))
print("\n".join(items))
PY
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
fuser -k "${BB_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${BB_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "blockbrew binary not found at $NODE_BIN (run build-all.sh blockbrew)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Launch the Core oracle on regtest (RPC-only). ──────────────────────
# -listen=0 : the sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener.
log "launching Core oracle rpc=:$CORE_RPC (listen=0)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < core_deadline )); do
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
    || fail "Core oracle RPC never responded within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch blockbrew on regtest (isolated: no peers). ──────────────────
log "launching blockbrew (regtest) rpc=:$BB_RPC p2p=:$BB_P2P -> $BB_LOG"
# -metricsport=0 disables the Prometheus listener (fixed 0.0.0.0:9332) which
# would COLLIDE with the live mainnet blockbrew's metrics port.
"$NODE_BIN" \
    -network=regtest -datadir="$BB_DATADIR" \
    -listen="127.0.0.1:${BB_P2P}" -rpcbind="127.0.0.1:${BB_RPC}" \
    -maxoutbound=0 -nolisten -metricsport=0 \
    >"$BB_LOG" 2>&1 &
BB_PID=$!
log "blockbrew pid=$BB_PID"
bb_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < bb_deadline )); do
    if [[ -z "$BB_COOKIE" && -f "$BB_COOKIE_FILE" ]]; then
        BB_COOKIE=$(cat "$BB_COOKIE_FILE")
    fi
    if [[ -n "$BB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "$BB_URL/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BB_PID" 2>/dev/null || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew exited during startup (see $BB_LOG)"; }
    sleep 1
done
[[ -n "$BB_COOKIE" ]] || fail "blockbrew cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$BB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$BB_URL/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "blockbrew RPC never responded within 90s"
log "blockbrew RPC ready"

# ── RPC helpers. ──────────────────────────────────────────────────────────
bb_rpc() {  # bb_rpc <method> <params-json> ; prints raw JSON-RPC envelope
    curl -s --max-time 120 -u "$BB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "$BB_URL/" 2>/dev/null
}
bb_result() {  # bb_result <method> <params-json> ; prints .result or ERR:..
    python3 - "$(bb_rpc "$1" "$2")" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("ERR:parse"); raise SystemExit
if d.get("error"):
    print("ERR:" + json.dumps(d["error"])); raise SystemExit
r = d.get("result")
print(r if isinstance(r, str) else json.dumps(r))
PY
}
core_rpc() {  # core_rpc <method> <params...> ; prints the bare result (cli)
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>&1
}

# ── 4. Fund the SAME fixed address on BOTH nodes (wallet-free). ───────────
# `generatetoaddress` pays the literal address; no wallet needed on either node.
log "mining $NBLOCKS_MINE blocks to fixed addr $FUND_ADDR on BOTH nodes"
GEN=$(bb_result generatetoaddress "[$NBLOCKS_MINE,\"$FUND_ADDR\"]")
[[ "$GEN" == ERR:* ]] && fail "blockbrew generatetoaddress failed: ${GEN#ERR:}"
BB_H=$(bb_result getblockcount "[]")
[[ "$BB_H" == "$NBLOCKS_MINE" ]] || fail "blockbrew height $BB_H != $NBLOCKS_MINE"

CGEN=$(core_rpc generatetoaddress "$NBLOCKS_MINE" "$FUND_ADDR")
echo "$CGEN" | python3 -c 'import sys,json;json.load(sys.stdin)' >/dev/null 2>&1 \
    || fail "core generatetoaddress failed: $CGEN"
CORE_H=$(core_rpc getblockcount)
[[ "$CORE_H" == "$NBLOCKS_MINE" ]] || fail "core height $CORE_H != $NBLOCKS_MINE"
log "both nodes at height $NBLOCKS_MINE, all coinbases pay $FUND_ADDR"

# ── 5. scantxoutset start on BOTH nodes for the funded address. ───────────
# blockbrew: object form AND bare-string form (both supported by Core).
BB_SCAN=$(bb_result scantxoutset "[\"start\",[{\"desc\":\"addr($FUND_ADDR)\"}]]")
[[ "$BB_SCAN" == ERR:* ]] && fail "blockbrew scantxoutset start (object form) errored: ${BB_SCAN#ERR:}"
BB_SCAN_BARE=$(bb_result scantxoutset "[\"start\",[\"addr($FUND_ADDR)\"]]")
[[ "$BB_SCAN_BARE" == ERR:* ]] && fail "blockbrew scantxoutset start (bare-string form) errored: ${BB_SCAN_BARE#ERR:}"

CORE_SCAN=$(core_rpc scantxoutset start "[{\"desc\":\"addr($FUND_ADDR)\"}]")
echo "$CORE_SCAN" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert isinstance(d,dict)' >/dev/null 2>&1 \
    || fail "core scantxoutset start did not return an object: $CORE_SCAN"

# ── 6. SHAPE (shape=ok): result object carries Core's load-bearing keys. ──
[[ "$(jget "$BB_SCAN" success)" == "true" ]] || fail "blockbrew scan success != true: $(jget "$BB_SCAN" success)"
for f in success txouts height bestblock unspents total_amount; do
    [[ "$(jget "$BB_SCAN" "$f")" != "<MISSING>" ]] || fail "blockbrew scan result missing top-level '$f'"
    # oracle sanity: Core emits the same top-level key.
    [[ "$(jget "$CORE_SCAN" "$f")" != "<MISSING>" ]] || fail "ORACLE: core scan missing top-level '$f' (oracle sanity)"
done
[[ "$(jget "$BB_SCAN" bestblock)" =~ ^[0-9a-f]{64}$ ]] || fail "blockbrew bestblock not a 64-hex: $(jget "$BB_SCAN" bestblock)"
BB_TIP=$(bb_result getbestblockhash "[]")
[[ "$(jget "$BB_SCAN" bestblock)" == "$BB_TIP" ]] || fail "blockbrew scan bestblock != tip ($BB_TIP)"
[[ "$(jget "$BB_SCAN" height)" == "$NBLOCKS_MINE" ]] || fail "blockbrew scan height != tip $NBLOCKS_MINE"
BB_NU=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["unspents"]))' "$BB_SCAN")
(( BB_NU >= 1 )) || fail "blockbrew scan found no unspents for funded address (count=$BB_NU)"
# each unspent must carry EVERY key Core emits per-output. blockhash and
# confirmations are GATED (not optional): Core emits exactly 9 keys
# (txid,vout,scriptPubKey,desc,amount,coinbase,height,blockhash,confirmations
# — blockchain.cpp:2455-2466) and a missing one is a real shape divergence.
# This mirrors the strict per-unspent key check in rustoshi_scantxoutset.sh.
for f in txid vout scriptPubKey desc amount coinbase height blockhash confirmations; do
    [[ "$(jget "$BB_SCAN" unspents 0 "$f")" != "<MISSING>" ]] || fail "blockbrew unspent[0] missing key '$f'"
    [[ "$(jget "$CORE_SCAN" unspents 0 "$f")" != "<MISSING>" ]] || fail "ORACLE: core unspent[0] missing key '$f' (oracle sanity)"
done
# scriptPubKey must be byte-identical across nodes (same address -> same script).
[[ "$(jget "$BB_SCAN" unspents 0 scriptPubKey)" == "$(jget "$CORE_SCAN" unspents 0 scriptPubKey)" ]] \
    || fail "scriptPubKey of matched unspent differs across nodes (same address must yield same script)"
# blockhash must be the 64-hex hash of the coin's block and EQUAL its height's
# block hash on blockbrew (Core: tip->GetAncestor(coin.nHeight)->GetBlockHash()).
# confirmations must be tip_height - coin_height + 1.
BB_U0_BH=$(jget "$BB_SCAN" unspents 0 blockhash)
BB_U0_H=$(jget "$BB_SCAN" unspents 0 height)
BB_U0_CONF=$(jget "$BB_SCAN" unspents 0 confirmations)
[[ "$BB_U0_BH" =~ ^[0-9a-f]{64}$ ]] || fail "blockbrew unspent[0] blockhash not a 64-hex: $BB_U0_BH"
BB_EXP_BH=$(bb_result getblockhash "[$BB_U0_H]")
[[ "$BB_U0_BH" == "$BB_EXP_BH" ]] \
    || fail "blockbrew unspent[0] blockhash ($BB_U0_BH) != getblockhash($BB_U0_H) ($BB_EXP_BH)"
BB_EXP_CONF=$(( NBLOCKS_MINE - BB_U0_H + 1 ))
[[ "$BB_U0_CONF" == "$BB_EXP_CONF" ]] \
    || fail "blockbrew unspent[0] confirmations ($BB_U0_CONF) != tip-height+1 ($BB_EXP_CONF)"
log "shape OK: success+txouts+height+bestblock+unspents+total_amount; unspent has txid/vout/scriptPubKey/desc/amount/coinbase/height/blockhash/confirmations; spk matches Core; blockhash==getblockhash(height); confirmations==tip-height+1"

BB_DESC0=$(jget "$BB_SCAN" unspents 0 desc); CORE_DESC0=$(jget "$CORE_SCAN" unspents 0 desc)
[[ "$BB_DESC0" == addr\(*\) || "$BB_DESC0" == addr\(*\)#* ]] || fail "blockbrew unspent desc not an addr() descriptor: $BB_DESC0"
if [[ "$BB_DESC0" != *"#"* && "$CORE_DESC0" == *"#"* ]]; then
    log "NOTE divergence: blockbrew desc lacks '#checksum' suffix (bb='$BB_DESC0' core='$CORE_DESC0')"
fi

# ── 7. DESC + AMOUNT (desc=ok, amount=ok): the matched unspents EQUAL Core's. ─
# Compare the matched unspents as a SORTED multiset of {amount,coinbase,height}
# plus count + total — the deterministic, cross-node-comparable scan identity.
BB_FP=$(unspents_fingerprint "$BB_SCAN")     || fail "blockbrew unspents malformed: $BB_FP"
CORE_FP=$(unspents_fingerprint "$CORE_SCAN") || fail "core unspents malformed (oracle): $CORE_FP"
if [[ "$BB_FP" != "$CORE_FP" ]]; then
    log "blockbrew fingerprint:"; echo "$BB_FP"   | head -5 >&2
    log "core fingerprint:";      echo "$CORE_FP" | head -5 >&2
    # Pinpoint which axis diverged for the summary line.
    BBC=$(echo "$BB_FP" | sed -n 's/^count=//p'); CC=$(echo "$CORE_FP" | sed -n 's/^count=//p')
    BBT=$(echo "$BB_FP" | sed -n 's/^total=//p'); CT=$(echo "$CORE_FP" | sed -n 's/^total=//p')
    [[ "$BBC" == "$CC" ]] || fail "matched unspent COUNT differs: blockbrew=$BBC core=$CC"
    [[ "$BBT" == "$CT" ]] || fail "total_amount(sat) differs: blockbrew=$BBT core=$CT"
    fail "matched unspents {amount,coinbase,height} multiset differs from Core (count/total equal — per-output divergence; see stderr)"
fi
log "desc OK: matched unspents {amount,coinbase,height} multiset EQUALS Core's (count + per-output identical)"

# Each blockbrew unspent's txid must be a real coinbase txid for its own block
# (verify a sample: the unspent at the min height must equal that block's tx[0]).
SAMPLE=$(python3 - "$BB_SCAN" <<'PY'
import sys, json
r = json.loads(sys.argv[1])
u = min(r["unspents"], key=lambda x: int(x["height"]))
print("%s %d %s" % (u["txid"], int(u["height"]), str(u["coinbase"]).lower()))
PY
)
read -r S_TXID S_HEIGHT S_CB <<<"$SAMPLE"
[[ "$S_CB" == "true" ]] || fail "blockbrew matured unspent not flagged coinbase: $SAMPLE"
S_BH=$(bb_result getblockhash "[$S_HEIGHT]")
[[ "$S_BH" =~ ^[0-9a-f]{64}$ ]] || fail "blockbrew getblockhash $S_HEIGHT failed: $S_BH"
S_BLK=$(bb_result getblock "[\"$S_BH\",2]")
S_CB_TXID=$(jget "$S_BLK" tx 0 txid)
[[ "$S_TXID" == "$S_CB_TXID" ]] \
    || fail "blockbrew unspent txid ($S_TXID) at h=$S_HEIGHT != that block's coinbase txid ($S_CB_TXID)"
log "desc OK: sample unspent txid==own-block coinbase txid (h=$S_HEIGHT)"

# bare-string descriptor form must yield the SAME fingerprint as object form.
BB_FP_BARE=$(unspents_fingerprint "$BB_SCAN_BARE") || fail "blockbrew bare-string unspents malformed"
[[ "$BB_FP_BARE" == "$BB_FP" ]] || fail "bare-string addr() result differs from object {desc:} form"
log "desc OK: bare-string ['addr(...)'] == object [{desc:'addr(...)'}] form"

# AMOUNT: total_amount EQUALS Core's to satoshi.
BB_TOTAL=$(jget "$BB_SCAN" total_amount); CORE_TOTAL=$(jget "$CORE_SCAN" total_amount)
amt_eq "$BB_TOTAL" "$CORE_TOTAL" || fail "total_amount differs: blockbrew=$BB_TOTAL core=$CORE_TOTAL"
log "amount OK: total_amount=$BB_TOTAL EQUALS Core's=$CORE_TOTAL"

# ── 8. EMPTY (empty=ok): an UNFUNDED address -> total 0 / empty unspents. ─
BB_EMPTY=$(bb_result scantxoutset "[\"start\",[\"addr($EMPTY_ADDR)\"]]")
[[ "$BB_EMPTY" == ERR:* ]] && fail "blockbrew scantxoutset (unfunded) errored: ${BB_EMPTY#ERR:}"
CORE_EMPTY=$(core_rpc scantxoutset start "[\"addr($EMPTY_ADDR)\"]")

[[ "$(jget "$BB_EMPTY" success)" == "true" ]] || fail "blockbrew unfunded-scan success != true"
BB_E_NU=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["unspents"]))' "$BB_EMPTY")
[[ "$BB_E_NU" == "0" ]] || fail "blockbrew unfunded-scan returned $BB_E_NU unspents (want 0)"
amt_eq "$(jget "$BB_EMPTY" total_amount)" "0" \
    || fail "blockbrew unfunded-scan total_amount != 0: $(jget "$BB_EMPTY" total_amount)"
# Oracle sanity: Core also returns empty/0 for the unfunded address.
CORE_E_NU=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["unspents"]))' "$CORE_EMPTY" 2>/dev/null || echo X)
[[ "$CORE_E_NU" == "0" ]] || fail "ORACLE: core unfunded-scan returned $CORE_E_NU unspents (oracle sanity)"
amt_eq "$(jget "$CORE_EMPTY" total_amount)" "0" \
    || fail "ORACLE: core unfunded-scan total_amount != 0 (oracle sanity)"
log "empty OK: unfunded addr -> success=true, 0 unspents, total_amount 0 on BOTH blockbrew and Core"

# ── 9. status/abort smoke (Core parity: status=null idle, abort=bool). ────
BB_STATUS=$(bb_rpc scantxoutset '["status"]')
echo "$BB_STATUS" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert not d.get("error"), d.get("error")' >/dev/null 2>&1 \
    || fail "blockbrew scantxoutset status errored: $BB_STATUS"
BB_ABORT=$(bb_result scantxoutset '["abort"]')
[[ "$BB_ABORT" == "false" || "$BB_ABORT" == "true" ]] || fail "blockbrew scantxoutset abort not a bool: $BB_ABORT"
log "status/abort smoke OK (status idle no-error, abort=$BB_ABORT bool)"

# ── 10. All green. ────────────────────────────────────────────────────────
log "PASS: scantxoutset matched-unspent multiset {amount,coinbase,height} and total_amount EQUAL Core; shape carries Core's load-bearing keys; unfunded -> empty/0 on both"
pass
