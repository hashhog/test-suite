#!/usr/bin/env bash
#
# nimrod_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for nimrod, differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches nimrod + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-nimrod* only;
# reserved ports 22158/22159 (Core RPC/P2P) + 22178/22179 (nimrod RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF nimrod: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.
#
# NOTE: nimrod needs the trailing `start` subcommand, binds RPC to
# 127.0.0.1:<rpcport>, writes its cookie to <datadir>/regtest/.cookie, and by
# default tries to bind Prometheus port 9332. We pass --metricsport=0 to disable
# metrics so a busy 9332 on this box is a non-issue.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="nimrod"
BIN="$HASHHOG_ROOT/nimrod/bin/nimrod"
BUILD_HINT="build with: nimble build -d:release -y"

CORE_RPC=22158
CORE_P2P=22159
IMPL_RPC=22178
IMPL_P2P=22179

IMPL_DATADIR="/tmp/walletdiff-nimrod"
CORE_DATADIR="/tmp/walletdiff-nimrod-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" --regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" --metricsport=0 start \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_address_main
