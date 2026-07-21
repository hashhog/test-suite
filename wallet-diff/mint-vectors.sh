#!/usr/bin/env bash
# mint-vectors.sh — DELIBERATE re-mint of the frozen walletdiff address corpus.
#
# vectors-address.json is minted ONCE from the live local Core oracle and then
# FROZEN (design §8 phase 0): later harness runs check the oracle against the
# frozen file first, so drift in EITHER the SUT or the local Core build is
# detected (a Core-side mismatch is BLOCKED infra, not DIVERGED). Only re-run
# this script after auditing a Core rebuild — never as a "fix" for a red run.
#
# Derivation: tprv = BIP32 master over the canonical 64-byte suite seed
# (test-suite/recovery/rustoshi_recovery.sh:52) with tprv version bytes; the 8
# descriptors are pkh/sh(wpkh)/wpkh/tr x external(0/*)+internal(1/*) at the
# BIP-44/49/84/86 coin-1 account-0 paths, h-form hardened markers throughout
# (checksums differ between the h and ' forms — never mix). Checksums +
# expected addresses come from Core getdescriptorinfo/deriveaddresses.
#
# Scratch-only (/tmp), reserved port 22158/22159. Refuses if the port is bound.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$DIR/../.." && pwd)}"
CORE_BIN="$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoin-cli"
RPC=22158; P2P=22159
DD="$(mktemp -d /tmp/walletdiff-mint.XXXXXX)"
OUT="$DIR/vectors-address.json"

if ss -tln 2>/dev/null | grep -qE ":(${RPC}|${P2P}) "; then
    echo "port ${RPC}/${P2P} already LISTENING — refusing (never kill a holder)" >&2
    exit 1
fi
cleanup() {
    "$CORE_CLI" -regtest -datadir="$DD" -rpcport="$RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$DD" -rpcport="$RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    rm -rf "$DD"
}
trap cleanup EXIT INT TERM

"$CORE_BIN" -regtest -datadir="$DD" -rpcport="$RPC" -port="$P2P" -listen=0 \
    >"$DD/core.log" 2>&1 &
for _ in $(seq 1 60); do
    "$CORE_CLI" -regtest -datadir="$DD" -rpcport="$RPC" getblockcount >/dev/null 2>&1 && break
    sleep 1
done
"$CORE_CLI" -regtest -datadir="$DD" -rpcport="$RPC" getblockcount >/dev/null \
    || { echo "Core oracle failed to start (see $DD/core.log)" >&2; exit 1; }

python3 - "$CORE_CLI" "$DD" "$RPC" > "$OUT.tmp" <<'EOF'
import hashlib, hmac, json, subprocess, sys, time

SEED = ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")

# BIP32 master tprv over the canonical suite seed (testnet/regtest version bytes).
I = hmac.new(b"Bitcoin seed", bytes.fromhex(SEED), hashlib.sha512).digest()
raw = bytes.fromhex("04358394") + b"\x00" * 9 + I[32:] + b"\x00" + I[:32]
raw += hashlib.sha256(hashlib.sha256(raw).digest()).digest()[:4]
ALPHA = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n, s = int.from_bytes(raw, "big"), ""
while n:
    n, r = divmod(n, 58)
    s = ALPHA[r] + s
TPRV = s

CLI = [sys.argv[1], "-regtest", f"-datadir={sys.argv[2]}", f"-rpcport={sys.argv[3]}"]
def cli(*a):
    return json.loads(subprocess.run(CLI + list(a), capture_output=True, text=True, check=True).stdout)

specs = [
    ("pkh-ext",     f"pkh({TPRV}/44h/1h/0h/0/*)",      [0, 19]),
    ("pkh-int",     f"pkh({TPRV}/44h/1h/0h/1/*)",      [0, 4]),
    ("sh-wpkh-ext", f"sh(wpkh({TPRV}/49h/1h/0h/0/*))", [0, 19]),
    ("sh-wpkh-int", f"sh(wpkh({TPRV}/49h/1h/0h/1/*))", [0, 4]),
    ("wpkh-ext",    f"wpkh({TPRV}/84h/1h/0h/0/*)",     [0, 19]),
    ("wpkh-int",    f"wpkh({TPRV}/84h/1h/0h/1/*)",     [0, 4]),
    ("tr-ext",      f"tr({TPRV}/86h/1h/0h/0/*)",       [0, 19]),
    ("tr-int",      f"tr({TPRV}/86h/1h/0h/1/*)",       [0, 4]),
]
out = {
    "_comment": [
        "walletdiff-address FROZEN corpus (design: CORE-PARITY-AUDIT/_wallet-diff-harness-design-2026-07-20.md sec 5+6, probe A1/A2).",
        "Minted ONCE from the local Core oracle (bitcoin-core/build/bin, v-see-git), then frozen so later runs",
        "detect drift in EITHER the SUT or the local Core build. Re-mint ONLY deliberately via mint-vectors.sh after a Core rebuild.",
        "tprv = BIP32 master over the canonical 64-byte suite seed (test-suite/recovery/rustoshi_recovery.sh:52), tprv version bytes.",
        "Descriptor paths use the h hardened marker EVERYWHERE (checksums differ between h and ' forms - never mix).",
        "range is Core deriveaddresses [begin,end] INCLUSIVE notation; addresses has end-begin+1 entries."
    ],
    "suite": "walletdiff-address",
    "minted": time.strftime("%Y-%m-%d", time.gmtime()),
    "seed": SEED,
    "tprv": TPRV,
    "network": "regtest",
    "descriptors": [],
}
for name, desc, rng in specs:
    info = cli("getdescriptorinfo", desc)
    full = desc + "#" + info["checksum"]
    addrs = cli("deriveaddresses", full, json.dumps(rng))
    assert len(addrs) == rng[1] - rng[0] + 1, f"{name}: Core returned {len(addrs)} for inclusive {rng}"
    out["descriptors"].append(
        {"name": name, "descriptor": full, "checksum": info["checksum"], "range": rng, "addresses": addrs}
    )
print(json.dumps(out, indent=1))
EOF
mv "$OUT.tmp" "$OUT"
echo "minted $(python3 -c "import json;d=json.load(open('$OUT'));print(len(d['descriptors']),'descriptors,',sum(len(x['addresses']) for x in d['descriptors']),'addresses')") -> $OUT"
