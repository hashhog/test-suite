#!/usr/bin/env python3
"""Fuzz testing framework for Bitcoin full node implementations.

Generates mutated/random blocks and transactions, submits them to regtest
nodes, and detects crashes, hangs, or consensus divergence.

Usage:
    python3 fuzzer.py [--iterations N] [--skip-setup]
"""

import argparse
import binascii
import hashlib
import json
import os
import random
import signal
import struct
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regtest_miner import rpc_call, mine_blocks, sha256d, compact_size

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HASHHOG = os.environ.get("HASHHOG_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FUZZ_DIR = "/tmp/hashhog-fuzz"
RESULTS_DIR = os.path.join(HASHHOG, "test-suite", "results")

CORE_BIN = f"{HASHHOG}/bitcoin-core/build/bin/bitcoind"
CORE_CLI = f"{HASHHOG}/bitcoin-core/build/bin/bitcoin-cli"

# ---------------------------------------------------------------------------
# Shared child environment for the compiled/interpreted nodes.
#
# Several nodes will not even spawn from the meta-repo root with the caller's
# bare environment (same class of bug as the lunarblock LUA_PATH one):
#   - hotbuns needs `bun` on PATH (~/.bun/bin).
#   - haskoin dynamically links the RocksDB 9.x `rocksdb_compat` shim from
#     ~/.local/lib64, so LD_LIBRARY_PATH must include it or it dies at load.
#   - camlcoin / ouroboros pick up their .local / .cargo tooling from PATH.
# These mirror the PATH / LD_LIBRARY_PATH that tools/diff-test.sh exports, so
# the nodes boot under fuzzer.py exactly as they do under the diff harness.
# ---------------------------------------------------------------------------
_HOME = os.path.expanduser("~")
_NODE_ENV = {
    "PATH": f"{_HOME}/.nimble/bin:{_HOME}/.local/bin:{_HOME}/.cargo/bin:"
            f"{_HOME}/.bun/bin:" + os.environ.get("PATH", ""),
    "LD_LIBRARY_PATH": f"{_HOME}/.local/lib64:/usr/local/lib:"
            + os.environ.get("LD_LIBRARY_PATH", ""),
}


def _find_haskoin():
    """Locate the haskoin executable under dist-newstyle (cabal build output)."""
    import glob
    for p in glob.glob(f"{HASHHOG}/haskoin/dist-newstyle/**/haskoin",
                       recursive=True):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


HASKOIN_BIN = _find_haskoin() or f"{HASHHOG}/haskoin/dist-newstyle/MISSING-haskoin"

# beamchain runs from a relx release and reads its config from sys.config /
# vm.args pointed at by RELX_CONFIG_PATH / VMARGS_PATH (no CLI flags).  Ports
# are baked into sys.config, so keep these in sync with the NODES entry below.
BEAMCHAIN_BIN = f"{HASHHOG}/beamchain/_build/prod/rel/beamchain/bin/beamchain"
BEAMCHAIN_RPC = 19362
BEAMCHAIN_P2P = 19363


def _beamchain_prelaunch(datadir):
    """Write beamchain's sys.config + vm.args and return the env pointing at
    them (mirrors tools/diff-test.sh).  Called by start_node just before spawn."""
    os.makedirs(datadir, exist_ok=True)
    sys_cfg = os.path.join(datadir, "sys.config")
    vm_args = os.path.join(datadir, "vm.args")
    with open(sys_cfg, "w") as f:
        f.write(
            "[\n"
            " {beamchain, [\n"
            "   {network, regtest},\n"
            f'   {{datadir, "{datadir}"}},\n'
            f"   {{p2pport, {BEAMCHAIN_P2P}}},\n"
            f"   {{rpcport, {BEAMCHAIN_RPC}}},\n"
            '   {txindex, "1"}\n'
            " ]},\n"
            " {kernel, [{logger_level, info}]},\n"
            " {sasl,   [{sasl_error_logger, false}]}\n"
            "].\n"
        )
    with open(vm_args, "w") as f:
        f.write(f"-sname fuzz_{os.getpid()}\n-setcookie fuzz\n"
                "+P 1048576\n+K true\n+A 64\n")
    return {"RELX_CONFIG_PATH": sys_cfg, "VMARGS_PATH": vm_args}


# Regtest port assignments (19xxx range to avoid conflicts)
NODES = {
    "core": {
        "binary": CORE_BIN,
        "args": [
            "-regtest",
            f"-datadir={FUZZ_DIR}/core",
            "-rpcport=19332",
            "-port=19333",
            "-server=1",
            "-nolisten",
            "-rpcuser=fuzz",
            "-rpcpassword=fuzz",
            "-txindex=1",
            "-printtoconsole=0",
        ],
        "rpcport": 19332,
        "rpcuser": "fuzz",
        "rpcpassword": "fuzz",
        "start_delay": 2,
    },
    "nimrod": {
        "binary": f"{HASHHOG}/nimrod/bin/nimrod",
        "args": [
            "start",
            "--regtest",
            f"--datadir={FUZZ_DIR}/nimrod",
            "--rpcport=19353",
            "--rpcuser=fuzz",
            "--rpcpassword=fuzz",
            "--port=0",
        ],
        "rpcport": 19353,
        "rpcuser": "fuzz",
        "rpcpassword": "fuzz",
        "start_delay": 2,
    },
    "blockbrew": {
        "binary": f"{HASHHOG}/blockbrew/blockbrew",
        "args": [
            "-network=regtest",
            f"-datadir={FUZZ_DIR}/blockbrew",
            "-rpcbind=127.0.0.1:19355",
            "-rpcuser=fuzz",
            "-rpcpassword=fuzz",
            "-nolisten",
        ],
        "rpcport": 19355,
        "rpcuser": "fuzz",
        "rpcpassword": "fuzz",
        "start_delay": 2,
    },
    "clearbit": {
        "binary": f"{HASHHOG}/clearbit/zig-out/bin/clearbit",
        "args": [
            "--regtest",
            f"--datadir={FUZZ_DIR}/clearbit",
            "--rpcport=19356",
            "--rpcuser=fuzz",
            "--rpcpassword=fuzz",
            "--port=0",
        ],
        "rpcport": 19356,
        "rpcuser": "fuzz",
        "rpcpassword": "fuzz",
        "start_delay": 2,
    },
    "lunarblock": {
        "binary": "/usr/bin/luajit",
        "args": [
            f"{HASHHOG}/lunarblock/src/main.lua",
            "--regtest",
            "--datadir", f"{FUZZ_DIR}/lunarblock",
            "--rpcport", "19358",
            "--rpcuser", "fuzz",
            "--rpcpassword", "fuzz",
            "--port", "0",
        ],
        "rpcport": 19358,
        "rpcuser": "fuzz",
        "rpcpassword": "fuzz",
        "start_delay": 3,
        # lunarblock's main.lua does `require("lunarblock.<mod>")`, which only
        # resolves when LUA_PATH points at its src/ tree.  Launched from the
        # meta-repo root without it, the node dies at startup with
        # `module 'lunarblock.consensus' not found` — the reason prior sweeps
        # couldn't fuzz it.  Set cwd + LUA_PATH/LUA_CPATH exactly like
        # tools/diff-test.sh does so it actually boots.
        "cwd": f"{HASHHOG}/lunarblock",
        "env": {
            "LUA_PATH": f"{HASHHOG}/lunarblock/src/?.lua;{HASHHOG}/lunarblock/src/?/init.lua;;",
            "LUA_CPATH": os.path.expanduser("~/.local/lib/lua/5.1/?.so") + ";;",
        },
    },
    # -----------------------------------------------------------------------
    # The five nodes below were previously fuzzable only via an ad-hoc
    # scratchpad driver (see CORE-PARITY-AUDIT/fuzz-sweep-6nodes-2026-07-11.md).
    # Unlike nimrod/blockbrew/clearbit/lunarblock, none of them accept
    # --rpcuser/--rpcpassword basic auth for the fuzz RPC; they authenticate
    # via a generated .cookie in the datadir, so each carries "auth": "cookie"
    # and the RPC helpers resolve the user:password from that file at call time
    # (the cookie only exists once the node has started).  Launch invocations,
    # cwd, env and cookie handling all mirror tools/diff-test.sh.
    # -----------------------------------------------------------------------
    "camlcoin": {
        "binary": f"{HASHHOG}/camlcoin/_build/default/bin/main.exe",
        "args": [
            "--network", "regtest",
            "--datadir", f"{FUZZ_DIR}/camlcoin",
            "--port", "19361",
            "--rpcport", "19360",
        ],
        "rpcport": 19360,
        "auth": "cookie",
        "start_delay": 2,
        "boot_timeout": 60,
        "env": dict(_NODE_ENV),
    },
    "beamchain": {
        # relx release binary (NOT _build/default/bin) run in `foreground`;
        # config comes from sys.config/vm.args via _beamchain_prelaunch.
        "binary": BEAMCHAIN_BIN,
        "args": ["foreground"],
        "rpcport": BEAMCHAIN_RPC,
        "auth": "cookie",
        "start_delay": 3,
        "boot_timeout": 75,
        "env": dict(_NODE_ENV),
        "prelaunch": _beamchain_prelaunch,
    },
    "hotbuns": {
        "binary": "bun",
        "args": [
            "run", "src/index.ts",
            "--network=regtest",
            f"--datadir={FUZZ_DIR}/hotbuns",
            "--port=19365",
            "--rpcport=19364",
            "--metrics-port=0",
        ],
        "rpcport": 19364,
        "auth": "cookie",
        "start_delay": 2,
        "boot_timeout": 50,
        # `bun run src/index.ts` resolves src/ relative to cwd.
        "cwd": f"{HASHHOG}/hotbuns",
        "env": dict(_NODE_ENV),
    },
    "ouroboros": {
        "binary": f"{HASHHOG}/ouroboros/.venv/bin/python3"
                  if os.access(f"{HASHHOG}/ouroboros/.venv/bin/python3", os.X_OK)
                  else "python3",
        "args": [
            "-m", "ouroboros.cli",
            "--network", "regtest",
            "--data-dir", f"{FUZZ_DIR}/ouroboros",
            "start", "--force",
            "--rpc-port", "19366",
            "--p2p-port", "19367",
        ],
        "rpcport": 19366,
        "auth": "cookie",
        "start_delay": 3,
        "boot_timeout": 70,
        "cwd": f"{HASHHOG}/ouroboros",
        "env": dict(_NODE_ENV),
    },
    "haskoin": {
        "binary": HASKOIN_BIN,
        "args": [
            "--network", "Regtest",
            "--datadir", f"{FUZZ_DIR}/haskoin",
            "node",
            "--port", "19369",
            "--rpcport", "19368",
        ],
        "rpcport": 19368,
        "auth": "cookie",
        "start_delay": 2,
        "boot_timeout": 70,
        "env": dict(_NODE_ENV),
    },
}


def resolve_auth(name):
    """Return (user, password) for a node's RPC.

    Basic-auth nodes (default) carry static rpcuser/rpcpassword.  Cookie-auth
    nodes ("auth": "cookie") have their credentials generated at startup into
    <datadir>/.cookie (or <datadir>/regtest/.cookie); read them fresh each call
    since the file only appears once the node is up.  Returns (None, None) if a
    cookie is expected but not yet written (RPC will fail and the wait loop
    retries)."""
    cfg = NODES[name]
    if cfg.get("auth") == "cookie":
        datadir = f"{FUZZ_DIR}/{name}"
        for c in (os.path.join(datadir, ".cookie"),
                  os.path.join(datadir, "regtest", ".cookie")):
            if os.path.isfile(c):
                try:
                    txt = open(c).read().strip()
                    if ":" in txt:
                        u, p = txt.split(":", 1)
                        return u, p
                except Exception:
                    pass
        return None, None
    return cfg.get("rpcuser"), cfg.get("rpcpassword")

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

processes = {}
seed_blocks = []  # list of (height, block_hash, raw_hex)
fuzz_log = []     # log of all fuzz inputs that caused issues
stats = {
    "iterations": 0,
    "mutations_by_type": {},
    "crashes": [],
    "hangs": [],
    "divergences": [],
    "rejections_expected": 0,
    "rejections_unexpected": 0,
    "accepts_expected": 0,
    "accepts_unexpected": 0,
    "errors": [],
}


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

def node_rpc(name, method, params=None):
    cfg = NODES[name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    user, password = resolve_auth(name)
    return rpc_call(url, user, password, method, params)


def wait_for_rpc(name, timeout=20):
    cfg = NODES[name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            user, password = resolve_auth(name)
            result, err = rpc_call(url, user, password, "getblockchaininfo")
            if result is not None:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def is_node_alive(name):
    """Check if a node responds to RPC within 5 seconds."""
    cfg = NODES[name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    try:
        user, password = resolve_auth(name)
        result, err = rpc_call(url, user, password, "getblockchaininfo")
        return result is not None
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Node lifecycle
# ---------------------------------------------------------------------------

def start_node(name):
    cfg = NODES[name]
    datadir = f"{FUZZ_DIR}/{name}"
    os.makedirs(datadir, exist_ok=True)

    log_path = f"{FUZZ_DIR}/{name}.log"
    log_file = open(log_path, "w")

    cmd = [cfg["binary"]] + cfg["args"]
    # Optional per-node cwd/env (needed by interpreted nodes whose module
    # resolution depends on the working directory / a *_PATH env var — e.g.
    # lunarblock's LUA_PATH).  Nodes without these keys launch unchanged.
    # Optional "prelaunch" callable writes any config files the node needs
    # before spawn (e.g. beamchain's sys.config/vm.args) and returns extra env.
    child_env = None
    if cfg.get("env") or cfg.get("prelaunch"):
        child_env = dict(os.environ)
        if cfg.get("env"):
            child_env.update(cfg["env"])
        if cfg.get("prelaunch"):
            extra = cfg["prelaunch"](datadir)
            if extra:
                child_env.update(extra)
    try:
        proc = subprocess.Popen(cmd, stdout=log_file, stderr=log_file,
                                cwd=cfg.get("cwd"), env=child_env,
                                preexec_fn=os.setsid)
    except Exception as e:
        log(f"  {name}: failed to spawn: {e}")
        return False

    processes[name] = proc
    time.sleep(cfg["start_delay"])

    if wait_for_rpc(name, timeout=cfg.get("boot_timeout", 25)):
        log(f"  {name}: started (pid {proc.pid}, rpc={cfg['rpcport']})")
        return True

    log(f"  {name}: FAILED to start")
    if proc.poll() is not None:
        log(f"  {name}: exited with code {proc.returncode}")
        try:
            with open(log_path) as lf:
                for line in lf.readlines()[-5:]:
                    log(f"    LOG: {line.rstrip()}")
        except Exception:
            pass
    return False


def stop_node(name):
    if name == "core":
        try:
            node_rpc("core", "stop")
            time.sleep(2)
        except Exception:
            pass
    if name in processes:
        proc = processes[name]
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass


def stop_all():
    log("Stopping all nodes...")
    for name in list(processes.keys()):
        stop_node(name)
    log("All nodes stopped.")
    # Self-clean the regtest scratch root so a completed run leaves ZERO
    # scratch behind on the /tmp tmpfs (results live under ~/hashhog, not
    # here). Set HASHHOG_KEEP_SCRATCH=1 to retain the datadirs for debugging.
    if not os.environ.get("HASHHOG_KEEP_SCRATCH"):
        import shutil
        shutil.rmtree(FUZZ_DIR, ignore_errors=True)


# ---------------------------------------------------------------------------
# Mutation strategies
# ---------------------------------------------------------------------------

def mutate_flip_bits(raw_hex, count=None):
    """Flip random bits in the block hex."""
    data = bytearray(binascii.unhexlify(raw_hex))
    if not data:
        return raw_hex
    if count is None:
        count = random.randint(1, 8)
    for _ in range(count):
        pos = random.randint(0, len(data) - 1)
        bit = 1 << random.randint(0, 7)
        data[pos] ^= bit
    return data.hex()


def mutate_header_flip(raw_hex):
    """Flip bits only in the 80-byte block header."""
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 80:
        return raw_hex
    count = random.randint(1, 4)
    for _ in range(count):
        pos = random.randint(0, 79)
        bit = 1 << random.randint(0, 7)
        data[pos] ^= bit
    return data.hex()


def mutate_truncate(raw_hex):
    """Truncate block to random length."""
    data = binascii.unhexlify(raw_hex)
    if len(data) < 81:
        return raw_hex
    # Keep at least the header
    cut = random.randint(80, len(data) - 1)
    return data[:cut].hex()


def mutate_zero_field(raw_hex):
    """Zero out a specific header field."""
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 80:
        return raw_hex
    # Header fields: version(0-3), prevhash(4-35), merkle(36-67),
    # time(68-71), bits(72-75), nonce(76-79)
    fields = [
        (0, 4, "version"),
        (4, 36, "prevhash"),
        (36, 68, "merkle"),
        (68, 72, "time"),
        (72, 76, "bits"),
        (76, 80, "nonce"),
    ]
    start, end, _ = random.choice(fields)
    for i in range(start, end):
        data[i] = 0
    return data.hex()


def mutate_max_field(raw_hex):
    """Set a header field to max value (0xff)."""
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 80:
        return raw_hex
    fields = [
        (0, 4), (4, 36), (36, 68), (68, 72), (72, 76), (76, 80),
    ]
    start, end = random.choice(fields)
    for i in range(start, end):
        data[i] = 0xff
    return data.hex()


def mutate_remove_tx(raw_hex):
    """Try to remove a transaction from the block (after header+txcount)."""
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 100:
        return raw_hex
    # Just chop some bytes from the tx area
    tx_start = 81  # after header + 1 byte tx count
    if tx_start >= len(data):
        return raw_hex
    chunk_size = random.randint(1, min(50, len(data) - tx_start))
    cut_pos = random.randint(tx_start, len(data) - chunk_size)
    data = data[:cut_pos] + data[cut_pos + chunk_size:]
    return data.hex()


def mutate_insert_random(raw_hex):
    """Insert random bytes at random position."""
    data = bytearray(binascii.unhexlify(raw_hex))
    pos = random.randint(0, len(data))
    insert = bytes(random.getrandbits(8) for _ in range(random.randint(1, 32)))
    data = data[:pos] + insert + data[pos:]
    return data.hex()


def mutate_duplicate_block(raw_hex):
    """Return the block unchanged (valid block replay)."""
    return raw_hex


def generate_random_garbage():
    """Generate completely random bytes as a 'block'."""
    length = random.randint(80, 1000)
    return bytes(random.getrandbits(8) for _ in range(length)).hex()


MUTATION_STRATEGIES = [
    ("flip_bits", mutate_flip_bits, 20),
    ("header_flip", mutate_header_flip, 20),
    ("truncate", mutate_truncate, 10),
    ("zero_field", mutate_zero_field, 10),
    ("max_field", mutate_max_field, 10),
    ("remove_tx", mutate_remove_tx, 10),
    ("insert_random", mutate_insert_random, 10),
    ("duplicate_block", mutate_duplicate_block, 5),
    ("random_garbage", None, 5),  # special case
]

# Build weighted selection
_strategy_names = []
_strategy_fns = []
_strategy_weights = []
for name, fn, weight in MUTATION_STRATEGIES:
    _strategy_names.append(name)
    _strategy_fns.append(fn)
    _strategy_weights.append(weight)


def pick_mutation():
    """Pick a mutation strategy based on weights. Returns (name, mutated_hex)."""
    idx = random.choices(range(len(_strategy_names)), weights=_strategy_weights, k=1)[0]
    name = _strategy_names[idx]
    fn = _strategy_fns[idx]

    if name == "random_garbage":
        return name, generate_random_garbage()

    # Pick a random seed block to mutate
    if not seed_blocks:
        return "random_garbage", generate_random_garbage()

    _, _, raw = random.choice(seed_blocks)
    return name, fn(raw)


# ---------------------------------------------------------------------------
# Seed corpus
# ---------------------------------------------------------------------------

def build_seed_corpus(alive_nodes):
    """Mine 50 blocks on Core and submit to all nodes."""
    log("Building seed corpus: mining 50 blocks on Core...")
    core_url = f"http://127.0.0.1:{NODES['core']['rpcport']}"

    hashes = mine_blocks(core_url, "fuzz", "fuzz", 50)
    if not hashes:
        log("FATAL: Could not mine seed blocks")
        return False

    count, _ = node_rpc("core", "getblockcount")
    log(f"  Core at height {count}, mined {len(hashes)} blocks")

    # Collect raw blocks for seed corpus
    for h in range(1, count + 1):
        bhash, _ = node_rpc("core", "getblockhash", [h])
        if not bhash:
            continue
        raw, _ = node_rpc("core", "getblock", [bhash, 0])
        if raw:
            seed_blocks.append((h, bhash, raw))

    log(f"  Seed corpus: {len(seed_blocks)} blocks")

    # Submit to all alive test nodes
    for name in alive_nodes:
        if name == "core":
            continue
        log(f"  Submitting seed blocks to {name}...")
        accepted = 0
        failed = 0
        for h, bhash, raw in seed_blocks:
            result, err = node_rpc(name, "submitblock", [raw])
            if err:
                # Check if it's a "duplicate" type error which is OK
                err_str = str(err).lower()
                if any(w in err_str for w in ["duplicate", "already", "inconsequential"]):
                    accepted += 1
                else:
                    failed += 1
            elif result is None or result == "":
                accepted += 1
            else:
                result_str = str(result).lower()
                if any(w in result_str for w in ["duplicate", "already", "inconsequential"]):
                    accepted += 1
                else:
                    failed += 1

        log(f"    {name}: {accepted} accepted, {failed} failed")

    # Verify all tips match
    core_tip, _ = node_rpc("core", "getbestblockhash")
    all_match = True
    for name in alive_nodes:
        if name == "core":
            continue
        tip, _ = node_rpc(name, "getbestblockhash")
        if tip != core_tip:
            log(f"  WARNING: {name} tip {tip} != core tip {core_tip}")
            all_match = False

    if all_match:
        log("  All nodes at same tip after seed corpus.")
    else:
        log("  WARNING: Not all nodes matched after seed corpus (continuing anyway).")

    return True


# ---------------------------------------------------------------------------
# Fuzz loop
# ---------------------------------------------------------------------------

def submit_fuzz_input(alive_nodes, mutated_hex, strategy_name, iteration):
    """Submit a mutated block to all nodes and check results."""
    results_per_node = {}

    for name in alive_nodes:
        try:
            result, err = node_rpc(name, "submitblock", [mutated_hex])
            if err:
                results_per_node[name] = ("rejected", str(err))
            elif result is None or result == "":
                results_per_node[name] = ("accepted", None)
            else:
                results_per_node[name] = ("rejected", str(result))
        except Exception as e:
            err_str = str(e)
            if "Connection refused" in err_str or "timed out" in err_str:
                results_per_node[name] = ("unreachable", err_str)
            else:
                results_per_node[name] = ("error", err_str)

    # Check for crashes/hangs (unreachable nodes)
    for name, (status, detail) in results_per_node.items():
        if status == "unreachable":
            # Only report if not already known dead
            already_crashed = any(c["node"] == name for c in stats["crashes"])
            already_hung = any(h["node"] == name for h in stats["hangs"])
            if already_crashed or already_hung:
                continue
            # Verify the process is still running
            proc = processes.get(name)
            if proc and proc.poll() is not None:
                stats["crashes"].append({
                    "node": name,
                    "iteration": iteration,
                    "strategy": strategy_name,
                    "exit_code": proc.returncode,
                    "input_hex_prefix": mutated_hex[:200],
                })
                log(f"  CRASH: {name} exited (code={proc.returncode}) at iteration {iteration} ({strategy_name})")
            else:
                stats["hangs"].append({
                    "node": name,
                    "iteration": iteration,
                    "strategy": strategy_name,
                })
                log(f"  HANG: {name} unreachable at iteration {iteration} ({strategy_name})")

    # Check for divergence: if Core rejected but another accepted (or vice versa)
    core_status = results_per_node.get("core", ("unknown", None))[0]
    for name, (status, detail) in results_per_node.items():
        if name == "core":
            continue
        if status in ("unreachable", "error"):
            continue
        # Skip nodes already known to be dead
        if any(c["node"] == name for c in stats["crashes"]):
            continue
        if core_status == "rejected" and status == "accepted":
            stats["accepts_unexpected"] += 1
            stats["divergences"].append({
                "node": name,
                "iteration": iteration,
                "strategy": strategy_name,
                "core_status": "rejected",
                "node_status": "accepted",
                "input_hex_prefix": mutated_hex[:200],
            })
            log(f"  DIVERGENCE: {name} ACCEPTED what Core REJECTED (iter={iteration}, {strategy_name})")
        elif core_status == "accepted" and status == "rejected":
            stats["rejections_unexpected"] += 1
            # This is less critical for mutated blocks but worth logging
        elif core_status == "rejected" and status == "rejected":
            stats["rejections_expected"] += 1
        elif core_status == "accepted" and status == "accepted":
            stats["accepts_expected"] += 1

    return results_per_node


def health_check(alive_nodes):
    """Check all nodes are alive and tips match. Returns updated alive list."""
    still_alive = []
    tips = {}

    for name in alive_nodes:
        if is_node_alive(name):
            still_alive.append(name)
            tip, _ = node_rpc(name, "getbestblockhash")
            tips[name] = tip
        else:
            proc = processes.get(name)
            if proc and proc.poll() is not None:
                log(f"  Health check: {name} has exited (code={proc.returncode})")
                stats["crashes"].append({
                    "node": name,
                    "iteration": stats["iterations"],
                    "strategy": "health_check",
                    "exit_code": proc.returncode,
                })
            else:
                log(f"  Health check: {name} unresponsive")
                stats["hangs"].append({
                    "node": name,
                    "iteration": stats["iterations"],
                    "strategy": "health_check",
                })

    # Check tip consensus
    core_tip = tips.get("core")
    if core_tip:
        for name, tip in tips.items():
            if name == "core":
                continue
            if tip != core_tip:
                log(f"  Health check: TIP DIVERGENCE {name} tip={tip} != core={core_tip}")
                stats["divergences"].append({
                    "node": name,
                    "iteration": stats["iterations"],
                    "strategy": "health_check_tip",
                    "core_tip": core_tip,
                    "node_tip": tip,
                })

    return still_alive


def run_fuzz(alive_nodes, iterations):
    """Main fuzz loop."""
    log(f"Starting fuzz loop: {iterations} iterations across {len(alive_nodes)} nodes")
    log(f"  Nodes: {', '.join(alive_nodes)}")

    check_interval = 1000
    batch_start = time.time()

    for i in range(1, iterations + 1):
        strategy_name, mutated_hex = pick_mutation()

        # Track mutation type
        stats["mutations_by_type"][strategy_name] = \
            stats["mutations_by_type"].get(strategy_name, 0) + 1
        stats["iterations"] = i

        submit_fuzz_input(alive_nodes, mutated_hex, strategy_name, i)

        # Remove nodes that just crashed from the alive list
        alive_nodes = [n for n in alive_nodes
                       if not any(c["node"] == n and c["iteration"] == i
                                  for c in stats["crashes"])]

        # Periodic health check
        if i % check_interval == 0:
            elapsed = time.time() - batch_start
            rate = check_interval / elapsed if elapsed > 0 else 0
            log(f"  Progress: {i}/{iterations} ({rate:.0f} iter/s)")
            log(f"    Mutations: {dict(stats['mutations_by_type'])}")
            log(f"    Crashes: {len(stats['crashes'])}, Hangs: {len(stats['hangs'])}, "
                f"Divergences: {len(stats['divergences'])}")

            alive_nodes = health_check(alive_nodes)
            if "core" not in alive_nodes:
                log("FATAL: Core node died, stopping fuzz")
                break
            if len(alive_nodes) < 2:
                log("WARNING: Only Core alive, stopping fuzz (no test nodes left)")
                break

            batch_start = time.time()

    log(f"Fuzz loop complete: {stats['iterations']} iterations")
    return alive_nodes


# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

def write_results(alive_nodes, total_time):
    """Write JSON results and text summary."""
    os.makedirs(RESULTS_DIR, exist_ok=True)

    # Final tip check
    final_tips = {}
    for name in list(NODES.keys()):
        if is_node_alive(name):
            tip, _ = node_rpc(name, "getbestblockhash")
            count, _ = node_rpc(name, "getblockcount")
            final_tips[name] = {"tip": tip, "height": count}

    result_data = {
        "test": "fuzz-testing",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "duration_seconds": round(total_time, 1),
        "iterations": stats["iterations"],
        "seed_blocks": len(seed_blocks),
        "nodes_started": list(alive_nodes),
        "mutations_by_type": stats["mutations_by_type"],
        "stats": {
            "rejections_expected": stats["rejections_expected"],
            "rejections_unexpected": stats["rejections_unexpected"],
            "accepts_expected": stats["accepts_expected"],
            "accepts_unexpected": stats["accepts_unexpected"],
        },
        "crashes": stats["crashes"],
        "hangs": stats["hangs"],
        "divergences": stats["divergences"],
        "errors": stats["errors"],
        "final_tips": final_tips,
    }

    json_path = os.path.join(RESULTS_DIR, "fuzz-results.json")
    with open(json_path, "w") as f:
        json.dump(result_data, f, indent=2)
    log(f"Results written to {json_path}")

    # Text summary
    lines = []
    lines.append("=" * 72)
    lines.append("FUZZ TESTING SUMMARY")
    lines.append("=" * 72)
    lines.append(f"Date:       {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
    lines.append(f"Duration:   {total_time:.1f}s")
    lines.append(f"Iterations: {stats['iterations']}")
    lines.append(f"Seed blocks: {len(seed_blocks)}")
    lines.append("")

    lines.append("Nodes tested:")
    for name in NODES:
        status = "alive" if is_node_alive(name) else "dead/stopped"
        tip_info = final_tips.get(name, {})
        h = tip_info.get("height", "?")
        lines.append(f"  {name:12s} {status:12s} height={h}")
    lines.append("")

    lines.append("Mutation distribution:")
    for mtype, count in sorted(stats["mutations_by_type"].items(),
                                key=lambda x: -x[1]):
        lines.append(f"  {mtype:20s} {count:>6}")
    lines.append("")

    lines.append(f"Expected rejections:    {stats['rejections_expected']}")
    lines.append(f"Unexpected rejections:  {stats['rejections_unexpected']}")
    lines.append(f"Expected accepts:       {stats['accepts_expected']}")
    lines.append(f"Unexpected accepts:     {stats['accepts_unexpected']}")
    lines.append("")

    lines.append(f"CRASHES:     {len(stats['crashes'])}")
    for c in stats["crashes"]:
        lines.append(f"  {c['node']} at iter {c['iteration']} ({c['strategy']}) "
                     f"exit_code={c.get('exit_code', '?')}")

    lines.append(f"HANGS:       {len(stats['hangs'])}")
    for h in stats["hangs"][:20]:
        lines.append(f"  {h['node']} at iter {h['iteration']} ({h['strategy']})")

    lines.append(f"DIVERGENCES: {len(stats['divergences'])}")
    for d in stats["divergences"][:20]:
        lines.append(f"  {d['node']} at iter {d['iteration']} ({d['strategy']}) "
                     f"core={d.get('core_status', '?')} node={d.get('node_status', '?')}")

    lines.append("")

    # Verdict
    total_issues = len(stats["crashes"]) + len(stats["divergences"])
    if total_issues == 0:
        lines.append("VERDICT: PASS - No crashes or divergences detected")
    else:
        lines.append(f"VERDICT: ISSUES FOUND - {total_issues} crash/divergence events")

    lines.append("=" * 72)

    summary_text = "\n".join(lines)
    summary_path = os.path.join(RESULTS_DIR, "fuzz-summary.txt")
    with open(summary_path, "w") as f:
        f.write(summary_text + "\n")
    log(f"Summary written to {summary_path}")

    print()
    print(summary_text)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Fuzz testing for Bitcoin nodes")
    parser.add_argument("--iterations", type=int, default=100000,
                        help="Number of fuzz iterations (default: 100000)")
    parser.add_argument("--skip-setup", action="store_true",
                        help="Skip node startup (assume already running)")
    args = parser.parse_args()

    log("=" * 72)
    log("HASHHOG FUZZ TESTING FRAMEWORK")
    log("=" * 72)

    t_start = time.time()

    # --- Phase 1: Start nodes ---
    alive_nodes = []
    if not args.skip_setup:
        log("\n--- Phase 1: Starting regtest nodes ---")

        # Clean up any previous fuzz data
        subprocess.run(["rm", "-rf", FUZZ_DIR], check=False)
        for name in NODES:
            os.makedirs(f"{FUZZ_DIR}/{name}", exist_ok=True)

        for name in NODES:
            ok = start_node(name)
            if ok:
                alive_nodes.append(name)
            elif name == "core":
                log("FATAL: Cannot start Bitcoin Core")
                stop_all()
                return 1

        log(f"Started: {alive_nodes}")
        failed = [n for n in NODES if n not in alive_nodes]
        if failed:
            log(f"Failed to start: {failed}")
    else:
        # Check which are alive
        for name in NODES:
            if is_node_alive(name):
                alive_nodes.append(name)
        log(f"Already running: {alive_nodes}")

    if "core" not in alive_nodes:
        log("FATAL: Core not available")
        stop_all()
        return 1

    if len(alive_nodes) < 2:
        log("FATAL: Need at least Core + 1 test node")
        stop_all()
        return 1

    # --- Phase 2: Build seed corpus ---
    log("\n--- Phase 2: Building seed corpus ---")
    if not build_seed_corpus(alive_nodes):
        log("FATAL: Could not build seed corpus")
        stop_all()
        return 1

    # --- Phase 3: Fuzz ---
    log(f"\n--- Phase 3: Fuzzing ({args.iterations} iterations) ---")
    alive_nodes = run_fuzz(alive_nodes, args.iterations)

    # --- Phase 4: Results ---
    total_time = time.time() - t_start
    log(f"\n--- Phase 4: Writing results ---")
    write_results(alive_nodes, total_time)

    # --- Phase 5: Cleanup ---
    log("\n--- Phase 5: Cleanup ---")
    stop_all()
    subprocess.run(["rm", "-rf", FUZZ_DIR], check=False)
    log("Cleanup complete.")

    # Exit non-zero when the fuzzer FOUND something, so CI fails on a real
    # finding instead of silently passing. A consensus divergence (an impl
    # deciding a block/tx differently from Core), a crash, or a hang under fuzz
    # is a genuine bug; the detail is in test-suite/results/fuzz-results.json.
    n_div = len(stats.get("divergences", []))
    n_crashes = len(stats.get("crashes", []))
    n_hangs = len(stats.get("hangs", []))
    if n_div or n_crashes or n_hangs:
        log(f"FUZZ FINDINGS: {n_div} divergence(s), {n_crashes} crash(es), "
            f"{n_hangs} hang(s) -- see {RESULTS_DIR}/fuzz-results.json")
        return 1
    log("No crashes, hangs, or divergences found across the fuzz run.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Interrupted")
        stop_all()
        subprocess.run(["rm", "-rf", FUZZ_DIR], check=False)
        sys.exit(1)
    except Exception as e:
        log(f"Error: {e}")
        traceback.print_exc()
        stop_all()
        subprocess.run(["rm", "-rf", FUZZ_DIR], check=False)
        sys.exit(1)
