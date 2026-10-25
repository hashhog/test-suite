"""The ouroboros policy harness must not share a regtest port with any other harness.

It used CORE_RPC=21843 (== blockbrew_policy.sh BB_RPC), CORE_P2P=21865 (== blockbrew's
strict-Core P2P and camlcoin's CC_P2P) and CORE_DEF_P2P=21867 (== blockbrew's default-Core
P2P), so any overlap with a blockbrew run aborted policy/getindexinfo as INFRA
("already LISTENING") on 10-12 of 30 nights.

Run: python3 test-suite/test_policy_port_collision.py
"""
import glob
import os
import re
import unittest

SUITE = os.path.dirname(os.path.abspath(__file__))
ASSIGN = re.compile(r"^([A-Z_]*(?:RPC|P2P))=(\d+)", re.M)


def ports(path):
    """Every port a harness binds. Core auto-binds P2P+1 (onion listener)."""
    out = set()
    for name, val in ASSIGN.findall(open(path).read()):
        v = int(val)
        out.add(v)
        if name.endswith("P2P"):
            out.add(v + 1)
    return out


class PortCollision(unittest.TestCase):
    def test_ouroboros_policy_ports_are_exclusive(self):
        mine_path = os.path.join(SUITE, "policy", "ouroboros_policy.sh")
        mine = ports(mine_path)
        self.assertGreaterEqual(len(mine), 6)
        others = [p for p in glob.glob(os.path.join(SUITE, "policy", "*.sh")) + glob.glob(os.path.join(SUITE, "index", "*.sh"))
                  if p != mine_path]
        self.assertGreater(len(others), 10)
        clashes = {os.path.basename(p): sorted(mine & ports(p)) for p in others if mine & ports(p)}
        self.assertEqual(clashes, {})

    def test_ouroboros_ports_are_internally_distinct(self):
        text = open(os.path.join(SUITE, "policy", "ouroboros_policy.sh")).read()
        vals = [int(v) for _, v in ASSIGN.findall(text)]
        self.assertEqual(len(vals), len(set(vals)))


if __name__ == "__main__":
    unittest.main()
