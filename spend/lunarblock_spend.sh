#!/usr/bin/env bash
# ============================================================================
# WALLET-NATIVE SPEND REGRESSION TEST — lunarblock
# ============================================================================
# REFERENCE green cell for the fleet's "the wallet can see and spend its own
# coins" completeness axis — the successor to the 10/10 recovery cell.
#
# Codifies the wallet-native spend landed in lunarblock's
#   feat(wallet): wallet-native spend — sendtoaddress txid + listunspent + BIP30 evict
# into a permanent, repeatable check. Wallet bookkeeping is NOT consensus
# code, but this proves the end-to-end coin movement settles on-chain.
#
# What "GREEN" means (proved empirically on a throwaway regtest chain):
#   1. getbalance reflects the spendable owned coins after funding.
#   2. listunspent lists the owned UTXOs (no crash; satoshis -> BTC).
#   3. sendtoaddress <fresh-addr> <amt>  ->  returns a real txid (no -32603
#      crash), the tx enters the mempool.
#   4. mine 1 block  ->  the tx CONFIRMS:
#        - the recipient address is credited <amt> (verified via scantxoutset),
#        - the sender's getbalance drops by <amt>+fee,
#        - listunspent reflects the new (post-spend) UTXO set,
#        - the mempool no longer lists the confirmed tx (NO bad-txns-BIP30
#          "tried to overwrite transaction" wedge on the next block).
#   5. a SECOND send+mine round-trip succeeds (proves the BIP30 eviction is a
#      permanent fix, not a first-block fluke).
#
# Recovery/funding mechanism mirrors recovery/lunarblock_recovery.sh:
# RESTORE-FROM-SEED (importmnemonic, the canonical "abandon … about" vector),
# then generatetoaddress to a wallet address to fund + mature coinbases.
#
# Three bugs this guards against (all were live before the fix):
#   (1) sendtoaddress crashed computing its return value — rpc.lua called the
#       nonexistent crypto.sha256d; coins moved on-chain but the caller got
#       -32603 and never received the txid. Fixed -> validation.compute_txid.
#   (2) confirmed txs were NOT evicted from the mempool on block-connect via
#       generatetoaddress -> the mined tx lingered, got re-selected into the
#       next template, and that block was rejected bad-txns-BIP30, wedging
#       block production after the first send. Fixed -> on_block_connected.
#   (3) listunspent crashed ("arithmetic on field 'value' (a nil value)") —
#       wallet list_unspent entries carry `satoshis`/`amount`, not `value`.
#
# Launch recipe mirrors tools/smoke-harness.sh (lunarblock arm):
#   luajit src/main.lua --network regtest --datadir <dd> --port <p2p> \
#       --rpcport <rpc> --nov2transport
#
# STRICT: scratch datadir /tmp/spendref-lunarblock/ + ports 21601 (RPC) /
# 21621 (P2P) ONLY. NEVER touches /data/nvme1/, testnet4-data/, or any live
# node.
#
# Output: exactly ONE summary line on stdout, then exit.
#   PASS -> "SPEND lunarblock: PASS funded=<X> sent=<Y> recipient=<Y> sender_debited=<Y+fee> ..."  exit 0
#   FAIL -> "SPEND lunarblock: FAIL <short reason>"                                                exit 1
# All other (noisy) output goes to stderr / the node log.
# ============================================================================
set -uo pipefail

# ── Fixed configuration ─────────────────────────────────────────────────────
REPO_ROOT="/home/work/hashhog"
LB_DIR="$REPO_ROOT/lunarblock"
SCRATCH="/tmp/spendref-lunarblock"
NODE_LOG="$SCRATCH/node.log"
RPC_PORT=21601
P2P_PORT=21621
RPC="http://127.0.0.1:${RPC_PORT}"

# The canonical "abandon … about" BIP-39 test mnemonic — deterministic across
# runs, same vector recovery/lunarblock_recovery.sh uses.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Amount to send (BTC) and a sane floor for the spendable funded balance.
SEND_AMT=10
SEND_AMT2=5
NODE_PID=""

# ── stdout discipline (mirrors recovery test) ───────────────────────────────
# Save the REAL stdout on fd 3, then point fd 1 at stderr. Only finish() writes
# the single summary line, and it writes to fd 3 — so stdout carries exactly
# one line no matter how the node is reaped.
exec 3>&1 1>&2

log() { echo "[spend-lunarblock] $*" >&2; }

finish() {
  local verdict="$1"; shift
  if [[ "$verdict" == "PASS" ]]; then
    echo "SPEND lunarblock: PASS $*" >&3
    exit 0
  else
    echo "SPEND lunarblock: FAIL $*" >&3
    exit 1
  fi
}

kill_node() {
  if [[ -n "$NODE_PID" ]]; then
    kill -TERM "-${NODE_PID}" 2>/dev/null || kill -TERM "$NODE_PID" 2>/dev/null || true
  fi
}

cleanup() {
  local rc=$?
  kill_node
  for _ in 1 2 3 4 5; do
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
      sleep 0.4
    else
      break
    fi
  done
  if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
    kill -KILL "-${NODE_PID}" 2>/dev/null || kill -KILL "$NODE_PID" 2>/dev/null || true
  fi
  rm -rf "$SCRATCH" 2>/dev/null || true
  return $rc
}
trap cleanup EXIT INT TERM

# JSON-RPC call. $1=url (RPC base or /wallet/<name>), $2=method, $3=params-json.
rpc_call() {
  local url="$1" method="$2" params="$3"
  curl -s --max-time 120 -X POST "$url" \
    -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"1.0\",\"id\":\"spend\",\"method\":\"${method}\",\"params\":${params}}"
}

# Extract a python-evaluated field from an RPC response on stdin.
# $1 = python expr over `r` (the "result") or `d` (whole doc). Prints the
# value, or "__ERR__" + json error to stderr on failure.
py_field() {
  python3 -c '
import sys, json
expr = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("json-parse-error: %s\n" % e)
    print("__ERR__"); sys.exit(0)
if d.get("error") not in (None, False):
    sys.stderr.write("rpc-error: %s\n" % json.dumps(d.get("error")))
    print("__ERR__"); sys.exit(0)
r = d.get("result")
try:
    print(eval(expr))
except Exception as e:
    sys.stderr.write("field-eval-error (%s): %s\n" % (expr, e))
    print("__ERR__"); sys.exit(0)
' "$1"
}

# Float comparison helper. $1 op $2 (op in: lt le gt ge eq) within 1e-6.
fcmp() {
  python3 -c "
import sys
a,op,b=float('$1'),'$2',float('$3')
eps=1e-6
res={'lt':a<b-eps,'le':a<=b+eps,'gt':a>b+eps,'ge':a>=b-eps,'eq':abs(a-b)<eps}[op]
print('True' if res else 'False')"
}

# ── 0. Idempotent reset ─────────────────────────────────────────────────────
log "resetting scratch state (ports ${RPC_PORT}/${P2P_PORT}, datadir ${SCRATCH})"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
  finish FAIL "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 0.5
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

if ! command -v luajit >/dev/null 2>&1; then
  finish FAIL "luajit not found on PATH"
fi
if [[ ! -f "$LB_DIR/src/main.lua" ]]; then
  finish FAIL "lunarblock src/main.lua missing at $LB_DIR"
fi

# ── 1. Launch lunarblock on regtest (smoke-harness recipe) ──────────────────
log "launching lunarblock regtest node"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$SCRATCH' \
    --port '$P2P_PORT' --rpcport '$RPC_PORT' --nov2transport" \
    >"$NODE_LOG" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID (log: $NODE_LOG)"

# ── 2. Wait for RPC (getblockchaininfo chain=regtest) ───────────────────────
RPC_UP=0
for _ in $(seq 1 60); do
  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    log "node died during startup; last log lines:"; tail -20 "$NODE_LOG" >&2 || true
    finish FAIL "node exited before RPC came up"
  fi
  resp="$(rpc_call "$RPC" getblockchaininfo '[]' 2>/dev/null || true)"
  chain="$(printf '%s' "$resp" | py_field 'r["chain"]' 2>/dev/null || true)"
  if [[ "$chain" == "regtest" ]]; then RPC_UP=1; break; fi
  sleep 0.5
done
if [[ "$RPC_UP" != "1" ]]; then
  log "RPC never reported chain=regtest; last log lines:"; tail -20 "$NODE_LOG" >&2 || true
  finish FAIL "rpc did not come up within timeout"
fi
log "RPC up (chain=regtest)"

# ── 3. Restore the spending wallet from the FIXED seed ──────────────────────
log "importmnemonic -> spend"
resp="$(rpc_call "$RPC" importmnemonic "[\"$MNEMONIC\",\"\",\"spend\"]")"
ok="$(printf '%s' "$resp" | py_field 'r["wallet_name"]')"
if [[ "$ok" != "spend" ]]; then finish FAIL "importmnemonic spend failed"; fi

# ── 4. Wallet receiving address A1 ──────────────────────────────────────────
A1="$(rpc_call "$RPC/wallet/spend" getnewaddress '[]' | py_field 'r')"
if [[ -z "$A1" || "$A1" == "__ERR__" || "$A1" != bcrt1* ]]; then
  finish FAIL "getnewaddress spend bad addr: '${A1}'"
fi
log "A1=$A1"

# ── 5. Fund + mature: mine 121 blocks to A1 (>=100 mature coinbases) ────────
# Coinbase matures at 100 confs (Core COINBASE_MATURITY). Mining 121 leaves
# ~21 mature coinbases for coin selection — comfortably above the spend.
log "generatetoaddress 121 -> A1 (fund + mature)"
resp="$(rpc_call "$RPC/wallet/spend" generatetoaddress "[121,\"$A1\"]")"
nblk="$(printf '%s' "$resp" | py_field 'len(r)')"
if [[ "$nblk" != "121" ]]; then finish FAIL "generatetoaddress did not mine 121 (got '${nblk}')"; fi

# ── 6. getbalance + listunspent (the two probe-crashers) ────────────────────
# getbalance now reports the MATURE spendable balance only (immature coinbases
# excluded — Core parity). Snapshot the immature total too so the later debit
# assertion can add back any coinbase that MATURES while we mine the confirming
# block (mining advances the tip, so a near-boundary coinbase crosses 101 confs
# and lands in the spendable balance — a real, correct accounting effect).
FUNDED="$(rpc_call "$RPC/wallet/spend" getbalance '[]' | py_field 'r')"
if [[ "$FUNDED" == "__ERR__" ]]; then finish FAIL "getbalance crashed"; fi
IMMATURE_PRE="$(rpc_call "$RPC/wallet/spend" getbalances '[]' | py_field 'r["mine"]["immature"]')"
if [[ "$IMMATURE_PRE" == "__ERR__" ]]; then IMMATURE_PRE=0; fi
log "funded balance=$FUNDED (immature=$IMMATURE_PRE)"
if [[ "$(fcmp "$FUNDED" gt 0)" != "True" ]]; then finish FAIL "funded balance not positive ($FUNDED)"; fi

# listunspent must not crash and must list owned UTXOs (the spendable set).
LU_SPENDABLE="$(rpc_call "$RPC/wallet/spend" listunspent '[]' \
  | py_field 'sum(1 for u in r if u.get("spendable"))')"
if [[ "$LU_SPENDABLE" == "__ERR__" ]]; then finish FAIL "listunspent crashed"; fi
if [[ -z "$LU_SPENDABLE" || "$LU_SPENDABLE" -lt 1 ]]; then
  finish FAIL "listunspent reports no spendable UTXOs ($LU_SPENDABLE)"
fi
log "listunspent spendable=$LU_SPENDABLE"

# ── 7. Fresh recipient + confirming-miner addresses ─────────────────────────
# RECV: a fresh address on the default (non-spend) wallet — clearly external
# to the sender so scantxoutset on RECV proves the coin actually moved.
RECV="$(rpc_call "$RPC" getnewaddress '[]' | py_field 'r')"
if [[ -z "$RECV" || "$RECV" == "__ERR__" || "$RECV" != bcrt1* ]]; then
  finish FAIL "recipient getnewaddress bad addr: '${RECV}'"
fi
log "RECV=$RECV"
# MINER: a foreign address (NOT in the spend wallet) so the confirming block's
# coinbase does NOT inflate the sender balance — keeps the debit assertion
# clean (debit == sent + fee exactly).
MINER="bcrt1q7rt494gc52tnt8w5pqeg5xhq49vskanvgfkfdy"

# ── 8. sendtoaddress -> txid (no -32603 crash) + tx in mempool ──────────────
log "sendtoaddress $RECV $SEND_AMT"
TXID="$(rpc_call "$RPC/wallet/spend" sendtoaddress "[\"$RECV\",$SEND_AMT]" | py_field 'r')"
if [[ "$TXID" == "__ERR__" ]]; then finish FAIL "sendtoaddress crashed/errored (the -32603 sha256d bug?)"; fi
if [[ -z "$TXID" || ! "$TXID" =~ ^[0-9a-f]{64}$ ]]; then
  finish FAIL "sendtoaddress returned bad txid: '${TXID}'"
fi
log "TXID=$TXID"

# tx must be in the mempool now
MP="$(rpc_call "$RPC" getrawmempool '[]' | py_field "'$TXID' in r")"
if [[ "$MP" != "True" ]]; then finish FAIL "sent tx not in mempool"; fi

# recipient must NOT be credited yet (unconfirmed)
PRE_RECV="$(rpc_call "$RPC" scantxoutset "[\"start\",[\"addr($RECV)\"]]" | py_field 'r["total_amount"]')"
if [[ "$PRE_RECV" == "__ERR__" ]]; then finish FAIL "scantxoutset(recv) pre-mine failed"; fi
if [[ "$(fcmp "$PRE_RECV" eq 0)" != "True" ]]; then
  finish FAIL "recipient credited before confirmation (pre=$PRE_RECV)"
fi

# ── 9. Mine 1 block to confirm — CRITICAL: must NOT BIP30-wedge ─────────────
log "generatetoaddress 1 -> MINER (confirm; must not bad-txns-BIP30 wedge)"
resp="$(rpc_call "$RPC/wallet/spend" generatetoaddress "[1,\"$MINER\"]")"
cnf="$(printf '%s' "$resp" | py_field 'len(r)')"
if [[ "$cnf" != "1" ]]; then
  finish FAIL "confirm-mine failed (BIP30 wedge?): $(printf '%s' "$resp" | py_field 'd.get("error")')"
fi

# mempool must now be EMPTY (eviction on block-connect)
MP_AFTER="$(rpc_call "$RPC" getrawmempool '[]' | py_field "len(r)")"
if [[ "$MP_AFTER" == "__ERR__" ]]; then finish FAIL "getrawmempool after-mine failed"; fi
if [[ "$MP_AFTER" != "0" ]]; then finish FAIL "mempool not cleared after confirm ($MP_AFTER left)"; fi

# recipient must be credited EXACTLY the sent amount
RECV_AMT="$(rpc_call "$RPC" scantxoutset "[\"start\",[\"addr($RECV)\"]]" | py_field 'r["total_amount"]')"
if [[ "$RECV_AMT" == "__ERR__" ]]; then finish FAIL "scantxoutset(recv) post-mine failed"; fi
if [[ "$(fcmp "$RECV_AMT" eq "$SEND_AMT")" != "True" ]]; then
  finish FAIL "recipient credited $RECV_AMT != sent $SEND_AMT"
fi
log "recipient credited=$RECV_AMT"

# sender debited by sent + fee (fee >= 0). MINER is foreign, so the confirming
# block's COINBASE does not credit the sender. But mining that block advances
# the tip, maturing any coinbase that crosses 101 confs — its value moves from
# `immature` into the spendable balance. Add that matured amount back so the
# debit reflects the spend alone:
#   AFTER = FUNDED - SEND_AMT - fee + matured
#   matured = IMMATURE_PRE - IMMATURE_POST
#   => debit = (FUNDED + matured) - AFTER = SEND_AMT + fee.
AFTER="$(rpc_call "$RPC/wallet/spend" getbalance '[]' | py_field 'r')"
if [[ "$AFTER" == "__ERR__" ]]; then finish FAIL "getbalance post-spend crashed"; fi
IMMATURE_POST="$(rpc_call "$RPC/wallet/spend" getbalances '[]' | py_field 'r["mine"]["immature"]')"
if [[ "$IMMATURE_POST" == "__ERR__" ]]; then IMMATURE_POST="$IMMATURE_PRE"; fi
MATURED="$(python3 -c "print(round(float('$IMMATURE_PRE') - float('$IMMATURE_POST'), 8))")"
DEBIT="$(python3 -c "print(round(float('$FUNDED') + float('$MATURED') - float('$AFTER'), 8))")"
FEE="$(python3 -c "print(round(float('$DEBIT') - float('$SEND_AMT'), 8))")"
log "sender FUNDED=$FUNDED AFTER=$AFTER matured=$MATURED debit=$DEBIT fee=$FEE"
# debit must be >= sent (i.e. fee >= 0) and == sent + fee by construction.
if [[ "$(fcmp "$DEBIT" ge "$SEND_AMT")" != "True" ]]; then
  finish FAIL "sender debit $DEBIT < sent $SEND_AMT (balance went UP?)"
fi
if [[ "$(fcmp "$FEE" ge 0)" != "True" ]]; then
  finish FAIL "negative fee ($FEE)"
fi

# listunspent must still work post-spend and reflect a non-empty owned set.
LU2="$(rpc_call "$RPC/wallet/spend" listunspent '[]' | py_field 'len(r)')"
if [[ "$LU2" == "__ERR__" || -z "$LU2" || "$LU2" -lt 1 ]]; then
  finish FAIL "listunspent post-spend bad ($LU2)"
fi
log "listunspent post-spend count=$LU2"

# ── 10. SECOND send+mine — proves BIP30 eviction is permanent, not a fluke ──
RECV2="$(rpc_call "$RPC" getnewaddress '[]' | py_field 'r')"
if [[ -z "$RECV2" || "$RECV2" == "__ERR__" ]]; then finish FAIL "recipient2 getnewaddress failed"; fi
log "second send: sendtoaddress $RECV2 $SEND_AMT2"
TXID2="$(rpc_call "$RPC/wallet/spend" sendtoaddress "[\"$RECV2\",$SEND_AMT2]" | py_field 'r')"
if [[ -z "$TXID2" || ! "$TXID2" =~ ^[0-9a-f]{64}$ ]]; then
  finish FAIL "second sendtoaddress bad txid: '${TXID2}'"
fi
resp="$(rpc_call "$RPC/wallet/spend" generatetoaddress "[1,\"$MINER\"]")"
cnf2="$(printf '%s' "$resp" | py_field 'len(r)')"
if [[ "$cnf2" != "1" ]]; then finish FAIL "second confirm-mine failed (BIP30 wedge returned)"; fi
MP2="$(rpc_call "$RPC" getrawmempool '[]' | py_field 'len(r)')"
if [[ "$MP2" != "0" ]]; then finish FAIL "mempool not cleared after 2nd confirm ($MP2 left)"; fi
RECV2_AMT="$(rpc_call "$RPC" scantxoutset "[\"start\",[\"addr($RECV2)\"]]" | py_field 'r["total_amount"]')"
if [[ "$(fcmp "$RECV2_AMT" eq "$SEND_AMT2")" != "True" ]]; then
  finish FAIL "recipient2 credited $RECV2_AMT != sent $SEND_AMT2"
fi
log "second round-trip OK (recv2=$RECV2_AMT, mempool clear)"

# ── Success ─────────────────────────────────────────────────────────────────
DEBIT_STR="$(python3 -c "print(('%g' % float('$DEBIT')))")"
FEE_STR="$(python3 -c "print(('%g' % float('$FEE')))")"
finish PASS "funded=${FUNDED} sent=${SEND_AMT} recipient=${RECV_AMT} sender_debited=${DEBIT_STR} fee=${FEE_STR} mempool_cleared=yes second_send=ok"
