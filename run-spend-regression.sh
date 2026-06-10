#!/usr/bin/env bash
# run-spend-regression.sh — SPEND-direction differential regression.
#
# Runs each per-impl wallet-native spend test in spend/<impl>_spend.sh. Each test is
# self-contained: it launches its impl on regtest in a scratch /tmp/spendref-<impl>
# datadir, then proves the full wallet-native spend round-trip end-to-end:
#
#   restore-from-seed -> fund (generatetoaddress to a wallet addr) -> assert getbalance
#     reflects the MATURE owned coins -> sendtoaddress <fresh> <amt> (coin-select -> sign
#     -> broadcast) -> mine 1 block -> assert the recipient is credited <amt>, the sender
#     is debited <amt>+fee, listunspent reflects the new set, and the mempool no longer
#     lists the confirmed tx (no BIP30 wedge on the next block).
#
# This is the successor to the recovery regression: recovery proved a wallet can REDISCOVER
# funds from a seed (via the chain-level scantxoutset); SPEND proves the wallet TRACKS its
# own on-chain UTXOs and can actually move them. The wallet-surface probe (2026-06-04)
# found that recovery-green masked a fleet-wide spend gap (no block-connect -> wallet-scan
# hook), so a FAIL here is a real loss of wallet spendability for that impl.
#
# Each test prints exactly ONE summary line — "SPEND <impl>: PASS/FAIL ..." — and exits
# 0 (PASS) / 1 (FAIL). An impl with no spend test yet, or whose binary/release isn't built,
# is SKIPped (logged, not FAILed) so the guard never spuriously alerts while the spend axis
# is still being driven green impl-by-impl — same philosophy as run-recovery-regression.sh.
#
# HEAVY: launches a real regtest node per impl, SEQUENTIALLY, so peak memory stays bounded.
# The nightly guard gates this behind a mem floor.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-spend-regression.sh                          # every impl with a spend test
#           SPEND_IMPLS="beamchain lunarblock" run-spend-regression.sh   # subset
#           SPEND_LOGDIR=/path run-spend-regression.sh        # per-impl logs
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SP="$DIR/spend"

# Interpreters in non-standard dirs (cron's minimal PATH lacks them): bun, luajit, escript.
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
# haskoin loads its BIP-39 wordlist via the cabal data dir; point getDataDir at the in-tree
# resources (the per-impl test also sets this — belt-and-suspenders for direct/cron runs).
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${SPEND_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${SPEND_LOGDIR:-/tmp/spend-regression}"
mkdir -p "$LOGDIR"

# A non-zero exit whose summary line matches this is a missing/stale BUILD, not a spend
# regression -> SKIP (don't alert the guard on a toolchain gap).
GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== spend-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$SP/${impl}_spend.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no spend test yet: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  # setsid -w: own session/process group so a per-test cleanup trap (pkill) can
  # never signal this runner. Do NOT capture via out=$(bash "$script") — that reintroduces
  # the same-process-group footgun (see the recovery runner's camlcoin exit-144 note).
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

echo "== spend-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
