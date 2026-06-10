#!/usr/bin/env bash
# run-bytediff-regression.sh — BYTE-EXACT RPC differential instrument.
#
# The strict COMPLEMENT to the order-insensitive run-<m>-regression harnesses.
# For each (method, params) in the shared manifest (bytediff/bytediff_lib.sh),
# it calls the impl AND the v31.99 Core oracle on an IDENTICAL deterministic
# regtest chain, normalizes ONLY the masked non-deterministic fields, and
# byte-compares the ORDER-PRESERVING JSON (.result, after number-canonicalization
# + per-method mask), reporting IDENTICAL / DIFF (with the specific divergence:
# key-order / value / type / missing-or-extra field) per method.
#
# This is the authoritative byte-exact residual map — it replaces the board's
# vibes-based "+417 points" RPC-completeness estimate with a measured per-method
# verdict per impl.
#
# Each per-impl arm bytediff/<impl>_bytediff.sh is self-contained: it boots the
# impl on regtest ALONGSIDE a real bitcoind regtest ORACLE (own scratch + ports,
# -listen=0), mirrors Core's chain block-for-block via submitblock so both share
# a byte-identical tip/UTXO set, pushes one in-process-signed spend to both
# mempools, confirms it, then runs the byte-diff matrix. It prints exactly ONE
# summary line — "BYTEDIFF <impl>: PASS methods=N identical=N diff=0" / "... FAIL
# ..." — and exits 0 (PASS = every method byte-identical after masking) / 1.
#
# ORACLE: wallet-OFF consensus oracle (bitcoin-core/build/bin/bitcoind) for the
# chain/network/mining/util surface; the wallet tier (deferred here) would use
# the wallet-ON oracle (bitcoin-core/build-wallet/bin/bitcoind, v31.99).
#
# SELF-TEST GATE: a bytediff arm run with BD_SELFTEST=1 stands up a SECOND Core
# in place of the impl; the matrix MUST then be 100% IDENTICAL with EVERY method
# genuinely evaluated (both sides produced a real, non-empty RPC body). That is
# the no-false-positives baseline — run it before trusting any impl verdict:
#   REGTEST_SLOTS=1 REGTEST_MEM=12G tools/regtest-slot.sh -- \
#       env BD_SELFTEST=1 BYTEDIFF_IMPLS=rustoshi bash test-suite/run-bytediff-regression.sh
#
# RESOURCES (W-fix-forward): the self-test stands up TWO Core instances + the
# heavy methods (getblock v2, getblockstats, gettxoutsetinfo, getmempoolinfo,
# getrawmempool, getnetworkinfo, getmininginfo). Under the default 6G/2-slot cap
# those curl calls STALLED, returning empty bodies that a prior engine bug waved
# through as "both error code " IDENTICAL. The engine now treats an empty body as
# a NON-PASS ERROR and retries it; but to get a clean 25/25-GENUINELY-evaluated
# baseline, give the self-test headroom: REGTEST_SLOTS=1 REGTEST_MEM>=10G. The
# runner exports a higher default RPC timeout (BD_RPC_MAXTIME) for the same reason.
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. Run locally
# only via tools/regtest-slot.sh (ports all < 32768; PID-only teardown). In CI it
# is the differential-sweep family "bytediff" (one impl per job, unwrapped).
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl
# byte-diverged from Core.
#
#   Usage:  run-bytediff-regression.sh
#           BYTEDIFF_IMPLS="rustoshi nimrod" run-bytediff-regression.sh
#           BD_SELFTEST=1 BYTEDIFF_IMPLS=rustoshi run-bytediff-regression.sh   # baseline gate
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BD="$DIR/bytediff"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

# Generous per-call RPC timeout + retry so the heavy methods (getblock v2,
# getblockstats, gettxoutsetinfo, getmempoolinfo, getrawmempool, getnetworkinfo,
# getmininginfo) actually return a body under load — an empty body is now a
# NON-PASS ERROR (never a silent identity), so these must really evaluate.
export BD_RPC_MAXTIME="${BD_RPC_MAXTIME:-120}"
export BD_RPC_TRIES="${BD_RPC_TRIES:-4}"

IMPLS="${BYTEDIFF_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${BYTEDIFF_LOGDIR:-/tmp/bytediff-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== bytediff-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$BD/${impl}_bytediff.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no bytediff arm yet: $script)"; SKIP=$((SKIP+1)); continue
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
    echo "  PASS  $impl — $line"; PASS=$((PASS+1))
  elif printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  SKIP  $impl (build gap) — $line"; SKIP=$((SKIP+1))
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== bytediff-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
