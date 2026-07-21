#!/usr/bin/env python3
"""P1.6 resource-exhaustion tests on regtest (PRODUCTION-GATE.md P1.6).

Gate bar (mirrors Bitcoin Core's behavior): under disk-full, fd-exhaustion,
and dbcache-ceiling pressure a node must DEGRADE LOUDLY and NEVER CORRUPT.

Core reference (read 2026-07-20):
  - src/util/fs_helpers.cpp:87   CheckDiskSpace(): free >= 50 MiB + additional
  - src/validation.cpp:2778,2811 FlushStateToDisk(): CheckDiskSpace before the
    block-index write and before the chainstate flush; on failure ->
    FatalError(..., "Disk space is too low!") — i.e. refuse to proceed, flush
    what is consistent, clean shutdown. Never a partial/corrupt state.
  - src/node/blockstorage.cpp:912,958 FindNextBlockPos/FindUndoPos: allocation
    out_of_space -> fatalError("Disk space is too low!").

Pass bar per case (see receipts/P1.6-resource-exhaustion-spec.md):
  disk_full:      loud disk-space error surfaced + node stops cleanly
                  (self-shutdown or SIGTERM honored; SIGKILL-required = FAIL)
                  + restart with space freed reaches a consistent tip and can
                  extend to core's tip (no corruption, no reindex).
  fd_exhaustion:  under low RLIMIT_NOFILE the node either refuses to start
                  with a loud error, or degrades loudly and RECOVERS once fds
                  are released; restart at normal limits -> consistent tip.
  dbcache_ceiling: extreme --dbcache values (floor and 64 GiB) still validate
                  the chain to core's tip with bounded RSS (no eager
                  allocation of the full budget, no OOM).

Harness style follows test_crash_recovery.py: standalone script (not pytest),
Core is the block source, nodes are driven over submitblock, results JSON in
test-suite/results/. Datadirs live under /tmp/hashhog-p16-<pid>/ and are
removed on exit (HASHHOG_KEEP_SCRATCH=1 to retain).

Disk-full mechanism (UNPRIVILEGED — no sudo on maxbox):
  1. HASHHOG_P16_SMALLFS=<dir>  — a Max-provided size-capped mount, used as-is.
  2. userns tmpfs (default)     — `unshare -r -m` + `mount -t tmpfs -o size=64M`
     inside an unprivileged user namespace; probed at runtime (works on
     Debian 13 maxbox, measured 2026-07-20). The node runs inside the
     namespace via tools' wrapper script; the datadir is copied out to a
     shared path before the namespace dies so the restart/corruption phase
     can inspect it.
  3. filler-file fallback       — fallocate a filler in the shared tmpdir to
     leave only a few MiB free. SAFETY-CAPPED at HASHHOG_P16_MAX_FILL_MB
     (default 1024): /tmp on maxbox is a 63G tmpfs, and fallocate on tmpfs
     consumes RAM, so filling 40G free space would eat 40G of RAM on a box
     running the live mainnet fleet. If the cap is insufficient the case
     SKIPs with a reason instead of endangering the host.

Usage:
  python3 test_resource_exhaustion.py                    # both flagships, all cases
  RESX_NODES=rustoshi RESX_CASES=disk_full python3 test_resource_exhaustion.py
"""

import json
import os
import re
import resource
import shutil
import signal
import socket
import subprocess
import sys
import time

import base64
import urllib.error
import urllib.request

from regtest_miner import mine_blocks, rpc_call

HASHHOG = os.environ.get("HASHHOG_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P16_DIR = f"/tmp/hashhog-p16-{os.getpid()}"
RESULTS_DIR = os.path.expanduser("~/hashhog/test-suite/results")
RESULTS_FILE = os.path.join(RESULTS_DIR, "resource-exhaustion.json")

# Port band 22432-22440: distinct from crash-recovery's 21332-21358 so the two
# suites can never collide. Verified unbound on maxbox 2026-07-20.
CORE_RPC = 22432
CORE_P2P = 22433

TOTAL_BLOCKS = 110
BASE_BLOCKS = 100
FD_SEED_BLOCKS = 60

# Tunables (env-overridable)
TMPFS_MB = int(os.environ.get("RESX_TMPFS_MB", "64"))
KEEP_KB = int(os.environ.get("RESX_KEEP_KB", "0"))            # free space left after fill
LOW_NOFILE = int(os.environ.get("RESX_NOFILE", "64"))
RSS_CAP_MB = int(os.environ.get("RESX_RSS_CAP_MB", "2048"))   # peak RSS bound for dbcache cases
MAX_FILL_MB = int(os.environ.get("HASHHOG_P16_MAX_FILL_MB", "1024"))
# SIGTERM grace before the FAIL-marking SIGKILL. 30s matches the fleet's
# stop_mainnet.sh convention (see root CLAUDE.md Ops section).
STOP_GRACE_S = int(os.environ.get("RESX_STOP_GRACE_S", "30"))

# NB: keep this specific — a bare "disk" false-positived on the datadir path
# ("rustoshi-diskfull") during bring-up. Case dirs are named "-dfull" now too.
DISK_ERR_RE = re.compile(r"no space|enospc|space is too low|out of (disk )?space|disk space|disk full"
                         r"|write fail|io error|i/o error|rocksdb.*error|corrupt",
                         re.IGNORECASE)
FD_ERR_RE = re.compile(r"too many open files|emfile|enfile|file descriptor|accept|open.*fail|resource temporarily",
                       re.IGNORECASE)

NODES = {
    "core": {
        "binary": f"{HASHHOG}/bitcoin-core/build/bin/bitcoind",
        "args": lambda d: [
            "-regtest", f"-datadir={d}", f"-rpcport={CORE_RPC}", f"-port={CORE_P2P}",
            "-server=1", "-nolisten", "-rpcuser=test", "-rpcpassword=test",
            "-txindex=1", "-printtoconsole=0",
        ],
        "rpcport": CORE_RPC, "start_delay": 2,
    },
    # Launch args mirror test_crash_recovery.py (P0.5-proven configs), only the
    # RPC ports differ. extra_args lets each case append e.g. --dbcache=N.
    "rustoshi": {
        "binary": f"{HASHHOG}/rustoshi/target/release/rustoshi",
        "args": lambda d: [
            "--network=regtest", f"--datadir={d}",
            "--rpcbind=127.0.0.1:22434", "--rpcuser=test", "--rpcpassword=test",
            "--port=0",
        ],
        "rpcport": 22434, "start_delay": 2,
        "dbcache_flag": lambda mib: [f"--dbcache={mib}"],
        # rustoshi clamps --dbcache to [4, 65536] MiB (rustoshi/src/main.rs:2220)
        "dbcache_floor": 4, "dbcache_ceiling": 65536,
    },
    "clearbit": {
        "binary": f"{HASHHOG}/clearbit/zig-out/bin/clearbit",
        "args": lambda d: [
            "--regtest", f"--datadir={d}",
            "--rpcport=22436", "--rpcuser=test", "--rpcpassword=test",
            "--port=0",
        ],
        "rpcport": 22436, "start_delay": 2,
        "dbcache_flag": lambda mib: [f"--dbcache={mib}"],
        # clearbit parses --dbcache=<MiB>, default 450 (clearbit/src/main.zig:345)
        "dbcache_floor": 4, "dbcache_ceiling": 65536,
    },
}

processes = {}


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _rpc_call_t(url, method, params, timeout):
    """regtest_miner.rpc_call with a configurable timeout (its own is fixed at
    30s, which turned a 10-block fd-pressure loop into a 5-minute hang)."""
    payload = json.dumps({"jsonrpc": "1.0", "id": "p16", "method": method,
                          "params": params or []}).encode()
    req = urllib.request.Request(url, data=payload)
    cred = base64.b64encode(b"test:test").decode()
    req.add_header("Authorization", f"Basic {cred}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            result = json.loads(resp.read())
            if result.get("error"):
                return None, result["error"]
            return result["result"], None
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            return None, json.loads(body).get("error", body)
        except Exception:
            return None, body


def node_rpc(name, method, params=None, timeout=30):
    cfg = NODES[name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    return _rpc_call_t(url, method, params, timeout)


def wait_for_rpc(name, timeout=25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            result, err = node_rpc(name, "getblockchaininfo")
            if result is not None:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def start_node(name, datadir, extra_args=None, preexec=None, log_suffix=""):
    """Start a node directly (no namespace). Returns Popen or None."""
    cfg = NODES[name]
    os.makedirs(datadir, exist_ok=True)
    log_path = f"{P16_DIR}/{name}{log_suffix}.log"
    log_file = open(log_path, "a")
    cmd = [cfg["binary"]] + cfg["args"](datadir) + (extra_args or [])

    def _pre():
        os.setsid()
        if preexec:
            preexec()

    proc = subprocess.Popen(cmd, stdout=log_file, stderr=log_file, preexec_fn=_pre)
    processes[name] = proc
    time.sleep(cfg["start_delay"])
    return proc


def stop_node(name, timeout=STOP_GRACE_S):
    """SIGTERM, escalate to SIGKILL after timeout. Returns 'term'|'kill'|'gone'."""
    proc = processes.pop(name, None)
    if proc is None:
        return "gone"
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        return "gone"
    try:
        proc.wait(timeout=timeout)
        return "term"
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
        return "kill"


def stop_all():
    for name in list(processes.keys()):
        stop_node(name)
    if not os.environ.get("HASHHOG_KEEP_SCRATCH"):
        shutil.rmtree(P16_DIR, ignore_errors=True)


def read_log_tail(path, n=4000):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 65536))
            return f.read().decode("utf-8", "replace")[-n:]
    except OSError:
        return ""


def scan_logs_for(regex, *paths):
    """Return the first matching line across log files (walks dirs too)."""
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _d, fns in os.walk(p):
                files += [os.path.join(root, fn) for fn in fns
                          if fn.endswith(".log") or "log" in fn.lower()]
        elif os.path.isfile(p):
            files.append(p)
    for fp in files:
        try:
            with open(fp, "r", errors="replace") as f:
                for line in f:
                    if regex.search(line):
                        return f"{os.path.basename(fp)}: {line.strip()[:200]}"
        except OSError:
            continue
    return None


def get_block_raw(height):
    h, err = node_rpc("core", "getblockhash", [height])
    if err:
        return None, None
    raw, err = node_rpc("core", "getblock", [h, 0])
    return h, (raw if not err else None)


def submit_blocks(name, start, end, rpc_timeout=30):
    """Submit core's blocks [start,end] to node. Returns (accepted, failed, first_error, last_ok_height)."""
    accepted = failed = 0
    first_error = None
    last_ok = start - 1
    for h in range(start, end + 1):
        _bh, raw = get_block_raw(h)
        if not raw:
            failed += 1
            continue
        try:
            result, err = node_rpc(name, "submitblock", [raw], timeout=rpc_timeout)
        except Exception as e:            # connection-level failure (fd exhaustion etc.)
            result, err = None, f"transport: {e}"
        ok = False
        if err is None and (result is None or result == ""):
            ok = True
        else:
            s = str(err if err is not None else result).lower()
            if any(x in s for x in ("duplicate", "already", "inconsequential")):
                ok = True
        if ok:
            accepted += 1
            last_ok = h
        else:
            failed += 1
            if first_error is None:
                first_error = str(err if err is not None else result)[:300]
    return accepted, failed, first_error, last_ok


def get_height(name):
    r, err = node_rpc(name, "getblockcount")
    return None if err else r


def get_tip(name):
    r, err = node_rpc(name, "getbestblockhash")
    return None if err else r


def peak_rss_mb(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1]) // 1024
    except OSError:
        pass
    return None


def verify_restart_consistency(name, datadir, result, step_prefix, min_height=0):
    """Restart bar shared by all three cases: node boots on `datadir` with normal
    resources, reports a tip that is a REAL prefix of core's chain (tip hash at
    node height == core's hash at that height — catches garbage tips), and can
    extend to core's tip. This is the 'never corrupt' half of the P1.6 gate."""
    proc = start_node(name, datadir, log_suffix=f".{step_prefix}")
    if not wait_for_rpc(name):
        result["steps"][f"{step_prefix}_boot"] = {
            "status": "fail", "error": "node failed to restart",
            "log_tail": read_log_tail(f"{P16_DIR}/{name}.{step_prefix}.log", 1500)}
        stop_node(name)
        return False
    h = get_height(name)
    tip = get_tip(name)
    prefix_ok = False
    if h is not None and tip is not None and min_height <= h <= TOTAL_BLOCKS:
        core_hash_at_h, err = node_rpc("core", "getblockhash", [h])
        prefix_ok = (err is None and core_hash_at_h == tip)
    result["steps"][f"{step_prefix}_boot"] = {
        "status": "pass" if prefix_ok else "fail",
        "height": h, "tip": tip, "prefix_of_core": prefix_ok,
    }
    if not prefix_ok:
        stop_node(name)
        return False
    acc, fail, err, _ = submit_blocks(name, (h or 0) + 1, TOTAL_BLOCKS)
    # allow a short settle in case block connection is async behind submitblock
    final_ok = False
    fh = ft = None
    for _ in range(10):
        fh, ft = get_height(name), get_tip(name)
        final_ok = (ft == get_tip("core"))
        if final_ok:
            break
        time.sleep(1)
    result["steps"][f"{step_prefix}_extend"] = {
        "status": "pass" if (fail == 0 and final_ok) else "fail",
        "accepted": acc, "failed": fail, "first_error": err,
        "final_height": fh, "final_tip": ft, "final_tip_match": final_ok,
    }
    stop_node(name)
    return fail == 0 and final_ok


# ── disk_full ────────────────────────────────────────────────────────────────

WRAPPER_SH = r"""#!/bin/sh
# P1.6 disk-full wrapper. Runs INSIDE `unshare -r -m`.
# $1=mountpoint $2=ctl-dir(shared fs, outside the mount) $3=tmpfs MiB, then -- node cmd...
MNT="$1"; CTL="$2"; MB="$3"; shift 3
[ "$1" = "--" ] && shift
mount -t tmpfs -o size="${MB}M" p16tmpfs "$MNT" || { echo mount-failed >"$CTL/done"; exit 97; }
"$@" >>"$CTL/node.log" 2>&1 &
PID=$!
FILLED=0
STOPPED=0
while :; do
  if [ -e "$CTL/fill-now" ] && [ "$FILLED" = 0 ]; then
    AVAIL_KB=$(df -kP "$MNT" | awk 'NR==2{print $4}')
    FILL_KB=$((AVAIL_KB - ${P16_KEEP_KB:-128}))
    if [ "$FILL_KB" -gt 0 ]; then
      fallocate -l "${FILL_KB}K" "$MNT/__p16_filler" 2>>"$CTL/wrapper.err" || \
        dd if=/dev/zero of="$MNT/__p16_filler" bs=1024 count="$FILL_KB" 2>>"$CTL/wrapper.err"
    fi
    FILLED=1; : >"$CTL/filled"
  fi
  if [ -e "$CTL/stop" ] && [ "$STOPPED" = 0 ]; then
    kill -TERM "$PID" 2>/dev/null; STOPPED=1; T=0
  fi
  if [ "$STOPPED" = 1 ]; then
    T=$((T + 1))
    if [ "$T" -gt "${P16_GRACE_TICKS:-150}" ]; then  # ticks*0.2s grace, then FAIL-marking kill
      kill -KILL "$PID" 2>/dev/null; : >"$CTL/sigkilled"
    fi
  fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.2
done
wait "$PID"; RC=$?
rm -f "$MNT/__p16_filler"
mkdir -p "$CTL/out"
cp -a "$MNT/." "$CTL/out/" 2>>"$CTL/wrapper.err"
echo "$RC" >"$CTL/done"
"""


def _userns_tmpfs_available():
    probe = subprocess.run(
        ["unshare", "-r", "-m", "sh", "-c",
         f"mkdir -p {P16_DIR}/.probe && mount -t tmpfs -o size=1M t {P16_DIR}/.probe && echo OK"],
        capture_output=True, text=True, timeout=15)
    return "OK" in probe.stdout


def test_disk_full(name):
    result = {"test_id": f"{name}_disk_full", "node": name, "case": "disk_full",
              "passed": False, "skipped": False, "steps": {}}
    log(f"\n  --- disk_full: {name} ---")

    case_dir = f"{P16_DIR}/{name}-dfull"
    shutil.rmtree(case_dir, ignore_errors=True)
    mnt = f"{case_dir}/mnt"
    ctl = f"{case_dir}/ctl"
    os.makedirs(mnt)
    os.makedirs(ctl)

    smallfs = os.environ.get("HASHHOG_P16_SMALLFS")
    mechanism = None
    if smallfs:
        mechanism = "smallfs-mount"
    elif _userns_tmpfs_available():
        mechanism = "userns-tmpfs"
    else:
        # filler-in-shared-tmpdir fallback — only safe when the shared fs has
        # little enough free space that the filler stays under the RAM cap
        # (fallocate on tmpfs consumes RAM; maxbox /tmp is a 63G tmpfs).
        st = os.statvfs(case_dir)
        free_mb = st.f_bavail * st.f_frsize // (1024 * 1024)
        if free_mb <= MAX_FILL_MB:
            mechanism = "shared-filler"
        else:
            result["skipped"] = True
            result["skip_reason"] = (
                f"no userns tmpfs, no HASHHOG_P16_SMALLFS, and shared-fs filler "
                f"would need {free_mb} MiB > cap {MAX_FILL_MB} MiB (RAM-backed /tmp; "
                f"needs a Max-provided size-capped mount)")
            log(f"  SKIP: {result['skip_reason']}")
            return result
    result["mechanism"] = mechanism
    log(f"  mechanism: {mechanism}")

    cfg = NODES[name]
    node_log = f"{ctl}/node.log"

    if mechanism == "userns-tmpfs":
        wrapper = f"{case_dir}/wrapper.sh"
        with open(wrapper, "w") as f:
            f.write(WRAPPER_SH)
        os.chmod(wrapper, 0o755)
        env = dict(os.environ, P16_KEEP_KB=str(KEEP_KB),
                   P16_GRACE_TICKS=str(STOP_GRACE_S * 5))
        cmd = (["unshare", "-r", "-m", "sh", wrapper, mnt, ctl, str(TMPFS_MB), "--",
                cfg["binary"]] + cfg["args"](mnt))
        wrap_log = open(f"{ctl}/wrapper.log", "a")
        proc = subprocess.Popen(cmd, stdout=wrap_log, stderr=wrap_log,
                                preexec_fn=os.setsid, env=env)
        processes[name] = proc
        datadir_after = f"{ctl}/out"
    else:
        # smallfs-mount / shared-filler: node runs directly on the dir; the
        # harness itself writes the filler. Same phase logic below.
        datadir = smallfs if mechanism == "smallfs-mount" else mnt
        mnt = datadir
        for entry in os.listdir(datadir) if os.path.isdir(datadir) else []:
            shutil.rmtree(os.path.join(datadir, entry), ignore_errors=True)
        lf = open(node_log, "a")
        proc = subprocess.Popen([cfg["binary"]] + cfg["args"](datadir),
                                stdout=lf, stderr=lf, preexec_fn=os.setsid)
        processes[name] = proc
        datadir_after = datadir

    time.sleep(cfg["start_delay"])
    if not wait_for_rpc(name):
        result["steps"]["start"] = {"status": "fail",
                                    "log_tail": read_log_tail(node_log, 1500)}
        stop_node(name)
        return result
    result["steps"]["start"] = {"status": "pass"}

    acc, fail, err, last_ok = submit_blocks(name, 1, BASE_BLOCKS)
    result["steps"]["base_blocks"] = {"status": "pass" if fail == 0 else "fail",
                                      "accepted": acc, "failed": fail, "first_error": err}
    if fail:
        log(f"    base blocks failed: {err}")

    # Fill the filesystem to ~KEEP_KB free
    log(f"  filling fs (leaving ~{KEEP_KB} KiB free)...")
    if mechanism == "userns-tmpfs":
        open(f"{ctl}/fill-now", "w").close()
        deadline = time.time() + 20
        while time.time() < deadline and not os.path.exists(f"{ctl}/filled"):
            time.sleep(0.2)
        filled = os.path.exists(f"{ctl}/filled")
    else:
        st = os.statvfs(mnt)
        fill_kb = (st.f_bavail * st.f_frsize) // 1024 - KEEP_KB
        filled = False
        if fill_kb > 0:
            rc = subprocess.run(["fallocate", "-l", f"{fill_kb}K", f"{mnt}/__p16_filler"],
                                capture_output=True)
            filled = rc.returncode == 0
    result["steps"]["fill"] = {"status": "pass" if filled else "fail"}
    if not filled:
        stop_node(name)
        return result

    # Drive ingestion into the wall
    acc2, fail2, err2, last_ok2 = submit_blocks(name, BASE_BLOCKS + 1, TOTAL_BLOCKS)
    last_accepted = max(last_ok, last_ok2)
    result["steps"]["pressure_blocks"] = {"accepted": acc2, "failed": fail2,
                                          "first_error": err2, "last_accepted": last_accepted}
    log(f"  under pressure: accepted={acc2} failed={fail2} err={err2}")

    # Loud bar: a disk/space error must surface in the node log or the RPC error
    loud_line = scan_logs_for(DISK_ERR_RE, node_log)
    loud_rpc = bool(err2 and DISK_ERR_RE.search(err2))
    # Core parity: expect the node to abort itself (FatalError). Give it 30s.
    self_exit = False
    deadline = time.time() + 30
    proc = processes.get(name)
    while proc and time.time() < deadline:
        if mechanism == "userns-tmpfs":
            if os.path.exists(f"{ctl}/done"):
                self_exit = True
                break
        elif proc.poll() is not None:
            self_exit = True
            break
        time.sleep(0.5)

    if self_exit:
        stop_mode = "self-shutdown"
        processes.pop(name, None)
    else:
        # Node still up (degraded-but-alive is allowed IF loud); clean-stop it.
        if mechanism == "userns-tmpfs":
            open(f"{ctl}/stop", "w").close()
            deadline = time.time() + STOP_GRACE_S + 15
            while time.time() < deadline and not os.path.exists(f"{ctl}/done"):
                time.sleep(0.5)
            sigkilled = os.path.exists(f"{ctl}/sigkilled")
            stop_mode = "kill" if sigkilled else ("term" if os.path.exists(f"{ctl}/done") else "wedge")
            try:
                processes.pop(name).wait(timeout=10)
            except Exception:
                stop_node(name)
        else:
            stop_mode = stop_node(name)
    # re-scan the log now that shutdown messages are flushed
    loud_line = loud_line or scan_logs_for(DISK_ERR_RE, node_log, datadir_after)
    loud = bool(loud_line or loud_rpc)
    clean_stop = stop_mode in ("self-shutdown", "term")
    result["steps"]["degrade"] = {
        "status": "pass" if (loud and clean_stop) else "fail",
        "loud": loud, "loud_evidence": loud_line or (err2 if loud_rpc else None),
        "stop_mode": stop_mode,
    }
    log(f"  degrade: loud={loud} stop={stop_mode}")

    if mechanism == "shared-filler" or mechanism == "smallfs-mount":
        # free the space in place; restart on the same dir
        try:
            os.unlink(f"{mnt}/__p16_filler")
        except OSError:
            pass
    if mechanism == "smallfs-mount":
        datadir_after = mnt

    # Restart with space available -> consistent tip, extend to core tip
    no_corrupt = verify_restart_consistency(name, datadir_after, result, "recovery")
    result["passed"] = bool(loud and clean_stop and no_corrupt and fail == 0)
    log(f"  disk_full {name}: {'PASS' if result['passed'] else 'FAIL'}")
    shutil.rmtree(case_dir, ignore_errors=True)
    return result


# ── fd_exhaustion ────────────────────────────────────────────────────────────

def test_fd_exhaustion(name):
    result = {"test_id": f"{name}_fd_exhaustion", "node": name, "case": "fd_exhaustion",
              "passed": False, "skipped": False, "steps": {}}
    log(f"\n  --- fd_exhaustion: {name} (RLIMIT_NOFILE={LOW_NOFILE}) ---")
    cfg = NODES[name]
    datadir = f"{P16_DIR}/{name}-fd"
    shutil.rmtree(datadir, ignore_errors=True)
    node_log = f"{P16_DIR}/{name}.fd.log"

    # Seed a healthy chain at normal limits, stop cleanly.
    start_node(name, datadir, log_suffix=".fd")
    if not wait_for_rpc(name):
        result["steps"]["seed_start"] = {"status": "fail",
                                         "log_tail": read_log_tail(node_log, 1500)}
        stop_node(name)
        return result
    acc, fail, err, _ = submit_blocks(name, 1, FD_SEED_BLOCKS)
    result["steps"]["seed"] = {"status": "pass" if fail == 0 else "fail",
                               "accepted": acc, "failed": fail, "first_error": err}
    stop_node(name)
    if fail:
        return result

    # Relaunch under a low fd limit.
    def _lower():
        resource.setrlimit(resource.RLIMIT_NOFILE, (LOW_NOFILE, LOW_NOFILE))

    log_size_before = os.path.getsize(node_log) if os.path.exists(node_log) else 0
    proc = start_node(name, datadir, preexec=_lower, log_suffix=".fd")
    started = wait_for_rpc(name, timeout=20)

    if not started:
        # Refusing to start IS acceptable degradation — but it must be LOUD:
        # nonzero exit + an error trace, not a silent death.
        rc = proc.poll()
        tail = read_log_tail(node_log, 2000)
        new_output = (os.path.getsize(node_log) if os.path.exists(node_log) else 0) > log_size_before
        loud = bool(new_output and rc is not None and rc != 0)
        result["steps"]["low_fd"] = {
            "mode": "refused-start", "exit_code": rc, "loud": loud,
            "log_tail": tail[-800:],
        }
        stop_node(name)
    else:
        # Node came up under the low limit: eat its fds with idle RPC connections,
        # push blocks, then release and require RECOVERY without restart.
        hogs = []
        for _ in range(LOW_NOFILE + 16):
            try:
                s = socket.create_connection(("127.0.0.1", cfg["rpcport"]), timeout=2)
                hogs.append(s)
            except OSError:
                break
        # Short per-call timeout: with every fd hogged the node can't accept()
        # and each RPC hangs in the listen backlog until timeout.
        acc2, fail2, err2, _ = submit_blocks(name, FD_SEED_BLOCKS + 1,
                                             FD_SEED_BLOCKS + 10, rpc_timeout=5)
        crashed = proc.poll() is not None
        for s in hogs:
            try:
                s.close()
            except OSError:
                pass
        time.sleep(2)
        recovered = (not crashed) and wait_for_rpc(name, timeout=15)
        loud_line = scan_logs_for(FD_ERR_RE, node_log)
        # loud = pressure was visible somewhere (log line, RPC/transport errors),
        # OR the node absorbed it entirely (fail2 == 0 with hogs held open).
        loud = bool(loud_line or (fail2 > 0 and err2) or fail2 == 0)
        if crashed:
            tail = read_log_tail(node_log, 2000)
            result["steps"]["low_fd"] = {
                "mode": "crashed-under-pressure", "exit_code": proc.poll(),
                "loud": bool(loud_line), "loud_evidence": loud_line,
                "log_tail": tail[-800:], "hogs": len(hogs),
            }
            processes.pop(name, None)
        else:
            result["steps"]["low_fd"] = {
                "mode": "survived-pressure", "hogs": len(hogs),
                "pressure_accepted": acc2, "pressure_failed": fail2,
                "first_error": (err2 or "")[:300],
                "recovered_after_release": recovered,
                "loud": loud, "loud_evidence": loud_line,
            }
            stop_mode = stop_node(name)
            result["steps"]["low_fd"]["stop_mode"] = stop_mode

    # Never-corrupt bar: restart at normal limits, tip must be a core prefix
    # at >= 0 and extend to core tip. (Seeded 60 blocks; a node that lost or
    # mangled them fails the prefix/extend check.)
    no_corrupt = verify_restart_consistency(name, datadir, result, "recovery")

    lf = result["steps"].get("low_fd", {})
    mode = lf.get("mode")
    if mode == "refused-start":
        degrade_ok = lf.get("loud", False)
    elif mode == "survived-pressure":
        degrade_ok = lf.get("recovered_after_release", False) and \
            lf.get("stop_mode") == "term" and lf.get("loud", False)
    elif mode == "crashed-under-pressure":
        # A crash is only acceptable as a LOUD abort (message + nonzero exit),
        # mirroring Core's FatalError posture. Silent crash = FAIL.
        degrade_ok = lf.get("loud", False) and lf.get("exit_code") not in (None, 0)
    else:
        degrade_ok = False
    result["passed"] = bool(degrade_ok and no_corrupt)
    log(f"  fd_exhaustion {name}: mode={mode} -> {'PASS' if result['passed'] else 'FAIL'}")
    shutil.rmtree(datadir, ignore_errors=True)
    return result


# ── dbcache_ceiling ──────────────────────────────────────────────────────────

def test_dbcache_ceiling(name):
    result = {"test_id": f"{name}_dbcache_ceiling", "node": name, "case": "dbcache_ceiling",
              "passed": False, "skipped": False, "steps": {}}
    cfg = NODES[name]
    if "dbcache_flag" not in cfg:
        result["skipped"] = True
        result["skip_reason"] = f"{name} has no dbcache flag configured in this harness"
        return result
    log(f"\n  --- dbcache_ceiling: {name} ---")

    sub_ok = {}
    for label, mib in (("floor", cfg["dbcache_floor"]), ("ceiling", cfg["dbcache_ceiling"])):
        datadir = f"{P16_DIR}/{name}-dbcache-{label}"
        shutil.rmtree(datadir, ignore_errors=True)
        proc = start_node(name, datadir, extra_args=cfg["dbcache_flag"](mib),
                          log_suffix=f".dbcache-{label}")
        if not wait_for_rpc(name):
            result["steps"][label] = {
                "status": "fail", "dbcache_mib": mib, "error": "failed to start",
                "log_tail": read_log_tail(f"{P16_DIR}/{name}.dbcache-{label}.log", 1200)}
            stop_node(name)
            sub_ok[label] = False
            continue
        acc, fail, err, _ = submit_blocks(name, 1, TOTAL_BLOCKS)
        rss = peak_rss_mb(proc.pid)
        tip_ok = (get_tip(name) == get_tip("core"))
        stop_mode = stop_node(name)
        rss_ok = rss is not None and rss <= RSS_CAP_MB
        ok = fail == 0 and tip_ok and rss_ok and stop_mode == "term"
        result["steps"][label] = {
            "status": "pass" if ok else "fail", "dbcache_mib": mib,
            "accepted": acc, "failed": fail, "first_error": err,
            "tip_match": tip_ok, "peak_rss_mb": rss, "rss_cap_mb": RSS_CAP_MB,
            "stop_mode": stop_mode,
        }
        log(f"  dbcache={mib}MiB: tip_match={tip_ok} peak_rss={rss}MB fail={fail} stop={stop_mode}")
        # never-corrupt: the floor-cache datadir must reboot to the same tip
        if ok and label == "floor":
            ok = verify_restart_consistency(name, datadir, result,
                                            f"recovery_{label}", min_height=0)
        sub_ok[label] = ok
        shutil.rmtree(datadir, ignore_errors=True)

    result["passed"] = all(sub_ok.values()) and len(sub_ok) == 2
    log(f"  dbcache_ceiling {name}: {'PASS' if result['passed'] else 'FAIL'}")
    return result


CASES = {
    "disk_full": test_disk_full,
    "fd_exhaustion": test_fd_exhaustion,
    "dbcache_ceiling": test_dbcache_ceiling,
}


def main():
    log("=" * 60)
    log("P1.6 Resource-Exhaustion Tests (regtest)")
    log("=" * 60)
    os.makedirs(P16_DIR, exist_ok=True)
    os.makedirs(RESULTS_DIR, exist_ok=True)

    report = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "test": "resource-exhaustion",
        "gate": "PRODUCTION-GATE.md P1.6",
        "tunables": {"tmpfs_mb": TMPFS_MB, "keep_kb": KEEP_KB, "low_nofile": LOW_NOFILE,
                     "rss_cap_mb": RSS_CAP_MB},
        "nodes_tested": [], "test_results": [], "summary": {},
    }

    wanted_nodes = [n.strip() for n in
                    os.environ.get("RESX_NODES", "rustoshi,clearbit").split(",") if n.strip()]
    wanted_cases = [c.strip() for c in
                    os.environ.get("RESX_CASES", "disk_full,fd_exhaustion,dbcache_ceiling").split(",")
                    if c.strip()]

    test_nodes = []
    for n in wanted_nodes:
        if n not in NODES:
            log(f"  {n}: not configured, skipping")
        elif not os.path.isfile(NODES[n]["binary"]):
            log(f"  {n}: binary not found, skipping")
        else:
            test_nodes.append(n)
    if not test_nodes:
        log("No test node binaries found, exiting")
        report["summary"] = {"error": "no test node binaries available"}
        with open(RESULTS_FILE, "w") as f:
            json.dump(report, f, indent=2)
        return 1
    report["nodes_tested"] = test_nodes

    log("\n--- Starting Bitcoin Core ---")
    os.makedirs(f"{P16_DIR}/core", exist_ok=True)
    start_node("core", f"{P16_DIR}/core")
    if not wait_for_rpc("core"):
        log("FATAL: Cannot start Bitcoin Core")
        report["summary"] = {"error": "core failed to start"}
        with open(RESULTS_FILE, "w") as f:
            json.dump(report, f, indent=2)
        stop_all()
        return 1

    log(f"--- Mining {TOTAL_BLOCKS} blocks on Core ---")
    mine_blocks(f"http://127.0.0.1:{CORE_RPC}", "test", "test", TOTAL_BLOCKS)
    core_height = get_height("core")
    report["core_height"] = core_height
    if core_height is None or core_height < TOTAL_BLOCKS:
        log("FATAL: failed to mine enough blocks")
        stop_all()
        return 1

    for n in test_nodes:
        for c in wanted_cases:
            if c not in CASES:
                log(f"  unknown case {c}, skipping")
                continue
            try:
                r = CASES[c](n)
            except Exception as e:
                import traceback
                traceback.print_exc()
                r = {"test_id": f"{n}_{c}", "node": n, "case": c,
                     "passed": False, "skipped": False, "error": str(e), "steps": {}}
                stop_node(n)
            report["test_results"].append(r)

    stop_all()

    ran = [r for r in report["test_results"] if not r.get("skipped")]
    passed = sum(1 for r in ran if r["passed"])
    skipped = [r for r in report["test_results"] if r.get("skipped")]
    report["summary"] = {
        "total": len(report["test_results"]), "ran": len(ran),
        "passed": passed, "failed": len(ran) - passed,
        "skipped": [{"test_id": r["test_id"], "reason": r.get("skip_reason")} for r in skipped],
    }
    log(f"\n{'=' * 60}")
    log(f"RESULTS: {passed}/{len(ran)} passed" +
        (f", {len(skipped)} skipped" if skipped else ""))
    for r in report["test_results"]:
        state = "SKIP" if r.get("skipped") else ("PASS" if r["passed"] else "FAIL")
        log(f"  {r['test_id']}: {state}")
    log("=" * 60)

    with open(RESULTS_FILE, "w") as f:
        json.dump(report, f, indent=2)
    log(f"Results written to {RESULTS_FILE}")
    return 0 if (passed == len(ran) and ran) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Interrupted")
        stop_all()
        sys.exit(1)
    except Exception as e:
        log(f"Fatal error: {e}")
        import traceback
        traceback.print_exc()
        stop_all()
        sys.exit(1)
