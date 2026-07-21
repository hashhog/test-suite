# _restore_lib.sh — shared driver for the wallet BACKUP->DESTROY->RESTORE->SPEND
# drill (gate row P2.3). Sourced, never run directly.
#
# Design: CORE-PARITY-AUDIT/_wallet-diff-harness-design-2026-07-20.md §6 row F*
# ("backup drill") + §8 phase 5. This is the "will I lose my funds" test: after
# backing up a funded wallet, destroying its datadir, and restoring into a fresh
# datadir, the wallet MUST recover its balance AND still be able to SIGN and
# BROADCAST a spend — a restore that recovers balance but cannot spend is still a
# funds-loss risk, so spend-after-restore is the hard gate.
#
# House rule (auto-memory harness-script-consistency): the per-impl adapter
# (<impl>_restore.sh) supplies ONLY launch/RPC/wallet-lifecycle plumbing; EVERY
# assertion lives here in the ONE shared driver so no adapter can weaken a check.
#
# ── Backup-mechanism model (why the SEED path is the spendable channel) ──────
# Neither flagship ships Core's backupwallet/restorewallet/dumpwallet (design §3;
# grep confirmed). The portable spendable backup both flagships DO expose is the
# HD master seed via `sethdseed` (proven spendable by recovery/ + spend/ cells).
# The drill therefore RESTORES via the seed. It SEPARATELY characterises the
# `listdescriptors true` descriptor-export channel (private=spendable vs
# watch-only) and records it, because descriptor portability matters for real
# custody and one flagship's descriptor import is watch-only (clearbit
# wallet.zig:1362 — recovers balance but CANNOT spend: a funds-loss trap on that
# channel). That characterisation is REPORTED, not gated, since the seed channel
# is the spendable one under test.
#
# ── Chain model across the destroy ───────────────────────────────────────────
# These nodes keep chain+wallet in one datadir and never peer, so "rm -rf datadir"
# destroys BOTH the private wallet AND the public chain. In production the public
# chain is always re-downloadable from peers; only the wallet secret must be
# backed up. The regtest stand-in for "re-download the public chain" is a
# DETERMINISTIC re-mine to the restored wallet's OWN (seed-derived) receive
# address: because that address is byte-identical after restore (asserted), the
# re-mined coinbases reproduce the identical UTXO set. So:
#   * addr re-derivation identical  => the backup carries the key material
#   * getbalance == original balance => the restored wallet SEES the funds
#   * spend confirms on the impl     => the restored wallet can SIGN (has privkeys)
#   * Core testmempoolaccept=true    => the signature is CONSENSUS-valid, not just
#                                       self-accepted (submitblock mirrors the
#                                       impl's exact chain into a Core oracle so
#                                       the spent prevout exists in Core's UTXO set)
#
# ── Summary-line contract (stdout, exactly one line; noise to stderr) ────────
#   WALLETDIFF-RESTORE <impl>: PASS recovered=<btc> spend=confirmed corexcheck=<st> backup=seed desc-export=<st>
#   WALLETDIFF-RESTORE <impl>: FAIL <reason>          (real funds-loss / divergence)
#   WALLETDIFF-RESTORE <impl>: SKIP <build/RPC gap>   (runner GAP_RE -> SKIP)
#   WALLETDIFF-RESTORE <impl>: BLOCKED <infra>        (runner INFRA_RE -> INFRA)
# Exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED.
#
# Adapter contract — before calling walletdiff_restore_main, the adapter sets:
#   IMPL BIN BUILD_HINT SEED
#   IMPL_RPC IMPL_P2P CORE_RPC CORE_P2P   (reserved 22150-22199 block)
#   DATADIR_ORIG DATADIR_RESTORE CORE_DATADIR   (scratch under /tmp/walletdiff-*)
# and defines:
#   adapter_launch <datadir>        — start node bg on IMPL_RPC/IMPL_P2P, set IMPL_PID
#   adapter_cookie_candidates <dd>  — echo space-separated candidate cookie paths
#   adapter_wpath                   — echo wallet RPC path suffix ("" or "/wallet/w1")
#   adapter_create_and_seed         — createwallet + sethdseed(SEED) on the live node

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CORE_BIN="$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoin-cli"
RESULTS_DIR="${WALLETDIFF_RESULTS_DIR:-$HASHHOG_ROOT/test-suite/results}"

# Funding schedule (identical to spend/ cells): mine 101 blocks to the wallet's
# own address; at tip 101 exactly the height-1 coinbase (50 BTC) is mature.
NBLOCKS=101
EXPECT_FUNDED_SATS=$(( 50 * 100000000 ))
SEND_BTC=10
SEND_SATS=$(( 10 * 100000000 ))
# Foreign recipient NOT derived from any wallet seed (proves value leaves the
# wallet, verified purely on-chain via scantxoutset).
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

IMPL_PID=""
CORE_BG=""
COOKIE_VAL=""

log()  { echo "[restore:${IMPL:-?}] $*" >&2; }
pass_line()    { echo "WALLETDIFF-RESTORE $IMPL: PASS $*"; exit 0; }
fail_line()    { echo "WALLETDIFF-RESTORE $IMPL: FAIL $*"; exit 1; }
skip_line()    { echo "WALLETDIFF-RESTORE $IMPL: SKIP $*"; exit 0; }
blocked_line() { echo "WALLETDIFF-RESTORE $IMPL: BLOCKED $*"; exit 1; }

# ── Cleanup: OUR pids only, OUR oracle, OUR scratch. ────────────────────────
wd_restore_cleanup() {
    local ec=$?
    if [[ -n "$IMPL_PID" ]] && kill -0 "$IMPL_PID" 2>/dev/null; then
        kill "$IMPL_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$IMPL_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$IMPL_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$DATADIR_ORIG" "$DATADIR_RESTORE" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}

# ── Core oracle launcher (pattern from wallet-diff/_lib.sh launch_core). ─────
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"
    local attempt
    for attempt in 1 2 3 4 5; do
        local wait_n=0
        while fuser "${rpc}/tcp" >/dev/null 2>&1 && (( wait_n < 15 )); do sleep 1; wait_n=$((wait_n+1)); done
        "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" -listen=0 \
            >"$lf" 2>&1 &
        local bg=$!
        local deadline=$(( $(date +%s) + 120 ))
        while (( $(date +%s) < deadline )); do
            if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
                echo "$bg"; return 0
            fi
            kill -0 "$bg" 2>/dev/null || { echo "[launch_core] attempt $attempt exited early" >&2; break; }
            sleep 1
        done
        kill -0 "$bg" 2>/dev/null && return 1
        sleep 2
    done
    tail -n 20 "$lf" >&2 2>/dev/null || true
    return 1
}
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ── Generic impl RPC (cookie auth). rpc <path> <method> <params-json>. ──────
rpc() {
    local path="$1" method="$2" params="${3:-[]}"
    curl -s --max-time 90 -u "$COOKIE_VAL" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:${IMPL_RPC}${path}" 2>/dev/null
}
wrpc() { rpc "$(adapter_wpath)" "$1" "${2:-[]}"; }   # wallet endpoint
nrpc() { rpc "" "$1" "${2:-[]}"; }                    # node endpoint

# ── JSON helpers (parsed, never raw-string — fleet-wire-key-order memory). ──
rpc_errmsg() {  # stdin JSON -> error.message or empty
    python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
e=d.get("error")
print(e.get("message","") if isinstance(e,dict) else "")' 2>/dev/null
}
res_str() {  # stdin JSON -> result if scalar string, else empty
    python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
r=d.get("result")
print(r if isinstance(r,str) else "")' 2>/dev/null
}
res_field() {  # res_field <key>  ; stdin JSON -> result[key]
    python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
r=d.get("result") or {}
v=r.get(sys.argv[1]) if isinstance(r,dict) else None
print("" if v is None else v)' "$1" 2>/dev/null
}
btc_to_sats() {  # BTC decimal -> integer sats (pure python for precision)
    python3 -c 'import sys,decimal
try: print(int((decimal.Decimal(sys.argv[1])*100000000).to_integral_value()))
except Exception: print("")' "$1" 2>/dev/null
}
count_txid() { python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(0); sys.exit(0)
r=d.get("result")
print(len(r) if isinstance(r,list) else 0)' 2>/dev/null; }

# Wait for the impl RPC to answer getblockcount (cookie resolved into COOKIE_VAL).
wait_impl_rpc() {
    local dd="$1" cookie="" deadline=$(( $(date +%s) + 120 )) c r
    while (( $(date +%s) < deadline )); do
        if [[ -z "$cookie" ]]; then
            for c in $(adapter_cookie_candidates "$dd"); do
                [[ -f "$c" ]] && cookie="$c" && break
            done
        fi
        if [[ -n "$cookie" ]]; then
            COOKIE_VAL="$(cat "$cookie")"
            r=$(nrpc getblockcount)
            echo "$r" | grep -q '"result"' && return 0
        fi
        kill -0 "$IMPL_PID" 2>/dev/null || { tail -n 20 "$dd/node.log" >&2 2>/dev/null || true; return 2; }
        sleep 1
    done
    return 1
}

# Wait for a TCP port to be released after we kill our own node.
wait_port_free() {
    local port="$1"
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":${port} " || return 0
        sleep 1
    done
    return 1
}

stop_impl() {
    [[ -n "$IMPL_PID" ]] || return 0
    kill "$IMPL_PID" 2>/dev/null || true
    for _ in $(seq 1 15); do kill -0 "$IMPL_PID" 2>/dev/null || break; sleep 1; done
    kill -9 "$IMPL_PID" 2>/dev/null || true
    IMPL_PID=""
}

# ── The shared driver. ──────────────────────────────────────────────────────
walletdiff_restore_main() {
    trap wd_restore_cleanup EXIT INT TERM
    local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"

    # 0. Port refusal — NEVER kill a listener (2026-06-10 fuser incident).
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":(${IMPL_RPC}|${IMPL_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
        sleep 1
    done
    if ss -tln 2>/dev/null | grep -qE ":(${IMPL_RPC}|${IMPL_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
        blocked_line "port ${IMPL_RPC}/${IMPL_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (2026-06-10 fuser incident)"
    fi
    rm -rf "$DATADIR_ORIG" "$DATADIR_RESTORE" "$CORE_DATADIR"
    mkdir -p "$DATADIR_ORIG" || blocked_line "cannot create scratch datadir $DATADIR_ORIG"

    # 1. Preconditions (build gaps are SKIP, not FAIL).
    command -v python3 >/dev/null 2>&1 || skip_line "python3 not found on PATH"
    command -v curl    >/dev/null 2>&1 || skip_line "curl not found on PATH"
    [[ -x "$BIN" ]]      || skip_line "$IMPL binary not found at $BIN ($BUILD_HINT)"
    [[ -x "$CORE_BIN" ]] || skip_line "bitcoind not found at $CORE_BIN"
    [[ -x "$CORE_CLI" ]] || skip_line "bitcoin-cli not found at $CORE_CLI"

    # ════════════════════════════════════════════════════════════════════════
    # PHASE 1 — original wallet: seed, fund, record balance + backup.
    # ════════════════════════════════════════════════════════════════════════
    log "PHASE 1: launch $IMPL on ORIGINAL datadir $DATADIR_ORIG"
    adapter_launch "$DATADIR_ORIG"
    [[ -n "$IMPL_PID" ]] || fail_line "adapter_launch did not set IMPL_PID"
    wait_impl_rpc "$DATADIR_ORIG"; local wrc=$?   # NOT in $(...): must set COOKIE_VAL in this shell
    [[ $wrc -eq 2 ]] && fail_line "$IMPL exited during startup (see $DATADIR_ORIG/node.log)"
    [[ $wrc -eq 0 ]] || fail_line "$IMPL RPC never came up on original datadir"

    log "createwallet + sethdseed (seed backup identity)"
    adapter_create_and_seed || fail_line "create/seed wallet failed on original node"

    local A1; A1="$(wrpc getnewaddress | res_str)"
    [[ -n "$A1" ]] || fail_line "getnewaddress returned empty on original wallet"
    log "receive address A1=$A1"

    log "generatetoaddress $NBLOCKS -> A1 (fund with coinbase)"
    local out; out=$(nrpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
    local em; em=$(echo "$out" | rpc_errmsg); [[ -z "$em" ]] || fail_line "generatetoaddress error: $em"
    local h; h=$(nrpc getblockcount | python3 -c 'import sys,json;print(json.load(sys.stdin).get("result",0))' 2>/dev/null)
    [[ "${h:-0}" -ge "$NBLOCKS" ]] || fail_line "height did not advance (got ${h:-?} want >= $NBLOCKS)"

    local bal_b_btc bal_b_sats
    bal_b_btc=$(wrpc getbalance | python3 -c 'import sys,json;r=json.load(sys.stdin).get("result");print(r if r is not None else "")' 2>/dev/null)
    [[ -n "$bal_b_btc" ]] || fail_line "getbalance returned no result on original wallet"
    bal_b_sats=$(btc_to_sats "$bal_b_btc")
    log "ORIGINAL balance = $bal_b_btc BTC ($bal_b_sats sats)"
    [[ "$bal_b_sats" == "$EXPECT_FUNDED_SATS" ]] \
        || fail_line "original balance $bal_b_sats sats != expected mature $EXPECT_FUNDED_SATS (funding/maturity wrong)"
    local n_b; n_b=$(count_txid < <(wrpc listunspent))
    [[ "${n_b:-0}" -gt 0 ]] || fail_line "listunspent empty after funding on original wallet"

    # BACKUP characterisation: is the descriptor-export channel spendable
    # (private tprv/xprv) or watch-only (public only)? Reported, not gated.
    local desc_json desc_err desc_export
    desc_json=$(wrpc listdescriptors "[true]")
    desc_err=$(echo "$desc_json" | rpc_errmsg)
    if [[ -n "$desc_err" ]]; then
        desc_export="unavailable(${desc_err})"
    elif echo "$desc_json" | grep -qE 'tprv|xprv'; then
        desc_export="private-spendable"
    elif echo "$desc_json" | grep -q '"desc"'; then
        desc_export="watch-only(no-privkeys)"
    else
        desc_export="empty"
    fi
    log "descriptor-export (listdescriptors true) channel: $desc_export"

    # ── DESTROY: kill node1, remove the entire original datadir. ────────────
    log "DESTROY: stopping node + rm -rf $DATADIR_ORIG (wallet + chain gone)"
    stop_impl
    wait_port_free "$IMPL_RPC" || log "warn: port $IMPL_RPC slow to free"
    rm -rf "$DATADIR_ORIG"
    [[ -d "$DATADIR_ORIG" ]] && fail_line "DESTROY failed: $DATADIR_ORIG still present"

    # ════════════════════════════════════════════════════════════════════════
    # PHASE 2 — restore into a FRESH datadir from the SEED backup.
    # ════════════════════════════════════════════════════════════════════════
    mkdir -p "$DATADIR_RESTORE" || fail_line "cannot create restore datadir $DATADIR_RESTORE"
    log "PHASE 2: launch $IMPL on FRESH RESTORE datadir $DATADIR_RESTORE"
    COOKIE_VAL=""
    adapter_launch "$DATADIR_RESTORE"
    [[ -n "$IMPL_PID" ]] || fail_line "adapter_launch did not set IMPL_PID on restore"
    wait_impl_rpc "$DATADIR_RESTORE"; wrc=$?   # NOT in $(...): must set COOKIE_VAL in this shell
    [[ $wrc -eq 2 ]] && fail_line "$IMPL exited during restore startup (see $DATADIR_RESTORE/node.log)"
    [[ $wrc -eq 0 ]] || fail_line "$IMPL RPC never came up on restore datadir"

    log "RESTORE: createwallet + sethdseed(SAME seed) — the seed IS the backup"
    adapter_create_and_seed || fail_line "create/seed wallet failed on restore node"

    local A1r; A1r="$(wrpc getnewaddress | res_str)"
    [[ -n "$A1r" ]] || fail_line "getnewaddress returned empty on restored wallet"
    [[ "$A1r" == "$A1" ]] \
        || fail_line "restored address $A1r != original $A1 (backup did not carry key material — funds unrecoverable)"
    log "restored address re-derives identical: $A1r"

    # Reconstruct the public chain deterministically (regtest stand-in for a
    # peer re-download): re-mine to the wallet's OWN address -> identical UTXOs.
    log "reconstruct chain: generatetoaddress $NBLOCKS -> A1r"
    out=$(nrpc generatetoaddress "[$NBLOCKS,\"$A1r\"]")
    em=$(echo "$out" | rpc_errmsg); [[ -z "$em" ]] || fail_line "restore generatetoaddress error: $em"
    h=$(nrpc getblockcount | python3 -c 'import sys,json;print(json.load(sys.stdin).get("result",0))' 2>/dev/null)
    [[ "${h:-0}" -ge "$NBLOCKS" ]] || fail_line "restore height did not advance (got ${h:-?})"

    local bal_r_btc bal_r_sats
    bal_r_btc=$(wrpc getbalance | python3 -c 'import sys,json;r=json.load(sys.stdin).get("result");print(r if r is not None else "")' 2>/dev/null)
    [[ -n "$bal_r_btc" ]] || fail_line "getbalance returned no result on restored wallet"
    bal_r_sats=$(btc_to_sats "$bal_r_btc")
    log "RESTORED balance = $bal_r_btc BTC ($bal_r_sats sats)"
    [[ "$bal_r_sats" == "$bal_b_sats" ]] \
        || fail_line "restored balance $bal_r_sats sats != original $bal_b_sats sats (BALANCE NOT RECOVERED — funds-loss)"
    log "BALANCE RECOVERED: $bal_r_btc BTC == original"

    # ════════════════════════════════════════════════════════════════════════
    # PHASE 3 — spend after restore (the hard gate).
    # ════════════════════════════════════════════════════════════════════════
    # Negative control: recipient holds nothing on-chain yet.
    local pre; pre=$(nrpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]" | res_field total_amount)
    pre=$(btc_to_sats "${pre:-0}")
    [[ "${pre:-0}" -eq 0 ]] || fail_line "recipient already funded before spend ($pre sats)"

    log "SPEND after restore: sendtoaddress $SEND_BTC -> $FOREIGN_ADDR"
    local send txid
    send=$(wrpc sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]")
    em=$(echo "$send" | rpc_errmsg); [[ -z "$em" ]] \
        || fail_line "restored wallet CANNOT SPEND: sendtoaddress error: $em"
    txid=$(echo "$send" | res_str)
    [[ -n "$txid" ]] || fail_line "restored wallet sendtoaddress returned no txid: $(echo "$send" | head -c 160)"
    [[ "$txid" =~ ^0+$ ]] && fail_line "restored wallet returned all-zero placeholder txid (tx not built/broadcast)"
    log "spend txid=$txid"

    nrpc getrawmempool | grep -q "$txid" || fail_line "spend tx $txid not in mempool after sendtoaddress"

    # Grab the raw signed tx (for the Core cross-accept) while it is in mempool.
    local rawtx
    rawtx=$(wrpc gettransaction "[\"$txid\"]" | res_field hex)
    [[ -n "$rawtx" ]] || rawtx=$(nrpc getrawtransaction "[\"$txid\"]" | res_str)
    [[ -n "$rawtx" ]] || rawtx=$(nrpc getrawtransaction "[\"$txid\",false]" | res_str)

    # ── Core cross-accept (strengthening): mirror the impl's exact chain into a
    #    Core oracle via submitblock, then testmempoolaccept the restored
    #    wallet's raw signed tx. allowed=true => the signature is CONSENSUS-valid
    #    (not merely self-accepted). A signature-class reject => real DIVERGENCE.
    #    A context/mirror shortfall => infra (self-confirmation still gates). ──
    local corex="skip:no-rawtx"
    if [[ -n "$rawtx" ]]; then
        log "Core cross-accept: launching oracle + mirroring $h blocks via submitblock"
        mkdir -p "$CORE_DATADIR"
        if CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$CORE_DATADIR/core.log"); then
            local i bh raw mirror_ok=1
            for (( i=1; i<=h; i++ )); do
                bh=$(nrpc getblockhash "[$i]" | res_str)
                [[ -n "$bh" ]] || { mirror_ok=0; corex="infra:getblockhash-$i"; break; }
                raw=$(nrpc getblock "[\"$bh\",0]" | res_str)
                [[ -n "$raw" ]] || { mirror_ok=0; corex="infra:getblock0-$i"; break; }
                core_cli submitblock "$raw" >/dev/null 2>&1 || true
            done
            if [[ "$mirror_ok" == "1" ]]; then
                local core_h; core_h=$(core_cli getblockcount 2>/dev/null)
                if [[ "${core_h:-0}" == "$h" ]]; then
                    local tma allowed reason
                    tma=$(core_cli testmempoolaccept "[\"$rawtx\"]" 2>/dev/null)
                    allowed=$(echo "$tma" | python3 -c 'import sys,json
try: a=json.load(sys.stdin);print(str(a[0].get("allowed")).lower())
except Exception: print("err")' 2>/dev/null)
                    reason=$(echo "$tma" | python3 -c 'import sys,json
try: a=json.load(sys.stdin);print(a[0].get("reject-reason",""))
except Exception: print("")' 2>/dev/null)
                    if [[ "$allowed" == "true" ]]; then
                        corex="ok"
                    elif echo "$reason" | grep -qiE 'missing|inputs|spent|already|txn-already'; then
                        corex="infra:context(${reason})"   # UTXO/mempool context, not a sig failure
                    elif [[ "$allowed" == "err" ]]; then
                        corex="infra:testmempoolaccept-parse"
                    else
                        # signature / script / consensus reject => the restored wallet
                        # produced an INVALID spend its own engine wrongly accepted.
                        fail_line "restored wallet spend REJECTED by Core testmempoolaccept: ${reason:-unknown} (consensus-invalid signature)"
                    fi
                else
                    corex="infra:mirror(core=${core_h:-?} impl=$h)"
                fi
            fi
        else
            corex="infra:core-oracle-launch"
        fi
    fi
    log "Core cross-accept verdict: corexcheck=$corex"

    # Confirm the spend on the impl (self-validation): mine 1, tx leaves mempool,
    # recipient credited on-chain, sender debited by amount+fee.
    log "confirm spend: generatetoaddress 1 -> A1r"
    out=$(nrpc generatetoaddress "[1,\"$A1r\"]")
    em=$(echo "$out" | rpc_errmsg); [[ -z "$em" ]] || fail_line "confirm-block generate error: $em"
    nrpc getrawmempool | grep -q "$txid" && fail_line "spend tx $txid STILL in mempool after confirm (wedge)"

    local recip; recip=$(nrpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]" | res_field total_amount)
    recip=$(btc_to_sats "${recip:-0}")
    [[ "${recip:-0}" -eq "$SEND_SATS" ]] \
        || fail_line "recipient credited $recip sats != sent $SEND_SATS sats (spend did not transfer value)"
    log "recipient credited $recip sats on-chain (== $SEND_BTC BTC)"

    local bal_after_btc bal_after_sats matured expect_nofee fee
    bal_after_btc=$(wrpc getbalance | python3 -c 'import sys,json;r=json.load(sys.stdin).get("result");print(r if r is not None else "")' 2>/dev/null)
    bal_after_sats=$(btc_to_sats "${bal_after_btc:-0}")
    matured=$(( 50 * 100000000 ))                       # height-2 coinbase matures at tip 102
    expect_nofee=$(( bal_r_sats + matured - SEND_SATS ))
    fee=$(( expect_nofee - bal_after_sats ))
    log "implied fee (sender debit beyond amount) = $fee sats"
    [[ "$fee" -gt 0 ]]      || fail_line "no fee debited (balance arithmetic wrong: before=$bal_r_sats after=$bal_after_sats)"
    [[ "$fee" -lt 200000 ]] || fail_line "implied fee $fee sats unreasonably large (balance accounting drift)"

    # ── Receipt (mirrors results/crash-recovery.json precedent). ────────────
    mkdir -p "$RESULTS_DIR" 2>/dev/null || true
    local receipt="$RESULTS_DIR/walletdiff-restore-$IMPL-$ts.json"
    python3 - "$receipt" <<PYEOF 2>/dev/null || true
import json,sys
json.dump({
 "suite":"walletdiff-restore","gate_row":"P2.3","impl":"$IMPL",
 "ts":"$ts","backup_mechanism":"seed(sethdseed)",
 "descriptor_export_channel":"$desc_export",
 "recv_address":"$A1","address_rederives_identical":True,
 "original_balance_sats":$bal_b_sats,"restored_balance_sats":$bal_r_sats,
 "balance_recovered":$([[ "$bal_r_sats" == "$bal_b_sats" ]] && echo True || echo False),
 "spend_txid":"$txid","recipient_credited_sats":$recip,"implied_fee_sats":$fee,
 "spend_confirmed_on_impl":True,"core_cross_accept":"$corex",
}, open(sys.argv[1],"w"), indent=1)
PYEOF
    log "receipt: $receipt"

    pass_line "recovered=$bal_r_btc spend=confirmed corexcheck=$corex backup=seed(sethdseed) desc-export=$desc_export"
}
