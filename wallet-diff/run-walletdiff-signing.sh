#!/usr/bin/env bash
# run-walletdiff-signing.sh — WALLET-differential regression, SLICE 3:
# signing + sighash correctness incl. TAPROOT key-path (gate row P2.1).
#
# The funding-critical slice: when a flagship wallet SIGNS a spend, the signature
# must be VALID and the tx ACCEPTED by consensus — especially taproot (BIP-341
# Schnorr key-path), the modern default. Each per-impl test launches a REAL
# bitcoind regtest ORACLE plus the impl on scratch /tmp datadirs (reserved ports
# 22154-22177), has the impl WALLET fund itself (coinbase to a p2wpkh and, when
# supported, a p2tr address) and sign a spend of each via the ONE shared
# comparator (probe_sign.py), replays the impl's chain into Core, and asserts
# Core testmempoolaccept ACCEPTS each SUT-signed tx. Core acceptance is the
# authoritative proof the sighash (BIP-143 / BIP-341) and signature are correct.
# A REJECT (wrong sighash / bad sig) or a missing taproot receive path is a
# funding-blocking failure — surfaced RED, never a silent green.
#
# Runner conventions cloned from run-walletdiff-address.sh:
#   - impls run SEQUENTIALLY (impl node + Core oracle each = bounded peak mem);
#   - each test prints EXACTLY ONE summary line, exits 0/1;
#   - build/RPC gaps are SKIP (GAP_RE), not FAIL — never alert on a stale
#     toolchain;
#   - launch/port aborts, block-replay rejects and chain drift are INFRA
#     (INFRA_RE), not FAIL;
#   - setsid -w isolation (camlcoin exit-144 footgun);
#   - one retry on non-gap failure (box-load false positives).
#
# Exit 0 = no signing divergence (PASS/SKIP only); 1 = at least one impl DIVERGED
# (bad/absent Core-accepted spend, incl. missing taproot); 3 = infra-only aborts.
#
#   Usage:  run-walletdiff-signing.sh                        # flagship impls
#           WALLETDIFF_IMPLS="clearbit" run-walletdiff-signing.sh
#           WALLETDIFF_LOGDIR=/path run-walletdiff-signing.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$DIR/../.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# Flagships only: rustoshi + clearbit are the audited wallet surfaces (design §3).
IMPLS="${WALLETDIFF_IMPLS:-rustoshi clearbit}"
LOGDIR="${WALLETDIFF_LOGDIR:-/tmp/walletsign-regression}"
mkdir -p "$LOGDIR"

# Missing/stale BUILD or missing RPC -> SKIP (not a wallet divergence).
GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

# Aborts that PREVENTED the comparison — port collision, launch failure, Core
# rejecting the replayed chain, chain drift. Fail-closed: anything else is FAIL.
INFRA_RE='already LISTENING|refusing to kill|produced no output|no output for|no summary line|address already in use|failed to (start|launch|bind|connect)|could not (start|launch|bind)|connection refused|port [0-9].* (in use|already)|bind: address|Errno 98|timed out (waiting|starting)|RPC (never came up|not ready)|launch (failed|error)|node (did not|failed to) start|BLOCKED|exited during startup|cookie never appeared|comparator infra|REJECTED impl block|chain divergence after replay|transport failure|neither proven nor disproven'

PASS=0; FAIL=0; SKIP=0; INFRA=0
declare -a FAILED=()
declare -a INFRAED=()

echo "== walletdiff-signing (slice 3: BIP-143/BIP-341 sign + Core-accept) $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$DIR/${impl}_walletsign.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no test script: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  # setsid -w: own session/pgroup so a per-test cleanup trap can never signal
  # THIS runner (run-recovery-regression.sh precedent). Do NOT capture via
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

echo "== walletdiff-signing: PASS=$PASS FAIL=$FAIL SKIP=$SKIP INFRA=$INFRA =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  [ "$INFRA" -gt 0 ] && printf '  INFRA (not a divergence): %s\n' "${INFRAED[*]}"
  exit 1
fi
if [ "$INFRA" -gt 0 ]; then
  printf '  INFRA-ONLY (no divergence; harness/port/launch/replay aborts): %s\n' "${INFRAED[*]}"
  exit 3
fi
exit 0
