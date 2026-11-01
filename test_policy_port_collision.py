"""The ouroboros policy harness must not share a regtest port with any other harness.

It used CORE_RPC=21843 (== blockbrew_policy.sh BB_RPC), CORE_P2P=21865 (== blockbrew's
strict-Core P2P and camlcoin's CC_P2P) and CORE_DEF_P2P=21867 (== blockbrew's default-Core
P2P), so any overlap with a blockbrew run aborted policy/getindexinfo as INFRA
("already LISTENING") on 10-12 of 30 nights. Its first replacement block (22140-22166)
clashed with scanblocks, blockfilter, proof, scan and wallet-diff harnesses, which a
policy/ + index/-only scan could not see -- so this scans every harness script.

A port counts as taken by a script when the script (or a lib it sources) assigns it to
a *RPC*/*P2P*/*PORT* variable AND references that variable again (passes it to a
process or lists it in the already-LISTENING preflight). P2P+1 (Core's onion listener)
counts as taken when the script names $((VAR + 1)) or launches bitcoind without
-listen=0.

Run: python3 test-suite/test_policy_port_collision.py
"""
import glob
import os
import re
import unittest

SUITE = os.path.dirname(os.path.abspath(__file__))
MINE = os.path.join(SUITE, "policy", "ouroboros_policy.sh")

VAR = r"[A-Z][A-Z0-9_]*(?:RPC|P2P|PORT)[A-Z0-9_]*"
ASSIGN = re.compile(
    r"^[ \t]*(?:local |export |readonly )?(" + VAR + r")="
    r"(?:\"?\$\{\w+:-(\d+)\}\"?|\$\(\(\s*\$?\{?BASE_PORT\}?\s*\+\s*(\d+)\s*\)\)|\"?(\d+)\"?)"
    r"(?=[\s;#]|$)",
    re.M,
)
BASE = re.compile(r"^[ \t]*(?:export )?BASE_PORT=\"?(?:\$\{BASE_PORT:-(\d+)\}|(\d+))\"?", re.M)
SOURCE = re.compile(r"^[ \t]*(?:source|\.)\s+(.*\.sh)\"?[ \t]*$", re.M)


def _read(path):
    with open(path, errors="replace") as f:
        return f.read()


def _sourced(path, text):
    """Libs a harness sources: same-dir libs, or $HASHHOG_ROOT/test-suite/<rel>."""
    out = []
    for ref in SOURCE.findall(text):
        if "test-suite/" in ref:
            cand = os.path.join(SUITE, ref.split("test-suite/", 1)[1])
        else:
            cand = os.path.join(os.path.dirname(path), ref.rsplit("/", 1)[-1])
        if os.path.isfile(cand):
            out.append(cand)
    return out


def ports(path):
    """Every port the harness at `path` binds or preflights."""
    own = _read(path)
    text = own + "".join(_read(p) for p in _sourced(path, own))
    base = BASE.search(text)
    base = int(base.group(1) or base.group(2)) if base else None
    body = ASSIGN.sub("", text)  # references only, not the assignments themselves
    launches_core = "bitcoind" in text or "CORE_BIN" in text
    no_listen = "-listen=0" in text
    out = set()
    for m in ASSIGN.finditer(text):
        name, dflt, off, lit = m.groups()
        if off is not None:
            if base is None:
                continue
            v = base + int(off)
        else:
            v = int(dflt or lit)
        if not 1024 <= v <= 65535:
            continue
        if not re.search(r"\$\{?" + name + r"\b", body):
            continue
        out.add(v)
        if "P2P" in name:
            plus1 = re.search(r"\$\(\(\s*\$?\{?" + name + r"\}?\s*\+\s*1\s*\)\)", body)
            if plus1 or (launches_core and not no_listen):
                out.add(v + 1)
    return out


def harnesses():
    return sorted(p for p in glob.glob(os.path.join(SUITE, "**", "*.sh"), recursive=True)
                  if "/results/" not in p)


class PortCollision(unittest.TestCase):
    maxDiff = None

    def test_scanner_sees_the_known_shapes(self):
        # A scanner that finds nothing would pass the exclusivity test trivially.
        sb = ports(os.path.join(SUITE, "scanblocks", "haskoin_scanblocks.sh"))
        self.assertIn(22160, sb)        # CORE_P2P, preflighted
        self.assertNotIn(22161, sb)     # Core runs -listen=0, P2P+1 never named
        wd = ports(os.path.join(SUITE, "wallet-diff", "beamchain_walletsign.sh"))
        self.assertTrue({22165, 22166} <= wd)
        sc = ports(os.path.join(SUITE, "scan", "ouroboros_scantxoutset.sh"))
        self.assertTrue({22142, 22143} <= sc)  # CORE_P2P and its P2P+1 preflight
        self.assertGreater(sum(1 for p in harnesses() if ports(p)), 150)

    def test_ouroboros_policy_ports_are_exclusive(self):
        mine = ports(MINE)
        self.assertGreaterEqual(len(mine), 8)  # 6 assigned + 2 Core onion ports
        clashes = {}
        for p in harnesses():
            if p == MINE:
                continue
            hit = mine & ports(p)
            if hit:
                clashes[os.path.relpath(p, SUITE)] = sorted(hit)
        self.assertEqual(clashes, {})

    def test_ouroboros_ports_are_internally_distinct(self):
        text = _read(MINE)
        vals = [int(m.group(4)) for m in ASSIGN.finditer(text) if m.group(4)]
        self.assertEqual(len(vals), 6)
        onion = [v + 1 for m, v in zip(ASSIGN.finditer(text), vals) if m.group(1).endswith("P2P")]
        self.assertEqual(len(vals + onion), len(set(vals + onion)))


if __name__ == "__main__":
    unittest.main()
