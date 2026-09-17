#!/usr/bin/env python3
"""Poll every fleet miner and print one display-ready JSON record.

The shell panel does no discovery and no flattening of its own: this script
emits a flat `miners` list, per-host rollups, and fleet totals, so the QML
delegates bind straight to it.

Unit names are DATA, not derived. Each host owns its own naming:

  zephyr  Omarchy, units hand-managed in /etc/systemd/system
          -> peakminer-3060ti.service, peakminer-3090.service
  nexus   Omarchy, service peakminer-nexus-3060ti (systemd)
  forge   Omarchy, persistent units
          -> peakminer-forge-4060-0.service, peakminer-forge-4060-1.service
  krash2  Windows 11, NSSM service (krash2 SSH alias, user 'krash')
          -> pearlhash (NSSM service name)
  krash3  Windows 11, the Kryptex desktop app (monitor-only; no unit).
          PRL via the bundled SRBMiner's API on the LAN; XMR + GPU power
          are 127.0.0.1-only reads, gathered over one ssh session.

Deriving a unit from the API port (the previous behaviour) matched no unit on
any host, so every pause silently did nothing. Keep these strings in step with
the hosts themselves, and never guess them from a port.

Some peakminer builds (e.g. v2.9.1 on forge) report power_w: null from their
API. When the miner API has no power, fall back to nvidia-smi -q -d POWER —
instantaneous draw is often N/A on headless mining hosts but the Power
Samples average works.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

TIMEOUT_SECONDS = 3
SSH_TIMEOUT_SECONDS = 12
SSH_OPTIONS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=6",
    # One connection per host instead of one per miner. The miner APIs bind
    # 127.0.0.1 only, so each remote host needs a curl run on the host itself;
    # opening a session per port trips sshd's MaxStartups throttling
    # (kex_exchange_identification: Connection reset by peer) and every probe
    # after the first fails.
    "-o", "ServerAliveInterval=5",
    # Multiplexing: every bar on every monitor runs its own copy of this
    # poller, so sessions to one host overlap several times a minute. One
    # shared master connection removes the connect/kex/auth churn (Windows
    # sshd resets sessions under it) and makes repeat probes much faster.
    "-o", "ControlMaster=auto",
    "-o", f"ControlPath=/run/user/{os.getuid()}/ssh-miners-%C",
    "-o", "ControlPersist=60",
]

# The fleet definition lives in fleet.py so poll.py and miner-control cannot
# drift apart on unit names — two copies of these strings is how a pause ends
# up targeting a unit that does not exist.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fleet import FLEET  # noqa: E402


def query_miner(ip, port):
    """Read one miner's /summary over the network. None when unreachable."""
    try:
        request = urllib.request.Request(
            f"http://{ip}:{port}/summary",
            headers={"Accept": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            return json.loads(response.read().decode())
    except Exception:
        return None


def query_host_over_ssh(config):
    """Read every miner on a remote host in ONE ssh connection.

    The miner APIs listen on 127.0.0.1 only, so they are unreachable from here
    no matter what the firewall says — the summary has to be fetched on the host
    itself. One connection per host keeps sshd's MaxStartups from throttling us.

    Returns {port: summary-or-None}, or {} when the host cannot be reached.
    """
    ports = [miner["port"] for miner in config["miners"]]
    if not ports or not shutil.which("ssh"):
        return None

    # Windows hosts run PowerShell as their SSH shell, where `curl` is an
    # alias for `Invoke-WebRequest` and fails. Wrap curl.exe in cmd /c so
    # it always runs the real binary regardless of shell.
    is_windows = config.get("platform") == "windows"
    if is_windows:
        script = "; ".join(
            f'cmd /c "curl.exe -s --max-time 3 http://127.0.0.1:{port}/summary"'
            for port in ports
        )
    else:
        script = "; ".join(
            f'printf "MINER %s %s\\n" {port} '
            f'"$(curl -s --max-time 3 http://127.0.0.1:{port}/summary | tr -d "\\n\")"'
            for port in ports
        )

    target = config.get("ssh") or f"{config['user']}@{config['ip']}"
    try:
        completed = subprocess.run(
            ["ssh", *SSH_OPTIONS, target, script],
            capture_output=True,
            text=True,
            timeout=SSH_TIMEOUT_SECONDS,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None  # ssh never completed: the host, not its miner, is down

    if completed.returncode == 255:
        # ssh's own convention: 255 is the connection/auth layer failing. The
        # remote command's exit codes (curl's 7 when a miner port is closed,
        # say) pass through unchanged and still prove the host is up.
        return None

    results = {}
    stdout_lines = (completed.stdout or "").splitlines()

    if is_windows:
        # Windows: each curl outputs raw JSON on its own line(s), separated
        # by newlines. Match them to ports in order (the script runs curls
        # sequentially with `;`).
        port_idx = 0
        for line in stdout_lines:
            line = line.strip()
            if not line or line.startswith("** "):
                continue
            if port_idx >= len(ports):
                break
            try:
                results[ports[port_idx]] = json.loads(line)
            except json.JSONDecodeError:
                results[ports[port_idx]] = None
            port_idx += 1
        return results

    for line in stdout_lines:
        if not line.startswith("MINER "):
            continue
        parts = line.split(" ", 2)
        if len(parts) < 3:
            continue
        try:
            port = int(parts[1])
        except ValueError:
            continue
        payload = parts[2].strip()
        if not payload:
            results[port] = None
            continue
        try:
            results[port] = json.loads(payload)
        except json.JSONDecodeError:
            results[port] = None
    return results


def _ssh_ok(config):
    """True when one trivial command runs over ssh (reachability only)."""
    target = config.get("ssh") or f"{config['user']}@{config['ip']}"
    try:
        completed = subprocess.run(
            ["ssh", *SSH_OPTIONS, target, "echo KR-OK"],
            capture_output=True,
            text=True,
            timeout=SSH_TIMEOUT_SECONDS,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return completed.returncode == 0


def query_kryptex_rig(config):
    """Read the Kryptex app rig (krash3) in one pass.

    Not peakminer, so there is no /summary to read: PRL comes from the bundled
    SRBMiner's HTTP API (it binds all interfaces, so the LAN reaches it), XMR
    comes from the bundled xmrig's HTTP API and GPU power from nvidia-smi —
    both 127.0.0.1-only, so they are gathered over ONE ssh session.

    Returns {port: peakminer-shaped summary}, or {} when unreachable.
    """
    port = config["miners"][0]["port"]

    try:
        request = urllib.request.Request(
            f"http://{config['ip']}:{port}/",
            headers={"Accept": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            srb = json.loads(response.read().decode())
    except Exception:
        # No SRBMiner listener. The rig is only unreachable if ssh also fails:
        # the Kryptex app being closed must not read as "host down".
        return {} if _ssh_ok(config) else None

    algorithm = next(iter(srb.get("algorithms") or []), {})
    hashrate = algorithm.get("hashrate") or {}
    prl_hashrate = number(
        hashrate.get("1min")
        or hashrate.get("1hr")
        or (hashrate.get("gpu") or {}).get("total")
    )
    gpu_stats = next(iter(srb.get("gpu_devices") or []), {})

    model = str(gpu_stats.get("model") or "").replace("_", " ")
    name = " ".join(
        {"rtx": "RTX", "gtx": "GTX", "nvidia": "NVIDIA", "geforce": "GeForce"}.get(
            word.lower(), word.capitalize()
        )
        for word in model.split()
    ) or "GPU"

    # The local-only reads over one ssh session. XMR_END separates the blocks:
    # cmd/curl prints multi-line JSON, nvidia-smi follows as plain text.
    script = "; ".join([
        'cmd /c "curl.exe -s --max-time 3 http://127.0.0.1:12000/2/summary"',
        "echo XMR_END",
        "nvidia-smi -q -d POWER",
        "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits",
    ])
    target = config.get("ssh") or f"{config['user']}@{config['ip']}"
    xmr_hashrate = 0.0
    xmr_shares = 0
    xmr_shares_total = 0
    xmr_algo = ""
    xmr_pool = ""
    xmr_cpu = ""
    power = 0.0
    utilization = 100.0 if prl_hashrate > 0 else 0.0
    try:
        completed = subprocess.run(
            ["ssh", *SSH_OPTIONS, target, script],
            capture_output=True,
            text=True,
            timeout=SSH_TIMEOUT_SECONDS,
            check=False,
        )
        xmr_part, _, nvidia_part = (completed.stdout or "").partition("XMR_END")
        try:
            xmrig = json.loads(xmr_part.strip())
            totals = (xmrig.get("hashrate") or {}).get("total") or []
            if len(totals) >= 2:
                xmr_hashrate = number(totals[1])  # 60-second average
            results = xmrig.get("results") or {}
            xmr_shares = number(results.get("shares_good"))
            xmr_shares_total = number(results.get("shares_total"))
            xmr_algo = str(xmrig.get("algo") or "")
            xmr_pool = str((xmrig.get("connection") or {}).get("pool") or "")
            cpu_brand = str((xmrig.get("cpu") or {}).get("brand") or "").replace(" Processor", "")
            # "AMD Ryzen 9 5900X 12-Core Processor" -> "AMD Ryzen 9 5900X"
            xmr_cpu = " ".join(part for part in cpu_brand.split() if not part.endswith("-Core"))
        except (json.JSONDecodeError, ValueError):
            pass
        powers = parse_nvidia_power(nvidia_part)
        if powers:
            power = powers[0]
        # The utilization CSV prints its bare number on the last line.
        tail = (nvidia_part or "").strip().splitlines()
        if tail and tail[-1].strip().isdigit():
            utilization = number(tail[-1].strip(), utilization)
    except (subprocess.TimeoutExpired, OSError):
        pass

    return {
        port: {
            "version": f"kryptex-app {srb.get('miner_version', '')}".strip(),
            "hashrate": prl_hashrate,
            "gpus": [
                {
                    "id": 0,
                    "name": name,
                    "hashrate": prl_hashrate,
                    "temperature_c": gpu_stats.get("temperature"),
                    "fan_pct": gpu_stats.get("fan_speed_percent"),
                    "utilization_pct": utilization,
                    "power_w": power,
                }
            ],
            # Passed through to the record for the xmrig readout in the panel.
            "xmrigHashrate": xmr_hashrate,
            "xmrigShares": xmr_shares,
            "xmrigSharesTotal": xmr_shares_total,
            "xmrigAlgo": xmr_algo,
            "xmrigPool": xmr_pool,
            "xmrigCpu": xmr_cpu,
        }
    }


def parse_nvidia_power(output):
    """Parse `nvidia-smi -q -d POWER` output.

    Returns a list of average-power-draw values in Watts, indexed by GPU id
    (the order nvidia-smi lists them: 0, 1, ...). Empty when nothing usable.
    """
    powers = []
    # Split on GPU section headers like "GPU 00000000:0F:00.0"
    sections = re.split(r'GPU\s+[0-9a-fA-F:.]+(?:\s*\n|\s*$)', output)
    for section in sections:
        # Find "Power Samples" then "Avg:" within that section
        match = re.search(
            r'Power\s+Samples.*?Avg\s*:\s*([\d.]+)\s*W',
            section,
            re.DOTALL,
        )
        if match:
            try:
                powers.append(float(match.group(1)))
            except ValueError:
                pass
    return powers


def fetch_nvidia_power_local():
    """Local nvidia-smi power readings, or [] when unavailable."""
    try:
        completed = subprocess.run(
            ["nvidia-smi", "-q", "-d", "POWER"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (FileNotFoundError, OSError):
        return []
    return parse_nvidia_power(completed.stdout)


def fetch_nvidia_power_over_ssh(config):
    """Remote nvidia-smi power readings, or [] when unavailable."""
    target = config.get("ssh") or f"{config['user']}@{config['ip']}"
    try:
        completed = subprocess.run(
            ["ssh", *SSH_OPTIONS, target, "nvidia-smi -q -d POWER"],
            capture_output=True,
            text=True,
            timeout=SSH_TIMEOUT_SECONDS,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return []
    return parse_nvidia_power(completed.stdout)


def number(value, fallback=0):
    try:
        result = float(value)
    except (TypeError, ValueError):
        return fallback
    if result != result or result in (float("inf"), float("-inf")):
        return fallback
    return result


def poll_fleet():
    hosts = {}
    miners = []
    fleet_hashrate = 0.0
    fleet_power = 0.0
    gpu_count = 0
    online_count = 0
    configured_count = 0

    # Remote hosts are probed in parallel: each is one ssh round trip, and doing
    # them in sequence would make the panel's refresh wait for the sum.
    remote_summaries = {}
    remote_hosts = [name for name, config in FLEET.items() if not config.get("local")]
    if remote_hosts:
        with ThreadPoolExecutor(max_workers=len(remote_hosts)) as pool:
            # The Kryptex app rig has no /summary to read: it gets its own probe.
            futures = {}
            for name in remote_hosts:
                probe = (
                    query_kryptex_rig
                    if FLEET[name].get("kind") == "kryptex"
                    else query_host_over_ssh
                )
                futures[pool.submit(probe, FLEET[name])] = name
            for future in as_completed(futures):
                name = futures[future]
                try:
                    remote_summaries[name] = future.result()
                except Exception:
                    remote_summaries[name] = None

    # Fetch nvidia-smi power readings in parallel with summaries.
    # Some peakminer builds report power_w: null from their API; nvidia-smi
    # Power Samples Avg is the fallback for those.
    nvidia_power = {}  # host_name -> [power_w_per_gpu]
    local_config = FLEET.get("zephyr")
    if local_config and local_config.get("local"):
        nvidia_power["zephyr"] = fetch_nvidia_power_local()

    remote_power_hosts = [
        name for name in remote_hosts
        if FLEET[name].get("platform") != "windows"
    ]
    if remote_power_hosts:
        with ThreadPoolExecutor(max_workers=len(remote_power_hosts)) as pool:
            futures = {
                pool.submit(fetch_nvidia_power_over_ssh, FLEET[name]): name
                for name in remote_power_hosts
            }
            for future in as_completed(futures):
                name = futures[future]
                try:
                    nvidia_power[name] = future.result()
                except Exception:
                    nvidia_power[name] = []

    for host, config in FLEET.items():
        host_hashrate = 0.0
        host_power = 0.0
        host_online = 0
        probe_result = remote_summaries.get(host)
        host_summaries = probe_result or {}
        # A host ssh answered is reachable even when its miner replied
        # nothing: "miner stopped" and "host down" are different states.
        reachable = config.get("local") or probe_result is not None
        host_nvidia = nvidia_power.get(host, [])

        for i, entry in enumerate(config["miners"]):
            configured_count += 1
            if config.get("local"):
                summary = query_miner(config["ip"], entry["port"])
            else:
                summary = host_summaries.get(entry["port"])
            gpus = (summary or {}).get("gpus") or []
            online = bool(summary and gpus)

            # One peakminer instance drives one GPU, so the first entry is the
            # one this unit owns. Fall back to the summary's own totals when a
            # build reports per-miner figures only.
            gpu = gpus[0] if gpus else {}

            gpu_power = number(gpu.get("power_w",
                summary.get("power_w") if summary else 0))

            # Fallback: miner API reports null power. Use nvidia-smi Power
            # Samples Avg indexed by GPU id.
            gpu_id = gpu.get("id", i)
            if gpu_power == 0 and online and isinstance(gpu_id, int) and gpu_id < len(host_nvidia):
                gpu_power = host_nvidia[gpu_id]

            record = {
                "host": host,
                "ip": config["ip"],
                "local": bool(config.get("local")),
                "user": config.get("user", ""),
                "unit": entry["unit"],
                "port": entry["port"],
                # Lets a row tell "stopped" apart from "we could not ask".
                "hostReachable": bool(reachable),
                # The GPU names itself when it is running; the configured label
                # keeps a stopped miner identifiable.
                "label": gpu.get("name") or entry["label"],
                "powerLimit": number(entry.get("powerLimit")),
                "online": online,
                "hashrate": number(gpu.get("hashrate", summary.get("hashrate") if summary else 0)),
                "power": gpu_power,
                "temp": number(gpu.get("temperature_c")),
                "fan": number(gpu.get("fan_pct")),
                "util": number(gpu.get("utilization_pct")),
            }
            # The Kryptex app rig has no unit to control: the panel hides the
            # pause/resume button when controllable is false.
            record["controllable"] = config.get("control") != "none"
            record["xmrigHashrate"] = number((summary or {}).get("xmrigHashrate"))
            record["xmrigShares"] = number((summary or {}).get("xmrigShares"))
            record["xmrigSharesTotal"] = number((summary or {}).get("xmrigSharesTotal"))
            record["xmrigAlgo"] = (summary or {}).get("xmrigAlgo", "")
            record["xmrigPool"] = (summary or {}).get("xmrigPool", "")
            record["xmrigCpu"] = (summary or {}).get("xmrigCpu", "")
            miners.append(record)

            if online:
                online_count += 1
                host_online += 1
                gpu_count += len(gpus)
                host_hashrate += record["hashrate"]
                host_power += record["power"]

        hosts[host] = {
            "ip": config["ip"],
            "local": bool(config.get("local")),
            # Unreachable is a third state, distinct from "miner stopped": a host
            # we cannot ssh into tells us nothing about its miners.
            "reachable": bool(reachable),
            "connected": host_online > 0,
            "online": host_online,
            "configured": len(config["miners"]),
            "hashrate": host_hashrate,
            "power": host_power,
        }
        fleet_hashrate += host_hashrate
        fleet_power += host_power

    return {
        "schemaVersion": 1,
        "hosts": hosts,
        "miners": miners,
        "totals": {
            "hashrate": fleet_hashrate,
            "power": fleet_power,
            "gpus": gpu_count,
            "online": online_count,
            "configured": configured_count,
        },
    }


CACHE_PATH = f"/run/user/{os.getuid()}/miners-poll-cache.json"
LOCK_PATH = f"/run/user/{os.getuid()}/miners-poll.lock"
CACHE_MAX_AGE_SECONDS = 5.0
SIBLING_WAIT_SECONDS = 16.0


def _read_cache(max_age, born_after=None):
    """Return the cached poll text when it is fresh enough.

    `born_after` additionally requires the cache to be newer than that
    timestamp, so a waiter never mistakes an older cycle's result for the
    sibling poller's fresh one.
    """
    try:
        mtime = os.path.getmtime(CACHE_PATH)
        if time.time() - mtime < max_age and (born_after is None or mtime >= born_after):
            with open(CACHE_PATH, encoding="utf-8") as handle:
                return handle.read()
    except OSError:
        pass
    return None


def _try_lock():
    """Exclusive non-blocking lock; None when another poller already holds it."""
    import fcntl

    fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        os.close(fd)
        return None


def _write_cache(text):
    try:
        tmp = CACHE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, CACHE_PATH)
    except OSError:
        pass


def _audit(payload, millis):
    """Record what this run saw, for multi-instance bar diagnostics.

    Every bar on every monitor owns a Main instance with its own poller, so
    several runs overlap. This log shows what each concurrent run observed.
    """
    try:
        import os as _os

        try:
            parent = open(f"/proc/{_os.getppid()}/comm").read().strip()
        except OSError:
            parent = "?"
        hosts = (payload or {}).get("hosts") or {}
        reach = ",".join(
            f"{name}:{'up' if config.get('reachable') else 'DOWN'}"
            for name, config in hosts.items()
        )
        with open("/tmp/miners-poll-audit.log", "a", encoding="utf-8") as handle:
            handle.write(
                f"{time.strftime('%H:%M:%S')} pid={_os.getpid()} parent={parent} "
                f"wall={millis}ms {reach or 'NO-DATA'}\n"
            )
    except Exception:  # noqa: BLE001 - diagnostics must never break the panel
        pass


if __name__ == "__main__":
    # Every monitor's bar owns a poller and they fire at the same instant.
    # One does the real ssh round trips; the rest wait for its result. That
    # keeps heavy work out of the shell and leaves sshd alone.
    cached = _read_cache(CACHE_MAX_AGE_SECONDS)
    if cached is not None:
        print(cached)
        sys.exit(0)

    started = time.time()
    lock = _try_lock()
    if lock is None:
        deadline = started + SIBLING_WAIT_SECONDS
        while time.time() < deadline:
            time.sleep(0.35)
            cached = _read_cache(SIBLING_WAIT_SECONDS, born_after=started)
            if cached is not None:
                print(cached)
                sys.exit(0)
        # The sibling is stuck; run our own poll rather than starve the panel.

    try:
        payload = poll_fleet()
        _audit(payload, int((time.time() - started) * 1000))
        text = json.dumps(payload, indent=2)
        _write_cache(text)
        print(text)
    except Exception as error:  # noqa: BLE001 - the panel renders the reason
        _audit(None, int((time.time() - started) * 1000))
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
    finally:
        if lock is not None:
            os.close(lock)  # releasing the fd drops the flock
