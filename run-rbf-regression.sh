#!/usr/bin/env bash
# run-rbf-regression.sh — RBF (BIP125) mempool-replacement Core-parity differential.
#
# Runs each per-impl test in rbf/<impl>_rbf.sh. Each test is self-contained: it drives its
# impl on regtest alongside a real bitcoind regtest ORACLE (own scratch + ports, -listen=0),
# builds conflicting signed txs over the SAME input, and asserts the impl matches Core:
#
#   REPLACE  — tx A (signals BIP125, low fee) accepted; tx B (same input, higher fee, meets
#     rules 3+4) REPLACES A: getrawmempool has B not A on both nodes.
#   RULE 3   — a conflict with fee <= A's -> rejected, category "insufficient fee".
#   RULE 4   — a conflict whose fee delta < incrementalRelayFee*vsize -> "insufficient fee".
#   (Rule 5 / 100-replacement cap out of scope.)
#
# Tenth differential axis (2nd mempool-policy cell). Consensus-ADJACENT relay policy. A FAIL
# means an impl diverged from Core's RBF behavior (accepts a replacement Core rejects, rejects
# in the wrong category, or fails to evict/accept the valid replacement).
#
# Each test prints exactly ONE summary line — "RBF <impl>: PASS/FAIL/SKIP ..." — and exits
# 0 (PASS) / 1 (FAIL). Impls with no test yet, an unbuilt/stale binary, or a raw-tx-build gap
# SKIP. A transient startup race retries once.
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. Gated behind a mem floor.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-rbf-regression.sh
#           RBF_IMPLS="rustoshi nimrod" run-rbf-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
RBF="$DIR/rbf"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${RBF_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${RBF_LOGDIR:-/tmp/rbf-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed|raw-tx gap|createrawtransaction'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== rbf-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$RBF/${impl}_rbf.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no rbf test yet: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
  line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  if [ "$rc" -ne 0 ] && ! printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  RETRY $impl (attempt 1 exit $rc: ${line})"
    setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
    line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  fi
  [ -z "$line" ] && line="(no summary line — see $log)"
  if [ "$rc" -eq 0 ] && ! printf '%s' "$line" | grep -qiE "SKIP"; then
    echo "  PASS  $impl — $line"; PASS=$((PASS+1))
  elif printf '%s' "$line" | grep -qiE "$GAP_RE|SKIP"; then
    echo "  SKIP  $impl — $line"; SKIP=$((SKIP+1))
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== rbf-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
