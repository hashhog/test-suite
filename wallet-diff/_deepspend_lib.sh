# _deepspend_lib.sh — shared driver for walletdiff SLICE 5 (DEEP spend surface:
# multi-input taproot, mixed p2wpkh+p2tr, non-default sighash, external-input
# prevtxs gap). Sourced, not run. Reuses the launch/cleanup/log plumbing from
# _lib.sh (launch_core, wd_cleanup, pass/fail/skip/blocked_line, CORE_CLI) and
# adds the deep-spend driver. ALL comparison logic lives in probe_deepspend.py;
# the per-impl adapter supplies ONLY launch/RPC plumbing (harness-script-
# consistency memory) and may not weaken the comparison.
#
# Oracle: the WALLET-ENABLED Core build (bitcoin-core/build-wallet/bin) per the
# slice-5 task, falling back to the plain validator build if it is absent. Core
# is used purely as the authoritative validator (validateaddress / submitblock /
# testmempoolaccept / decoderawtransaction) — no Core wallet is created.
#
# An adapter (<impl>_deepspend.sh) must, before calling walletdiff_deepspend_main:
#   - set IMPL, BIN (impl binary path), BUILD_HINT (how to build it)
#   - set IMPL_RPC IMPL_P2P CORE_RPC CORE_P2P (reserved 22150-22199 block)
#   - set IMPL_DATADIR CORE_DATADIR (scratch under /tmp/walletdeep-*)
#   - set IMPL_COOKIE_CANDIDATES (array of possible cookie paths)
#   - define launch_impl()  — start the node in background, set IMPL_PID
#
# Summary-line contract (stdout, exactly one line; everything else stderr):
#   WALLETDIFF <impl>: PASS deepspend div=0 [multi_taproot=ACCEPT ...]
#   WALLETDIFF <impl>: FAIL deepspend div=1 [... sighash_ALL|ANYONECANPAY=WRONG-FLAG ...]
#   WALLETDIFF <impl>: SKIP <build/RPC gap>           (runner GAP_RE -> SKIP)
#   WALLETDIFF <impl>: BLOCKED <infra>                (runner INFRA_RE -> INFRA)
# Exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED.

set -uo pipefail
WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$WD_DIR/_lib.sh"

# Slice-5 oracle: prefer the wallet-enabled Core build; fall back to the plain
# validator build that _lib.sh points CORE_BIN at.
CORE_WALLET_BIN="$HASHHOG_ROOT/bitcoin-core/build-wallet/bin/bitcoind"
if [[ -x "$CORE_WALLET_BIN" ]]; then
    CORE_BIN="$CORE_WALLET_BIN"
    CORE_CLI="$HASHHOG_ROOT/bitcoin-core/build-wallet/bin/bitcoin-cli"
fi

DEEP_PROBE="$WD_DIR/probe_deepspend.py"

walletdiff_deepspend_main() {
    trap wd_cleanup EXIT INT TERM
    local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local core_log="$CORE_DATADIR/core.log"
    local probe_out="$IMPL_DATADIR/probe-deepspend.out"

    # 0. Port refusal — NEVER kill a listener (2026-06-10 fuser incident).
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":(${IMPL_RPC}|${IMPL_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
        sleep 1
    done
    if ss -tln 2>/dev/null | grep -qE ":(${IMPL_RPC}|${IMPL_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
        fail_line "port ${IMPL_RPC}/${IMPL_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (2026-06-10 fuser incident)"
    fi
    rm -rf "$IMPL_DATADIR" "$CORE_DATADIR"
    mkdir -p "$IMPL_DATADIR" "$CORE_DATADIR" || fail_line "cannot create scratch datadirs"

    # 1. Preconditions (build gaps are SKIP, not FAIL).
    command -v python3 >/dev/null 2>&1 || skip_line "python3 not found on PATH"
    [[ -x "$BIN" ]]      || skip_line "$IMPL binary not found at $BIN ($BUILD_HINT)"
    [[ -x "$CORE_BIN" ]] || skip_line "bitcoind not found at $CORE_BIN"
    [[ -x "$CORE_CLI" ]] || skip_line "bitcoin-cli not found at $CORE_CLI"
    [[ -s "$DEEP_PROBE" ]] || fail_line "shared comparator missing: $DEEP_PROBE"

    # 2. Launch the Core oracle (validator; also the receiver of SUT blocks).
    log "launching Core oracle rpc=:$CORE_RPC (regtest, -listen=0) bin=$CORE_BIN"
    CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$core_log") \
        || fail_line "Core oracle failed to start within 120s (see $core_log)"
    local core_cookie="$CORE_DATADIR/regtest/.cookie"
    [[ -f "$core_cookie" ]] || fail_line "Core cookie not found at $core_cookie"
    log "Core oracle ready (pid=$CORE_BG)"

    # 3. Launch the SUT (adapter-supplied plumbing) and wait for its RPC.
    log "launching $IMPL (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P"
    launch_impl
    [[ -n "$IMPL_PID" ]] || fail_line "launch_impl did not set IMPL_PID"
    local cookie="" deadline=$(( $(date +%s) + 120 )) c r
    while (( $(date +%s) < deadline )); do
        if [[ -z "$cookie" ]]; then
            for c in "${IMPL_COOKIE_CANDIDATES[@]}"; do
                [[ -f "$c" ]] && cookie="$c" && break
            done
        fi
        if [[ -n "$cookie" ]]; then
            r=$(curl -s --max-time 5 -u "$(cat "$cookie")" \
                --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
                "http://127.0.0.1:$IMPL_RPC/" 2>/dev/null)
            echo "$r" | grep -q '"result"' && break
        fi
        kill -0 "$IMPL_PID" 2>/dev/null || { tail -n 20 "$IMPL_DATADIR/node.log" >&2 2>/dev/null || true; fail_line "$IMPL exited during startup (see $IMPL_DATADIR/node.log)"; }
        sleep 1
    done
    [[ -n "$cookie" ]] || fail_line "$IMPL cookie never appeared within 120s"
    r=$(curl -s --max-time 5 -u "$(cat "$cookie")" \
        --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
        "http://127.0.0.1:$IMPL_RPC/" 2>/dev/null)
    echo "$r" | grep -q '"result"' || fail_line "$IMPL RPC never responded within 120s"
    log "$IMPL RPC ready"

    # 4. Run the ONE shared comparator against BOTH endpoints.
    mkdir -p "$RESULTS_DIR" 2>/dev/null || true
    local results_json="$RESULTS_DIR/walletdeepspend-$IMPL-$ts.json"
    python3 "$DEEP_PROBE" --impl "$IMPL" \
        --impl-url "http://127.0.0.1:$IMPL_RPC/" --impl-cookie-file "$cookie" \
        --core-url "http://127.0.0.1:$CORE_RPC/" --core-cookie-file "$core_cookie" \
        --results-out "$results_json" \
        >"$probe_out" 2>&1
    local prc=$?
    cat "$probe_out" >&2

    # 5. Verdict from the probe's SUMMARY line + exit code.
    local summary
    summary="$(grep '^SUMMARY ' "$probe_out" | tail -n 1 | sed 's/^SUMMARY //')"
    case $prc in
        0)  [[ -n "$summary" ]] || fail_line "probe exit 0 but no SUMMARY line (see $probe_out)"
            log "results receipt: $results_json"
            pass_line "$summary" ;;
        1)  [[ -n "$summary" ]] || summary="(no SUMMARY line — see $probe_out)"
            log "results receipt: $results_json"
            fail_line "$summary" ;;
        2)  local gap
            gap="$(grep '^RPCGAP ' "$probe_out" | tail -n 1 | sed 's/^RPCGAP //')"
            skip_line "${gap:-required RPC missing} — rebuild $IMPL ($BUILD_HINT)" ;;
        3)  local infra
            infra="$(grep '^INFRA ' "$probe_out" | tail -n 1 | sed 's/^INFRA //')"
            blocked_line "${infra:-infra abort} (comparison neither proven nor disproven)" ;;
        *)  fail_line "comparator infra error (exit $prc, see $probe_out)" ;;
    esac
}
