#!/usr/bin/env bash
# ============================================================================
# WALLET TRANSACTION HISTORY REGRESSION TEST — lunarblock
# ============================================================================
# REFERENCE green cell for the fleet's "the wallet can report its own
# transaction history" completeness axis — the successor to the recovery
# (10/10) and spend (10/10) cells.
#
# Codifies the wallet transaction history landed in lunarblock's
#   feat(wallet): listtransactions + gettransaction wallet transaction history
# into a permanent, repeatable check. Wallet bookkeeping is NOT consensus code,
# but this proves the wallet surfaces its own receive/send/coinbase txs in the
# Bitcoin-Core shape.
#
# How the history is built (mirrors recovery/spend): the wallet keeps no
# durable history ledger you can trust after a disk loss, so — exactly like
# scan_utxos rebuilds the UTXO view by walking the connected chain —
# scan_history rebuilds the transaction history by walking every connected
# block in chain order and classifying each tx as a wallet credit (an output
# paying one of our scripts) and/or a wallet debit (an input spending one of
# our earlier outputs). Categories match Core wallet.cpp / rpc/wallet:
#   generate = mature coinbase to us; immature = coinbase < 101 confs;
#   receive  = non-coinbase output to us; send = the wallet spent (negative).
#
# What "GREEN" means (proved empirically on a throwaway regtest chain):
#   1. restore the FIXED "abandon … about" seed (same vector as recovery/spend)
#   2. getnewaddress A1 ; generatetoaddress 101 A1   -> coinbase history
#   3. sendtoaddress <fresh> 10 (wallet-native send, proven by the spend cell)
#   4. mine 1 block to confirm
#   then:
#     * listtransactions shows the SEND entry (category "send", amount == -10,
#       NEGATIVE fee, txid == the send txid) AND coinbase entries
#       (category "generate"/"immature", amount +50). Was [] before.
#     * gettransaction <send-txid> returns amount ~ -10, a NEGATIVE fee,
#       confirmations >= 1, and a details[] containing the send. Was absent
#       before.
#
# Field shapes + sign conventions verified against bitcoin-core/ as the oracle
# (rpc/wallet/transactions.cpp ListTransactions / gettransaction; receive.cpp
# CachedTxGetAmounts):
#   * send amount is NEGATIVE, send fee is NEGATIVE.
#   * generate/immature/receive amounts are POSITIVE.
#   * gettransaction.amount = nNet - nFee  (≈ -(sent) for a pure send).
#
# Launch recipe mirrors tools/smoke-harness.sh (lunarblock arm):
#   luajit src/main.lua --network regtest --datadir <dd> --port <p2p> \
#       --rpcport <rpc> --nov2transport
#
# STRICT: scratch datadir /tmp/histfleet-lunarblock/ + ports 21668 (RPC) /
# 21688 (P2P) ONLY. NEVER touches /data/nvme1/, testnet4-data/, or any live
# node.
#
# Output: exactly ONE summary line on stdout, then exit.
#   PASS -> "HISTORY lunarblock: PASS sent_entry=yes recv_entries=<n> gettx=ok"  exit 0
#   FAIL -> "HISTORY lunarblock: FAIL <short reason>"                            exit 1
# All other (noisy) output goes to stderr / the node log.
# ============================================================================
set -uo pipefail

# ── Fixed configuration ─────────────────────────────────────────────────────
REPO_ROOT="/home/work/hashhog"
LB_DIR="$REPO_ROOT/lunarblock"
SCRATCH="/tmp/histfleet-lunarblock"
NODE_LOG="$SCRATCH/node.log"
RPC_PORT=21668
P2P_PORT=21688
RPC="http://127.0.0.1:${RPC_PORT}"

# The canonical "abandon … about" BIP-39 test mnemonic — deterministic across
# runs, same vector recovery/lunarblock_recovery.sh + spend use.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

SEND_AMT=10
# A foreign address (NOT in the spend wallet) for the confirming block's
# coinbase, so it does not pollute the spend wallet's own history.
MINER="bcrt1q7rt494gc52tnt8w5pqeg5xhq49vskanvgfkfdy"
NODE_PID=""

# ── stdout discipline (mirrors spend/recovery tests) ────────────────────────
exec 3>&1 1>&2

log() { echo "[history-lunarblock] $*" >&2; }

finish() {
  local verdict="$1"; shift
  if [[ "$verdict" == "PASS" ]]; then
    echo "HISTORY lunarblock: PASS $*" >&3
    exit 0
  else
    echo "HISTORY lunarblock: FAIL $*" >&3
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
    --data "{\"jsonrpc\":\"1.0\",\"id\":\"hist\",\"method\":\"${method}\",\"params\":${params}}"
}

# Extract a python-evaluated field from an RPC response on stdin.
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

# Float comparison helper. $1 op $2 within 1e-6.
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
log "importmnemonic -> hist"
resp="$(rpc_call "$RPC" importmnemonic "[\"$MNEMONIC\",\"\",\"hist\"]")"
ok="$(printf '%s' "$resp" | py_field 'r["wallet_name"]')"
if [[ "$ok" != "hist" ]]; then finish FAIL "importmnemonic hist failed"; fi

# ── 4. Wallet receiving address A1 ──────────────────────────────────────────
A1="$(rpc_call "$RPC/wallet/hist" getnewaddress '[]' | py_field 'r')"
if [[ -z "$A1" || "$A1" == "__ERR__" || "$A1" != bcrt1* ]]; then
  finish FAIL "getnewaddress hist bad addr: '${A1}'"
fi
log "A1=$A1"

# ── 5. Fund + mature: mine 101 blocks to A1 (coinbase history) ──────────────
log "generatetoaddress 101 -> A1 (coinbase history)"
resp="$(rpc_call "$RPC/wallet/hist" generatetoaddress "[101,\"$A1\"]")"
nblk="$(printf '%s' "$resp" | py_field 'len(r)')"
if [[ "$nblk" != "101" ]]; then finish FAIL "generatetoaddress did not mine 101 (got '${nblk}')"; fi

# ── 6. Wallet-native send (proven by the spend cell) ────────────────────────
RECV="$(rpc_call "$RPC" getnewaddress '[]' | py_field 'r')"
if [[ -z "$RECV" || "$RECV" == "__ERR__" || "$RECV" != bcrt1* ]]; then
  finish FAIL "recipient getnewaddress bad addr: '${RECV}'"
fi
log "RECV=$RECV  sendtoaddress $SEND_AMT"
TXID="$(rpc_call "$RPC/wallet/hist" sendtoaddress "[\"$RECV\",$SEND_AMT]" | py_field 'r')"
if [[ "$TXID" == "__ERR__" ]]; then finish FAIL "sendtoaddress crashed/errored"; fi
if [[ -z "$TXID" || ! "$TXID" =~ ^[0-9a-f]{64}$ ]]; then
  finish FAIL "sendtoaddress returned bad txid: '${TXID}'"
fi
log "send TXID=$TXID"

# ── 7. Mine 1 block to confirm the send (foreign miner) ─────────────────────
log "generatetoaddress 1 -> MINER (confirm send)"
resp="$(rpc_call "$RPC/wallet/hist" generatetoaddress "[1,\"$MINER\"]")"
cnf="$(printf '%s' "$resp" | py_field 'len(r)')"
if [[ "$cnf" != "1" ]]; then
  finish FAIL "confirm-mine failed: $(printf '%s' "$resp" | py_field 'd.get("error")')"
fi

# ── 8. listtransactions — SEND entry + coinbase entries ─────────────────────
# Pull a large window so the (older) send entry is included alongside coinbases.
LT="$(rpc_call "$RPC/wallet/hist" listtransactions "[\"*\",1000,0]")"
LT_OK="$(printf '%s' "$LT" | py_field 'isinstance(r, list)')"
if [[ "$LT_OK" != "True" ]]; then
  finish FAIL "listtransactions did not return a list (was [] / crash before fix)"
fi

# The SEND entry: category=send, amount==-SEND_AMT, fee<0, txid matches.
SEND_CHECK="$(printf '%s' "$LT" | python3 -c '
import sys, json
d = json.load(sys.stdin); r = d.get("result") or []
txid = sys.argv[1]; amt = float(sys.argv[2])
found = None
for e in r:
    if e.get("category") == "send" and e.get("txid") == txid:
        found = e; break
if not found:
    print("NOSEND"); sys.exit(0)
ok = True
if abs(float(found.get("amount", 0)) - (-amt)) > 1e-6: ok = False
fee = found.get("fee", None)
if fee is None or float(fee) >= 0: ok = False  # send fee must be negative
print("OK" if ok else ("BADSEND amount=%s fee=%s" % (found.get("amount"), found.get("fee"))))
' "$TXID" "$SEND_AMT")"
if [[ "$SEND_CHECK" != "OK" ]]; then
  finish FAIL "send entry wrong/missing in listtransactions ($SEND_CHECK)"
fi
log "listtransactions send entry OK"

# Coinbase entries: at least one generate/immature, amount +50.
RECV_ENTRIES="$(printf '%s' "$LT" | python3 -c '
import sys, json
d = json.load(sys.stdin); r = d.get("result") or []
n = 0
for e in r:
    if e.get("category") in ("generate","immature","receive"):
        # amount must be positive for these categories
        if float(e.get("amount", 0)) > 0:
            n += 1
print(n)
')"
if [[ -z "$RECV_ENTRIES" || "$RECV_ENTRIES" == "__ERR__" || "$RECV_ENTRIES" -lt 1 ]]; then
  finish FAIL "no positive-amount coinbase/receive entries in listtransactions ($RECV_ENTRIES)"
fi
log "listtransactions positive recv/coinbase entries=$RECV_ENTRIES"

# Sanity: at least one coinbase entry is categorized generate or immature with
# amount == 50 (regtest coinbase subsidy).
CB_OK="$(printf '%s' "$LT" | python3 -c '
import sys, json
d = json.load(sys.stdin); r = d.get("result") or []
for e in r:
    if e.get("category") in ("generate","immature") and abs(float(e.get("amount",0)) - 50.0) < 1e-6:
        print("OK"); sys.exit(0)
print("NO")
')"
if [[ "$CB_OK" != "OK" ]]; then
  finish FAIL "no generate/immature coinbase entry with amount 50 in listtransactions"
fi
log "listtransactions coinbase amount=50 OK"

# ── 9. gettransaction <send-txid> — amount ~ -10, fee<0, confs>=1, details[] ─
GT="$(rpc_call "$RPC/wallet/hist" gettransaction "[\"$TXID\"]")"
GT_CHECK="$(printf '%s' "$GT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if d.get("error") not in (None, False):
    print("ERR %s" % json.dumps(d.get("error"))); sys.exit(0)
r = d.get("result")
if not isinstance(r, dict):
    print("NOTOBJ"); sys.exit(0)
amt = sys.argv[1]
# amount ≈ -SEND_AMT for a pure send (Core: nNet - nFee == -(sent))
if abs(float(r.get("amount", 0)) - (-float(amt))) > 1e-6:
    print("BADAMT amount=%s" % r.get("amount")); sys.exit(0)
fee = r.get("fee", None)
if fee is None or float(fee) >= 0:
    print("BADFEE fee=%s" % fee); sys.exit(0)
if int(r.get("confirmations", 0)) < 1:
    print("BADCONF confirmations=%s" % r.get("confirmations")); sys.exit(0)
det = r.get("details")
if not isinstance(det, list) or len(det) < 1:
    print("NODETAILS"); sys.exit(0)
# at least one send detail referencing the recipient
has_send = any(x.get("category") == "send" for x in det)
if not has_send:
    print("NOSENDDETAIL"); sys.exit(0)
if not r.get("hex"):
    print("NOHEX"); sys.exit(0)
print("OK")
' "$SEND_AMT")"
if [[ "$GT_CHECK" != "OK" ]]; then
  finish FAIL "gettransaction send-txid wrong/absent ($GT_CHECK)"
fi
log "gettransaction OK"

# negative control: gettransaction on a non-wallet txid must error (-5).
BOGUS="$(python3 -c "print('00'*32)")"
NEG="$(rpc_call "$RPC/wallet/hist" gettransaction "[\"$BOGUS\"]" \
  | py_field 'r' 2>/dev/null || true)"
# We expect an rpc-error here (py_field prints __ERR__ on error). If it instead
# returned a result object, that is a false-positive.
if [[ "$NEG" != "__ERR__" ]]; then
  finish FAIL "gettransaction on non-wallet txid did not error (got '$NEG')"
fi
log "gettransaction negative control OK (non-wallet txid errors)"

# ── Success ─────────────────────────────────────────────────────────────────
finish PASS "sent_entry=yes recv_entries=${RECV_ENTRIES} gettx=ok"
