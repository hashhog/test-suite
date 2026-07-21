#!/usr/bin/env bash
# run-walletdiff-psbt.sh — WALLET-differential regression, SLICE 2:
# PSBT round-trip parity (gate rows P2.1 / P2.2).
#
# Design: CORE-PARITY-AUDIT/_wallet-diff-harness-design-2026-07-20.md sec 5-8
# (phase 2, B1/B2/B3 + the fee/vsize clause of P2.2). Runs each per-impl test in
# wallet-diff/<impl>_walletdiff_psbt.sh. Each test is self-contained: it launches
# a REAL wallet-enabled bitcoind regtest oracle (bitcoin-core/build-wallet/bin)
# plus the impl on scratch /tmp datadirs (reserved ports 22150-22199), and drives
# ONE differential probe (probe_psbt.py) that:
#   - funds the SUT's native wallet from its own coinbase, builds
#     walletcreatefundedpsbt -> walletprocesspsbt -> finalizepsbt, copies the SUT
#     blocks into Core (submitblock), and asserts (a) Core testmempoolaccept
#     ALLOWS the finalized tx and (b) fee/vsize are within Core-parity bounds
#     (incl. the 0.1 BTC absurd-fee guard);  [P2WPKH required, P2TR best-effort]
#   - re-imports the frozen wpkh tprv descriptor on BOTH sides and checks
#     assertion (c): Core, given the SAME unsigned PSBT + the shared key, produces
#     an accepted finalization — and flags the case where the SUT's own signing of
#     the imported descriptor is Core-REJECTED (a funding-blocking wrong-key spend)
#     vs. a safe watch-only refusal.
#
# Runner conventions cloned from run-walletdiff-address.sh / run-recovery-
# regression.sh:
#   - impls run SEQUENTIALLY (impl node + Core oracle each = bounded peak mem);
#   - each test prints EXACTLY ONE summary line, exits 0/1;
#   - build/RPC gaps are SKIP (GAP_RE), not FAIL — never alert on a stale
#     toolchain or a missing wallet-enabled Core build;
#   - launch/port aborts and infra are INFRA (INFRA_RE), not FAIL;
#   - setsid -w isolation (camlcoin exit-144 footgun);
#   - one retry on non-gap failure (box-load false positives).
#
# Exit 0 = no divergence (PASS/SKIP only); 1 = at least one impl DIVERGED;
# 3 = infra-only aborts. Same contract tools/nightly-differential-guard.sh
# consumes for recovery/spend/address (NOT wired yet, by design).
#
#   Usage:  run-walletdiff-psbt.sh                       # flagship impls
#           WALLETDIFF_IMPLS="rustoshi" run-walletdiff-psbt.sh
#           WALLETDIFF_LOGDIR=/path run-walletdiff-psbt.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$DIR/../.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# Flagships only for slice 2 (design sec 3: rustoshi + clearbit are the audited
# wallet surfaces). Add impls here as their wallet surfaces qualify.
IMPLS="${WALLETDIFF_IMPLS:-rustoshi clearbit}"
LOGDIR="${WALLETDIFF_LOGDIR:-/tmp/walletdiff-psbt-regression}"
mkdir -p "$LOGDIR"

# Missing/stale BUILD or missing RPC -> SKIP (not a wallet divergence). Includes
# the wallet-enabled Core build being absent.
GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed|build-wallet|ENABLE_WALLET'

# Aborts that PREVENTED the comparison. Fail-closed: anything else is a real FAIL.
INFRA_RE='already LISTENING|refusing to kill|produced no output|no output for|no summary line|address already in use|failed to (start|launch|bind|connect)|could not (start|launch|bind)|connection refused|port [0-9].* (in use|already)|bind: address|Errno 98|timed out (waiting|starting)|RPC (never came up|not ready)|launch (failed|error)|node (did not|failed to) start|BLOCKED|oracle|exited during startup|cookie never appeared|comparator infra|submitblock|lacks wallet'

PASS=0; FAIL=0; SKIP=0; INFRA=0
declare -a FAILED=()
declare -a INFRAED=()

echo "== walletdiff-psbt (slice 2: PSBT create/sign/finalize round-trip parity) $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$DIR/${impl}_walletdiff_psbt.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no test script: $script)"; SKIP=$((SKIP+1)); continue
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
  if [ "$rc" -eq 0 ]; then
    if printf '%s' "$line" | grep -q ': SKIP'; then
      echo "  SKIP  $impl — $line"; SKIP=$((SKIP+1))
    else
      echo "  PASS  $impl — $line"; PASS=$((PASS+1))
    fi
  elif printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  SKIP  $impl (build gap) — $line"; SKIP=$((SKIP+1))
  elif printf '%s' "$line" | grep -qiE "$INFRA_RE"; then
    echo "  INFRA $impl (exit $rc) — $line  [detail: $log]"; INFRA=$((INFRA+1)); INFRAED+=("$impl")
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== walletdiff-psbt: PASS=$PASS FAIL=$FAIL SKIP=$SKIP INFRA=$INFRA =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  [ "$INFRA" -gt 0 ] && printf '  INFRA (not a divergence): %s\n' "${INFRAED[*]}"
  exit 1
fi
if [ "$INFRA" -gt 0 ]; then
  printf '  INFRA-ONLY (no divergence; harness/port/launch/oracle aborts): %s\n' "${INFRAED[*]}"
  exit 3
fi
exit 0
