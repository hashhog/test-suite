"""The ouroboros policy lane may only kill PIDs it recorded itself.

Its reset step ran `pkill -f "policyfleet-ouroboros"`, a pattern match over every
process on the box. The 2026-06-10 rule bans pkill/killall/fuser/pgrep in harness
scripts (pattern- and port-kills reached mainnet nodes). The lane now records each
process it launches, with that process's scratch datadir, in a pidfile, and the
reset stops only a recorded PID whose /proc cmdline still names that datadir.

Run: python3 test-suite/test_policy_lane_kill_scope.py
"""
import os
import re
import subprocess
import tempfile
import time
import unittest

SUITE = os.path.dirname(os.path.abspath(__file__))
MINE = os.path.join(SUITE, "policy", "ouroboros_policy.sh")
BANNED = re.compile(r"\b(pkill|killall|fuser|pgrep)\b")


def _code_lines(text):
    """Script lines with comments and quoted strings removed."""
    out = []
    for line in text.splitlines():
        line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
        line = re.sub(r"'[^']*'", "''", line)
        out.append(line.split("#", 1)[0])
    return out


def _function(text, name):
    m = re.search(r"^" + name + r"\(\) \{\n.*?^\}\n", text, re.M | re.S)
    return m.group(0) if m else None


class LaneKillScope(unittest.TestCase):
    def test_no_pattern_or_port_kills(self):
        hits = [(i + 1, l.strip()) for i, l in enumerate(_code_lines(open(MINE).read()))
                if BANNED.search(l)]
        self.assertEqual(hits, [])

    def test_detector_sees_a_pkill(self):
        # Negative control: the scan above must be able to fail.
        self.assertTrue(any(BANNED.search(l) for l in _code_lines('pkill -f "x" || true  # y')))
        self.assertFalse(any(BANNED.search(l) for l in _code_lines('fail "no fuser here"  # pkill')))

    def test_reset_stops_only_recorded_pids_that_still_name_their_datadir(self):
        fn = _function(open(MINE).read(), "stop_recorded_lane")
        self.assertIsNotNone(fn, "ouroboros_policy.sh defines no stop_recorded_lane()")
        with tempfile.TemporaryDirectory(prefix="lane-kill-scope-") as d:
            mine_dir = os.path.join(d, "policyfleet-ouroboros")
            other_dir = os.path.join(d, "policyfleet-blockbrew")
            # The datadir rides in argv so it shows up in /proc/<pid>/cmdline.
            def spawn(tag):
                return subprocess.Popen(["python3", "-c", "import time; time.sleep(60)", tag],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            recorded = spawn(mine_dir)          # recorded + names its datadir -> stopped
            unrecorded = spawn(mine_dir)        # names the datadir but not recorded -> kept
            reused = spawn(other_dir)           # recorded pid, cmdline names another lane -> kept
            procs = [recorded, unrecorded, reused]
            try:
                pidfile = os.path.join(d, "lane.pids")
                with open(pidfile, "w") as f:
                    f.write(f"{recorded.pid} {mine_dir}\n")
                    f.write(f"{reused.pid} {mine_dir}\n")
                    f.write("garbage line\n")
                r = subprocess.run(["bash", "-c", fn + '\nstop_recorded_lane "$1"', "_", pidfile],
                                   capture_output=True, text=True, timeout=60)
                self.assertEqual(r.returncode, 0, r.stderr)
                deadline = time.time() + 10
                while recorded.poll() is None and time.time() < deadline:
                    time.sleep(0.1)
                self.assertIsNotNone(recorded.poll(), "recorded lane pid was not stopped")
                self.assertIsNone(unrecorded.poll(), "an unrecorded process was killed")
                self.assertIsNone(reused.poll(), "a recorded pid now naming another datadir was killed")
                self.assertFalse(os.path.exists(pidfile), "pidfile left behind after reset")
            finally:
                for p in procs:
                    if p.poll() is None:
                        p.kill()
                    p.wait()


if __name__ == "__main__":
    unittest.main()
