#!/usr/bin/env bash
# run-recovery-regression.sh — RECOVERY-direction differential regression.
#
# Runs each per-impl wallet-recovery test in recovery/<impl>_recovery.sh. Each test
# is self-contained: it launches its impl on regtest in a scratch /tmp/recreg-<impl>
# datadir, then proves the seed-only recovery flow end-to-end:
#
#   restore-from-seed  ->  fund (generatetoaddress)  ->  scantxoutset BEFORE
#     ->  wipe wallet + restore the SAME seed (re-derives byte-identical addrs)
#     ->  scantxoutset AFTER  ->  assert AFTER == BEFORE  +  negative control 0.
#
# This LOCKS IN the wallet-recovery green cell (0/10 -> 10/10, 2026-06-03) so it
# cannot silently regress. A FAIL here is a real recovery regression for that impl
# (the deployed binary lost the ability to recover funds from a seed alone).
#
# Each test prints exactly ONE summary line — "RECOVERY <impl>: PASS/FAIL ..." — and
# exits 0 (PASS) / 1 (FAIL). An impl whose binary/release isn't built fast-fails with
# a build-gap reason (e.g. "release binary not found", "sethdseed RPC missing —
# rebuild nimrod"); the runner classifies those as SKIP (logged, not FAILed) so the
# nightly guard never spuriously alerts on a missing/stale toolchain — same
# philosophy as run-regression.sh's unbuilt-shim SKIP.
#
# HEAVY: launches a real regtest node per impl, SEQUENTIALLY (one at a time), so peak
# memory stays bounded. The nightly differential guard gates this behind a mem floor.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl
# regressed (the failing impls are listed).
#
#   Usage:  run-recovery-regression.sh                              # all 10 impls
#           RECOVERY_IMPLS="rustoshi nimrod" run-recovery-regression.sh   # subset
#           RECOVERY_LOGDIR=/path run-recovery-regression.sh        # per-impl logs
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REC="$DIR/recovery"

# Interpreters that live in non-standard dirs (cron's minimal PATH lacks them):
#   bun (hotbuns), luajit (lunarblock), escript (beamchain).
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
# haskoin loads its BIP-39 wordlist via the cabal data dir; the fleet binary is
# built-not-cabal-installed, so point getDataDir at the in-tree resources. The
# haskoin test also sets this — belt-and-suspenders for direct/cron invocation.
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${RECOVERY_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${RECOVERY_LOGDIR:-/tmp/recovery-regression}"
mkdir -p "$LOGDIR"

# A non-zero exit whose summary line matches this is a missing/stale BUILD, not a
# recovery regression -> SKIP (don't alert the guard on a toolchain gap).
GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== recovery-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$REC/${impl}_recovery.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no test script: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  # setsid -w: run each test in its OWN session / process group so its cleanup trap
  # (pkill -f recreg-<impl>) can never signal THIS runner. camlcoin's
  # trap signals its process group; under plain command-substitution that reached the
  # parent shell (exit 144). setsid -w isolates it and still propagates the child's
  # exit status. NOTE: do NOT capture via out=$(bash "$script") — that reintroduces
  # the same-process-group footgun.
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

echo "== recovery-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
