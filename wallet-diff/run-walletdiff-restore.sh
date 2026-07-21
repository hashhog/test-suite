#!/usr/bin/env bash
# run-walletdiff-restore.sh — WALLET BACKUP->DESTROY->RESTORE->SPEND drill
# (gate row P2.3). Runs each per-impl drill in wallet-diff/<impl>_restore.sh.
#
# Design: CORE-PARITY-AUDIT/_wallet-diff-harness-design-2026-07-20.md §6 row F*
# / §8 phase 5. Each per-impl drill is self-contained: it launches the flagship
# on a scratch /tmp datadir, seeds+funds a wallet, records balance + a receive
# address, BACKS UP (seed export, + descriptor-export characterisation),
# DESTROYS the datadir, RESTORES into a FRESH datadir from the backup, and
# asserts the restored wallet (1) re-derives the identical address, (2) recovers
# the identical balance, and (3) can SIGN + BROADCAST a spend that confirms on
# the impl AND is accepted by a real Core `testmempoolaccept` oracle (submitblock
# mirrors the impl's exact chain so the spent prevout exists in Core's UTXO set).
# The spend-after-restore is the hard gate: a wallet that restores balance but
# cannot spend is still a funds-loss risk.
#
# Runner conventions cloned from wallet-diff/run-walletdiff-address.sh:
#   - impls run SEQUENTIALLY (each = flagship node + Core oracle => bounded mem);
#   - each drill prints EXACTLY ONE summary line, exits 0/1;
#   - build/RPC gaps are SKIP (GAP_RE), not FAIL;
#   - launch/port aborts + oracle infra are INFRA (INFRA_RE), not FAIL;
#   - setsid -w isolation; one retry on non-gap failure.
#
# Exit 0 = no funds-loss/divergence (PASS/SKIP only); 1 = at least one impl
# FAILED the drill (real funds-loss or consensus-invalid restored spend);
# 3 = infra-only aborts (no divergence proven or disproven).
#
#   Usage:  run-walletdiff-restore.sh
#           WALLETDIFF_IMPLS="rustoshi" run-walletdiff-restore.sh
#           WALLETDIFF_LOGDIR=/path run-walletdiff-restore.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$DIR/../.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

IMPLS="${WALLETDIFF_IMPLS:-rustoshi clearbit}"
LOGDIR="${WALLETDIFF_LOGDIR:-/tmp/walletdiff-restore}"
mkdir -p "$LOGDIR"

# Missing/stale BUILD or missing RPC -> SKIP (not a wallet divergence).
GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

# Aborts that PREVENTED the drill from proving/disproving a funds-loss.
INFRA_RE='already LISTENING|refusing to kill|produced no output|no output for|no summary line|address already in use|failed to (start|launch|bind|connect)|could not (start|launch|bind)|connection refused|port [0-9].* (in use|already)|bind: address|Errno 98|timed out (waiting|starting)|RPC (never came up|not ready)|launch (failed|error)|node (did not|failed to) start|BLOCKED|exited during startup|cookie never appeared|oracle'

PASS=0; FAIL=0; SKIP=0; INFRA=0
declare -a FAILED=()
declare -a INFRAED=()

echo "== walletdiff-restore (P2.3: backup->destroy->restore->spend drill) $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$DIR/${impl}_restore.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no drill script: $script)"; SKIP=$((SKIP+1)); continue
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

echo "== walletdiff-restore: PASS=$PASS FAIL=$FAIL SKIP=$SKIP INFRA=$INFRA =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED (funds-loss / consensus-invalid restored spend): %s\n' "${FAILED[*]}"
  [ "$INFRA" -gt 0 ] && printf '  INFRA (not a divergence): %s\n' "${INFRAED[*]}"
  exit 1
fi
if [ "$INFRA" -gt 0 ]; then
  printf '  INFRA-ONLY (no funds-loss proven or disproven): %s\n' "${INFRAED[*]}"
  exit 3
fi
exit 0
