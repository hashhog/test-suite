#!/usr/bin/env python3
"""
ibd_benchmark.py — cold-start IBD regression harness (W68b).

Spins up ONE node on an isolated datadir, connects it to a warm
bootstrap peer on localhost, and measures wall time to reach a target
block height. Emits a JSON result suitable for CI gating or
wave-over-wave perf comparison.

Safety model:
- `--datadir` MUST be under /tmp/** or ~/bench-*/.
  The harness refuses to touch `/data/nvme1/hashhog-mainnet/` (live
  fleet data) or `<repo>/testnet4-data/`. No exceptions
  and no overrides — a typo here would wipe production datadirs.
- On exit (success, timeout, or Ctrl-C), the harness SIGTERMs the
  benched node, waits 30 s, then SIGKILLs if needed. Datadir is
  preserved for post-mortem unless `--cleanup` is passed.
- Bench ports (28xxx range) are hardcoded away from the mainnet
  fleet's 8xxx + 48xxx ports to prevent any chance of collision
  with a running production node.

v1 scope (W68b): clearbit only. Adding blockbrew / lunarblock is a
matter of filling in the `LAUNCHERS` dict; the orchestration loop is
node-agnostic. Other launchers raise NotImplementedError with a
pointer to this comment.

Usage:
    # Smoke: clearbit 0 -> 100 blocks, 5 min budget.
    python3 ibd_benchmark.py --node clearbit --target-height 100 \
        --datadir /tmp/bench-$$/clearbit \
        --timeout 300 \
        --result-json /tmp/bench.json

    # Real regression run: clearbit 0 -> 100,000 blocks, 4 h budget.
    python3 ibd_benchmark.py --node clearbit --target-height 100000 \
        --datadir /tmp/bench-$(date +%s)/clearbit \
        --timeout 14400 \
        --bootstrap-peer 127.0.0.1:8456 \
        --result-json wave68-2026-04-18/W68-CLEARBIT-IBD-100K.json

stdlib only (Python 3.9+).
"""
from __future__ import annotations
MAINNET_ROOT = os.environ.get("HASHHOG_MAINNET_ROOT", "/data/nvme1/hashhog-mainnet")

import argparse
import base64
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

REPO_ROOT = Path(os.environ.get("HASHHOG_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

ALLOWED_DATADIR_PREFIXES = ("/tmp/", os.path.expanduser("~/bench-"))
FORBIDDEN_DATADIR_PREFIXES = (
    "/data/nvme1/hashhog-mainnet",
    os.path.join(str(REPO_ROOT), "testnet4-data"),
    os.path.join(str(REPO_ROOT), "bitcoin-core"),
    os.path.expanduser("~/.bitcoin"),
)

BENCH_RPC_PORT = {
    "clearbit": 28356,
    "blockbrew": 28355,
    "lunarblock": 28358,
}
BENCH_P2P_PORT = {
    "clearbit": 28456,
    "blockbrew": 28455,
    "lunarblock": 28458,
}

DEFAULT_BOOTSTRAP_PEER = "127.0.0.1:8333"  # Bitcoin Core — gold-standard peer


@dataclass
class BenchResult:
    node: str
    target_height: int
    reached_height: Optional[int]
    wall_seconds: float
    blocks_per_hour: Optional[float]
    exit: str  # "success" | "timeout" | "crash" | "interrupted"
    start_iso: str
    end_iso: str
    datadir: str
    rpc_port: int
    p2p_port: int
    bootstrap_peer: str
    samples: list = field(default_factory=list)  # [{"t": 0.0, "tip": 0}, ...]

    def to_dict(self) -> dict:
        return asdict(self)


def _safety_check_datadir(datadir: Path) -> None:
    resolved = str(datadir.resolve())
    for forbid in FORBIDDEN_DATADIR_PREFIXES:
        if resolved.startswith(forbid):
            raise SystemExit(
                f"ERROR: datadir {resolved!r} is under forbidden prefix "
                f"{forbid!r}. The harness refuses to touch live node data."
            )
    if not any(resolved.startswith(p) for p in ALLOWED_DATADIR_PREFIXES):
        raise SystemExit(
            f"ERROR: datadir {resolved!r} is not under an allowed prefix. "
            f"Must start with one of {ALLOWED_DATADIR_PREFIXES}. This is an "
            f"explicit allowlist to prevent accidental production-path typos."
        )


def _safety_check_ports(rpc_port: int, p2p_port: int) -> None:
    """Reject ports that collide with known mainnet / testnet4 fleet ranges."""
    for port in (rpc_port, p2p_port):
        if 8300 <= port <= 8499 or 48000 <= port <= 48999:
            raise SystemExit(
                f"ERROR: port {port} overlaps mainnet/testnet4 fleet ranges. "
                f"Bench ports must be outside 8300-8499 and 48000-48999."
            )


def _build_clearbit_cmd(datadir: Path, rpc_port: int, p2p_port: int,
                       bootstrap_peer: str) -> list[str]:
    binary = REPO_ROOT / "clearbit" / "zig-out" / "bin" / "clearbit"
    if not binary.exists():
        raise SystemExit(
            f"ERROR: clearbit binary missing at {binary}. "
            f"Run `cd clearbit && zig build -Doptimize=ReleaseFast` first."
        )
    return [
        str(binary),
        f"--datadir={datadir}",
        f"--port={p2p_port}",
        f"--rpcport={rpc_port}",
        f"--connect={bootstrap_peer}",
        "--nodnsseed",
        "--dbcache=1024",
    ]


LAUNCHERS = {
    "clearbit": _build_clearbit_cmd,
}


def _cookie_auth(cookie_path: Path, timeout: float = 0.5) -> Optional[str]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            raw = cookie_path.read_text().strip()
        except OSError:
            time.sleep(0.1)
            continue
        if raw:
            encoded = base64.b64encode(raw.encode()).decode()
            return f"Basic {encoded}"
        time.sleep(0.1)
    return None


def _rpc_getblockcount(rpc_port: int, auth: str, timeout: float) -> Optional[int]:
    body = json.dumps({
        "jsonrpc": "1.0",
        "id": "ibd-benchmark",
        "method": "getblockcount",
        "params": [],
    }).encode()
    headers = {"Content-Type": "application/json", "Authorization": auth}
    req = urllib.request.Request(
        f"http://127.0.0.1:{rpc_port}/", data=body, headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode())
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError):
        return None
    result = payload.get("result")
    return result if isinstance(result, int) else None


def _wait_for_rpc(rpc_port: int, cookie_path: Path, proc: subprocess.Popen,
                  deadline_ts: float) -> Optional[str]:
    """Block until the node's RPC answers or the deadline passes. Returns the
    auth header string on success, None if the node died first."""
    while time.time() < deadline_ts:
        if proc.poll() is not None:
            return None
        if cookie_path.exists():
            auth = _cookie_auth(cookie_path, timeout=1.0)
            if auth is not None:
                tip = _rpc_getblockcount(rpc_port, auth, timeout=1.0)
                if tip is not None:
                    return auth
        time.sleep(0.5)
    return None


def _shutdown(proc: subprocess.Popen, grace_seconds: int = 30) -> None:
    if proc.poll() is not None:
        return
    try:
        proc.terminate()
    except OSError:
        return
    for _ in range(grace_seconds):
        if proc.poll() is not None:
            return
        time.sleep(1)
    try:
        proc.kill()
    except OSError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def run_benchmark(node: str, target_height: int, datadir: Path,
                  rpc_port: int, p2p_port: int, bootstrap_peer: str,
                  timeout_seconds: int, poll_interval: float,
                  log_path: Path) -> BenchResult:
    launcher = LAUNCHERS.get(node)
    if launcher is None:
        raise SystemExit(
            f"ERROR: no launcher for node {node!r}. v1 supports: "
            f"{sorted(LAUNCHERS.keys())}. To add one, write a "
            f"`_build_<node>_cmd` function and register it in LAUNCHERS."
        )

    if datadir.exists():
        raise SystemExit(
            f"ERROR: datadir {datadir} already exists. The harness refuses "
            f"to overwrite existing directories; pass a fresh --datadir or "
            f"remove this one manually."
        )
    datadir.mkdir(parents=True)

    cmd = launcher(datadir, rpc_port, p2p_port, bootstrap_peer)
    start_ts = time.time()
    start_iso = datetime.fromtimestamp(start_ts, tz=timezone.utc).isoformat(
        timespec="seconds")

    log_fh = log_path.open("w")
    log_fh.write(f"# ibd_benchmark {node} start {start_iso}\n")
    log_fh.write(f"# cmd: {' '.join(cmd)}\n")
    log_fh.flush()

    proc = subprocess.Popen(
        cmd,
        stdout=log_fh,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )

    result = BenchResult(
        node=node,
        target_height=target_height,
        reached_height=None,
        wall_seconds=0.0,
        blocks_per_hour=None,
        exit="crash",
        start_iso=start_iso,
        end_iso=start_iso,
        datadir=str(datadir),
        rpc_port=rpc_port,
        p2p_port=p2p_port,
        bootstrap_peer=bootstrap_peer,
    )

    cookie_path = datadir / ".cookie"
    deadline_ts = start_ts + timeout_seconds
    rpc_ready_deadline = start_ts + min(120, timeout_seconds)

    interrupted = {"flag": False}

    def handle_sigint(_sig, _frame):
        interrupted["flag"] = True

    prev_sigint = signal.signal(signal.SIGINT, handle_sigint)
    prev_sigterm = signal.signal(signal.SIGTERM, handle_sigint)

    try:
        auth = _wait_for_rpc(rpc_port, cookie_path, proc, rpc_ready_deadline)
        if auth is None:
            if proc.poll() is not None:
                result.exit = "crash"
            else:
                result.exit = "timeout"
            result.wall_seconds = time.time() - start_ts
            return result

        last_tip = 0
        while time.time() < deadline_ts and not interrupted["flag"]:
            if proc.poll() is not None:
                result.exit = "crash"
                result.wall_seconds = time.time() - start_ts
                return result

            tip = _rpc_getblockcount(rpc_port, auth, timeout=2.0)
            now = time.time()
            if tip is not None:
                last_tip = tip
                result.samples.append({"t": round(now - start_ts, 2), "tip": tip})
                if tip >= target_height:
                    result.exit = "success"
                    result.reached_height = tip
                    result.wall_seconds = now - start_ts
                    result.blocks_per_hour = (
                        tip * 3600.0 / result.wall_seconds
                        if result.wall_seconds > 0 else None
                    )
                    return result
            time.sleep(poll_interval)

        if interrupted["flag"]:
            result.exit = "interrupted"
        else:
            result.exit = "timeout"
        result.reached_height = last_tip
        result.wall_seconds = time.time() - start_ts
        if result.wall_seconds > 0 and last_tip > 0:
            result.blocks_per_hour = last_tip * 3600.0 / result.wall_seconds
        return result
    finally:
        _shutdown(proc)
        signal.signal(signal.SIGINT, prev_sigint)
        signal.signal(signal.SIGTERM, prev_sigterm)
        end_ts = time.time()
        result.end_iso = datetime.fromtimestamp(end_ts, tz=timezone.utc).isoformat(
            timespec="seconds")
        if result.wall_seconds == 0.0:
            result.wall_seconds = end_ts - start_ts
        log_fh.write(f"\n# ibd_benchmark {node} end {result.end_iso} exit={result.exit}\n")
        log_fh.close()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Cold-start IBD benchmark harness (W68b).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--node", required=True,
                        choices=sorted(LAUNCHERS.keys()) +
                                [n for n in BENCH_RPC_PORT if n not in LAUNCHERS])
    parser.add_argument("--target-height", type=int, required=True,
                        help="benchmark completes when RPC tip reaches this height")
    parser.add_argument("--datadir", type=Path, required=True,
                        help="isolated datadir (must be under /tmp/ or ~/bench-*/)")
    parser.add_argument("--timeout", type=int, default=3600,
                        help="max wall seconds (default: 3600)")
    parser.add_argument("--poll-interval", type=float, default=5.0,
                        help="seconds between getblockcount probes (default: 5.0)")
    parser.add_argument("--rpc-port", type=int, default=None,
                        help="bench RPC port (default: BENCH_RPC_PORT[node])")
    parser.add_argument("--p2p-port", type=int, default=None,
                        help="bench P2P port (default: BENCH_P2P_PORT[node])")
    parser.add_argument("--bootstrap-peer", type=str, default=DEFAULT_BOOTSTRAP_PEER,
                        help="localhost:port of a warm peer (default: 127.0.0.1:8456)")
    parser.add_argument("--result-json", type=Path, required=True,
                        help="output path for the JSON result")
    parser.add_argument("--log-path", type=Path, default=None,
                        help="node log path (default: <datadir>/../bench.log)")
    parser.add_argument("--cleanup", action="store_true",
                        help="rm -rf the datadir on exit (default: keep for post-mortem)")
    args = parser.parse_args()

    _safety_check_datadir(args.datadir)

    rpc_port = args.rpc_port or BENCH_RPC_PORT.get(args.node)
    p2p_port = args.p2p_port or BENCH_P2P_PORT.get(args.node)
    if rpc_port is None or p2p_port is None:
        print(f"ERROR: no bench port for {args.node}; pass --rpc-port and --p2p-port",
              file=sys.stderr)
        return 2
    _safety_check_ports(rpc_port, p2p_port)

    log_path = args.log_path or (args.datadir.parent / "bench.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    args.result_json.parent.mkdir(parents=True, exist_ok=True)

    print(f"ibd_benchmark: node={args.node} target={args.target_height} "
          f"datadir={args.datadir}", flush=True)
    print(f"  rpc={rpc_port} p2p={p2p_port} peer={args.bootstrap_peer} "
          f"timeout={args.timeout}s poll={args.poll_interval}s", flush=True)
    print(f"  log={log_path}", flush=True)
    print(f"  result_json={args.result_json}", flush=True)

    result = run_benchmark(
        node=args.node,
        target_height=args.target_height,
        datadir=args.datadir,
        rpc_port=rpc_port,
        p2p_port=p2p_port,
        bootstrap_peer=args.bootstrap_peer,
        timeout_seconds=args.timeout,
        poll_interval=args.poll_interval,
        log_path=log_path,
    )

    args.result_json.write_text(json.dumps(result.to_dict(), indent=2) + "\n")
    print(f"\nresult: exit={result.exit} reached={result.reached_height} "
          f"wall={result.wall_seconds:.1f}s "
          f"rate={result.blocks_per_hour:.0f}/hr" if result.blocks_per_hour
          else f"\nresult: exit={result.exit} reached={result.reached_height} "
               f"wall={result.wall_seconds:.1f}s rate=n/a")
    print(f"result_json: {args.result_json}")

    if args.cleanup:
        shutil.rmtree(args.datadir, ignore_errors=True)
        print(f"cleaned up {args.datadir}")
    else:
        print(f"datadir preserved at {args.datadir}")

    return 0 if result.exit == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
