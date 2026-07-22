#!/usr/bin/env bash
#
# camlcoin_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for camlcoin (OCaml), differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches camlcoin + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# Launch shape (start_testnet4.sh:100): `main.exe --network <net>
# --datadir <dd> --port <p2p> --rpcport <rpc>` (space-separated args). camlcoin
# does NOT append a network subdir to an explicit --datadir (bin/main.ml:771
# data_dir = resolved_datadir) and writes its cookie at <datadir>/.cookie
# (lib/cli.ml:1301). RPC binds 127.0.0.1 by default; wallet is enabled unless
# --no-wallet. camlcoin routes /wallet/<name> and base "/" -> default wallet.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-camlcoin* only;
# reserved ports 22194/22195 (Core RPC/P2P) + 22196/22197 (camlcoin RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF camlcoin: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="camlcoin"
BIN="$HASHHOG_ROOT/camlcoin/_build/default/bin/main.exe"
BUILD_HINT="build with: ./build-all.sh camlcoin"

CORE_RPC=22194
CORE_P2P=22195
IMPL_RPC=22196
IMPL_P2P=22197

IMPL_DATADIR="/tmp/walletdiff-camlcoin"
CORE_DATADIR="/tmp/walletdiff-camlcoin-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie" "$IMPL_DATADIR/regtest/.cookie")

launch_impl() {
    "$BIN" --network regtest --datadir "$IMPL_DATADIR" \
        --port "$IMPL_P2P" --rpcport "$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_address_main
