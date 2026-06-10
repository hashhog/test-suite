#!/usr/bin/env bash
#
# rustoshi_watchonly.sh — Core-faithful WATCH-ONLY import differential test.
#
# PARITY BAR (Core v31.99): the importdescriptors path on a
# disable_private_keys wallet — src/wallet/rpc/backup.cpp:302 is the ONLY
# watch-only import path left in Core; importaddress/importpubkey/importmulti
# are REMOVED and return -32601 on the oracle itself (wallet.cpp:904-960,
# server.cpp:499), so the legacy probe here is INFORMATIONAL only.
#
# Sequence (all graded checks via watchonly/wo_lib.py, single verdict line):
#   1. fund EXTERNAL offline-constructed keys BEFORE any import:
#      gen 1->A, 1->B, 1->W, 101->M  (tip 104 < the regtest 150 halving;
#      A/B/W coinbases are mature; 50 BTC each, 150 total)
#   2. createwallet wo {disable_private_keys:true, blank:true} (Core shape,
#      positional + name-only fallbacks; dpk reported as an info tag)
#   3. importdescriptors [addr(A)#chk, wpkh(PUBW)#chk] timestamp:0 ->
#      array of {"success":true}, same length as the request
#   4. negatives: no checksum -> per-element -5 "Missing checksum";
#      private-key descriptor -> -4 (backup.cpp:224-226)
#   5. importdescriptors addr(B)#chk timestamp:0 -> the PRE-IMPORT funding
#      must be credited (rescan semantics: ts 0 clamps to 1, scans from
#      genesis — backup.cpp:376-409)
#   6. observability: listunspent A/B/W @50; balance ~150 (getbalances
#      mine.trusted per coins.cpp:401-455, fallbacks recorded);
#      getaddressinfo A -> ismine:true (iswatchonly NEVER asserted true —
#      deprecated always-false, addresses.cpp:383,478)
#   7. nonspend: sendtoaddress on wo must error (watch-only funds)
#   8. legacy importaddress/importpubkey probe — informational tag only
#
# SKIP-vs-FAIL contract (run-watchonly-regression.sh GAP_RE): ONLY binary/
# interpreter/boot preconditions may use "not found"/"cannot boot" wording;
# every missing or erroring watch-only RPC is a FAIL ("<x>=missing" —
# wo_lib.py sanitizes impl error strings against GAP_RE collisions).
#
# Summary line (stdout): "WATCHONLY rustoshi: PASS|FAIL ...". exit 0/1.
# Touches ONLY /tmp/hashhog-wofleet-rustoshi/ and ports 41400 (RPC) / 41420
# (P2P). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

BASEDIR="/home/work/hashhog"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WO_LIB="$SCRIPT_DIR/wo_lib.py"
BIN="$BASEDIR/rustoshi/target/release/rustoshi"
DATADIR="/tmp/hashhog-wofleet-rustoshi"
RPC_PORT=21400
P2P_PORT=21420
LOG="$DATADIR/node.log"
NODE_PID=""

log() { echo "[watchonly] $*" >&2; }
fail() { echo "WATCHONLY rustoshi: FAIL $*"; exit 1; }
# boot/build gaps ONLY (GAP_RE vocabulary -> runner classifies SKIP)
boot_gap() { echo "WATCHONLY rustoshi: FAIL cannot boot: $*"; exit 1; }

cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NODE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    [[ -n "${HASHHOG_KEEP_SCRATCH:-}" ]] || rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── RPC helper (cookie auth; base URL — wallet calls go via /wallet/). ─────
rpc() {
    local method=$1 params="${2:-[]}" auth=""
    for c in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
        if [[ -f "$c" ]]; then auth="-u $(cat "$c")"; break; fi
    done
    # shellcheck disable=SC2086
    curl -s --max-time 40 $auth \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    boot_gap "port ${RPC_PORT}/${P2P_PORT} already LISTENING (refusing to kill: fuser-on-ephemeral-port killed mainnet nodes, 2026-06-10 incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR" || fail "cannot create scratch datadir $DATADIR"

# ── 1. Preconditions (GAP_RE wording allowed here ONLY). ───────────────────
[[ -x "$BIN" ]] || boot_gap "rustoshi binary not found at $BIN"
[[ -f "$WO_LIB" ]] || fail "wo_lib.py absent at $WO_LIB"
python3 -c "import coincurve" 2>/dev/null || boot_gap "python coincurve not installed"

# ── 2. Offline external keys + checksummed descriptors. ────────────────────
KEYS="$DATADIR/keys.json"
python3 "$WO_LIB" keys --addr-kind p2wpkh >"$KEYS"
[[ -s "$KEYS" ]] || fail "offline key construction produced no output"
read -r A_ADDR B_ADDR W_ADDR M_ADDR < <(python3 -c '
import json,sys
k=json.load(open(sys.argv[1]))
print(k["A"]["addr"], k["B"]["addr"], k["W"]["addr"], k["M"]["addr"])
' "$KEYS")
[[ -n "$A_ADDR" && -n "$M_ADDR" ]] || fail "could not extract external addresses"
log "A=$A_ADDR B=$B_ADDR W=$W_ADDR M=$M_ADDR"

# ── 3. Launch rustoshi on regtest. ─────────────────────────────────────────
log "launching rustoshi regtest (rpc=$RPC_PORT p2p=$P2P_PORT)"
"$BIN" --network=regtest --datadir="$DATADIR" \
    --port="$P2P_PORT" --rpcbind="127.0.0.1:$RPC_PORT" >"$LOG" 2>&1 &
NODE_PID=$!
kill -0 "$NODE_PID" 2>/dev/null || boot_gap "node exited immediately (see $LOG)"
deadline=$(( $(date +%s) + 30 )); up=0
while (( $(date +%s) < deadline )); do
    if rpc getblockcount | grep -q '"result"'; then up=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || boot_gap "node died during startup (see $LOG)"
    sleep 1
done
[[ "$up" == 1 ]] || boot_gap "RPC never responded within 30s"
log "RPC ready"

# ── 4. PRE-IMPORT funding (wallet-less mining; rustoshi divergence: with
#       >1 wallet loaded every wallet RPC errors -19 "specify wallet name in
#       URL" even ON the /wallet/<name> URL, so the test keeps exactly ONE
#       wallet — the watch wallet — loaded; no funding wallet is needed). ───
for spec in "1 $A_ADDR" "1 $B_ADDR" "1 $W_ADDR" "101 $M_ADDR"; do
    n=${spec%% *}; ad=${spec#* }
    out=$(rpc generatetoaddress "[$n, \"$ad\"]")
    echo "$out" | grep -q '"error":{' && fail "generatetoaddress $n->$ad errored: $(echo "$out" | grep -o '"message":"[^"]*"' | head -1)"
done
H=$(rpc getblockcount | grep -o '"result":[0-9]*' | head -1 | sed 's/"result"://')
[[ "${H:-0}" -eq 104 ]] || fail "tip height ${H:-?} != 104 after pre-import funding"
log "pre-import funding done at tip $H (A/B/W coinbases mature)"

# ── 5. The Core-faithful watch-only sequence (shared engine). ──────────────
OUT=$(python3 "$WO_LIB" check --impl rustoshi \
    --base-url "http://127.0.0.1:$RPC_PORT" \
    --cookie "$DATADIR/.cookie" --cookie "$DATADIR/regtest/.cookie" \
    --routing global --keys "$KEYS" \
    --watch-wallet wo --fallback-wallet "")
rc=$?
[[ -n "$OUT" ]] || fail "checker produced no verdict line (rc=$rc)"
echo "WATCHONLY rustoshi: $OUT"
exit $rc
