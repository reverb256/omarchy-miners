#!/usr/bin/env python3
"""Poll every fleet miner and print one display-ready JSON record.

The shell panel does no discovery and no flattening of its own: this script
emits a flat `miners` list, per-host rollups, and fleet totals, so the QML
delegates bind straight to it. Since 2.2.0 it also carries the GPU view —
`gpus` (per-GPU util/VRAM/power/temp/clocks/owner), `workloads` (LLM, image,
audio, transcodes), `k8s` (GPU nodes + pods) and `models` (on-disk files) —
produced read-only by gpu.py (its own ~20 s cache keeps the ssh fan-out out
of every tick).

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

The two Windows hosts also run a READ-ONLY collector
(windows-collector-contract.md). When a host profile declares
`source: "collector"`, this poller reads the collector's status.json FIRST and
falls back to its ssh read on ANY failure — timeout, non-200, oversized body,
bad JSON, or a payload that fails the §5 validation below. krash2 is
virus-quarantined, so a collector payload is HOSTILE input: nothing from it
reaches a shell, a file path, or a unit name, and a payload that fails
validation is a FAILED PROBE, never data.

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
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

TIMEOUT_SECONDS = 3
SSH_TIMEOUT_SECONDS = 12
HOST_NAME = socket.gethostname().split(".")[0]


def is_local(name, config):
    """An entry marked `local` is read locally ONLY on the host it names.

    The widget runs on more than one machine (zephyr and nexus): on nexus,
    zephyr is remote and must be read over its ssh alias.
    """
    return bool(config.get("local")) and name == HOST_NAME

# SSH_OPTIONS (with the mux path and timeouts) lives in fleet.py now — gpu.py
# shares it, so the master connections are reused across both probes.

# The fleet definition lives in fleet.py so poll.py and miner-control cannot
# drift apart on unit names — two copies of these strings is how a pause ends
# up targeting a unit that does not exist.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fleet import FLEET, SSH_OPTIONS  # noqa: E402
import gpu  # noqa: E402


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


# ---------------------------------------------------------------------------
# Read-only Windows collector (windows-collector-contract.md §4/§5).
#
# krash2 is virus-quarantined: everything it emits is UNTRUSTED input. Every
# rule below exists because of that, and none of it may be relaxed:
#   * the body is capped at 256 KB and the response must be 200, no redirect
#   * collector.host must be THIS host and collector.readonly must be true
#   * JSON types are checked (a string where a number belongs rejects the body)
#   * numbers are clamped to physical ranges, null stays null
#   * strings are truncated to 64 chars with control characters stripped
#   * miners is limited to the ports the host profile declares
# A body that fails any rule is a FAILED PROBE — the caller falls back to the
# ssh read. Nothing here ever reaches a shell, a file path, or a unit name.
# ---------------------------------------------------------------------------

COLLECTOR_MAX_BYTES = 256 * 1024  # response cap (contract §4/§5)
COLLECTOR_TIMEOUT_SECONDS = 2.5   # per-request budget when the profile has none
COLLECTOR_MAX_STRING = 64         # string truncation cap (contract §5)
COLLECTOR_MAX_DEPTH = 12          # nested payloads deeper than this are rejected
# Physical ranges (contract §5). Values arrive hostile: out-of-range numbers
# are CLAMPED into the range, wrong types are rejected, null stays null.
COLLECTOR_NUMBER_RANGES = {
    "temp_c": (0.0, 120.0),
    "fan_pct": (0.0, 100.0),
    "power_w": (0.0, 600.0),
    "power_limit_w": (0.0, 600.0),
    "util_pct": (0.0, 100.0),
    "clocks_sm_mhz": (0.0, 12000.0),
    "vram_used_mb": (0.0, 10 ** 7),
    "vram_total_mb": (0.0, 10 ** 7),
}
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")


def declared_ports(config):
    """Every port this host's profile declares: its row miners plus the
    auxiliary APIs its probe consumes (the kryptex rig's CPU xmrig)."""
    ports = {miner["port"] for miner in config.get("miners") or []}
    ports.update(config.get("auxPorts") or [])
    return ports


def _clean_text(value):
    """One string out of a hostile payload: control chars stripped, capped."""
    if not isinstance(value, str):
        return ""
    return CONTROL_CHARACTERS.sub("", value[: COLLECTOR_MAX_STRING * 4])[:COLLECTOR_MAX_STRING]


def _clean_number(value):
    """JSON null -> None; a finite number -> float; anything else -> ValueError."""
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("not a number")
    result = float(value)
    if result != result or result in (float("inf"), float("-inf")):
        raise ValueError("not a finite number")
    return result


def _sanitize_collector_tree(value, depth=0):
    """Strip control characters + truncate every string in a payload tree.

    Structure and numbers ride through untouched — `miners.<port>` stays the
    miner API's JSON, verbatim, minus the strings a hostile host could weaponise.
    """
    if depth > COLLECTOR_MAX_DEPTH:
        raise ValueError("payload nested too deep")
    if isinstance(value, str):
        return _clean_text(value)
    if isinstance(value, list):
        return [_sanitize_collector_tree(item, depth + 1) for item in value]
    if isinstance(value, dict):
        return {
            (_clean_text(key) if isinstance(key, str) else str(key)):
                _sanitize_collector_tree(item, depth + 1)
            for key, item in value.items()
        }
    return value


def validate_collector_payload(host, config, payload):
    """Contract §5 validation. Returns the normalized payload, or None.

    None means an untrusted host's body failed the rules — a failed probe,
    never data. Unknown top-level keys are dropped; `miners` keeps only the
    ports this host's profile declares.
    """
    if not isinstance(payload, dict):
        return None
    collector = payload.get("collector")
    if not isinstance(collector, dict):
        return None
    if _clean_text(collector.get("host")) != host:
        return None  # a different host's answer is not this host's data
    if collector.get("readonly") is not True:
        return None  # a collector claiming write access breaks the contract
    platform = collector.get("platform")
    if platform is not None and _clean_text(platform) != str(config.get("platform") or "windows"):
        return None

    declared = declared_ports(config)

    raw_miners = payload.get("miners")
    if raw_miners is None:
        raw_miners = {}
    elif not isinstance(raw_miners, dict):
        return None
    miners = {}
    for key, summary in raw_miners.items():
        if not isinstance(key, str) or not key.isdigit() or int(key) not in declared:
            continue  # only the ports the profile declares
        if not isinstance(summary, dict):
            return None
        miners[int(key)] = _sanitize_collector_tree(summary)

    raw_gpus = payload.get("gpus")
    if raw_gpus is None:
        raw_gpus = []
    elif not isinstance(raw_gpus, list):
        return None
    gpus = []
    for entry in raw_gpus:
        if not isinstance(entry, dict):
            return None
        index = entry.get("index")
        if isinstance(index, bool) or not isinstance(index, int) or index < 0:
            return None
        try:
            gpu = {"index": index, "name": _clean_text(entry.get("name"))}
            for key, (low, high) in COLLECTOR_NUMBER_RANGES.items():
                value = _clean_number(entry.get(key))
                gpu[key] = None if value is None else min(max(value, low), high)
        except ValueError:
            return None
        gpus.append(gpu)

    raw_session = payload.get("session")
    session = {"active": False, "user": None, "idle_seconds": None, "state": ""}
    if raw_session is not None:
        if not isinstance(raw_session, dict):
            return None
        active = raw_session.get("active")
        idle = raw_session.get("idle_seconds")
        user = raw_session.get("user")
        state = raw_session.get("state")
        if active is not None and not isinstance(active, bool):
            return None
        if idle is not None and (isinstance(idle, bool) or not isinstance(idle, (int, float))):
            return None
        if user is not None and not isinstance(user, str):
            return None
        if state is not None and not isinstance(state, str):
            return None
        session = {
            "active": active is True,
            "user": _clean_text(user) if user else None,
            "idle_seconds": None if idle is None else min(max(float(idle), 0.0), 10 ** 9),
            "state": _clean_text(state),
        }

    raw_errors = payload.get("errors")
    errors = []
    if raw_errors is not None:
        if not isinstance(raw_errors, list) or any(not isinstance(item, str) for item in raw_errors):
            return None
        errors = [_clean_text(item) for item in raw_errors[:16]]

    return {
        "collector": {
            "host": host,
            "readonly": True,
            "platform": _clean_text(platform),
            "ts": _clean_text(collector.get("ts")),
        },
        "gpus": gpus,
        "miners": miners,
        "session": session,
        "errors": errors,
    }


def fetch_collector_status(url, timeout):
    """GET one collector status.json under the §4 caps. None on any failure.

    A redirect is refused (a hostile host must not aim this probe at another
    service), a body over the cap is refused rather than truncated, and a
    non-200 or unparsable body is refused. Never raises, never partial.
    """
    try:
        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if getattr(response, "status", 0) != 200:
                return None
            if response.geturl() != url:
                return None
            raw = response.read(COLLECTOR_MAX_BYTES + 1)
    except Exception:
        return None
    if len(raw) > COLLECTOR_MAX_BYTES:
        return None
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        return None
    return payload if isinstance(payload, dict) else None


def session_text(session):
    """'in use' / 'idle 42m' / 'none' — the Windows rows' session fact (§5)."""
    if not isinstance(session, dict):
        return ""
    if session.get("active") is True:
        return "in use"
    idle = number(session.get("idle_seconds"), None)
    if idle is not None and idle > 0:
        if idle < 90:
            return f"idle {round(idle)}s"
        if idle < 5400:
            return f"idle {round(idle / 60)}m"
        return f"idle {round(idle / 3600)}h"
    state = str(session.get("state") or "").lower()
    if state.startswith("disc"):
        return "none"
    return ""


def collector_summaries(config, payload):
    """Summaries + extras from a VALIDATED collector payload.

    Handed to the SAME builders the ssh path uses — no parser fork: a
    peakminer host's verbatim `miners.<port>` JSON *is* what its ssh read
    returns, and the Kryptex rig goes through kryptex_summary(). `extras`
    carries the collector-only facts the rows may show (the nvidia-smi power
    fallback list, the user-session text).
    """
    miners = payload["miners"]
    if config.get("kind") == "kryptex":
        port = config["miners"][0]["port"]
        aux = next(iter(config.get("auxPorts") or []), None)
        gpu0 = payload["gpus"][0] if payload["gpus"] else {}
        summaries = kryptex_summary(
            port,
            miners.get(port),
            miners.get(aux) if aux else None,
            number(gpu0.get("power_w"), None),
            gpu0.get("util_pct"),
        )
    else:
        summaries = {
            miner["port"]: miners[miner["port"]]
            for miner in config["miners"]
            if miner["port"] in miners
        }

    power_by_index = {}
    for gpu in payload["gpus"]:
        power = number(gpu.get("power_w"), None)
        if power is not None:
            power_by_index[gpu["index"]] = power
    gpu_power = [
        power_by_index.get(index, 0.0)
        for index in range(max(power_by_index, default=-1) + 1)
    ]
    return summaries, {
        "gpuPower": gpu_power,
        "sessionText": session_text(payload["session"]),
    }


def query_collector(host, config):
    """One host's collector read. (summaries, extras) or None (failed probe).

    Every failure mode — timeout, non-200, oversized body, invalid JSON, a
    payload that fails §5 validation, or a payload shape that trips a parser —
    is a FAILED PROBE: the caller falls back to the ssh read.
    """
    if config.get("source") != "collector":
        return None
    collector = config.get("collector") or {}
    url = collector.get("url")
    if not url:
        return None
    timeout = number(collector.get("timeout"), COLLECTOR_TIMEOUT_SECONDS)
    try:
        payload = fetch_collector_status(url, timeout)
        if payload is None:
            return None
        payload = validate_collector_payload(host, config, payload)
        if payload is None:
            return None
        return collector_summaries(config, payload)
    except Exception:  # noqa: BLE001 - a hostile body must never take the poll down
        return None


def probe_host(name, config, extras_sink=None):
    """One host's summaries: the collector when configured, else the ssh read.

    Fallback order (contract §5): collector first; on ANY failure the ssh
    probe; when both fail the host reads as offline. Correctness of the
    ssh read is unchanged — it is the same code that ran before.
    """
    if config.get("source") == "collector":
        collected = query_collector(name, config)
        if collected is not None:
            summaries, extras = collected
            if extras_sink is not None:
                extras_sink[name] = extras
            return summaries
    if config.get("kind") == "kryptex":
        return query_kryptex_rig(config)
    return query_host_over_ssh(config)


# The metrics broker. miner-telemetry (a DaemonSet on nexus/forge, plus the
# nexus -> zephyr remote-pull unit) feeds VictoriaMetrics; reading the broker
# means no ssh fan-out from every bar for the hosts it covers. j_kro's rule:
# use the proper data pipeline, ssh is only for what the broker does not cover
# (the two Windows boxes).
VM_QUERY_URL = "https://mining.lan/vm/api/v1/query"
VM_FRESH_SECONDS = 240
VM_METRICS = [
    "miner_up",
    "miner_hashrate_hs",
    "miner_power_watts",
    "miner_gpu_hashrate_hs",
    "miner_gpu_power_watts",
    "miner_gpu_temperature_celsius",
    "miner_gpu_fan_percent",
    "miner_gpu_utilization_percent",
    # Share throughput, device-level (no gpu label): the panel row shows
    # shares/hour and falls back to the last-share age, which is how a card
    # that is hashing but no longer getting work accepted becomes visible.
    "miner_share_rate_per_hour",
    "miner_last_share_age_seconds",
]


def query_vm_summaries():
    """Read every broker-covered miner in ONE VictoriaMetrics query.

    Returns {(host, port): peakminer-shaped summary} for series fresh within
    VM_FRESH_SECONDS. An empty dict (broker down, stale series, host absent)
    makes the caller fall through to the ssh/local path — the panel never
    depends on the broker being up, it just prefers it.
    """
    context = ssl._create_unverified_context()  # internal .lan endpoint
    # One label-match query, NOT `metric or metric`: MetricsQL's `or` drops
    # right-side series whose labels (ignoring __name__) collide with a
    # left-side one — miner_gpu_* share their label set, so `or` returned a
    # fraction of the metrics. The regex keeps every series and its name.
    selector = '{__name__=~"%s"}' % "|".join(VM_METRICS)
    url = f"{VM_QUERY_URL}?query={urllib.parse.quote(selector)}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=6, context=context) as response:
        payload = json.loads(response.read().decode())

    now = time.time()
    per_instance = {}
    for series in (payload.get("data") or {}).get("result") or []:
        try:
            timestamp = float(series["value"][0])
            value = float(series["value"][1])
        except (KeyError, IndexError, ValueError):
            continue
        if now - timestamp > VM_FRESH_SECONDS:
            continue  # stale sample: the collector, not the miner, is dead
        metric = series.get("metric") or {}
        instance = metric.get("instance") or ""
        if ":" not in instance:
            continue
        host, _, port_text = instance.rpartition(":")
        if not port_text.isdigit():
            continue
        port = int(port_text)
        entry = per_instance.setdefault(
            (host, port), {"device": {}, "gpus": {}, "model": metric.get("model", "")}
        )
        gpu = metric.get("gpu")
        if gpu is None:
            entry["device"][metric.get("__name__", "")] = value
        else:
            slot = entry["gpus"].setdefault(str(gpu), {})
            slot[metric.get("__name__", "")] = value
            slot.setdefault("__model", metric.get("model", ""))

    summaries = {}
    for (host, port), entry in per_instance.items():
        gpus = []
        for gpu_id, slot in sorted(entry["gpus"].items()):
            gpus.append({
                "id": int(gpu_id) if gpu_id.isdigit() else 0,
                "name": slot.get("__model") or entry.get("model", ""),
                "hashrate": number(slot.get("miner_gpu_hashrate_hs")),
                "power_w": number(slot.get("miner_gpu_power_watts")),
                "temperature_c": number(slot.get("miner_gpu_temperature_celsius")),
                "fan_pct": number(slot.get("miner_gpu_fan_percent")),
                "utilization_pct": number(slot.get("miner_gpu_utilization_percent")),
            })
        gpu_total = sum(gpu["hashrate"] for gpu in gpus)
        summaries[(host, port)] = {
            "hashrate": number(entry["device"].get("miner_hashrate_hs"), gpu_total),
            "power_w": number(entry["device"].get("miner_power_watts")),
            "share_rate_per_hour": number(entry["device"].get("miner_share_rate_per_hour")),
            "last_share_age_seconds": number(entry["device"].get("miner_last_share_age_seconds")),
            "gpus": gpus,
        }
    return summaries


def broker_covered(vm_summaries, deploy_replicas):
    """Hosts whose live (non-paused) ports all have fresh broker data.

    Returns {host: {port: summary}}. A host qualifies only as a whole: a
    partial answer would mix broker and ssh reads for one host, which is how
    a row ends up half-updated. Paused ports (replicas == 0) need no live
    data — the row renders from user intent alone.
    """
    covered = {}
    for host, config in FLEET.items():
        if not config["miners"]:
            continue
        live_ports = {}
        complete = True
        for miner in config["miners"]:
            k8s = miner.get("k8s") or {}
            if k8s and deploy_replicas.get(k8s.get("deploy", "")) == 0:
                continue  # paused: no live data required
            if (host, miner["port"]) in vm_summaries:
                live_ports[miner["port"]] = vm_summaries[(host, miner["port"])]
            else:
                complete = False
        if complete:
            covered[host] = live_ports
    return covered


KRYPTEX_THROTTLE_RATIO = 0.5  # 1min under half its sustained rate = throttled


def kryptex_summary(port, srb, xmrig, power, utilization):
    """The Kryptex row summary from verbatim miner API payloads.

    Shared by the ssh probe and the collector path — one parser, two
    transports, so a row cannot depend on which one answered. `srb` is
    SRBMiner's `/` JSON (None when the GPU miner is absent), `xmrig` its
    `/1/summary` or `/2/summary` JSON (None when the CPU miner is absent).

    Shape guards sit on every sub-object: on the collector path this JSON is
    hostile input (krash2 is quarantined), so a wrong-shaped field degrades
    to "no reading" instead of turning into an exception.
    """
    if not isinstance(srb, dict):
        srb = None
    if not isinstance(xmrig, dict):
        xmrig = None

    algorithm = next(iter((srb or {}).get("algorithms") or []), {})
    if not isinstance(algorithm, dict):
        algorithm = {}
    hashrate = algorithm.get("hashrate")
    if not isinstance(hashrate, dict):
        hashrate = {}
    gpu_window = hashrate.get("gpu")
    gpu_window = gpu_window.get("total") if isinstance(gpu_window, dict) else None
    # srb is None when the Kryptex GPU miner is absent (krash3 may run xmrig
    # only). Fall through with zeroed PRL figures so the xmrig readout still
    # populates.
    prl_hashrate = number(hashrate.get("1min") or hashrate.get("1hr") or gpu_window)
    gpu_stats = next(iter((srb or {}).get("gpu_devices") or []), {})
    if not isinstance(gpu_stats, dict):
        gpu_stats = {}

    model = str(gpu_stats.get("model") or "").replace("_", " ")
    name = " ".join(
        {"rtx": "RTX", "gtx": "GTX", "nvidia": "NVIDIA", "geforce": "GeForce"}.get(
            word.lower(), word.capitalize()
        )
        for word in model.split()
    ) or "GPU"

    # The SRB 1min/1hr/6hr windows: when the 1-minute figure has fallen to
    # half the sustained rate the miner is being THROTTLED — the gaming-rig
    # signal (the box's user is on it and the card is shared).
    windows = {}
    for key in ("1min", "1hr", "6hr"):
        value = number(hashrate.get(key), None)
        if value is not None:
            windows[key] = value
    sustained = windows.get("1hr") or windows.get("6hr") or 0.0
    short = windows.get("1min") or 0.0
    ratio = short / sustained if (short and sustained) else None
    throttled = ratio is not None and ratio < KRYPTEX_THROTTLE_RATIO

    xmr_hashrate = 0.0
    xmr_shares = 0
    xmr_shares_total = 0
    xmr_algo = ""
    xmr_pool = ""
    xmr_cpu = ""
    if xmrig:
        hashrate_block = xmrig.get("hashrate")
        totals = hashrate_block.get("total") if isinstance(hashrate_block, dict) else None
        if isinstance(totals, list) and len(totals) >= 2:
            xmr_hashrate = number(totals[1])  # 60-second average
        results = xmrig.get("results")
        if not isinstance(results, dict):
            results = {}
        connection = xmrig.get("connection")
        if not isinstance(connection, dict):
            connection = {}
        cpu = xmrig.get("cpu")
        if not isinstance(cpu, dict):
            cpu = {}
        xmr_shares = number(results.get("shares_good"))
        xmr_shares_total = number(results.get("shares_total"))
        xmr_algo = str(xmrig.get("algo") or "")
        xmr_pool = str(connection.get("pool") or "")
        cpu_brand = str(cpu.get("brand") or "").replace(" Processor", "")
        # "AMD Ryzen 9 5900X 12-Core Processor" -> "AMD Ryzen 9 5900X"
        xmr_cpu = " ".join(part for part in cpu_brand.split() if not part.endswith("-Core"))

    if utilization is None:
        utilization = 100.0 if prl_hashrate > 0 else 0.0

    return {
        port: {
            "version": f"kryptex-app {(srb or {}).get('miner_version', '')}".strip(),
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
            # The throttle signal and its windows ride the summary so the
            # record builder passes them through for both transports.
            "srbWindows": windows,
            "throttled": throttled,
            "throttleRatio": ratio,
        }
    }


def query_kryptex_rig(config):
    """Read the Kryptex app rig (krash3) over the LAN + one ssh session.

    Not peakminer, so there is no /summary to read: PRL comes from the bundled
    SRBMiner's HTTP API (it binds all interfaces, so the LAN reaches it), XMR
    comes from the bundled xmrig's HTTP API and GPU power from nvidia-smi —
    both 127.0.0.1-only, so they are gathered over ONE ssh session.

    Returns {port: peakminer-shaped summary}, or None when unreachable.
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
        # No SRBMiner listener. If ssh also fails, the host is truly down.
        if not _ssh_ok(config):
            return None
        # SRBMiner is gone but the host reachable: krash3 may now run xmrig
        # only (the Kryptex app GPU miner was removed). Fall through to gather
        # xmrig + nvidia-smi data so the row stays informative.
        srb = None

    # The local-only reads over one ssh session. XMR_END separates the blocks:
    # cmd/curl prints multi-line JSON, nvidia-smi follows as plain text.
    script = "; ".join([
        'cmd /c "curl.exe -s --max-time 3 http://127.0.0.1:12000/2/summary"',
        "echo XMR_END",
        "nvidia-smi -q -d POWER",
        "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits",
    ])
    target = config.get("ssh") or f"{config['user']}@{config['ip']}"
    xmrig = None
    power = 0.0
    utilization = None
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
        except (json.JSONDecodeError, ValueError):
            xmrig = None
        powers = parse_nvidia_power(nvidia_part)
        if powers:
            power = powers[0]
        # The utilization CSV prints its bare number on the last line.
        tail = (nvidia_part or "").strip().splitlines()
        if tail and tail[-1].strip().isdigit():
            utilization = number(tail[-1].strip(), None)
    except (subprocess.TimeoutExpired, OSError):
        pass

    return kryptex_summary(port, srb, xmrig, power, utilization)


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


def query_k8s_deploy_replicas():
    """Spec replicas per mining Deployment — the USER-INTENT signal.

    On a k3s miner, replicas == 0 is a DELIBERATE pause (the panel's pause
    control scales to zero; ArgoCD carries ignoreDifferences so it sticks).
    Anything else with no /summary is a failure. Returns {deploy: replicas};
    {} when kubectl is unavailable or the API does not answer — the state
    then falls back to online/offline, never a fake "paused".
    """
    kubectl = shutil.which("kubectl")
    if not kubectl:
        candidates = sorted(Path.home().glob(".local/share/mise/installs/kubectl/*/kubectl"))
        if candidates:
            kubectl = str(candidates[-1])
        else:
            for fallback in ("/usr/local/bin/kubectl", "/usr/bin/kubectl"):
                if os.path.exists(fallback):
                    kubectl = fallback
                    break
    if not kubectl:
        return {}
    env = dict(os.environ)
    env.setdefault("KUBECONFIG", str(Path.home() / ".kube" / "config"))
    try:
        completed = subprocess.run(
            [kubectl, "-n", "mining", "get", "deploy", "-o", "json"],
            capture_output=True, text=True, timeout=6, check=False, env=env,
        )
    except (subprocess.TimeoutExpired, OSError):
        return {}
    if completed.returncode != 0:
        return {}
    replicas = {}
    try:
        for item in json.loads(completed.stdout).get("items", []):
            replicas[item["metadata"]["name"]] = item.get("spec", {}).get("replicas", 1)
    except (ValueError, KeyError):
        return {}
    return replicas


def miner_record(host, config, entry, index, summary, reachable, paused,
                 host_nvidia, session_text=""):
    """One display-ready miner row from its summary.

    The record cannot tell which transport produced the summary — that is the
    point (contract §5): the ssh probes and the collector path hand over the
    SAME shapes, so this builder is shared, never forked. Shape guards keep a
    hostile collector payload (krash2 is quarantined) from becoming an
    exception: anything unusable degrades to a row that says so.
    """
    if not isinstance(summary, dict):
        summary = None
    gpus = summary.get("gpus") if summary else None
    if not isinstance(gpus, list):
        gpus = []
    online = bool(summary and gpus)

    if paused:
        state = "paused"
    elif online:
        state = "mining"
    elif reachable:
        state = "offline"
    else:
        state = "unknown"

    # One peakminer instance drives one GPU, so the first entry is the one
    # this unit owns. Fall back to the summary's own totals when a build
    # reports per-miner figures only.
    gpu_entry = gpus[0] if gpus and isinstance(gpus[0], dict) else {}

    gpu_power = number(gpu_entry.get("power_w",
        summary.get("power_w") if summary else 0))

    # Fallback: miner API reports null power. Use nvidia-smi Power Samples
    # Avg indexed by GPU id — gathered over ssh, or carried by a §5-validated
    # collector payload.
    gpu_id = gpu_entry.get("id", index)
    if gpu_power == 0 and online and isinstance(gpu_id, int) and gpu_id < len(host_nvidia):
        gpu_power = host_nvidia[gpu_id]

    k8s = entry.get("k8s") or {}
    record = {
        "host": host,
        "ip": config["ip"],
        "local": is_local(host, config),
        "user": config.get("user", ""),
        "unit": entry["unit"],
        "port": entry["port"],
        # Lets a row tell "stopped" apart from "we could not ask".
        "hostReachable": bool(reachable),
        # The GPU names itself when it is running; the configured label
        # keeps a stopped miner identifiable.
        "label": gpu_entry.get("name") or entry["label"],
        "powerLimit": number(entry.get("powerLimit")),
        "online": online,
        # paused = user intent (deployment scaled to 0); state folds
        # both signals for everything that reads the JSON.
        "paused": paused,
        # managed = a k3s Deployment owns this miner, so its spec is
        # the DESIRED state the panel's checkbox shows (checked =
        # replicas != 0, even while a transient fault is being
        # healed). Unmanaged rows fall back to live state.
        "managed": bool(k8s),
        "state": state,
        "hashrate": number(gpu_entry.get("hashrate", summary.get("hashrate") if summary else 0)),
        "power": gpu_power,
        "temp": number(gpu_entry.get("temperature_c")),
        "fan": number(gpu_entry.get("fan_pct")),
        "util": number(gpu_entry.get("utilization_pct")),
    }
    # The Kryptex app rig has no unit to control: the panel hides the
    # pause/resume button when controllable is false.
    record["controllable"] = config.get("control") != "none"
    # Share throughput rides the same summary as the hashrate: the
    # broker covers the k3s/host boxes, the ssh paths (the two Windows
    # rigs) do not report it — 0 there, and the row says so rather
    # than inventing a rate.
    record["shareRatePerHour"] = number((summary or {}).get("share_rate_per_hour"))
    record["lastShareAgeSec"] = number((summary or {}).get("last_share_age_seconds"))
    record["xmrigHashrate"] = number((summary or {}).get("xmrigHashrate"))
    record["xmrigShares"] = number((summary or {}).get("xmrigShares"))
    record["xmrigSharesTotal"] = number((summary or {}).get("xmrigSharesTotal"))
    record["xmrigAlgo"] = (summary or {}).get("xmrigAlgo", "")
    record["xmrigPool"] = (summary or {}).get("xmrigPool", "")
    record["xmrigCpu"] = (summary or {}).get("xmrigCpu", "")
    # Collector-only facts, when the host's payload carries them: the user
    # session (the rows' tooltip) and the SRB window ratio that flags a miner
    # running throttled below its own sustained rate.
    record["sessionText"] = session_text
    record["throttled"] = (summary or {}).get("throttled") is True
    record["srbWindows"] = (summary or {}).get("srbWindows") or {}
    return record


def poll_fleet():
    hosts = {}
    miners = []
    fleet_hashrate = 0.0
    fleet_power = 0.0
    gpu_count = 0
    online_count = 0
    configured_count = 0
    paused_count = 0

    # Broker first: the miner-telemetry pipeline (VictoriaMetrics) is the
    # proper data source. ssh probes remain only for hosts the broker does
    # not cover (the two Windows boxes), and as fallback when it is down,
    # stale, or a host is missing from it.
    try:
        vm_summaries = query_vm_summaries()
    except Exception:
        vm_summaries = {}
    # Fresh user-intent state: which k3s miner Deployments are scaled to zero.
    deploy_replicas = query_k8s_deploy_replicas()
    covered = broker_covered(vm_summaries, deploy_replicas)

    # Remote hosts are probed in parallel: each is one ssh round trip, and doing
    # them in sequence would make the panel's refresh wait for the sum.
    remote_summaries = {}
    collector_extras = {}
    remote_hosts = [
        name for name, config in FLEET.items()
        if not is_local(name, config) and name not in covered
    ]
    if remote_hosts:
        with ThreadPoolExecutor(max_workers=len(remote_hosts)) as pool:
            # probe_host picks the transport per host: the READ-ONLY collector
            # first when the profile declares one (falling back to ssh on any
            # failure), then the ssh read — peakminer's /summary, or the
            # Kryptex app rig's own probe.
            futures = {
                pool.submit(probe_host, name, FLEET[name], collector_extras): name
                for name in remote_hosts
            }
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
    local_config = FLEET.get(HOST_NAME)
    if local_config and is_local(HOST_NAME, local_config):
        nvidia_power[HOST_NAME] = fetch_nvidia_power_local()

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

    # A collector payload's nvidia-smi facts (§5-validated) take the same
    # fallback slot the ssh Power Samples read fills on the Linux hosts.
    for name, extras in collector_extras.items():
        gpu_power = extras.get("gpuPower") or []
        if gpu_power:
            nvidia_power[name] = gpu_power

    for host, config in FLEET.items():
        host_hashrate = 0.0
        host_power = 0.0
        host_online = 0
        host_paused = 0
        probe_result = covered.get(host) or remote_summaries.get(host)
        host_summaries = probe_result or {}
        # A host ssh answered is reachable even when its miner replied
        # nothing: "miner stopped" and "host down" are different states.
        reachable = is_local(host, config) or probe_result is not None
        host_nvidia = nvidia_power.get(host, [])
        session_state = (collector_extras.get(host) or {}).get("sessionText", "")

        for i, entry in enumerate(config["miners"]):
            configured_count += 1
            vm_host = covered.get(host)
            if vm_host is not None:
                summary = vm_host.get(entry["port"])
            elif is_local(host, config):
                summary = query_miner(config["ip"], entry["port"])
            else:
                summary = host_summaries.get(entry["port"])

            # User-intent state, from the k3s Deployment spec: replicas == 0
            # is a DELIBERATE pause (the panel's Pause control writes that),
            # never a failure. Falls back to online/offline when kubectl
            # cannot answer.
            k8s = entry.get("k8s") or {}
            paused = bool(k8s) and deploy_replicas.get(k8s.get("deploy", "")) == 0

            # One record builder for every transport (contract §5): the
            # collector and the ssh probes hand over the same shapes.
            record = miner_record(host, config, entry, i, summary, reachable,
                                  paused, host_nvidia, session_text=session_state)
            miners.append(record)

            if record["online"]:
                online_count += 1
                host_online += 1
                summary_gpus = summary.get("gpus") if isinstance(summary, dict) else None
                gpu_count += len(summary_gpus) if isinstance(summary_gpus, list) else 0
                host_hashrate += record["hashrate"]
                host_power += record["power"]

            if record["paused"]:
                paused_count += 1
                host_paused += 1

        hosts[host] = {
            "ip": config["ip"],
            "local": is_local(host, config),
            # Unreachable is a third state, distinct from "miner stopped": a host
            # we cannot ssh into tells us nothing about its miners.
            "reachable": bool(reachable),
            "connected": host_online > 0,
            "online": host_online,
            "paused": host_paused,
            "configured": len(config["miners"]),
            "hashrate": host_hashrate,
            "power": host_power,
        }
        fleet_hashrate += host_hashrate
        fleet_power += host_power

    # GPU + workload view: read-only, cached ~20 s inside gpu.py. A failure
    # here must never take the miners down with it — the panel renders the
    # sections it gets.
    try:
        gpu_view = gpu.collect()
    except Exception as error:  # noqa: BLE001 - additive section, never fatal
        gpu_view = {
            "gpus": [], "gpuHosts": {},
            "workloads": {"llm": [], "image": [], "audio": [], "transcode": []},
            "k8s": {"ok": False, "nodes": [], "pods": [], "deploys": {}},
            "models": [],
            "totals": {},
            "error": str(error),
        }

    totals = {
        "hashrate": fleet_hashrate,
        "power": fleet_power,
        "gpus": gpu_count,
        "online": online_count,
        "paused": paused_count,
        "configured": configured_count,
    }
    # GPU totals carry their own names (gpuTotal, modelsLoaded, …); "gpus"
    # above stays the mining-GPU count the hero has always shown.
    totals.update(gpu_view.get("totals") or {})

    return {
        "schemaVersion": 2,
        "hosts": hosts,
        "miners": miners,
        "gpus": gpu_view.get("gpus") or [],
        "gpuHosts": gpu_view.get("gpuHosts") or {},
        "workloads": gpu_view.get("workloads") or {},
        "k8s": gpu_view.get("k8s") or {},
        "models": gpu_view.get("models") or [],
        "totals": totals,
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
