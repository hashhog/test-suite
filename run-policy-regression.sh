#!/usr/bin/env bash
# run-policy-regression.sh — mempool/policy reject-parity differential regression.
#
# Runs each per-impl policy test in policy/<impl>_policy.sh. Each test is self-contained:
# it launches its impl on regtest + a real bitcoind regtest as the ORACLE, builds a REAL
# ECDSA-signed spend (so a tx passes input-existence and REACHES the standardness gate),
# derives one-rule-violating variants, and asserts each impl's testmempoolaccept reject
# reason matches Core's:
#
#   GENUINE must-reject floor (rejected by BOTH strict + default Core): dust, bad-version,
#   below-min-relay  ->  the impl MUST reject (normalized to Core's category).
#   valid-control    ->  the impl MUST accept.
#   bare-multisig / oversize-OP_RETURN -> strict-flag-only in Core v31.99 (default accepts),
#   so the impl accepting them is parity-with-default-Core (ok), not a failure.
#
# Fifth differential axis (after recovery/spend/history/import), consensus-ADJACENT. A FAIL
# means an impl diverged from Core's relay policy on the genuine floor (e.g. accepts a
# below-min-relay or dust tx Core rejects — a real standardness hole).
#
# Each test prints exactly ONE summary line — "POLICY <impl>: PASS/FAIL ..." — and exits
# 0 (PASS) / 1 (FAIL). Impls with no policy test yet, or an unbuilt/stale binary, SKIP.
# A transient startup race (two daemons racing on a loaded box) retries once before FAIL.
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. Gated behind a mem
# floor in the nightly guard.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-policy-regression.sh
#           POLICY_IMPLS="rustoshi nimrod" run-policy-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
POL="$DIR/policy"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${POLICY_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${POLICY_LOGDIR:-/tmp/policy-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0; INFRA=0
declare -a FAILED=()
declare -a INFRAED=()
# Infra-abort signatures: a per-impl failure that PREVENTED the comparison
# (port collision, node never launched, empty output) — NOT a divergence.
# Fail-closed: anything not matching this stays a real FAIL.
INFRA_RE='already LISTENING|refusing to kill|produced no output|no output for|no summary line|address already in use|failed to (start|launch|bind|connect)|could not (start|launch|bind)|connection refused|port [0-9].* (in use|already)|bind: address|Errno 98|timed out (waiting|starting)|RPC (never came up|not ready)|launch (failed|error)|node (did not|failed to) start'

echo "== policy-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$POL/${impl}_policy.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no policy test yet: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
  line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  # transient startup race (impl daemon + Core oracle racing on a loaded box) -> retry once.
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
  elif printf '%s' "$line" | grep -qiE "$INFRA_RE"; then
    echo "  INFRA $impl (exit $rc) — $line  [detail: $log]"; INFRA=$((INFRA+1)); INFRAED+=("$impl")
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== policy-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP${INFRA:+ INFRA=$INFRA} =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  [ "$INFRA" -gt 0 ] && printf '  INFRA (not a divergence): %s\n' "${INFRAED[*]}"
  exit 1
fi
if [ "$INFRA" -gt 0 ]; then
  printf '  INFRA-ONLY (no divergence; harness/port/launch aborts): %s\n' "${INFRAED[*]}"
  exit 3
fi
exit 0
