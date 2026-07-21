#!/usr/bin/env bash
# run-walletdiff-address.sh — WALLET-differential regression, SLICE 1:
# address-derivation parity (gate row P2.1, first cells).
#
# Design: CORE-PARITY-AUDIT/_wallet-diff-harness-design-2026-07-20.md §5-§8
# (phase 0+1). Runs each per-impl test in wallet-diff/<impl>_walletdiff.sh.
# Each test is self-contained: it launches a REAL bitcoind regtest oracle plus
# the impl on scratch /tmp datadirs (reserved ports 22150-22199), replays the
# FROZEN descriptor corpus (vectors-address.json: pkh / sh(wpkh) / wpkh / tr
# incl. BIP-86 taproot, external+internal, from the canonical 64-byte suite
# seed) against BOTH via the ONE shared comparator (probe_address.py), and
# asserts byte-exact address + checksum equality. Any A1 address mismatch is
# fund-loss class — no allowance tier.
#
# Runner conventions cloned from test-suite/run-recovery-regression.sh:
#   - impls run SEQUENTIALLY (impl node + Core oracle each = bounded peak mem);
#   - each test prints EXACTLY ONE summary line, exits 0/1;
#   - build/RPC gaps are SKIP (GAP_RE), not FAIL — never alert on a stale
#     toolchain;
#   - launch/port aborts and oracle drift are INFRA (INFRA_RE), not FAIL;
#   - setsid -w isolation (camlcoin exit-144 footgun);
#   - one retry on non-gap failure (box-load false positives).
#
# Exit 0 = no divergence (PASS/SKIP only); 1 = at least one impl DIVERGED;
# 3 = infra-only aborts (no divergence proven or disproven) — same contract
# tools/nightly-differential-guard.sh consumes for recovery/spend, so this
# runner can be wired in later (NOT wired yet, by design).
#
#   Usage:  run-walletdiff-address.sh                       # flagship impls
#           WALLETDIFF_IMPLS="rustoshi" run-walletdiff-address.sh
#           WALLETDIFF_LOGDIR=/path run-walletdiff-address.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$DIR/../.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# Flagships only for slice 1 (design §3: rustoshi + clearbit are the audited
# wallet surfaces). Add impls here as their wallet surfaces qualify.
IMPLS="${WALLETDIFF_IMPLS:-rustoshi clearbit}"
LOGDIR="${WALLETDIFF_LOGDIR:-/tmp/walletdiff-regression}"
mkdir -p "$LOGDIR"

# Missing/stale BUILD or missing RPC -> SKIP (not a wallet divergence).
GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

# Aborts that PREVENTED the comparison — port collision, launch failure,
# oracle drift vs the frozen corpus. Fail-closed: anything else is a real FAIL.
INFRA_RE='already LISTENING|refusing to kill|produced no output|no output for|no summary line|address already in use|failed to (start|launch|bind|connect)|could not (start|launch|bind)|connection refused|port [0-9].* (in use|already)|bind: address|Errno 98|timed out (waiting|starting)|RPC (never came up|not ready)|launch (failed|error)|node (did not|failed to) start|BLOCKED|oracle drift|exited during startup|cookie never appeared|comparator infra'

PASS=0; FAIL=0; SKIP=0; INFRA=0
declare -a FAILED=()
declare -a INFRAED=()

echo "== walletdiff-address (slice 1: A1 byte-exact addresses + A2 checksums) $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$DIR/${impl}_walletdiff.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no test script: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  # setsid -w: own session/pgroup so a per-test cleanup trap can never signal
  # THIS runner (run-recovery-regression.sh:69 precedent). Do NOT capture via
  # $(bash "$script") — that reintroduces the same-process-group footgun.
  setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
  line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  # One retry on non-gap failure (transient box-load false positives).
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

echo "== walletdiff-address: PASS=$PASS FAIL=$FAIL SKIP=$SKIP INFRA=$INFRA =="
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
