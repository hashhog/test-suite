#!/usr/bin/env bash
# Regression test: a node must recover from a MISSING BLOCK BODY in its store.
#
# WHY THIS EXISTS
# ---------------
# 2026-08-04: /data/nvme1 filled, rustoshi lost the body for block 960959, and
# the node wedged PERMANENTLY — blocks=960958 while headers=960977, with 8
# healthy peers, discarding every new block as "previous block not found" and
# never re-requesting the missing parent. See
# receipts/rustoshi-block-gap-wedge-2026-08-04.md.
#
# Any cause of a lost body reproduces it: ENOSPC, bad sector, kill mid-flush.
#
# WHAT CORRECT BEHAVIOUR IS
# -------------------------
# Bitcoin Core drives block download from a header-chain walk anchored on the
# ACTIVE TIP, not on what a peer just sent:
#
#   net_processing.cpp:1426  pindexLastCommonBlock = LastCommonAncestor(
#                                peer_best_header, ActiveTip())
#   net_processing.cpp:1506  have body -> skip; in flight -> skip; else REQUEST
#
# Because the walk restarts from the active tip every sync pass, a hole is
# re-requested until it is filled. A node that only reacts to inbound blocks
# cannot self-heal.
#
# USAGE
#   bash test-suite/test_block_gap_recovery.sh <node>
#
# STATUS: WRITTEN, NEVER RUN. Drafted 2026-08-04 while the box was at 0 bytes
# free and could not build or run anything. Treat every expectation below as
# unverified until it has passed once against a node known to be correct
# (bitcoin-core is the natural control — it should PASS by construction).
set -euo pipefail

NODE="${1:?usage: $0 <node>}"
BLOCKS="${BLOCKS:-200}"
GAP_AT="${GAP_AT:-100}"          # which height's body to delete
TIMEOUT="${TIMEOUT:-180}"        # seconds to wait for recovery
WORKDIR="$(mktemp -d "/tmp/gap-recovery-${NODE}-XXXXXX")"

cleanup() { [ "${KEEP:-0}" = "1" ] || rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "=== block-gap recovery test: $NODE ==="
echo "    datadir : $WORKDIR"
echo "    blocks  : $BLOCKS, deleting the body at height $GAP_AT"
echo

# ---------------------------------------------------------------------------
# The three steps below are deliberately written as explicit TODOs rather than
# guessed commands. Each node has its own CLI, datadir layout and block-store
# format, and inventing them would produce a test that fails for the wrong
# reason — the exact failure mode this whole receipt trail is about.
#
# Fill these in per node from build-all.sh / start_testnet4.sh before use.
# ---------------------------------------------------------------------------

echo "STEP 1 — start $NODE on regtest against $WORKDIR, generate $BLOCKS blocks"
echo "  TODO(per-node): launch command + generatetoaddress"
echo

echo "STEP 2 — stop the node cleanly, then delete ONLY the body at height $GAP_AT"
echo "  TODO(per-node): locate the block body in the store and remove it."
echo "  MUST delete the BODY ONLY — the header/index entry has to remain, or"
echo "  the node simply re-syncs the tail and the test proves nothing. The"
echo "  wedge requires: header present, body absent."
echo

echo "STEP 3 — restart, reconnect to a peer holding the full chain, wait ${TIMEOUT}s"
echo "  TODO(per-node): restart + connect to the control node"
echo

echo "PASS  iff getblockchaininfo reports blocks == headers == $BLOCKS"
echo "FAIL  if blocks stalls at $((GAP_AT - 1)) while headers reaches $BLOCKS"
echo "      -> that is exactly the rustoshi 2026-08-04 signature"
echo
echo "Assertion helper (works against any node exposing getblockchaininfo):"
cat <<'ASSERT'
  deadline=$(( $(date +%s) + TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    r=$(curl -s -u "$COOKIE" --data-binary \
        '{"jsonrpc":"1.0","id":1,"method":"getblockchaininfo","params":[]}' \
        -H 'content-type:text/plain' "http://127.0.0.1:$RPCPORT/")
    b=$(grep -oE '"blocks":[0-9]+'  <<<"$r" | cut -d: -f2)
    h=$(grep -oE '"headers":[0-9]+' <<<"$r" | cut -d: -f2)
    echo "  blocks=$b headers=$h"
    [ "${b:-0}" = "${h:-1}" ] && [ "${b:-0}" = "$BLOCKS" ] && { echo "PASS"; exit 0; }
    sleep 5
  done
  echo "FAIL: blocks=$b headers=$h after ${TIMEOUT}s — node did not re-request the gap"
  exit 1
ASSERT

echo
echo "NOT RUN. See the STATUS note at the top of this file."
exit 2
