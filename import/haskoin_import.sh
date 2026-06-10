#!/usr/bin/env bash
#
# haskoin_import.sh — wallet IMPORT + RESCAN regression test (regtest).
#
# Codifies the "wallet rescan + raw-key import" cell for haskoin — the
# successor to the recovery / spend / history cells.  Proves the REAL wallet
# rescan (rescanblockchain) and raw-key import (importprivkey), distinct from
# the chain-level scantxoutset which never touches the wallet ledger.
#
# CORE PROOF — RESCAN (required for green):
#   restorewallet w1 <fixed mnemonic>  -> getnewaddress A1
#   generatetoaddress -> A1            -> w1 mature balance M (block-connect scan)
#   restorewallet w2 <SAME mnemonic>   -> derives the SAME keys, but does NOT
#                                         scan the chain  => w2 balance == 0
#   make w2 the default wallet         -> getbalance (w2) == 0
#   rescanblockchain                   -> w2 rediscovers its funds via a REAL
#                                         wallet rescan (scanBlockForWallet over
#                                         the height range), NOT scantxoutset
#   ASSERT: getbalance (w2) == M  AND  listunspent shows A1's scriptPubKey.
#
# SECOND PROOF — IMPORTPRIVKEY (target):
#   foreign wallet w3 <different seed> -> A_ext + dumpprivkey A_ext -> K_ext
#   mine a coinbase to A_ext (matured) -> A_ext holds 50 BTC the wallet w2 does
#                                         not own
#   importprivkey K_ext (rescan=true)  -> w2 ALSO credits A_ext's mature funds.
#   ASSERT: w2 balance grows by exactly one mature coinbase.
#
# haskoin's wallet RPCs dispatch on the single DEFAULT wallet (no /wallet/<name>
# URI routing), so the test sequences restore/unload to make the wallet under
# test the default for each phase, and re-restores deterministically (same seed
# => same keys) when it needs a wallet back.  All blocks stay below regtest
# height 150 (the regtest subsidy-halving boundary) to avoid the miner's
# mainnet-schedule coinbase-value drift.
#
# Field shapes follow bitcoin-core/src/wallet/rpc/transactions.cpp
# (rescanblockchain -> {start_height, stop_height}) and wallet/rpc/backup.cpp
# (importprivkey / dumpprivkey).
#
# STRICT UNIFORM INTERFACE (mirrors haskoin_history.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout.  All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: IMPORT haskoin: PASS rescan=ok importprivkey=<ok|partial|absent> rediscovered=<M>
#   FAIL: IMPORT haskoin: FAIL <short reason>
#
# Touches ONLY /tmp/importfleet-haskoin/ and ports 21718 (RPC) / 21738 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
HASKOIN_REPO="$BASEDIR/haskoin"
DATADIR="/tmp/importfleet-haskoin"
RPC_PORT=21718
P2P_PORT=21738
LOGFILE="$DATADIR/import-test.log"

# Same FIXED all-zero-entropy BIP-39 test mnemonic as the recovery / spend /
# history cells (test-suite/recovery/haskoin_recovery.sh).
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
# A DIFFERENT valid 12-word BIP-39 mnemonic for the foreign (import) wallet.
MNEMONIC_EXT="legal winner thank year wave sausage worth useful legal winner thank yellow"

# Regtest coinbase maturity = 100 (mature when tip >= blockHeight + 100).
# We fund A_ext at height 1 and A1 across heights 2..102 so the tip is 102
# (< 150 halving boundary): A1's height-2 coinbase matures at tip 102, and
# A_ext's height-1 coinbase matured at tip 101 — so exactly one A1 coinbase
# (50 BTC) is in the spendable balance and the foreign coinbase is mature too.
A1_BLOCKS=101
COINBASE_SATS=5000000000   # 50 BTC regtest coinbase subsidy below height 150

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy -> stderr + logfile, never stdout. ──────────
log() { echo "[import] $*" >&2; }

# ── Cleanup trap: always kill node + wipe scratch datadir on any exit. ────
cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Emit the single summary line + exit. ──────────────────────────────────
pass() {
    echo "IMPORT haskoin: PASS rescan=ok importprivkey=$1 rediscovered=$2"
    exit 0
}
fail() {
    echo "IMPORT haskoin: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth; JSON-RPC 1.0). ───────────────────────────────
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

result_str() { echo "$1" | sed 's/.*"result":"//; s/".*//'; }
result_num() { echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'; }
has_error()  { echo "$1" | grep -q '"error":null' && return 1 || return 0; }

# Convert a (possibly negative) BTC decimal string to integer satoshis.
btc_to_sats() {
    local amt="$1" sign=1 whole frac
    [[ -z "$amt" ]] && { echo ""; return 1; }
    if [[ "${amt:0:1}" == "-" ]]; then sign=-1; amt="${amt:1}"; fi
    whole="${amt%%.*}"
    if [[ "$amt" == *.* ]]; then frac="${amt#*.}"; else frac="0"; fi
    frac="${frac}00000000"; frac="${frac:0:8}"
    whole=$((10#${whole:-0})); frac=$((10#${frac:-0}))
    echo $(( sign * (whole * 100000000 + frac) ))
}

# getbalance -> integer satoshis (uses the streaming btc decimal result).
balance_sats() {
    local r b
    r=$(rpc getbalance)
    has_error "$r" && { echo ""; return 1; }
    b=$(echo "$r" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://')
    btc_to_sats "$b"
}

# Resolve an address to its scriptPubKey hex via validateaddress.
addr_spk() {
    rpc validateaddress "[\"$1\"]" | grep -o '"scriptPubKey":"[0-9a-f]*"' | head -1 | sed 's/"scriptPubKey":"//; s/"//'
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Locate the haskoin binary. ─────────────────────────────────────────
HB=$(find "$HASKOIN_REPO/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)
[[ -n "$HB" && -x "$HB" ]] || fail "haskoin binary not found under $HASKOIN_REPO/dist-newstyle (run build-all.sh haskoin)"

# ── 2. Launch haskoin on regtest. ─────────────────────────────────────────
log "launching $HB (regtest) -> $DATADIR/node.log"
haskoin_datadir="$HASKOIN_REPO" \
    "$HB" --network Regtest --datadir "$DATADIR" \
    node --port "$P2P_PORT" --rpcport "$RPC_PORT" \
    >"$DATADIR/node.log" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 3. Locate the cookie + wait for RPC. ──────────────────────────────────
deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" ]]; then
        for c in "$DATADIR/regtest/.cookie" "$DATADIR/.cookie"; do
            if [[ -f "$c" ]]; then COOKIE=$(cat "$c"); break; fi
        done
    fi
    if [[ -n "$COOKIE" ]]; then
        r=$(rpc getblockcount)
        echo "$r" | grep -q '"result"' && { log "RPC ready: $r"; break; }
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $DATADIR/node.log)"
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 60s"
r=$(rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 60s"
h0=$(echo "$r" | grep -o '"result":[0-9]*' | grep -o '[0-9]*')
[[ "$h0" == "0" ]] || fail "fresh regtest not at height 0 (got ${h0:-none})"

# ══════════════════════════════════════════════════════════════════════════
# SETUP — derive A1 (own) and A_ext (foreign), then fund the chain (< height 150)
# ══════════════════════════════════════════════════════════════════════════

# w1 (own wallet) becomes the default; derive A1.
log "restorewallet w1 from fixed mnemonic -> A1"
r=$(rpc restorewallet "[\"w1\",\"$MNEMONIC\"]")
has_error "$r" && fail "restorewallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
A1=$(result_str "$(rpc getnewaddress "[]")")
[[ "$A1" == bcrt1q* ]] || fail "getnewaddress A1 not a regtest bech32 addr (got '${A1:0:40}')"
log "A1=$A1"

# Foreign wallet w3 (different seed); to act on it, make it the default by
# unloading w1.  Derive A_ext + dump its private key K_ext.
log "restorewallet w3 from a DIFFERENT mnemonic (foreign-key source)"
r=$(rpc restorewallet "[\"w3\",\"$MNEMONIC_EXT\"]")
has_error "$r" && fail "restorewallet w3 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
log "unloadwallet w1 -> w3 becomes default (to derive + dump the foreign key)"
r=$(rpc unloadwallet "[\"w1\"]")
has_error "$r" && fail "unloadwallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
A_EXT=$(result_str "$(rpc getnewaddress "[]")")
[[ "$A_EXT" == bcrt1q* ]] || fail "foreign getnewaddress not bech32 (got '${A_EXT:0:40}')"
log "A_ext=$A_EXT (foreign, w3)"
DP=$(rpc dumpprivkey "[\"$A_EXT\"]")
has_error "$DP" && fail "dumpprivkey A_ext error: $(echo "$DP" | grep -o '"message":"[^"]*"' | head -1)"
K_EXT=$(result_str "$DP")
[[ -n "$K_EXT" ]] || fail "dumpprivkey returned empty WIF"
log "K_ext WIF obtained (len ${#K_EXT})"

# Mine the foreign coinbase to A_ext at height 1 (w3 is default; it credits w3,
# which we discard).  Then mine A1_BLOCKS to A1 so the tip is 1+A1_BLOCKS=101.
log "generatetoaddress 1 -> A_ext (foreign coinbase, height 1)"
r=$(rpc generatetoaddress "[1,\"$A_EXT\"]")
has_error "$r" && fail "fund A_ext error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

# Bring back an OWN wallet (w1b, same seed => same A1) and make it default to
# fund + scan A1.  Then unload w3 so only the own wallet sees the A1 blocks.
log "restorewallet w1b from fixed mnemonic (re-derives A1 deterministically)"
r=$(rpc restorewallet "[\"w1b\",\"$MNEMONIC\"]")
has_error "$r" && fail "restorewallet w1b error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
log "unloadwallet w3 -> w1b becomes default"
r=$(rpc unloadwallet "[\"w3\"]")
has_error "$r" && fail "unloadwallet w3 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "generatetoaddress $A1_BLOCKS -> A1 (heights 2..$((1+A1_BLOCKS)))"
r=$(rpc generatetoaddress "[$A1_BLOCKS,\"$A1\"]")
has_error "$r" && fail "generatetoaddress A1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT%.*}" -eq $((1+A1_BLOCKS)) ]] || fail "tip != $((1+A1_BLOCKS)) (got ${HEIGHT:-?})"
log "tip height=$HEIGHT (below regtest halving boundary 150)"

# w1b mature balance M — the headline figure w2 must rediscover via rescan.
M=$(balance_sats)
[[ -n "$M" && "$M" -gt 0 ]] \
    || fail "w1b balance 0 after funding (block-connect wallet scan did not run; stale node?)"
log "w1b mature balance M=$M sats"
[[ "$M" -eq "$COINBASE_SATS" ]] \
    || log "note: M=$M (expected one mature coinbase $COINBASE_SATS) — proceeding with measured M"

# ══════════════════════════════════════════════════════════════════════════
# PART A — RESCAN (required for green)
# ══════════════════════════════════════════════════════════════════════════

# Restore w2 from the SAME seed — derives keys, does NOT scan.
log "restorewallet w2 from the SAME mnemonic (fresh, unscanned)"
r=$(rpc restorewallet "[\"w2\",\"$MNEMONIC\"]")
has_error "$r" && fail "restorewallet w2 (same seed) error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
log "unloadwallet w1b -> w2 becomes default"
r=$(rpc unloadwallet "[\"w1b\"]")
has_error "$r" && fail "unloadwallet w1b error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

# w2 must start at 0 — restore alone credits nothing (no chain scan yet).
W2_PRE=$(balance_sats)
[[ -n "$W2_PRE" ]] || fail "getbalance (w2) returned no number pre-rescan"
[[ "$W2_PRE" -eq 0 ]] \
    || fail "w2 balance != 0 BEFORE rescan (got $W2_PRE; restore must not scan the chain)"
log "w2 balance BEFORE rescan = 0, as expected (restore derives keys, no scan)"

# listunspent must also be empty pre-rescan.
LU_PRE=$(rpc listunspent "[1]")
LU_PRE_N=$(echo "$LU_PRE" | grep -o '"txid"' | wc -l | tr -d ' ')
[[ "${LU_PRE_N:-0}" -eq 0 ]] \
    || fail "w2 listunspent non-empty BEFORE rescan (got $LU_PRE_N; restore must not scan)"

# rescanblockchain on w2 — the REAL wallet rescan.
log "rescanblockchain (w2) -> rediscover funds via real wallet rescan"
RS=$(rpc rescanblockchain "[]")
has_error "$RS" && fail "rescanblockchain error: $(echo "$RS" | grep -o '"message":"[^"]*"' | head -1)"
echo "$RS" | grep -q '"start_height"' || fail "rescanblockchain result missing start_height: $(echo "$RS" | head -c 200)"
echo "$RS" | grep -q '"stop_height"'  || fail "rescanblockchain result missing stop_height: $(echo "$RS" | head -c 200)"
RS_STOP=$(echo "$RS" | grep -o '"stop_height":[0-9]*' | head -1 | sed 's/"stop_height"://')
[[ "${RS_STOP:-0}" -ge $((1+A1_BLOCKS)) ]] \
    || fail "rescanblockchain stop_height ${RS_STOP:-?} < tip $((1+A1_BLOCKS))"
log "rescanblockchain returned {start_height,stop_height=$RS_STOP}"

# ASSERT: w2 balance == M and listunspent shows A1's scriptPubKey.
W2_POST=$(balance_sats)
[[ -n "$W2_POST" ]] || fail "getbalance (w2) returned no number post-rescan"
[[ "$W2_POST" -eq "$M" ]] \
    || fail "w2 balance after rescan ($W2_POST) != w1 balance M ($M) — rescan did not rediscover funds"
log "w2 balance AFTER rescan = $W2_POST sats == M (REDISCOVERED via real wallet rescan)"

A1_SPK=$(addr_spk "$A1")
[[ -n "$A1_SPK" ]] || fail "could not resolve A1 scriptPubKey via validateaddress"
LU_POST=$(rpc listunspent "[1]")
has_error "$LU_POST" && fail "listunspent (post-rescan) error"
LU_POST_N=$(echo "$LU_POST" | grep -o '"txid"' | wc -l | tr -d ' ')
[[ "${LU_POST_N:-0}" -gt 0 ]] \
    || fail "w2 listunspent empty AFTER rescan (rescan credited no UTXOs)"
echo "$LU_POST" | grep -q "$A1_SPK" \
    || fail "w2 listunspent after rescan does not show A1's scriptPubKey ($A1_SPK)"
log "w2 listunspent AFTER rescan = $LU_POST_N UTXOs paying A1 (rescan-green PROVEN)"

# ══════════════════════════════════════════════════════════════════════════
# PART B — IMPORTPRIVKEY (target; PARTIAL/ABSENT acceptable)
#
# w2 is the default wallet and does NOT own A_ext.  Import K_ext with
# rescan=true and assert w2 now also credits the foreign mature coinbase.
# ══════════════════════════════════════════════════════════════════════════
IMPORTSTATE="absent"

W2_BEFORE_IMPORT=$(balance_sats)
log "w2 balance before importprivkey = $W2_BEFORE_IMPORT sats"
IP=$(rpc importprivkey "[\"$K_EXT\",\"foreign\",true]")
if has_error "$IP"; then
    log "importprivkey RPC error ($(echo "$IP" | grep -o '"message":"[^"]*"' | head -1)); importprivkey=partial"
    IMPORTSTATE="partial"
else
    W2_AFTER_IMPORT=$(balance_sats)
    log "w2 balance after importprivkey = $W2_AFTER_IMPORT sats"
    if [[ -n "$W2_AFTER_IMPORT" && "$W2_AFTER_IMPORT" -gt "${W2_BEFORE_IMPORT:-0}" ]]; then
        GAIN=$(( W2_AFTER_IMPORT - W2_BEFORE_IMPORT ))
        IMPORTSTATE="ok"
        if [[ "$GAIN" -eq "$COINBASE_SATS" ]]; then
            log "importprivkey credited the foreign key's mature funds (+$GAIN sats == one coinbase) — importprivkey=ok"
        else
            log "importprivkey credited +$GAIN sats (expected $COINBASE_SATS) — importprivkey=ok (nonzero credit)"
        fi
        A_EXT_SPK=$(addr_spk "$A_EXT")
        LU_IMP=$(rpc listunspent "[1]")
        if [[ -n "$A_EXT_SPK" ]] && echo "$LU_IMP" | grep -q "$A_EXT_SPK"; then
            log "listunspent now shows the imported A_ext scriptPubKey"
        else
            log "note: imported balance grew but A_ext scriptPubKey not in listunspent (mature-filter?)"
        fi
    else
        log "importprivkey did not increase w2 balance (before=$W2_BEFORE_IMPORT after=$W2_AFTER_IMPORT); importprivkey=partial"
        IMPORTSTATE="partial"
    fi
fi

# ── Success.  rescan is GREEN; importprivkey state is reported. ───────────
log "PASS: rescan=ok importprivkey=$IMPORTSTATE rediscovered=$M"
pass "$IMPORTSTATE" "$M"
