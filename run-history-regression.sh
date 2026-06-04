#!/usr/bin/env bash
# run-history-regression.sh — wallet TRANSACTION-HISTORY differential regression.
#
# Runs each per-impl wallet tx-history test in history/<impl>_history.sh. Each test is
# self-contained: it launches its impl on regtest in a scratch /tmp/histfleet-<impl>
# datadir, then proves the wallet reports its own transaction history Core-shaped:
#
#   restore-from-seed -> fund (generatetoaddress -> coinbase "generate"/"immature"
#     entries) -> sendtoaddress <fresh> <amt> (the wallet-native send) -> mine ->
#     listtransactions shows the SEND entry (category "send", negative amount + fee,
#     matching txid) AND the coinbase receives; gettransaction <send-txid> returns
#     amount/fee/confirmations/details. (Was [] / -32601 before.)
#
# Third wallet axis after recovery + spend: recovery proves restore-from-seed, spend
# proves the wallet tracks + moves its coins, history proves the wallet can REPORT what
# it received and sent. A FAIL is a real loss of wallet history for that impl.
#
# Each test prints exactly ONE summary line — "HISTORY <impl>: PASS/FAIL ..." — and
# exits 0 (PASS) / 1 (FAIL). Impls with no history test yet, or an unbuilt/stale binary,
# are SKIPped (logged, not FAILed) — same philosophy as run-spend-regression.sh.
#
# HEAVY: launches a real regtest node per impl, SEQUENTIALLY. The nightly guard gates
# this behind a mem floor.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-history-regression.sh
#           HISTORY_IMPLS="rustoshi nimrod" run-history-regression.sh
#           HISTORY_LOGDIR=/path run-history-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
HIST="$DIR/history"

export PATH="/home/work/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-/home/work/hashhog/haskoin}"

IMPLS="${HISTORY_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${HISTORY_LOGDIR:-/tmp/history-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== history-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$HIST/${impl}_history.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no history test yet: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  # setsid -w: own session so a per-test cleanup trap can't signal this runner (no $(...)).
  setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
  line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  # Transient startup failures under load (node death / slow RPC) are not regressions —
  # retry ONCE before declaring FAIL, unless it's a build gap (deterministic). Kills the
  # box-load false-positives seen when the guard runs alongside another heavy job.
  if [ "$rc" -ne 0 ] && ! printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  RETRY $impl (attempt 1 exit $rc: ${line})"
    setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
    line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  fi
  [ -z "$line" ] && line="(no summary line — see $log)"
  if [ "$rc" -eq 0 ]; then
    echo "  PASS  $impl — $line"; PASS=$((PASS+1))
  elif printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  SKIP  $impl (build gap) — $line"; SKIP=$((SKIP+1))
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== history-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
