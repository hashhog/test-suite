#!/usr/bin/env bash
#
# haskoin_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for haskoin (Haskell), differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches haskoin + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# Launch shape (start_testnet4.sh:135 + `haskoin --help`): GLOBAL options
# (--datadir/--network) come BEFORE the `node` subcommand; node options
# (--rpcport/--port/--metricsport) come after. For regtest haskoin appends a
# `regtest/` subdir to the datadir (app/Main.hs:480 netName Regtest = "regtest")
# and writes its cookie at <datadir>/regtest/.cookie (Rpc.hs:949). We pass
# --metricsport 0 and --healthport 0 so a busy 9332/health port on this box is a
# non-issue.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-haskoin* only;
# reserved ports 22158/22159 (Core RPC/P2P) + 22178/22179 (haskoin RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF haskoin: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="haskoin"
BIN="$(find "$HASHHOG_ROOT/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
BUILD_HINT="build with: cd haskoin && cabal build (rocksdb_compat shim: scripts/build-rocksdb-compat.sh)"

CORE_RPC=22158
CORE_P2P=22159
IMPL_RPC=22178
IMPL_P2P=22179

IMPL_DATADIR="/tmp/walletdiff-haskoin"
CORE_DATADIR="/tmp/walletdiff-haskoin-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" --datadir="$IMPL_DATADIR" --network Regtest \
        node --rpcport "$IMPL_RPC" --port "$IMPL_P2P" \
        --metricsport 0 --healthport 0 \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_address_main
