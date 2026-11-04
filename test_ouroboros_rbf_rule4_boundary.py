#!/usr/bin/env python3
"""Boundary-verdict logic of rbf/ouroboros_rbf.sh (item nd-ouroboros-rbf-rule4-boundary).

2026-11-04 nightly: Core's own control rejected the exact-boundary replacement
(core=false, 'replacement-failed') while ouroboros accepted it, and the harness
reported "ouroboros over-rejected ... ouroboros='(accepted)'" -- a FAIL blamed
on the node under test for a broken oracle control.  Contract pinned here:

  core accepts, ouro accepts -> ok
  core accepts, ouro rejects -> FAIL  (a real over-rejection, names ouroboros' reason)
  core rejects (any ouro)    -> INCONCLUSIVE (control broken; never a node FAIL)
"""
import subprocess
import unittest
from pathlib import Path

LIB = Path(__file__).parent / "rbf" / "lib_rule4_boundary.sh"


def verdict(core_ok, core_reason, ou_ok, ou_reason):
    p = subprocess.run(
        ["bash", "-c", 'source "$1"; rule4ok_verdict "$2" "$3" "$4" "$5"', "_",
         str(LIB), core_ok, core_reason, ou_ok, ou_reason],
        capture_output=True, text=True)
    return p.returncode, p.stdout.strip()


class Rule4Boundary(unittest.TestCase):
    def test_both_accept_is_ok(self):
        self.assertEqual(verdict("true", "(accepted)", "true", "(accepted)"), (0, "ok"))

    def test_ouroboros_rejects_when_core_accepts_is_fail(self):
        rc, out = verdict("true", "(accepted)", "false", "insufficient fee")
        self.assertEqual(rc, 1)
        self.assertTrue(out.startswith("FAIL"), out)
        self.assertIn("insufficient fee", out)

    def test_core_control_rejects_while_ouroboros_accepts_is_inconclusive(self):
        rc, out = verdict("false", "replacement-failed", "true", "(accepted)")
        self.assertEqual(rc, 2)
        self.assertTrue(out.startswith("INCONCLUSIVE"), out)
        self.assertNotIn("over-rejected", out)  # the contradictory 2026-11-04 wording
        self.assertIn("replacement-failed", out)

    def test_core_control_rejects_and_ouroboros_rejects_is_inconclusive(self):
        rc, _ = verdict("false", "replacement-failed", "false", "insufficient fee")
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
