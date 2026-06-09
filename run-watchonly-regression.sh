#!/usr/bin/env bash
# run-watchonly-regression.sh — WATCH-ONLY import differential regression.
#
# Runs each per-impl watch-only test in watchonly/<impl>_watchonly.sh. Each
# test is self-contained: it launches its impl on regtest in a scratch
# /tmp/hashhog-wofleet-<impl> datadir, funds EXTERNAL (offline-constructed)
# keys BEFORE any import, then proves the Core v31.99 watch-only sequence:
#
#   createwallet wo {disable_private_keys:true, blank:true}
#   importdescriptors addr(A)#chk + wpkh(PUB)#chk with timestamp:0
#   negatives: no checksum -> per-element -5; privkey descriptor -> -4
#   pre-import funding MUST appear after the import rescan (timestamp 0)
#   observability: listunspent / balance / getaddressinfo ismine:true
#   nonspend: watched funds are not spendable
#   legacy importaddress/importpubkey probe = INFORMATIONAL ONLY (Core
#   v31.99 itself returns -32601 for them — src/wallet/rpc/wallet.cpp:904-960;
#   the old "importaddress missing in ~9/10" scoreboard row measured parity
#   against a surface Core no longer has).
#
# Fifth wallet axis after recovery + spend + history + import. The parity bar
# here is the importdescriptors path (src/wallet/rpc/backup.cpp:302) — the
# ONLY watch-only import path left in Core.
#
# SKIP POLICY (deliberately TIGHTER than run-import-regression.sh): GAP_RE
# carries build/boot phrases ONLY. The import family's "missing.*RPC|RPC
# missing" alternates are REMOVED — for watch-only, a missing RPC is the
# finding, so it must classify FAIL, never SKIP. Arms phrase RPC gaps as
# "<method>=missing" and reserve "not found"/"cannot boot" wording for
# binary/interpreter/boot preconditions (wo_lib.py sanitizes impl error
# strings so e.g. "Method not found" can never leak in and demote a FAIL).
#
# Each test prints exactly ONE summary line — "WATCHONLY <impl>: PASS/FAIL
# ..." — and exits 0 (PASS) / 1 (FAIL). Impls with no arm yet, or an
# unbuilt/unbootable binary, are SKIPped (logged, not FAILed).
#
# HEAVY: a real regtest node per impl, strictly SEQUENTIALLY (setsid -w; one
# node at a time, no oracle process — wallet-family substrate).
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one
# impl FAILed. Honest exit codes: rc captured directly, never pipeline tails.
#
#   Usage:  run-watchonly-regression.sh
#           WATCHONLY_IMPLS="rustoshi nimrod" run-watchonly-regression.sh
#           WATCHONLY_LOGDIR=/path run-watchonly-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
WO="$DIR/watchonly"

export PATH="/home/work/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-/home/work/hashhog/haskoin}"

IMPLS="${WATCHONLY_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${WATCHONLY_LOGDIR:-/tmp/hashhog-watchonly-regression}"
mkdir -p "$LOGDIR"

# Build/boot gaps ONLY — missing-RPC alternates deliberately absent (see
# header). "cannot boot" is the arms' phrase for a built binary that never
# serves RPC on regtest.
GAP_RE='not found|not built|no binary|release binary|rebuild|not installed|cannot boot'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== watchonly-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$WO/${impl}_watchonly.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no watchonly test yet: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
  line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  # Transient startup failures under load are not regressions — retry ONCE
  # before declaring FAIL, unless it's a build/boot gap (deterministic).
  if [ "$rc" -ne 0 ] && ! printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  RETRY $impl (attempt 1 exit $rc: ${line})"
    setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
    line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  fi
  [ -z "$line" ] && line="(no summary line — see $log)"
  if [ "$rc" -eq 0 ]; then
    echo "  PASS  $impl — $line"; PASS=$((PASS+1))
  elif printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  SKIP  $impl (build/boot gap) — $line"; SKIP=$((SKIP+1))
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== watchonly-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
