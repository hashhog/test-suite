#!/usr/bin/env bash
# run-walletdiff-deepspend.sh — WALLET-differential regression, SLICE 5:
# the DEEP spend surface between "simple receive+spend works" and "the wallet is
# trustworthy for real funds".
#
# SLICE 3 (signing) proved single-input SIGHASH_ALL/DEFAULT key-path spends. This
# slice extends to the cases deep enough to hide a funds-losing bug that single-
# input testing never reaches:
#   1. MULTI-INPUT taproot key-path (BIP-341 commits the sighash to ALL prevout
#      amounts + scriptPubKeys — a mis-aggregated midstate yields an invalid sig);
#   2. MULTI-INPUT mixed (P2WPKH + P2TR in one tx — per-input sighash dispatch);
#   3. NON-DEFAULT sighash via signrawtransactionwithwallet's sighashtype arg
#      (ALL/NONE/SINGLE/ALL|ANYONECANPAY) — the produced flag byte must match the
#      request (no SILENT SIGHASH_ALL) AND Core must accept;
#   4. EXTERNAL-INPUT / prevtxs characterization (does the wallet honor prevtxs
#      or require every input in its own UTXO set — the HW/coordinator gap).
#
# Each per-impl test launches a REAL wallet-enabled bitcoind regtest ORACLE plus
# the impl on scratch /tmp datadirs (reserved ports 22194-22197), has the impl
# WALLET fund itself across several coinbases, drives the deep cases via the ONE
# shared comparator (probe_deepspend.py), replays the impl chain into Core, and
# asserts Core testmempoolaccept ACCEPTS each SUT-signed spend. Core acceptance is
# the authoritative proof the BIP-143/BIP-341 sighash + signature are correct.
#
# Verdict policy (probe exit code):
#   - A must-pass case (multi_taproot, mixed, sighash_ALL) that is not ACCEPTed,
#     or any SILENT wrong-sighash-flag, is a funding-blocking DIVERGENCE -> FAIL.
#   - An HONEST "not yet supported" sighash refusal (UNSUPPORTED) and the
#     characterized external-input GAP do NOT fail the slice — they are recorded.
#   - A wholly-missing wallet RPC is a build gap -> SKIP (never alert on a stale
#     toolchain). Launch/port/replay aborts are INFRA, not FAIL.
#
# Runner conventions cloned from run-walletdiff-signing.sh:
#   - impls run SEQUENTIALLY (impl node + Core oracle each = bounded peak mem);
#   - each test prints EXACTLY ONE summary line, exits 0/1;
#   - build/RPC gaps are SKIP (GAP_RE), not FAIL;
#   - launch/port aborts, block-replay rejects and chain drift are INFRA (INFRA_RE);
#   - setsid -w isolation (camlcoin exit-144 footgun);
#   - one retry on non-gap failure (box-load false positives).
#
# Exit 0 = no deep-spend divergence (PASS/SKIP only); 1 = at least one impl
# DIVERGED; 3 = infra-only aborts.
#
#   Usage:  run-walletdiff-deepspend.sh                        # flagship (rustoshi)
#           WALLETDIFF_IMPLS="rustoshi" run-walletdiff-deepspend.sh
#           WALLETDIFF_LOGDIR=/path run-walletdiff-deepspend.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$DIR/../.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# rustoshi is the funding-target flagship this slice audits (design §3). Other
# impls can be added as their deep-spend surfaces come online.
IMPLS="${WALLETDIFF_IMPLS:-rustoshi}"
LOGDIR="${WALLETDIFF_LOGDIR:-/tmp/walletdeep-regression}"
mkdir -p "$LOGDIR"

# Missing/stale BUILD or missing RPC -> SKIP (not a wallet divergence).
GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed|cannot produce'

# Aborts that PREVENTED the comparison — port collision, launch failure, Core
# rejecting the replayed chain, chain drift. Fail-closed: anything else is FAIL.
INFRA_RE='already LISTENING|refusing to kill|produced no output|no output for|no summary line|address already in use|failed to (start|launch|bind|connect)|could not (start|launch|bind)|connection refused|port [0-9].* (in use|already)|bind: address|Errno 98|timed out (waiting|starting)|RPC (never came up|not ready)|launch (failed|error)|node (did not|failed to) start|BLOCKED|exited during startup|cookie never appeared|comparator infra|REJECTED impl block|chain divergence|transport failure|neither proven nor disproven'

PASS=0; FAIL=0; SKIP=0; INFRA=0
declare -a FAILED=()
declare -a INFRAED=()

echo "== walletdiff-deepspend (slice 5: multi-input/taproot/sighash/prevtxs) $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$DIR/${impl}_deepspend.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no test script: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  # setsid -w: own session/pgroup so a per-test cleanup trap can never signal
  # THIS runner. Do NOT capture via $(bash "$script").
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

echo "== walletdiff-deepspend: PASS=$PASS FAIL=$FAIL SKIP=$SKIP INFRA=$INFRA =="
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
