#!/usr/bin/env python3
"""Poll every fleet miner and print one display-ready JSON record.

The shell panel does no discovery and no flattening of its own: this script
emits a flat `miners` list, per-host rollups, and fleet totals, so the QML
delegates bind straight to it.

Unit names are DATA, not derived. Each host owns its own naming:

  zephyr  Omarchy, units hand-managed in /etc/systemd/system
          -> peakminer-3060ti.service, peakminer-3090.service
  nexus   NixOS, services.peakminer instances
  forge   NixOS, services.peakminer instances
          -> peakminer-<instance-name>.service

Deriving a unit from the API port (the previous behaviour) matched no unit on
any host, so every pause silently did nothing. Keep these strings in step with
the hosts themselves, and never guess them from a port.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
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
        return {}

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
            f'"$(curl -s --max-time 3 http://127.0.0.1:{port}/summary | tr -d "\\n")"'
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
        return {}

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
            futures = {
                pool.submit(query_host_over_ssh, FLEET[name]): name
                for name in remote_hosts
            }
            for future in as_completed(futures):
                name = futures[future]
                try:
                    remote_summaries[name] = future.result()
                except Exception:
                    remote_summaries[name] = {}

    for host, config in FLEET.items():
        host_hashrate = 0.0
        host_power = 0.0
        host_online = 0
        host_summaries = remote_summaries.get(host, {})
        reachable = config.get("local") or bool(host_summaries)

        for entry in config["miners"]:
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
                "power": number(gpu.get("power_w", summary.get("power_w") if summary else 0)),
                "temp": number(gpu.get("temperature_c")),
                "fan": number(gpu.get("fan_pct")),
                "util": number(gpu.get("utilization_pct")),
            }
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


if __name__ == "__main__":
    try:
        print(json.dumps(poll_fleet(), indent=2))
    except Exception as error:  # noqa: BLE001 - the panel renders the reason
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
