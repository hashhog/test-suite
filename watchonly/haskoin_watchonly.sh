#!/usr/bin/env bash
#
# haskoin_watchonly.sh — Core-faithful WATCH-ONLY import differential test.
#
# PARITY BAR (Core v31.99): the importdescriptors path on a
# disable_private_keys wallet (src/wallet/rpc/backup.cpp:302 — Core's ONLY
# remaining watch-only import path; legacy importaddress/importpubkey return
# -32601 on the oracle itself and are probed INFORMATIONALLY only).
# Full ground-truth citations + check semantics: watchonly/wo_lib.py.
#
# haskoin divergences honoured (from haskoin_import.sh): wallet RPCs
# dispatch on the single DEFAULT wallet (no /wallet/<name> URI routing), so
# the checker runs with --routing global and --unload w1 (after creating the
# watch wallet it unloads the funding wallet so the watch wallet becomes the
# default; if the watch wallet cannot be created, w1 stays default as the
# fallback). Binary located under dist-newstyle; haskoin_datadir env points
# at the repo for the BIP-39 wordlist.
#
# Flow: fund external offline keys A/B/W (1 coinbase each) + 101 -> M
# (tip 104) BEFORE any import; createwallet wo (dpk, blank);
# importdescriptors addr(A)#chk + wpkh(PUBW)#chk ts=0; negatives (-5 / -4);
# addr(B)#chk ts=0 must credit the PRE-IMPORT funding; observability;
# nonspend; legacy probe (informational).
#
# SKIP-vs-FAIL: only binary/boot preconditions may use GAP_RE vocabulary;
# missing watch-only RPCs are FAILs.
#
# Summary line (stdout): "WATCHONLY haskoin: PASS|FAIL ...". exit 0/1.
# Touches ONLY /tmp/hashhog-wofleet-haskoin/ and ports 41408 (RPC) / 41428
# (P2P). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

BASEDIR="/home/work/hashhog"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WO_LIB="$SCRIPT_DIR/wo_lib.py"
HASKOIN_REPO="$BASEDIR/haskoin"
DATADIR="/tmp/hashhog-wofleet-haskoin"
RPC_PORT=41408
P2P_PORT=41428
LOG="$DATADIR/node.log"
NODE_PID=""
COOKIE=""

# Same FIXED BIP-39 mnemonic the other haskoin wallet cells use.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

log() { echo "[watchonly] $*" >&2; }
fail() { echo "WATCHONLY haskoin: FAIL $*"; exit 1; }
boot_gap() { echo "WATCHONLY haskoin: FAIL cannot boot: $*"; exit 1; }

cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NODE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    fuser -k "${RPC_PORT}/tcp" >/dev/null 2>&1 || true
    fuser -k "${P2P_PORT}/tcp" >/dev/null 2>&1 || true
    [[ -n "${HASHHOG_KEEP_SCRATCH:-}" ]] || rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── RPC helper (cookie auth; single default wallet — haskoin shape). ───────
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}
has_error() { echo "$1" | grep -q '"error":null' && return 1 || return 0; }

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
fuser -k "${RPC_PORT}/tcp" >/dev/null 2>&1 || true
fuser -k "${P2P_PORT}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions (locate the binary like the sibling cells do). ────────
HB=$(find "$HASKOIN_REPO/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)
[[ -n "$HB" && -x "$HB" ]] || boot_gap "haskoin binary not found under $HASKOIN_REPO/dist-newstyle"
[[ -f "$WO_LIB" ]] || fail "wo_lib.py absent at $WO_LIB"
python3 -c "import coincurve" 2>/dev/null || boot_gap "python coincurve not installed"

# ── 2. Offline external keys. ──────────────────────────────────────────────
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

# ── 3. Launch haskoin on regtest ('node' subcommand). ──────────────────────
log "launching $HB (regtest) -> $LOG"
haskoin_datadir="$HASKOIN_REPO" \
    "$HB" --network Regtest --datadir "$DATADIR" \
    node --port "$P2P_PORT" --rpcport "$RPC_PORT" \
    >"$LOG" 2>&1 &
NODE_PID=$!
deadline=$(( $(date +%s) + 60 )); up=0
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" ]]; then
        for c in "$DATADIR/regtest/.cookie" "$DATADIR/.cookie"; do
            if [[ -f "$c" ]]; then COOKIE=$(cat "$c"); break; fi
        done
    fi
    if [[ -n "$COOKIE" ]] && rpc getblockcount | grep -q '"result"'; then up=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || boot_gap "node exited during startup (see $LOG)"
    sleep 1
done
[[ "$up" == 1 ]] || boot_gap "RPC never responded within 60s"
log "RPC ready"

# ── 4. Funding wallet w1 (restorewallet; becomes default) + funding. ───────
r=$(rpc restorewallet "[\"w1\",\"$MNEMONIC\"]")
has_error "$r" && log "note: restorewallet w1: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
for spec in "1 $A_ADDR" "1 $B_ADDR" "1 $W_ADDR" "101 $M_ADDR"; do
    n=${spec%% *}; ad=${spec#* }
    r=$(rpc generatetoaddress "[$n,\"$ad\"]")
    has_error "$r" && fail "generatetoaddress $n->$ad errored: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
done
H=$(rpc getblockcount | grep -o '"result":[0-9]*' | head -1 | sed 's/"result"://')
[[ "${H:-0}" -eq 104 ]] || fail "tip height ${H:-?} != 104 after pre-import funding"
log "pre-import funding done at tip $H"

# ── 5. The Core-faithful watch-only sequence (shared engine). ──────────────
# --unload w1: once the watch wallet is created it must become the DEFAULT
# wallet (haskoin has no /wallet routing); if creation fails, w1 stays
# default and serves as the fallback.
OUT=$(python3 "$WO_LIB" check --impl haskoin \
    --base-url "http://127.0.0.1:$RPC_PORT" \
    --cookie "$DATADIR/regtest/.cookie" --cookie "$DATADIR/.cookie" \
    --routing global --keys "$KEYS" \
    --watch-wallet wo --fallback-wallet w1 --unload w1)
rc=$?
[[ -n "$OUT" ]] || fail "checker produced no verdict line (rc=$rc)"
echo "WATCHONLY haskoin: $OUT"
exit $rc
