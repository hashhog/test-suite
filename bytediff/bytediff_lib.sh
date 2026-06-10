#!/usr/bin/env bash
#
# bytediff_lib.sh — shared engine for the BYTE-EXACT RPC differential instrument.
#
# This is the load-bearing library sourced by every bytediff/<impl>_bytediff.sh
# arm (and by the oracle-vs-oracle self-test). It provides:
#
#   (a) rule-10 teardown + idempotent port-abort preamble (NEVER kills by port);
#   (b) boot helpers: launch a Core regtest oracle (RPC-only, -listen=0) and an
#       impl node, SEQUENTIALLY, with cookie discovery + a generous deadline;
#   (c) a raw-curl JSON-RPC helper `rpc <node> <method> <params-json>` returning
#       the RAW response body (wire-format JSON) — parameterized by (url, auth)
#       so it serves cookie impls, the no-cookie lunarblock, AND Core;
#   (d) the chain-mirror driver: mine-on-Core -> submitblock-into-impl -> assert
#       byte-identical tip, then build+sign ONE spend in-process and push it to
#       both mempools, then confirm it in one more mirrored block;
#   (e) THE DIFF ENGINE: capture the raw body from BOTH sides, run BOTH through
#       ONE identical jq filter
#         '.result | walk(number-canonicalize) | <per-method mask>'
#       (order-preserving — never -S; the `walk(.+0)` number canonicalization is
#       MANDATORY because jq-1.7 preserves literal float tokens so Core's
#       1.00000000 vs an impl's 1.0 would otherwise false-DIFF), then byte-compare.
#       On DIFF a python-built structured per-key summary (missing-on-one-side /
#       type-mismatch / value-mismatch / order-mismatch) goes to the log.
#
# The instrument is the STRICT COMPLEMENT to the existing order-INsensitive
# run-<m>-regression harnesses: it asserts byte-identity of the masked JSON
# INCLUDING key order, int-vs-hex-vs-string formatting, and presence/absence.
#
# Core field-order references (the pushKV emission order is the byte-exact target):
#   getblockchaininfo   bitcoin-core/src/rpc/blockchain.cpp:1418
#   blockheaderToJSON   bitcoin-core/src/rpc/blockchain.cpp:160  (getblockheader, getblock>=1)
#   blockToJSON         bitcoin-core/src/rpc/blockchain.cpp:202
#   TxToUniv            bitcoin-core/src/core_io.cpp:430
#   ScriptToUniv        bitcoin-core/src/core_io.cpp:409
#   gettxout            bitcoin-core/src/rpc/blockchain.cpp:1245
#   gettxoutsetinfo     bitcoin-core/src/rpc/blockchain.cpp:1115
#   getchaintxstats     bitcoin-core/src/rpc/blockchain.cpp:1877
#   getblockstats       bitcoin-core/src/rpc/blockchain.cpp:2167 (alphabetical ret_all)
#   getdifficulty       bitcoin-core/src/rpc/blockchain.cpp:505  (bare number)
#   MempoolInfoToJSON   bitcoin-core/src/rpc/mempool.cpp:1043
#   entryToJSON         bitcoin-core/src/rpc/mempool.cpp:508
#   getnetworkinfo      bitcoin-core/src/rpc/net.cpp
#   getmininginfo       bitcoin-core/src/rpc/mining.cpp:416
#
# SELF-TEST MODE: when BD_SELFTEST=1 the "impl" node is a SECOND Core instance.
# The diff matrix MUST then be 100% IDENTICAL — that is the gate that proves the
# engine + masks have no false positives. A bytediff arm with BD_SELFTEST=1 is
# the oracle-vs-oracle baseline.
#
# Rule 10: teardown kills ONLY PIDs this process spawned; all ports are private
# and BELOW 32768; we ABORT (never kill) if a chosen port is already LISTENING.
# Touches ONLY /tmp scratch dirs. NEVER /data/nvme1 or testnet4-data.

set -uo pipefail

# ── Root + binaries ───────────────────────────────────────────────────────
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CORE_BIN="${CORE_BIN:-$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoind}"
CORE_CLI="${CORE_CLI:-$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoin-cli}"
TF_PATH="${TF_PATH:-$HASHHOG_ROOT/bitcoin-core/test/functional}"   # key/script/tx helpers

# Deterministic secrets (mine to MINE_ADDR which we hold the key for; spend to DEST_ADDR).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"
NBLOCKS="${NBLOCKS:-101}"          # block-1 coinbase matures + is spendable
MOCKTIME="${MOCKTIME:-1700000000}" # pin block times so time/mediantime become byte-comparable

# ── Impl identity — the per-impl arm sets these BEFORE sourcing or before bd_run.
# IMPL_NAME       : short name, e.g. rustoshi
# IMPL_LAUNCH_FN  : name of a shell function that launches the impl (backgrounded,
#                   sets IMPL_PID); see the per-impl arm. In SELFTEST mode this is
#                   ignored and a second Core is launched instead.
# IMPL_AUTH_MODE  : "cookie" (default) or "none" (lunarblock).
# IMPL_COOKIE_PATHS : space-separated candidate cookie file paths (cookie mode).
IMPL_NAME="${IMPL_NAME:-UNSET}"
IMPL_AUTH_MODE="${IMPL_AUTH_MODE:-cookie}"
IMPL_COOKIE_PATHS="${IMPL_COOKIE_PATHS:-}"

# ── Ports (private, all < 32768; per-impl arm overrides to avoid collisions). ─
CORE_RPC="${CORE_RPC:-22612}"
CORE_P2P="${CORE_P2P:-22632}"
IMPL_RPC="${IMPL_RPC:-22610}"
IMPL_P2P="${IMPL_P2P:-22630}"
# Second Core (self-test "impl"):
CORE2_RPC="${CORE2_RPC:-22614}"
CORE2_P2P="${CORE2_P2P:-22634}"

# ── Scratch dirs (unique per impl). ───────────────────────────────────────
SCRATCH_TOKEN="bd-${IMPL_NAME}"
CORE_DATADIR="/tmp/${SCRATCH_TOKEN}-core"
CORE2_DATADIR="/tmp/${SCRATCH_TOKEN}-core2"
IMPL_DATADIR="/tmp/${SCRATCH_TOKEN}-impl"
CORE_LOG="$CORE_DATADIR/core.log"
CORE2_LOG="$CORE2_DATADIR/core2.log"
IMPL_LOG="$IMPL_DATADIR/impl.log"

CORE_BG=""
CORE2_BG=""
IMPL_PID=""
IMPL_COOKIE=""

# ── Runtime selection: self-test vs real impl. ────────────────────────────
BD_SELFTEST="${BD_SELFTEST:-0}"

# ── Logging: everything noisy -> stderr; stdout carries ONLY the summary line. ─
log() { echo "[bytediff:${IMPL_NAME}] $*" >&2; }

# ── Summary emitters (single stdout line; matches the runner's last-line read). ─
# pass <methods> <evaluated> <identical>
pass() {
    echo "BYTEDIFF ${IMPL_NAME}: PASS methods=$1 evaluated=$2 identical=$3 diff=0 error=0"
    exit 0
}
# fail <reason...>  (used for setup/infra failures AND for diff/error failures)
fail() {
    echo "BYTEDIFF ${IMPL_NAME}: FAIL $*"
    exit 1
}

# ════════════════════════════════════════════════════════════════════════
# RULE-10 TEARDOWN + idempotent port-abort preamble.
# ════════════════════════════════════════════════════════════════════════
cleanup() {
    local ec=$?
    # Impl: PID-scoped only.
    if [[ -n "$IMPL_PID" ]] && kill -0 "$IMPL_PID" 2>/dev/null; then
        kill "$IMPL_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$IMPL_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$IMPL_PID" 2>/dev/null || true
    fi
    # Core(s): graceful stop via cli then PID-scoped kill of OUR background pid.
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR"  -rpcport="$CORE_RPC"  stop >/dev/null 2>&1 || true
    "$CORE_CLI" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG"  ]] && kill "$CORE_BG"  2>/dev/null || true
    [[ -n "$CORE2_BG" ]] && kill "$CORE2_BG" 2>/dev/null || true
    rm -rf "$CORE_DATADIR" "$CORE2_DATADIR" "$IMPL_DATADIR" 2>/dev/null || true
    return $ec
}

bd_preamble() {
    trap cleanup EXIT INT TERM
    log "resetting scratch state (token=$SCRATCH_TOKEN, selftest=$BD_SELFTEST)"
    # Idempotent reset: pkill OUR scratch token (matches the datadir path, NOT a port).
    pkill -f "$SCRATCH_TOKEN" 2>/dev/null || true
    # Sweep STALE /tmp/bd-* scratch from prior runs whose EXIT trap missed a hard /
    # OOM kill (W-fix-forward). Only reap dirs that are NOT this arm's and NOT in
    # active use (no process has the dir path in its cmdline) and older than 30min,
    # so a concurrent sibling arm (different token, 2-slot run) is never clobbered.
    local d base
    for d in /tmp/bd-*-core /tmp/bd-*-core2 /tmp/bd-*-impl; do
        [[ -d "$d" ]] || continue
        case "$d" in "$CORE_DATADIR"|"$CORE2_DATADIR"|"$IMPL_DATADIR") continue ;; esac
        base="$(basename "$d")"
        pgrep -f "$base" >/dev/null 2>&1 && continue          # still in use by a live arm
        if [[ -z "$(find "$d" -prune -mmin -30 2>/dev/null)" ]]; then
            log "reaping stale scratch dir $d (no live process, >30min old)"
            rm -rf "$d" 2>/dev/null || true
        fi
    done
    local ports="${IMPL_RPC} ${IMPL_P2P} ${CORE_RPC} ${CORE_P2P} ${CORE2_RPC} ${CORE2_P2P}"
    local re; re="$(printf '%s' "$ports" | tr ' ' '|')"
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":(${re}) " || break
        sleep 1
    done
    if ss -tln 2>/dev/null | grep -qE ":(${re}) "; then
        fail "a chosen port ($ports) is already LISTENING — refusing to kill by port (rule 10 / 2026-06-10 fuser incident)"
    fi
    sleep 2
    rm -rf "$CORE_DATADIR" "$CORE2_DATADIR" "$IMPL_DATADIR"
    mkdir -p "$CORE_DATADIR" "$CORE2_DATADIR" "$IMPL_DATADIR"
}

# ════════════════════════════════════════════════════════════════════════
# CORE ORACLE — bitcoin-cli helpers (for chain control) + raw-curl (for diff).
# ════════════════════════════════════════════════════════════════════════
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# Tolerant of the .cookie read race + heavy concurrent fleet load.
core_cli_retry() {
    local out="" rc=1
    for _ in $(seq 1 20); do
        out=$(core_cli "$@" 2>/dev/null); rc=$?
        [[ $rc -eq 0 && -n "$out" ]] && { echo "$out"; return 0; }
        [[ -n "$CORE_BG" ]] && ! kill -0 "$CORE_BG" 2>/dev/null && return 1
        sleep 3
    done
    return 1
}

# core_call <method> <params-json> -> the .result (compact JSON / bare string), or
# empty on error. Uses CURL (not bitcoin-cli) — under heavy box load (the live
# mainnet fleet) bitcoin-cli's per-call process spawn stalls for tens of seconds
# whereas curl-to-RPC stays sub-second. Requires CORE_COOKIE (read post-launch).
core_call() {
    local method="$1" params="${2:-[]}" out
    for _ in $(seq 1 20); do
        out=$(curl -s --max-time 90 -u "$CORE_COOKIE" \
            --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
            "http://127.0.0.1:$CORE_RPC/" 2>/dev/null)
        if [[ -n "$out" ]] && grep -q '"result"' <<<"$out"; then
            python3 -c 'import sys,json
d=json.load(sys.stdin); r=d.get("result")
if r is None and d.get("error"): sys.exit(1)
print(r if isinstance(r,str) else json.dumps(r) if r is not None else "")' <<<"$out" && return 0
        fi
        [[ -n "$CORE_BG" ]] && ! kill -0 "$CORE_BG" 2>/dev/null && return 1
        sleep 2
    done
    return 1
}

# Launch the primary Core oracle (the GROUND TRUTH).
launch_core_oracle() {
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # -listen=0: RPC-only (sandbox SIGKILLs a 0.0.0.0 P2P listener).
    # txindex/coinstatsindex OFF: lock the minimal stable shape (no optional branches).
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -fallbackfee=0.0002 -mocktime="$MOCKTIME" >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        core_cli getblockcount >/dev/null 2>&1 && { core_cli_retry getblockcount >/dev/null && return 0; }
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

# Read the primary Core's cookie for raw-curl diffing.
CORE_COOKIE=""
read_core_cookie() {
    local c="$CORE_DATADIR/regtest/.cookie"
    [[ -f "$c" ]] || c="$CORE_DATADIR/.cookie"
    [[ -f "$c" ]] || return 1
    CORE_COOKIE=$(cat "$c"); [[ -n "$CORE_COOKIE" ]]
}

# ════════════════════════════════════════════════════════════════════════
# SECOND CORE (self-test "impl"): identical chain, queried as if it were the impl.
# ════════════════════════════════════════════════════════════════════════
core2_cli() { "$CORE_CLI" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" "$@"; }
core2_cli_retry() {
    local out="" rc=1
    for _ in $(seq 1 20); do
        out=$(core2_cli "$@" 2>/dev/null); rc=$?
        [[ $rc -eq 0 && -n "$out" ]] && { echo "$out"; return 0; }
        [[ -n "$CORE2_BG" ]] && ! kill -0 "$CORE2_BG" 2>/dev/null && return 1
        sleep 3
    done
    return 1
}
launch_core2() {
    rm -rf "$CORE2_DATADIR"; mkdir -p "$CORE2_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" -port="$CORE2_P2P" \
        -listen=0 -fallbackfee=0.0002 -mocktime="$MOCKTIME" >"$CORE2_LOG" 2>&1 &
    CORE2_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        core2_cli getblockcount >/dev/null 2>&1 && { core2_cli_retry getblockcount >/dev/null && return 0; }
        kill -0 "$CORE2_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
read_core2_cookie() {
    local c="$CORE2_DATADIR/regtest/.cookie"
    [[ -f "$c" ]] || c="$CORE2_DATADIR/.cookie"
    [[ -f "$c" ]] || return 1
    IMPL_COOKIE=$(cat "$c"); [[ -n "$IMPL_COOKIE" ]]
}

# ════════════════════════════════════════════════════════════════════════
# RAW-CURL JSON-RPC. rpc <which> <method> <params-json-array> -> raw body.
#   which = "core"  -> primary oracle (cookie)
#   which = "impl"  -> the impl node (cookie or none); in self-test, the 2nd Core
# ════════════════════════════════════════════════════════════════════════
# RPC call timeout / retry knobs. The heavy methods (getblock v2, getblockstats,
# gettxoutsetinfo, getmempoolinfo, getrawmempool, getnetworkinfo, getmininginfo)
# can stall a curl under load — a stall returns an EMPTY/non-JSON body, which the
# engine MUST NOT conflate with "byte-identical". We retry such calls before
# giving up (W-fix-forward: heavy methods were silently waved through as "both
# error code " in the under-provisioned 6G/2-slot self-test path).
BD_RPC_MAXTIME="${BD_RPC_MAXTIME:-120}"   # per-attempt curl --max-time (s)
BD_RPC_TRIES="${BD_RPC_TRIES:-4}"         # attempts on an empty / non-JSON body

# bd_is_rpc_body <body> -> 0 iff the body is a non-empty, parseable JSON-RPC
# envelope (a JSON object with a "result" or "error" key). An empty body
# (transport stall / curl timeout) or a non-JSON body is NOT a comparable RPC
# result — it is an EVALUATION FAILURE, and must never reach the byte-compare.
bd_is_rpc_body() {
    local b="$1"
    [[ -n "$b" ]] || return 1
    jq -e 'type=="object" and (has("result") or has("error"))' >/dev/null 2>&1 <<<"$b"
}

# rpc_one — a single raw curl. Returns the raw response body (may be empty).
rpc_one() {
    local which="$1" method="$2" params="${3:-[]}"
    local url auth=()
    if [[ "$which" == "core" ]]; then
        url="http://127.0.0.1:$CORE_RPC/"
        auth=(-u "$CORE_COOKIE")
    else
        url="http://127.0.0.1:$IMPL_RPC/"
        if [[ "$BD_SELFTEST" == "1" ]]; then
            url="http://127.0.0.1:$CORE2_RPC/"; auth=(-u "$IMPL_COOKIE")
        elif [[ "$IMPL_AUTH_MODE" == "cookie" ]]; then
            auth=(-u "$IMPL_COOKIE")
        fi   # auth-mode none -> no -u
    fi
    curl -s --max-time "$BD_RPC_MAXTIME" "${auth[@]}" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$url" 2>/dev/null
}

# rpc — robust call: retries up to BD_RPC_TRIES on an empty / non-JSON body so a
# transient stall on a heavy method doesn't masquerade as an (empty) result. The
# LAST body is returned even if still empty (the caller's bd_diff then classifies
# it as ERROR / evaluation-failure — never IDENTICAL).
rpc() {
    local which="$1" method="$2" params="${3:-[]}"
    local body="" t
    for ((t=1; t<=BD_RPC_TRIES; t++)); do
        body="$(rpc_one "$which" "$method" "$params")"
        bd_is_rpc_body "$body" && { printf '%s' "$body"; return 0; }
        # Empty/non-JSON: if the node is dead, stop early; else back off and retry.
        if [[ "$which" == "core" && -n "$CORE_BG" ]] && ! kill -0 "$CORE_BG" 2>/dev/null; then break; fi
        if [[ "$which" == "impl" && "$BD_SELFTEST" == "1" && -n "$CORE2_BG" ]] && ! kill -0 "$CORE2_BG" 2>/dev/null; then break; fi
        if [[ "$which" == "impl" && "$BD_SELFTEST" != "1" && -n "$IMPL_PID" ]] && ! kill -0 "$IMPL_PID" 2>/dev/null; then break; fi
        (( t < BD_RPC_TRIES )) && { log "rpc $which $method: empty/non-JSON body (attempt $t/$BD_RPC_TRIES) — retrying"; sleep 2; }
    done
    printf '%s' "$body"
}

# ════════════════════════════════════════════════════════════════════════
# IMPL control helpers. All go through the curl `rpc impl` path, which routes to
# the real impl node OR (in self-test) the 2nd Core's RPC — so NO per-call
# bitcoin-cli process spawn, which matters because the mirror submits NBLOCKS+1
# blocks one at a time.
# ════════════════════════════════════════════════════════════════════════
impl_submitblock() {
    rpc impl submitblock "[\"$1\"]" >/dev/null 2>&1 || true
}
impl_blockcount() {
    python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"])
except Exception: pass' <<<"$(rpc impl getblockcount '[]')"
}
impl_bestblockhash() {
    python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"])
except Exception: pass' <<<"$(rpc impl getbestblockhash '[]')"
}
impl_sendrawtransaction() {
    local hex="$1"
    if [[ "$BD_SELFTEST" == "1" ]]; then core2_cli_retry sendrawtransaction "$hex" >/dev/null 2>&1 || true; return 0; fi
    rpc impl sendrawtransaction "[\"$hex\"]"
}

# ════════════════════════════════════════════════════════════════════════
# THE DIFF ENGINE.
# ════════════════════════════════════════════════════════════════════════
# Per-method mask table. Each mask is a jq filter applied AFTER number
# canonicalization, BEFORE the byte-compare. Masks sentinel-ASSIGN (never
# delete) so a missing/extra key or a type-flip still trips the diff.
# Sentinel type matches the field's JSON type (number->0, string->"M", bool->false).
#
# Many chain/tx methods need NO mask: with -mocktime pinned and the chain
# mirrored block-for-block, time/mediantime/etc. are byte-identical by
# construction, so they drop OUT of the mask set.
declare -gA BD_MASK=(
    # getblockchaininfo: verificationprogress/size_on_disk/warnings are state/wall-clock derived.
    # time/mediantime ARE deterministic (mocktime + identical chain) so they are NOT masked.
    [getblockchaininfo]='.verificationprogress=0 | .size_on_disk=0 | .warnings=(.warnings|if type=="array" then ["M"] else "M" end)'
    # getblockheader / getblock: confirmations is deterministic (identical mirrored tip) -> not masked.
    #   No mask needed — everything is chain-derived & pinned.
    [getblockheader]='.'
    [getblock]='.'
    # gettxout: bestblock/confirmations deterministic on the pinned chain.
    [gettxout]='.'
    # gettxoutsetinfo (hash_type=none): height/bestblock/txouts/bogosize/total_amount deterministic.
    [gettxoutsetinfo]='.'
    # getmempoolinfo: usage/loaded may vary; on an empty mempool everything is stable, but
    # mask usage defensively (allocator-derived) — keep loaded (deterministic true).
    [getmempoolinfo]='.usage=0'
    # getrawmempool true: per-entry time is entry-walltime (we set it via mocktime so it IS
    # pinned, but mask defensively); height is the entry block height (deterministic).
    [getrawmempool]='if type=="object" then with_entries(.value.time=0) else . end'
    # getchaintxstats: time/txrate/window_interval are wall-clock-derived.
    [getchaintxstats]='.time=0 | (if has("txrate") then .txrate=0 else . end) | (if has("window_interval") then .window_interval=0 else . end)'
    # getnetworkinfo: per-node/socket/UA state. subversion is the per-impl user-agent -> MASK.
    [getnetworkinfo]='.timeoffset=0 | .connections=0 | (if has("connections_in") then .connections_in=0 else . end) | (if has("connections_out") then .connections_out=0 else . end) | .networkactive=false | .localaddresses=["M"] | .subversion="M" | .warnings=(.warnings|if type=="array" then ["M"] else "M" end)'
    # getmininginfo: networkhashps/pooledtx are state-derived. currentblockweight/
    # currentblocktx are OPTIONAL template-assembler state — present only on a node
    # that has assembled a block template (the miner), ABSENT on a node that only
    # received blocks via submitblock. Their very PRESENCE is non-deterministic, so
    # (uniquely) DELETE them on both sides — assignment can't normalize present-vs-
    # absent without creating the key. This is the same class as getblocktemplate's
    # curtime: legitimately node-state-dependent presence.
    [getmininginfo]='del(.currentblockweight) | del(.currentblocktx) | .networkhashps=0 | .pooledtx=0 | .warnings=(.warnings|if type=="array" then ["M"] else "M" end)'
    # getwalletinfo (wallet tier): birthtime/scanning/lastprocessedblock.hash/unlocked_until.
    [getwalletinfo]='(if has("birthtime") then .birthtime=0 else . end) | .scanning=false | (if has("lastprocessedblock") then .lastprocessedblock.hash="M" else . end) | (if has("unlocked_until") then .unlocked_until=0 else . end)'
    [getaddressinfo]='(if has("timestamp") then .timestamp=0 else . end)'
    # Pure functions of input (decoderawtransaction/decodescript/validateaddress/
    # getdescriptorinfo/deriveaddresses) + getblockhash/getblockstats/getchaintips/
    # getdifficulty/getbestblockhash/getblockcount: NO mask (default '.').
)

# bd_norm <raw-response-body> <method>  -> canonical compact JSON of .result (or empty).
# 1. extract .result  2. canonicalize numbers (collapse 1.00000000 / 1.0 / 1 -> 1,
#    preserving key order)  3. apply the per-method mask (position-preserving).
# NEVER -S (that sorts keys; key ORDER is part of the diff).
bd_norm() {
    local raw="$1" method="$2"
    local mask="${BD_MASK[$method]:-.}"
    jq -c ".result | walk(if type==\"number\" then .+0 else . end) | ${mask}" 2>/dev/null <<<"$raw"
}

# bd_has_error <raw> -> 0 iff the body is a valid envelope carrying a non-null
# error object. (Presupposes bd_is_rpc_body already passed.)
bd_has_error() {
    jq -e '.error != null' >/dev/null 2>&1 <<<"$1"
}

# bd_err_norm <raw> -> the error object normalized to {code,message} compact JSON,
# for a BYTE-for-byte error comparison. An impl that returns a bare -32601
# "Method not found" vs Core's real {code:-5,message:"No such ..."} is a real
# DIFF and must be caught — so we compare the whole {code,message}, not just code.
bd_err_norm() {
    jq -c '.error | {code: .code, message: .message}' 2>/dev/null <<<"$1"
}

# Structured per-key divergence summary for the log. Compares the two NORMALIZED
# (post-mask) JSON strings and classifies: missing-on-impl / extra-on-impl /
# type-mismatch / value-mismatch / order-mismatch.
bd_detail() {  # $1=impl_norm $2=core_norm
    python3 - "$1" "$2" <<'PY' 2>/dev/null
import sys, json
impl_s, core_s = sys.argv[1], sys.argv[2]
try:
    impl = json.loads(impl_s)
except Exception:
    print("impl-result-not-json"); sys.exit(0)
try:
    core = json.loads(core_s)
except Exception:
    print("core-result-not-json"); sys.exit(0)

out = []
def jt(v):
    if isinstance(v, bool): return "bool"
    if isinstance(v, (int, float)): return "number"
    if isinstance(v, str): return "string"
    if isinstance(v, list): return "array"
    if isinstance(v, dict): return "object"
    if v is None: return "null"
    return type(v).__name__

def walk(path, ci, ii):
    if isinstance(ci, dict) and isinstance(ii, dict):
        ck, ik = list(ci.keys()), list(ii.keys())
        if ck != ik:
            # distinguish order-mismatch from missing/extra
            if set(ck) == set(ik):
                out.append(f"{path or '<root>'}: KEY-ORDER core={ck} impl={ik}")
            else:
                miss = [k for k in ck if k not in ik]
                extra = [k for k in ik if k not in ck]
                if miss:  out.append(f"{path or '<root>'}: MISSING-ON-IMPL {miss}")
                if extra: out.append(f"{path or '<root>'}: EXTRA-ON-IMPL {extra}")
        for k in ck:
            if k in ii:
                walk(f"{path}.{k}" if path else k, ci[k], ii[k])
        return
    if isinstance(ci, list) and isinstance(ii, list):
        if len(ci) != len(ii):
            out.append(f"{path}: ARRAY-LEN core={len(ci)} impl={len(ii)}")
        for i in range(min(len(ci), len(ii))):
            walk(f"{path}[{i}]", ci[i], ii[i])
        return
    if jt(ci) != jt(ii):
        out.append(f"{path or '<root>'}: TYPE core={jt(ci)}({ci!r}) impl={jt(ii)}({ii!r})")
    elif ci != ii:
        out.append(f"{path or '<root>'}: VALUE core={ci!r} impl={ii!r}")

walk("", core, impl)
if not out:
    out.append("(normalized strings differ but structural walk found no diff — likely number-token or whitespace; raw compare below)")
print(" ; ".join(out[:25]))
PY
}

# Counters (per-arm). Set by bd_run.
#   BD_METHODS   : total methods attempted (rows in the matrix).
#   BD_EVALUATED : methods where BOTH sides returned a real (non-empty, parseable)
#                  RPC envelope — i.e. were actually compared. A method that hit an
#                  empty/transport-failure body on either side is NOT evaluated.
#   BD_COMPARED  : methods that reached a result-vs-result OR error-vs-error
#                  byte-comparison (== BD_EVALUATED; kept distinct for clarity).
#   BD_IDENTICAL : compared methods that were byte-identical after masking.
#   BD_DIFFS     : space-separated list of methods that DIFFed.
#   BD_ERRORS    : space-separated list of methods that ERRORed (evaluation
#                  failure: empty/non-JSON body on a side) — these are NON-PASS.
BD_METHODS=0
BD_EVALUATED=0
BD_COMPARED=0
BD_IDENTICAL=0
BD_DIFFS=""
BD_ERRORS=""

# bd_diff <method> <params-json>  -> queries BOTH sides, normalizes, byte-compares.
# Emits one of, to the log:
#   "<method>: IDENTICAL"               both sides compared byte-identical
#   "<method>: DIFF <detail>"           both sides produced a result/error, differ
#   "<method>: ERROR <reason>"          EVALUATION FAILURE (empty/non-JSON body on a
#                                       side) — NEVER counted IDENTICAL.
# Verdict precedence (W-fix-forward): an empty / non-JSON body on EITHER side is an
# evaluation failure (ERROR), is NON-PASS, and never maps to IDENTICAL. 'both empty'
# is NOT identity. A genuine RPC error (a real {code,message} envelope on both
# sides) IS compared byte-for-byte (error-shape parity is a legitimate IDENTICAL).
bd_diff() {
    local method="$1" params="${2:-[]}"
    local core_raw impl_raw nc ni
    BD_METHODS=$((BD_METHODS+1))
    core_raw="$(rpc core "$method" "$params")"
    impl_raw="$(rpc impl "$method" "$params")"

    # ── Gate 1: BOTH bodies MUST be real, parseable JSON-RPC envelopes. An empty
    #    or non-JSON body is a transport/evaluation failure, NOT a comparable
    #    result. This is the no-false-positive fix: 'both empty' => ERROR, never
    #    IDENTICAL.
    local core_ok=1 impl_ok=1
    bd_is_rpc_body "$core_raw" || core_ok=0
    bd_is_rpc_body "$impl_raw" || impl_ok=0
    if [[ "$core_ok" == "0" || "$impl_ok" == "0" ]]; then
        local who=""
        [[ "$core_ok" == "0" ]] && who="core"
        [[ "$impl_ok" == "0" ]] && who="${who:+$who+}impl"
        log "$method $params: ERROR evaluation-failure (empty/non-JSON body on: $who)"
        [[ "$core_ok" == "0" ]] && log "    core_raw=[${core_raw}]"
        [[ "$impl_ok" == "0" ]] && log "    impl_raw=[${impl_raw}]"
        BD_ERRORS="$BD_ERRORS $method"; return 1
    fi

    # Both bodies are real envelopes -> this method is EVALUATED (actually compared).
    BD_EVALUATED=$((BD_EVALUATED+1))
    BD_COMPARED=$((BD_COMPARED+1))

    # ── Gate 2: error-envelope parity. If EITHER side carries a non-null error,
    #    compare the full {code,message} byte-for-byte. (An impl -32601 vs Core's
    #    real {code:-5,message:...} is a real DIFF.)
    local ce ie; ce=$(bd_has_error "$core_raw" && echo 1 || echo 0); ie=$(bd_has_error "$impl_raw" && echo 1 || echo 0)
    if [[ "$ce" == "1" || "$ie" == "1" ]]; then
        local cen ien; cen="$(bd_err_norm "$core_raw")"; ien="$(bd_err_norm "$impl_raw")"
        if [[ "$ce" == "1" && "$ie" == "1" && "$cen" == "$ien" ]]; then
            log "$method $params: IDENTICAL (both error: $cen)"; BD_IDENTICAL=$((BD_IDENTICAL+1)); return 0
        fi
        log "$method $params: DIFF error-envelope core_err=$cen impl_err=$ien"
        BD_DIFFS="$BD_DIFFS $method"; return 1
    fi

    # ── Gate 3: result byte-compare (the normal path).
    nc="$(bd_norm "$core_raw" "$method")"
    ni="$(bd_norm "$impl_raw" "$method")"
    # A non-null result that fails to normalize (mask filter blew up) is an ERROR,
    # not a silent identity — surface it.
    if [[ -z "$nc" || -z "$ni" ]]; then
        log "$method $params: ERROR result-not-normalizable (mask/jq failure) core_norm=[${nc}] impl_norm=[${ni}]"
        log "    core_raw=$core_raw"
        log "    impl_raw=$impl_raw"
        # This is a real residual: emit as a DIFF so it is NON-PASS and visible.
        BD_DIFFS="$BD_DIFFS $method"; return 1
    fi
    if [[ "$ni" == "$nc" ]]; then
        log "$method $params: IDENTICAL"
        BD_IDENTICAL=$((BD_IDENTICAL+1)); return 0
    fi
    local detail; detail="$(bd_detail "$ni" "$nc")"
    log "$method $params: DIFF  $detail"
    log "    core=$nc"
    log "    impl=$ni"
    BD_DIFFS="$BD_DIFFS $method"
    return 1
}

# ════════════════════════════════════════════════════════════════════════
# DETERMINISTIC REGTEST STATE (shared recipe).
#   Mine NBLOCKS on Core to MINE_ADDR (fixed key) under -mocktime, mirror block-
#   for-block into the impl via submitblock (byte-identical tip), then build+sign
#   ONE spend in-process, push to BOTH mempools, then mine+mirror one more block
#   to confirm it. Sets globals: MINE_ADDR DEST_ADDR TXID CB_TXID SPEND_HEX
#   CONF_BLOCKHASH TIP_HASH.
# ════════════════════════════════════════════════════════════════════════
derive_addrs() {
    MINE_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null) \
        || fail "could not derive mining address (test_framework import failed)"
    [[ "$MINE_ADDR" == bcrt1* ]] || fail "mining address not regtest bech32: '$MINE_ADDR'"
    DEST_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$DEST_SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null) \
        || fail "could not derive destination address"
    [[ "$DEST_ADDR" == bcrt1* ]] || fail "destination address not regtest bech32: '$DEST_ADDR'"
    log "mine addr=$MINE_ADDR dest addr=$DEST_ADDR"
}

build_state() {
    derive_addrs
    log "mining $NBLOCKS blocks to $MINE_ADDR on Core (mocktime=$MOCKTIME)"
    # Use curl (core_call), not bitcoin-cli: under the live-fleet box load,
    # bitcoin-cli's per-call process spawn stalls; curl-to-RPC stays sub-second.
    core_call setmocktime "[$MOCKTIME]" >/dev/null 2>&1 || true
    core_call generatetoaddress "[$NBLOCKS, \"$MINE_ADDR\"]" >/dev/null \
        || fail "Core generatetoaddress failed"
    local ch; ch=$(core_call getblockcount '[]')
    [[ "$ch" == "$NBLOCKS" ]] || fail "Core height $ch != $NBLOCKS after mining"

    log "mirroring $NBLOCKS blocks into impl via submitblock"
    BLK1_RAW=""
    local h BH RAW
    for ((h=1; h<=NBLOCKS; h++)); do
        BH=$(core_call getblockhash "[$h]")        || fail "Core getblockhash $h failed"
        BH=${BH//\"/}
        RAW=$(core_call getblock "[\"$BH\", 0]")    || fail "Core getblock $h (raw) failed"
        RAW=${RAW//\"/}
        [[ "$h" == "1" ]] && BLK1_RAW="$RAW"
        impl_submitblock "$RAW" >/dev/null 2>&1 || true
    done
    local ih; ih=$(impl_blockcount)
    [[ "$ih" == "$NBLOCKS" ]] || fail "impl height '$ih' != $NBLOCKS after mirror (submitblock did not connect chain)"
    local ct rt; ct=$(core_call getbestblockhash '[]'); ct=${ct//\"/}; rt=$(impl_bestblockhash)
    [[ "$ct" == "$rt" ]] || fail "tip mismatch after mirror: core=$ct impl=$rt"
    TIP_HASH="$ct"
    log "both nodes at identical tip $TIP_HASH (height $NBLOCKS)"

    # Build + sign ONE spend of block-1's matured coinbase.
    [[ -n "$BLK1_RAW" ]] || fail "block-1 raw bytes not captured"
    read -r CB_TXID CB_VALUE < <(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
import io
from test_framework.messages import CBlock
b = CBlock(); b.deserialize(io.BytesIO(bytes.fromhex('$BLK1_RAW')))
cb = b.vtx[0]
print(cb.txid_hex, cb.vout[0].nValue)
" 2>/dev/null) || fail "could not parse block-1 coinbase"
    [[ "$CB_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "bad block-1 coinbase txid '$CB_TXID'"

    SPEND_HEX=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import sign_input_segwitv0
from test_framework.script_util import key_to_p2wpkh_script, keyhash_to_p2pkh_script
from test_framework.address import address_to_scriptpubkey
from test_framework.crypto.ripemd160 import ripemd160
import hashlib
src = ECKey(); src.set(bytes.fromhex('$SECRET'), compressed=True)
src_pub = src.get_pubkey().get_bytes()
tx = CTransaction(); tx.version = 2
tx.vin = [CTxIn(COutPoint(int('$CB_TXID',16), 0), b'', 0xffffffff)]
tx.vout = [CTxOut(int('$CB_VALUE') - 10000, address_to_scriptpubkey('$DEST_ADDR'))]
tx.wit.vtxinwit = [CTxInWitness()]
keyhash = ripemd160(hashlib.sha256(src_pub).digest())
sign_input_segwitv0(tx, 0, keyhash_to_p2pkh_script(keyhash), int('$CB_VALUE'), src)
tx.wit.vtxinwit[0].scriptWitness.stack.append(src_pub)
print(tx.serialize_with_witness().hex())
" 2>/dev/null) || fail "in-process tx signing failed"
    [[ "$SPEND_HEX" =~ ^[0-9a-f]+$ ]] || fail "signed tx hex malformed"

    local cs; cs=$(core_call sendrawtransaction "[\"$SPEND_HEX\"]") || fail "Core rejected the signed spend"
    TXID=$(echo "$cs" | tr -d '"[:space:]')
    [[ "$TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned non-txid '$TXID'"
    impl_sendrawtransaction "$SPEND_HEX" >/dev/null 2>&1 || true
    log "identical spend $TXID now in both mempools"

    # Confirm it: mine 1 more block on Core (still under mocktime), mirror it.
    core_call generatetoaddress "[1, \"$MINE_ADDR\"]" >/dev/null || fail "Core confirm-mine failed"
    CONF_BLOCKHASH=$(core_call getbestblockhash '[]'); CONF_BLOCKHASH=${CONF_BLOCKHASH//\"/}
    [[ "$CONF_BLOCKHASH" =~ ^[0-9a-f]{64}$ ]] || fail "could not resolve confirming blockhash"
    local craw; craw=$(core_call getblock "[\"$CONF_BLOCKHASH\", 0]"); craw=${craw//\"/}
    [[ -n "$craw" ]] || fail "Core getblock confirming failed"
    impl_submitblock "$craw" >/dev/null 2>&1 || true
    local rt2; rt2=$(impl_bestblockhash)
    [[ "$rt2" == "$CONF_BLOCKHASH" ]] || fail "impl did not connect the confirming block (tip=$rt2 want=$CONF_BLOCKHASH)"
    TIP_HASH="$CONF_BLOCKHASH"
    log "spend $TXID confirmed in $CONF_BLOCKHASH on both nodes; tip now $TIP_HASH (height $((NBLOCKS+1)))"
}

# ════════════════════════════════════════════════════════════════════════
# THE METHOD MATRIX. Runs bd_diff over the manifest of high-value, deterministic,
# READ methods. Uses the state globals built by build_state.
# ════════════════════════════════════════════════════════════════════════
run_manifest() {
    # --- Pure-function util tier (zero masking, highest-confidence byte signal). ---
    #  decoderawtransaction / decodescript: pure functions of the input hex.
    bd_diff decoderawtransaction "[\"$SPEND_HEX\"]"          || true
    # decodescript on the destination P2WPKH scriptPubKey hex.
    local DEST_SPK
    DEST_SPK=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.address import address_to_scriptpubkey
print(address_to_scriptpubkey('$DEST_ADDR').hex())" 2>/dev/null)
    [[ -n "$DEST_SPK" ]] && { bd_diff decodescript "[\"$DEST_SPK\"]" || true; }
    bd_diff validateaddress "[\"$DEST_ADDR\"]"               || true
    bd_diff validateaddress "[\"not_a_real_address_xyz\"]"   || true   # invalid-shape parity
    # getdescriptorinfo / deriveaddresses on a fixed descriptor.
    local DESC="addr($DEST_ADDR)"
    bd_diff getdescriptorinfo "[\"$DESC\"]"                  || true

    # --- Chain tier (deterministic by construction). ---
    bd_diff getblockchaininfo '[]'                           || true
    bd_diff getblockcount '[]'                               || true
    bd_diff getbestblockhash '[]'                            || true
    bd_diff getblockhash '[1]'                               || true
    bd_diff getdifficulty '[]'                               || true
    bd_diff getchaintips '[]'                                || true
    bd_diff getchaintxstats '[]'                             || true
    bd_diff getblockheader "[\"$TIP_HASH\", true]"           || true
    bd_diff getblock "[\"$TIP_HASH\", 0]"                    || true
    bd_diff getblock "[\"$TIP_HASH\", 1]"                    || true
    bd_diff getblock "[\"$TIP_HASH\", 2]"                    || true
    bd_diff getblockstats "[$((NBLOCKS+1))]"                 || true
    bd_diff gettxoutsetinfo '["none"]'                       || true

    # --- UTXO / tx tier. ---
    # The spend's output is now an unspent UTXO: gettxout TXID 0 -> object.
    bd_diff gettxout "[\"$TXID\", 0]"                        || true
    # A spent coinbase output: gettxout CB_TXID 0 -> null (it was spent).
    bd_diff gettxout "[\"$CB_TXID\", 0]"                     || true

    # --- Mempool tier (empty after confirm; still byte-comparable shapes). ---
    bd_diff getmempoolinfo '[]'                              || true
    bd_diff getrawmempool '[false]'                          || true
    bd_diff getrawmempool '[true]'                           || true

    # --- Network / mining tier (heavily masked). ---
    bd_diff getnetworkinfo '[]'                              || true
    bd_diff getmininginfo '[]'                               || true
}

# ════════════════════════════════════════════════════════════════════════
# bd_run — top-level driver called by each per-impl arm.
#   The per-impl arm sets IMPL_NAME/ports/auth + defines impl_launch(), then
#   calls bd_run. In self-test (BD_SELFTEST=1) a 2nd Core stands in for the impl.
# ════════════════════════════════════════════════════════════════════════
bd_run() {
    bd_preamble
    command -v python3 >/dev/null 2>&1 || fail "python3 not found"
    command -v curl    >/dev/null 2>&1 || fail "curl not found"
    command -v jq      >/dev/null 2>&1 || fail "jq not found"
    [[ -x "$CORE_BIN" ]]               || fail "bitcoind not found at $CORE_BIN"
    [[ -x "$CORE_CLI" ]]               || fail "bitcoin-cli not found at $CORE_CLI"
    [[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

    # 1. Core oracle FIRST.
    local ok=0 a
    for a in 1 2 3; do
        log "launching Core oracle rpc=:$CORE_RPC (attempt $a)"
        launch_core_oracle && { ok=1; break; }
        [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
        sleep 3
    done
    [[ "$ok" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start"; }
    read_core_cookie || fail "Core cookie never appeared"
    log "Core oracle ready (pid=$CORE_BG)"

    # 2. Impl (or 2nd Core in self-test) SECOND.
    if [[ "$BD_SELFTEST" == "1" ]]; then
        ok=0
        for a in 1 2 3; do
            log "launching 2nd Core (self-test impl) rpc=:$CORE2_RPC (attempt $a)"
            launch_core2 && { ok=1; break; }
            [[ -n "$CORE2_BG" ]] && kill "$CORE2_BG" 2>/dev/null || true
            sleep 3
        done
        [[ "$ok" == "1" ]] || { tail -n 20 "$CORE2_LOG" >&2 2>/dev/null || true; fail "2nd Core failed to start"; }
        read_core2_cookie || fail "2nd Core cookie never appeared"
        log "2nd Core (self-test impl) ready (pid=$CORE2_BG)"
    else
        impl_launch   # per-impl arm function: backgrounds the node, sets IMPL_PID
        # Cookie discovery (cookie mode) + RPC readiness.
        local deadline=$(( $(date +%s) + 120 ))
        while (( $(date +%s) < deadline )); do
            if [[ "$IMPL_AUTH_MODE" == "cookie" && -z "$IMPL_COOKIE" ]]; then
                local c
                for c in $IMPL_COOKIE_PATHS; do
                    [[ -f "$c" ]] && IMPL_COOKIE=$(cat "$c") && break
                done
            fi
            if [[ "$IMPL_AUTH_MODE" == "none" || -n "$IMPL_COOKIE" ]]; then
                rpc impl getblockcount '[]' | grep -q '"result"' && break
            fi
            [[ -n "$IMPL_PID" ]] && ! kill -0 "$IMPL_PID" 2>/dev/null && { tail -n 20 "$IMPL_LOG" >&2 2>/dev/null || true; fail "impl exited during startup (see $IMPL_LOG)"; }
            sleep 1
        done
        if [[ "$IMPL_AUTH_MODE" == "cookie" ]]; then
            [[ -n "$IMPL_COOKIE" ]] || fail "impl cookie never appeared within 120s"
        fi
        rpc impl getblockcount '[]' | grep -q '"result"' || fail "impl RPC never responded within 120s"
        log "impl RPC ready"
    fi

    # 3. Build the deterministic shared state.
    build_state

    # 4. Run the byte-diff matrix.
    run_manifest

    # 5. Verdict.
    #    PASS requires: (a) every method actually EVALUATED (both sides produced a
    #    real envelope) — an ERROR (empty/non-JSON body) is NON-PASS; AND (b) zero
    #    DIFFs. 'both empty' is an ERROR here, never a silent identity.
    local ndiff nerr; ndiff=$(echo $BD_DIFFS | wc -w); nerr=$(echo $BD_ERRORS | wc -w)
    log "matrix done: methods=$BD_METHODS evaluated=$BD_EVALUATED compared=$BD_COMPARED identical=$BD_IDENTICAL diff=$ndiff error=$nerr"
    log "    diffs=[$BD_DIFFS ]  errors=[$BD_ERRORS ]"
    if [[ "$BD_EVALUATED" -ne "$BD_METHODS" ]]; then
        log "NOT ALL METHODS EVALUATED: $BD_EVALUATED/$BD_METHODS real compares ($nerr evaluation-failures: $BD_ERRORS)"
    fi
    if [[ "$ndiff" -eq 0 && "$nerr" -eq 0 && "$BD_EVALUATED" -eq "$BD_METHODS" ]]; then
        pass "$BD_METHODS" "$BD_EVALUATED" "$BD_IDENTICAL"
    elif [[ "$nerr" -gt 0 && "$ndiff" -eq 0 ]]; then
        # Pure evaluation failures (no real divergence found): report distinctly so
        # the parent sees compares-that-never-happened, not a clean board.
        fail "evaluation-failures on:$BD_ERRORS (methods=$BD_METHODS evaluated=$BD_EVALUATED identical=$BD_IDENTICAL diff=0 error=$nerr)"
    else
        fail "byte-diff on:$BD_DIFFS (methods=$BD_METHODS evaluated=$BD_EVALUATED identical=$BD_IDENTICAL diff=$ndiff error=$nerr)${BD_ERRORS:+ errors:$BD_ERRORS}"
    fi
}
