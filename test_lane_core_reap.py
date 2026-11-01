"""A lane's cleanup must wait for its Core oracle to exit, not just signal it.

policy/, chaintxstats/ and index/ scripts start a bitcoind oracle (CORE_BG, CORE_DEF_BG)
and tear it down in cleanup(). The teardown used to `stop` over RPC, wait until RPC went
quiet, then `kill "$CORE_BG"` and return. RPC goes quiet while bitcoind is still shutting
down, and its P2P listener (e.g. 21913) stays bound for about a second after that. The next
lane in run-*-regression.sh -- always blockbrew after ouroboros, both use 21893/21913 --
hit its already-LISTENING preflight, burned its one retry window and was reported INFRA
("a blockbrew from an earlier lane is still bound": it was the previous lane's Core).

The fix reaps by PID only (never by port or name: 2026-06-10 fuser incident): signal the
recorded pid, poll until it is gone, SIGKILL only that pid if it is still there.

Run: python3 -m unittest test_lane_core_reap   (from test-suite/)
"""
import glob
import os
import re
import subprocess
import tempfile
import time
import unittest

SUITE = os.path.dirname(os.path.abspath(__file__))
LANES = sorted(
    glob.glob(os.path.join(SUITE, "policy", "*_policy.sh"))
    + glob.glob(os.path.join(SUITE, "chaintxstats", "*_chaintxstats.sh"))
    + glob.glob(os.path.join(SUITE, "index", "*_getindexinfo.sh"))
)
# the teardown line(s) for the Core oracle pid(s) in cleanup()
TEARDOWN = re.compile(r'^[ \t]*\[\[ -n "\$CORE(?:_DEF)?_BG" \]\] && .*$', re.M)


class LaneCoreReap(unittest.TestCase):
    def test_lane_scripts_found(self):
        # 3 lanes x 10 impls; guards against the glob silently matching nothing
        self.assertEqual(len(LANES), 30)

    def test_every_lane_waits_for_core_pid(self):
        # policy/camlcoin, policy/hotbuns, chaintxstats/{hotbuns,nimrod} and
        # index/camlcoin already poll their own pid ("kill -0" loop) or have no Core oracle;
        # the other 25 use the CORE_BG teardown line and are checked here.
        checked = 0
        for path in LANES:
            with open(path, errors="replace") as f:
                lines = [m.group(0) for m in TEARDOWN.finditer(f.read())]
            if not lines:
                continue
            checked += 1
            with self.subTest(lane=os.path.relpath(path, SUITE)):
                for line in lines:
                    self.assertIn("kill -0", line, "signals the Core pid but never waits for it to exit")
                    self.assertNotRegex(line, r"fuser|pkill|killall", "must reap by pid only")
        self.assertEqual(checked, 25)

    def test_no_name_based_kills(self):
        """Kill only the PID the lane recorded: no pkill/killall/fuser -k/pgrep (2026-06-10 rule).

        A name or datadir pattern also matches processes the lane never started -- another lane's
        Core oracle, the shell running the pattern, a production node -- so the reset path must rely
        on the previous run's PID-scoped cleanup() plus the wait-and-refuse port check instead.
        Comments and the refusal message ("refusing to kill it ... fuser incident") are allowed.
        """
        bad = re.compile(r"\b(pkill|killall|pgrep)\b|\bfuser\s+-k")
        checked = 0
        for path in LANES:
            with open(path, errors="replace") as f:
                text = f.read()
            if not TEARDOWN.search(text):
                continue
            checked += 1
            hits = [
                f"{n}: {line.strip()}"
                for n, line in enumerate(text.splitlines(), 1)
                if bad.search(line)
                and not line.lstrip().startswith("#")
                and "refusing to kill" not in line
            ]
            with self.subTest(lane=os.path.relpath(path, SUITE)):
                self.assertEqual(hits, [], "name-based kill in a lane script")
        self.assertEqual(checked, 25)

    def test_teardown_blocks_until_core_exits(self):
        """Run the real teardown line from blockbrew_chaintxstats.sh against a slow-dying process."""
        path = os.path.join(SUITE, "chaintxstats", "blockbrew_chaintxstats.sh")
        with open(path, errors="replace") as f:
            line = TEARDOWN.search(f.read()).group(0)
        with tempfile.TemporaryDirectory() as td:
            script = os.path.join(td, "t.sh")
            with open(script, "w") as f:
                # stand-in bitcoind: takes 2s to exit after SIGTERM, like a real shutdown
                f.write(
                    "bash -c 'trap \"sleep 2; exit 0\" TERM; while :; do sleep 0.1; done' &\n"
                    "CORE_BG=$!\nCORE_DEF_BG=\nsleep 0.5\n"
                    + line.strip() + "\n"
                    'if kill -0 "$CORE_BG" 2>/dev/null; then echo ALIVE; else echo GONE; fi\n'
                )
            t0 = time.time()
            out = subprocess.run(["bash", script], capture_output=True, text=True, timeout=60).stdout.strip()
            self.assertEqual(out, "GONE", "Core pid still alive when cleanup returned")
            self.assertGreaterEqual(time.time() - t0, 1.5)


    def test_beamchain_index_cleanup_reaps_launcher_children(self):
        """index/beamchain used to name-kill "giifleet-beamchain" stragglers; it now reaps the
        descendants of the recorded BC_PID. Run the real block against a launcher whose child
        outlives it on SIGTERM."""
        path = os.path.join(SUITE, "index", "beamchain_getindexinfo.sh")
        with open(path, errors="replace") as f:
            text = f.read()
        block = re.search(r'^    if \[\[ -n "\$BC_PID" \]\] && kill -0.*?^    fi$', text, re.M | re.S).group(0)
        with tempfile.TemporaryDirectory() as td:
            script = os.path.join(td, "t.sh")
            kidfile = os.path.join(td, "kid")
            with open(script, "w") as f:
                f.write(
                    # launcher: a shell (not exec) whose child ignores nothing but is not a group
                    # member we signal -- killing only the launcher would orphan it
                    f"bash -c 'sleep 300 & echo $! > {kidfile}; trap \"exit 0\" TERM; wait' &\n"
                    "BC_PID=$!\nsleep 0.5\n"
                    "reap() {\n" + block + "\n}\nreap\n"
                    f'KID=$(cat {kidfile}); sleep 0.2\n'
                    'kill -0 "$BC_PID" 2>/dev/null && echo LAUNCHER_ALIVE\n'
                    'kill -0 "$KID" 2>/dev/null && { echo CHILD_ALIVE; kill -9 "$KID"; }\n'
                    "echo DONE\n"
                )
            out = subprocess.run(["bash", script], capture_output=True, text=True, timeout=60).stdout.split()
            self.assertEqual(out, ["DONE"])


if __name__ == "__main__":
    unittest.main()
