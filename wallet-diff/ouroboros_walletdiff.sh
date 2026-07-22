#!/usr/bin/env bash
#
# ouroboros_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for ouroboros (Python + Rust FFI), differential against a REAL bitcoind
# regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches ouroboros + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-ouroboros* only;
# reserved ports 22158/22159 (Core RPC/P2P) + 22178/22179 (ouroboros RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF ouroboros: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.
#
# ouroboros dialect: launched as the Python CLI (no compiled binary) —
#   python3 -m ouroboros.cli --network regtest --data-dir <dd> start --force
#   --rpc-port <R> --p2p-port <P> --nodnsseed --nolisten
# Cookie is written to <dd>/.cookie (__cookie__:<hex>, NO network subdir).
# Node-level RPCs (getdescriptorinfo, deriveaddresses) are answered on the base
# URL "/", so the address slice needs no wallet.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="ouroboros"
# ouroboros is interpreted (Python) — the "binary" is the CLI module, launched
# via `python3 -m ouroboros.cli`. Mirror the lunarblock (Lua) precedent: point
# BIN at the interpreter so _lib.sh's `[[ -x "$BIN" ]]` precondition passes
# without a compiled artifact; launch_impl invokes the module from OURO_DIR.
OURO_DIR="$HASHHOG_ROOT/ouroboros"
BIN="$(command -v python3 || echo python3)"
BUILD_HINT="python module ouroboros.cli (no build; reinstall Rust ext via tools/reinstall_ouroboros.sh only if import fails)"

CORE_RPC=22158
CORE_P2P=22159
IMPL_RPC=22178
IMPL_P2P=22179

IMPL_DATADIR="/tmp/walletdiff-ouroboros"
CORE_DATADIR="/tmp/walletdiff-ouroboros-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie" "$IMPL_DATADIR/regtest/.cookie")

launch_impl() {
    ( cd "$OURO_DIR" && exec python3 -m ouroboros.cli \
        --network regtest --data-dir "$IMPL_DATADIR" \
        start --force --rpc-port "$IMPL_RPC" --p2p-port "$IMPL_P2P" \
        --nodnsseed --nolisten \
        >"$IMPL_DATADIR/node.log" 2>&1 ) &
    IMPL_PID=$!
}

walletdiff_address_main
