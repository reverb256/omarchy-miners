#!/usr/bin/env python3
"""Read every GPU, model server, and model file across the fleet. READ-ONLY.

Companion to poll.py: this module observes, it never controls. It probes:

  * GPUs      nvidia-smi (Linux and Windows) + amdgpu sysfs readings (Linux)
  * workloads LLM endpoints (llama.cpp / llama-swap / LM Studio / ollama),
              ComfyUI /queue, voice-models /health, the yue2 deployment, and
              Jellyfin transcodes (jellyfin-ffmpeg process count on the host)
  * k8s       GPU allocatable per node + GPU pods — `kubectl get`, read-only
  * models    on-disk GGUF/safetensors/ckpt files per host (bounded find)

One ssh session per host per refresh (the poll.py pattern; loopback services
are curled ON the host, same rule as the miner APIs). Everything is cached on
disk — ~20 s for the live sections, ~300 s for the model-file scan — so every
bar instance on every monitor can call this cheaply, and forge (15 GB RAM)
never sees a heavy scan more than once per five minutes.

The fleet definition lives in fleet.py (GPU_FLEET); this module holds no host
names of its own. A per-host probe is one shell script with `@SECT:<name>`
markers; the script only reads (nvidia-smi queries, sysfs cats, curl GETs,
find listings) — there is no control verb anywhere in this file.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fleet import GPU_FLEET, SSH_OPTIONS  # noqa: E402

HOST_NAME = socket.gethostname().split(".")[0]
SSH_TIMEOUT_SECONDS = 30
GPU_TTL_SECONDS = 20.0
MODELS_TTL_SECONDS = 300.0

_CACHE_DIR = f"/run/user/{os.getuid()}"
if not os.path.isdir(_CACHE_DIR):
    _CACHE_DIR = "/tmp"
GPU_CACHE_PATH = f"{_CACHE_DIR}/gpufleet-gpu-cache.json"
MODELS_CACHE_PATH = f"{_CACHE_DIR}/gpufleet-models-cache.json"
LOCK_PATH = f"{_CACHE_DIR}/gpufleet.lock"

# nvidia-smi --query-gpu fields, in emit order. `uuid` is the join key for
# --query-compute-apps (which names the process that owns each GPU).
NVIDIA_FIELDS = [
    "index", "name", "uuid", "utilization.gpu", "memory.used", "memory.total",
    "power.draw", "power.limit", "temperature.gpu", "fan.speed",
    "clocks.current.graphics", "clocks.current.memory",
]

# Process-name needles -> the label shown as the GPU's owner. First hit wins;
# the fallback is the process basename.
APP_MARKERS = [
    ("peakminer", "miner"),
    ("xmrig", "miner"),
    ("srbminer", "miner"),
    ("pearlhash", "miner"),
    ("llama-server", "llama.cpp"),
    ("llama-swap", "llama.cpp"),
    ("llama", "llama.cpp"),
    ("stabilitymatrix", "ComfyUI"),
    ("/opt/conda", "voice-models"),
    ("llmster", "LM Studio"),
    ("lm studio", "LM Studio"),
    ("ollama", "ollama"),
    ("vesktop", "desktop (vesktop)"),
    ("chromium", "browser"),
    ("chrome", "browser"),
    ("ffmpeg", "transcode"),
]

# Desktop/driver housekeeping processes that nvidia-smi lists on Windows but
# that never own a workload — filtered out of the owner column.
APP_SKIP = [
    "dwm.exe", "logonui", "nvidia overlay", "crossdeviceresume", "nvcontainer",
    "explorer.exe", "searchhost", "textinputhost", "runtimebroker",
    "shellexperiencehost", "startmenuexperiencehost", "widgets.exe", "lockapp",
    "msedgewebview2", "phoneexperiencehost", "tabtip", "applicationframehost",
    "systemsettings.exe", "shellhost", "steamwebhelper", "textinputhost",
]

# PCI id -> a short name for the amdgpu cards (product_name is empty on these
# builds; both the RX 5600 and 5700 families report 1002:731f).
AMD_PCI_NAMES = {
    "1002:731f": "AMD Radeon RX 5600/5700 (Navi 10)",
    "1002:73ff": "AMD Radeon RX 6600 (Navi 23)",
}


def is_local(name, config):
    """An entry marked `local` is read locally ONLY on the host it names.

    The widget runs on more than one machine (zephyr and nexus): on nexus,
    zephyr is remote and must be read over its ssh alias.
    """
    return bool(config.get("local")) and name == HOST_NAME


def number(value, fallback=None):
    try:
        result = float(value)
    except (TypeError, ValueError):
        return fallback
    if result != result or result in (float("inf"), float("-inf")):
        return fallback
    return result


def _int(value, fallback=None):
    result = number(value)
    return int(result) if result is not None else fallback


def _basename(path):
    return str(path or "").replace("\\", "/").rsplit("/", 1)[-1]


# ---------------------------------------------------------------------------
# probe scripts (one ssh session per host)
# ---------------------------------------------------------------------------

def _linux_script(config, include_models):
    """The full per-host probe as one bash script (read-only)."""
    parts = []

    # ---- NVIDIA ----
    fields = ",".join(NVIDIA_FIELDS)
    parts.append('echo "@SECT:NVIDIA"')
    parts.append(
        f'nvidia-smi --query-gpu={fields} --format=csv,noheader,nounits 2>/dev/null'
    )
    parts.append('echo "@SECT:NVIDIA_APPS"')
    parts.append(
        'nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory '
        '--format=csv,noheader,nounits 2>/dev/null'
    )
    if config.get("powerFallback"):
        parts.append('echo "@SECT:NVIDIA_POWER"')
        parts.append("nvidia-smi -q -d POWER 2>/dev/null")

    # ---- AMD (amdgpu sysfs; no rocm-smi needed) ----
    parts.append('echo "@SECT:AMD"')
    parts.append(
        'for card in /sys/class/drm/card[0-9]; do\n'
        '  dev="$card/device"\n'
        '  [ -e "$dev/gpu_busy_percent" ] || continue\n'
        '  pci=$(sed -n "s/^PCI_ID=//p" "$dev/uevent" 2>/dev/null)\n'
        '  busy=$(cat "$dev/gpu_busy_percent" 2>/dev/null)\n'
        '  vu=$(cat "$dev/mem_info_vram_used" 2>/dev/null)\n'
        '  vt=$(cat "$dev/mem_info_vram_total" 2>/dev/null)\n'
        '  temp=""; pwr=""; pwm=""\n'
        '  for h in "$dev"/hwmon/hwmon*; do\n'
        '    if [ -r "$h/temp1_input" ]; then\n'
        '      temp=$(cat "$h/temp1_input" 2>/dev/null)\n'
        '      pwr=$(cat "$h/power1_average" 2>/dev/null)\n'
        '      pwm=$(cat "$h/pwm1" 2>/dev/null)\n'
        '      break\n'
        '    fi\n'
        '  done\n'
        '  echo "$(basename "$card")|$pci|$busy|$vu|$vt|$temp|$pwr|$pwm"\n'
        'done 2>/dev/null'
    )

    # ---- transcode count (the media host) ----
    if config.get("transcodes"):
        parts.append('echo "@SECT:FFMPEG"')
        parts.append("pgrep -x ffmpeg 2>/dev/null | wc -l")

    # ---- workload endpoints (loopback curls, ON the host) ----
    # Every curl is followed by an explicit newline: curl writes no trailing
    # newline, and a marker glued to the JSON (…}"#PROPS") stops splitting
    # correctly and swallows every later section.
    for index, probe in enumerate(config.get("workloads") or []):
        ptype = probe.get("type")
        name = probe.get("name", ptype or "?")
        port = probe.get("port")
        parts.append('echo "@SECT:WL{0}"'.format(index))
        parts.append('echo "#NAME"')
        parts.append(f'echo "{name}"')

        def curl(url):
            return [f'curl -s --connect-timeout 1 --max-time 2 "{url}" 2>/dev/null', 'echo ""']

        if ptype == "llama_server":
            parts.append('echo "#HEALTH"')
            parts += curl(f"http://127.0.0.1:{port}/health")
            parts.append('echo "#PROPS"')
            parts += curl(f"http://127.0.0.1:{port}/props")
            parts.append('echo "#SLOTS"')
            parts += curl(f"http://127.0.0.1:{port}/slots")
        elif ptype == "llama_swap":
            parts.append('echo "#RUNNING"')
            parts += curl(f"http://127.0.0.1:{port}/running")
            parts.append('echo "#MODELS"')
            parts += curl(f"http://127.0.0.1:{port}/v1/models")
        elif ptype == "lmstudio":
            parts.append('echo "#MODELS"')
            parts += curl(f"http://127.0.0.1:{port}/api/v0/models")
        elif ptype == "ollama":
            parts.append('echo "#PS"')
            parts += curl(f"http://127.0.0.1:{port}/api/ps")
            parts.append('echo "#TAGS"')
            parts += curl(f"http://127.0.0.1:{port}/api/tags")
        elif ptype == "comfyui":
            parts.append('echo "#QUEUE"')
            parts += curl(f"http://127.0.0.1:{port}/queue")
            parts.append('echo "#STATS"')
            parts += curl(f"http://127.0.0.1:{port}/system_stats")
        elif ptype == "http":
            path = probe.get("healthPath", "/")
            parts.append('echo "#HEALTH"')
            parts += curl(f"http://127.0.0.1:{port}{path}")
        elif ptype == "k8s_deploy":
            # Only meaningful while the deployment runs; a dead ClusterIP
            # rejects instantly, so this is cheap when the service is asleep.
            svc_ip = probe.get("serviceIP")
            if svc_ip:
                parts.append('echo "#SVC"')
                parts += curl(f"http://{svc_ip}:{port}/")
        elif ptype == "transcodes":
            parts.append('echo "#COUNT"')
            parts.append("pgrep -x ffmpeg 2>/dev/null | wc -l")

    # ---- model files (bounded; only on model-refresh cycles) ----
    if include_models:
        for index, root in enumerate(config.get("models") or []):
            path = root.get("path")
            depth = _int(root.get("depth"), 3)
            parts.append(f'echo "@SECT:MODELS:{index}"')
            parts.append(
                f"find -L {path} -maxdepth {depth} -type f "
                r"\( -name '*.gguf' -o -name '*.safetensors' -o -name '*.ckpt' -o -name '*.pt' \) "
                "-size +20M -printf '%s\\t%p\\n' 2>/dev/null | sort -rn | head -40"
            )

    return "\n".join(parts)


def _windows_script(config):
    """The Windows probe: one cmd /c chain (ssh runs PowerShell there).

    `echo.` after each command forces a newline so the next `@SECT:` marker
    cannot glue onto command output (nvidia-smi writes no trailing newline in
    some reporters).
    """
    fields = ",".join(NVIDIA_FIELDS)
    parts = [
        'echo @SECT:NVIDIA',
        f"nvidia-smi --query-gpu={fields} --format=csv,noheader,nounits",
        "echo.",
        'echo @SECT:NVIDIA_APPS',
        "nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory "
        "--format=csv,noheader,nounits",
        "echo.",
    ]
    if config.get("powerFallback"):
        parts += ['echo @SECT:NVIDIA_POWER',
                  "nvidia-smi -q -d POWER", "echo."]
    for index, probe in enumerate(config.get("workloads") or []):
        # No workload probes on the Windows boxes today; keep the marker so
        # the parser stays uniform if one is ever added.
        parts += [f'echo @SECT:WL{index}', "echo."]
    script = " & ".join(f"({piece})" for piece in parts)
    return f'cmd /c "{script}"'


def _run_probe(name, config, include_models):
    """Run one host's probe; returns (host, sections-or-None, reachable)."""
    if config.get("platform") == "windows":
        script = _windows_script(config)
    else:
        script = _linux_script(config, include_models)

    if is_local(name, config) and config.get("platform") != "windows":
        try:
            completed = subprocess.run(
                ["bash", "-c", script],
                capture_output=True, text=True, timeout=SSH_TIMEOUT_SECONDS, check=False,
            )
        except (subprocess.TimeoutExpired, OSError):
            return name, None, False
        return name, _split_sections(completed.stdout or ""), True

    target = config.get("ssh") or f"{config['user']}@{config['ip']}"
    try:
        completed = subprocess.run(
            ["ssh", *SSH_OPTIONS, target, script],
            capture_output=True, text=True, timeout=SSH_TIMEOUT_SECONDS, check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return name, None, False
    # ssh's convention: 255 is the connection/auth layer failing.
    if completed.returncode == 255:
        return name, None, False
    return name, _split_sections(completed.stdout or ""), True


def _split_sections(text):
    """Split probe output on `@SECT:<name>` marker lines."""
    sections = {}
    current = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("@SECT:"):
            current = line[len("@SECT:"):].strip()
            sections[current] = []
            continue
        if current is not None:
            sections[current].append(line)
    return sections


def _sub(section, marker):
    """Lines between inner `#MARKER` markers inside one section."""
    lines = section or []
    out = []
    inside = False
    for line in lines:
        if line.startswith("#"):
            if inside:
                break
            inside = line.upper() == f"#{marker}".upper()
            continue
        if inside:
            out.append(line)
    return out


# ---------------------------------------------------------------------------
# parsers
# ---------------------------------------------------------------------------

def parse_nvidia(section, apps_lines):
    """nvidia-smi CSV -> GPU records with per-GPU process attribution."""
    by_uuid = {}
    gpus = []
    for line in section or []:
        fields = [part.strip() for part in line.split(",")]
        if len(fields) < len(NVIDIA_FIELDS) or not fields[0].isdigit():
            continue
        page = dict(zip(NVIDIA_FIELDS, fields))
        record = {
            "index": _int(page["index"]),
            "name": page["name"],
            "uuid": page["uuid"],
            "util": number(page["utilization.gpu"]),
            "vramUsed": _int(page["memory.used"]),
            "vramTotal": _int(page["memory.total"]),
            "power": number(page["power.draw"]),
            "powerLimit": number(page["power.limit"]),
            "temp": number(page["temperature.gpu"]),
            "fan": number(page["fan.speed"]),
            "clockCore": _int(page["clocks.current.graphics"]),
            "clockMem": _int(page["clocks.current.memory"]),
            "apps": [],
        }
        gpus.append(record)
        by_uuid[record["uuid"]] = record

    for line in apps_lines or []:
        fields = [part.strip() for part in line.split(",")]
        if len(fields) < 4:
            continue
        gpu = by_uuid.get(fields[0])
        if gpu is None:
            continue
        raw_name = (fields[2] or "").lower()
        if any(needle in raw_name for needle in APP_SKIP):
            continue
        label = _app_label(fields[2])
        gpu["apps"].append({
            "label": label,
            "memMiB": _int(fields[3], 0),
            # A marker-matched label names a real workload; the fallback is
            # some other desktop process (kept only when it holds memory).
            "known": label != _basename(fields[2])[:28],
        })
    return gpus


def _app_label(process_name):
    lowered = (process_name or "").lower()
    for needle, label in APP_MARKERS:
        if needle in lowered:
            return label
    return _basename(process_name)[:28] or "process"


def owner_from_apps(apps):
    """'miner, voice-models' — real workload labels first, then, only when no
    workload matched, memory-holding desktop processes."""
    if not apps:
        return ""
    known = [app for app in apps if app.get("known")]
    picked = known or [
        app for app in apps if (app.get("memMiB") or 0) >= 64
    ]
    if not picked:
        return ""
    totals = {}
    for app in picked:
        totals[app["label"]] = totals.get(app["label"], 0) + (app["memMiB"] or 0)
    ordered = sorted(totals.items(), key=lambda item: -item[1])
    return ", ".join(label for label, _ in ordered[:3])


def parse_power_samples(text):
    """nvidia-smi -q -d POWER -> per-GPU Power Samples average watts."""
    powers = []
    sections = re.split(r"GPU\s+[0-9a-fA-F:.]+(?:\s*\n|\s*$)", text or "")
    for section in sections:
        match = re.search(r"Power\s+Samples.*?Avg\s*:\s*([\d.]+)\s*W", section, re.DOTALL)
        if match:
            value = number(match.group(1))
            if value is not None:
                powers.append(value)
    return powers


def parse_amd(lines, host, config):
    """amdgpu sysfs lines (`card|pci|busy|vramUsed|vramTotal|temp|power|pwm`)."""
    gpus = []
    for line in lines or []:
        fields = line.split("|")
        if len(fields) < 8:
            continue
        card, pci = fields[0], fields[1]
        busy = number(fields[2])
        vram_used = _int(fields[3])
        vram_total = _int(fields[4])
        temp = number(fields[5])
        power = number(fields[6])
        pwm = number(fields[7])
        if vram_used is not None:
            vram_used //= 1024 * 1024  # bytes -> MiB
        if vram_total is not None:
            vram_total //= 1024 * 1024
        if temp is not None:
            temp = round(temp / 1000.0, 1)
        if power is not None:
            power = round(power / 1_000_000.0, 1)
        fan = round((pwm or 0) / 255.0 * 100.0) if (pwm or 0) > 0 else None
        gpus.append({
            "index": len(gpus),
            "name": AMD_PCI_NAMES.get((pci or "").lower(), "AMD GPU"),
            "uuid": card,
            "util": busy,
            "vramUsed": vram_used,
            "vramTotal": vram_total,
            "power": power,
            "powerLimit": None,
            "temp": temp,
            "fan": fan,
            "clockCore": None,  # amdgpu exposes no clock counters without ROCm
            "clockMem": None,
            "apps": [],
        })
    return gpus


def quant_of(name):
    """PTQ1 / PQ2 / Q4_K_M … as written in the file name, else ''."""
    upper = (name or "").upper()
    match = re.search(r"(PTQ\d|PQ\d)", upper)
    if match:
        return match.group(1)
    match = re.search(r"(?:^|[-_.])((?:I?Q\d(?:_[A-Z0-9]+)*))", upper)
    return match.group(1) if match else ""


def _parse_json(lines):
    text = "\n".join(lines or []).strip()
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return None


def parse_llama_server(host, probe, section):
    health = _sub(section, "HEALTH")
    props = _parse_json(_sub(section, "PROPS"))
    slots = _parse_json(_sub(section, "SLOTS"))
    healthy = any(re.search(r'"status"\s*:\s*"ok"', line) for line in health or [])
    model_path = (props or {}).get("model_path", "") if isinstance(props, dict) else ""
    n_ctx = None
    if isinstance(props, dict):
        n_ctx = _int((props.get("default_generation_settings") or {}).get("n_ctx"))
    processing = 0
    slot_total = 0
    if isinstance(slots, list):
        slot_total = len(slots)
        processing = sum(1 for slot in slots if isinstance(slot, dict) and slot.get("is_processing"))
    name = _basename(model_path) or probe.get("name", "")
    models = []
    if healthy and name:
        models.append({
            "id": name,
            "quant": quant_of(name),
            "context": n_ctx,
            "loaded": True,
            "slots": slot_total,
            "slotsProcessing": processing,
        })
    return {
        "host": host, "kind": "llm", "type": "llama-server", "name": probe.get("name", ""),
        "endpoint": f"127.0.0.1:{probe.get('port')}",
        "health": bool(healthy), "state": "loaded" if healthy else "down",
        "loadedCount": len(models), "catalogCount": len(models),
        "models": models,
        "error": "" if healthy else "no health response",
    }


def parse_llama_swap(host, probe, section):
    running = _parse_json(_sub(section, "RUNNING"))
    catalog = _parse_json(_sub(section, "MODELS"))
    loaded_ids = []
    if isinstance(running, dict):
        for item in running.get("running") or []:
            if isinstance(item, dict):
                loaded_ids.append(str(item.get("model") or item.get("id") or item.get("name") or ""))
            elif item:
                loaded_ids.append(str(item))
    elif isinstance(running, list):
        for item in running:
            loaded_ids.append(str(item.get("model") if isinstance(item, dict) else item))
    loaded_ids = [item for item in loaded_ids if item]
    catalog_ids = []
    if isinstance(catalog, dict):
        catalog_ids = [str(entry.get("id", "")) for entry in catalog.get("data") or []]
    health = running is not None or catalog is not None
    return {
        "host": host, "kind": "llm", "type": "llama-swap", "name": probe.get("name", ""),
        "endpoint": f"127.0.0.1:{probe.get('port')}",
        "health": bool(health),
        "state": "loaded" if loaded_ids else ("idle" if health else "down"),
        "loadedCount": len(loaded_ids), "catalogCount": len(catalog_ids),
        "models": [{"id": model_id, "quant": quant_of(model_id), "context": None,
                    "loaded": True, "slots": None, "slotsProcessing": None}
                   for model_id in loaded_ids],
        "error": "" if health else "no response",
    }


def parse_lmstudio(host, probe, section):
    payload = _parse_json(_sub(section, "MODELS"))
    entries = (payload or {}).get("data") if isinstance(payload, dict) else None
    if not isinstance(entries, list):
        error = ""
        if isinstance(payload, dict) and payload.get("error"):
            error = str(payload.get("error"))[:80]
        return {
            "host": host, "kind": "llm", "type": "lmstudio", "name": probe.get("name", ""),
            "endpoint": f"127.0.0.1:{probe.get('port')}",
            "health": bool(entries is not None), "state": "down",
            "loadedCount": 0, "catalogCount": 0, "models": [], "error": error or "no response",
        }
    loaded = [entry for entry in entries if isinstance(entry, dict) and entry.get("state") == "loaded"]
    models = [{
        "id": _basename(entry.get("id", "")),
        "quant": quant_of(entry.get("id", "")),
        "context": _int(entry.get("max_context_length")),
        "loaded": True, "slots": None, "slotsProcessing": None,
    } for entry in loaded]
    return {
        "host": host, "kind": "llm", "type": "lmstudio", "name": probe.get("name", ""),
        "endpoint": f"127.0.0.1:{probe.get('port')}",
        "health": True,
        "state": "loaded" if loaded else "idle",
        "loadedCount": len(loaded), "catalogCount": len(entries),
        "models": models, "error": "",
    }


def parse_ollama(host, probe, section):
    ps = _parse_json(_sub(section, "PS"))
    tags = _parse_json(_sub(section, "TAGS"))
    loaded = (ps or {}).get("models") if isinstance(ps, dict) else None
    catalog = (tags or {}).get("models") if isinstance(tags, dict) else None
    error = ""
    if isinstance(ps, dict) and ps.get("error"):
        error = str(ps["error"])[:80]
    elif isinstance(tags, dict) and tags.get("error"):
        error = str(tags["error"])[:80]
    if not isinstance(loaded, list):
        loaded = []
    models = [{
        "id": str(entry.get("name", "")),
        "quant": quant_of(str(entry.get("name", ""))),
        "context": None,
        "loaded": True, "slots": None, "slotsProcessing": None,
    } for entry in loaded if isinstance(entry, dict)]
    healthy = isinstance(ps, dict) and not ps.get("error")
    return {
        "host": host, "kind": "llm", "type": "ollama", "name": probe.get("name", ""),
        "endpoint": f"127.0.0.1:{probe.get('port')}",
        "health": bool(healthy),
        "state": "loaded" if models else ("idle" if healthy else "down"),
        "loadedCount": len(models),
        "catalogCount": len(catalog) if isinstance(catalog, list) else 0,
        "models": models, "error": error,
    }


def parse_comfyui(host, probe, section):
    queue = _parse_json(_sub(section, "QUEUE"))
    stats = _parse_json(_sub(section, "STATS"))
    running = len((queue or {}).get("queue_running") or []) if isinstance(queue, dict) else 0
    pending = len((queue or {}).get("queue_pending") or []) if isinstance(queue, dict) else 0
    healthy = isinstance(queue, dict) or isinstance(stats, dict)
    version = ""
    if isinstance(stats, dict):
        version = str((stats.get("system") or {}).get("comfyui_version", ""))
    return {
        "host": host, "kind": probe.get("kind", "image"), "type": "comfyui",
        "name": probe.get("name", "ComfyUI"),
        "endpoint": f"127.0.0.1:{probe.get('port')}",
        "health": bool(healthy),
        "state": "busy" if running > 0 else ("idle" if healthy else "down"),
        "busy": running > 0, "queueRunning": running, "queuePending": pending,
        "version": version, "models": [], "error": "" if healthy else "no response",
    }


def parse_http(host, probe, section):
    lines = _sub(section, "HEALTH")
    body = "\n".join(lines or []).strip()
    payload = None
    try:
        payload = json.loads(body)
    except (ValueError, TypeError):
        pass
    ok = bool(body) and (payload is None or not (isinstance(payload, dict) and payload.get("error")))
    state = "ok"
    if isinstance(payload, dict):
        state = str(payload.get("status") or "ok")
    return {
        "host": host, "kind": probe.get("kind", "other"), "type": "http",
        "name": probe.get("name", ""),
        "endpoint": f"127.0.0.1:{probe.get('port')}",
        "health": ok, "state": state if ok else "down",
        "models": [], "error": "" if ok else "no response",
    }


def parse_k8s_deploy(host, probe, section, deploy_replicas):
    replicas = deploy_replicas.get(probe.get("deploy", ""))
    body = "\n".join(_sub(section, "SVC") or []).strip()
    if replicas == 0:
        return {
            "host": host, "kind": probe.get("kind", "other"), "type": "k8s-deploy",
            "name": probe.get("name", ""), "endpoint": "",
            "health": False, "state": "asleep", "asleep": True,
            "models": [], "error": "",
        }
    if body:
        state, healthy, error = "running", True, ""
    elif replicas is None:
        # No k8s answer at all: never claim the deployment is down.
        state, healthy, error = "unknown", False, "k8s unavailable"
    else:
        state, healthy, error = "down", False, "no response"
    return {
        "host": host, "kind": probe.get("kind", "other"), "type": "k8s-deploy",
        "name": probe.get("name", ""),
        "endpoint": f"{probe.get('serviceIP')}:{probe.get('port')}",
        "health": healthy, "state": state, "asleep": False,
        "models": [], "error": error,
    }


def parse_transcodes(host, probe, section):
    lines = _sub(section, "COUNT")
    count = _int(lines[0], -1) if lines else -1
    healthy = count >= 0
    return {
        "host": host, "kind": "transcode", "type": "jellyfin", "name": probe.get("name", "Jellyfin"),
        "endpoint": "", "health": healthy,
        "state": f"transcoding {count}" if count > 0 else ("idle" if healthy else "down"),
        "active": max(count, 0), "models": [], "error": "" if healthy else "no response",
    }


# ---------------------------------------------------------------------------
# k8s (read-only kubectl gets)
# ---------------------------------------------------------------------------

def _kubectl_bin():
    found = shutil.which("kubectl")
    if found:
        return found
    candidates = sorted(Path.home().glob(".local/share/mise/installs/kubectl/*/kubectl"))
    if candidates:
        return str(candidates[-1])
    for fallback in ("/usr/local/bin/kubectl", "/usr/bin/kubectl"):
        if os.path.exists(fallback):
            return fallback
    return None


def query_k8s():
    """GPU allocatable per node + GPU pods + the mining deployment replicas."""
    kubectl = _kubectl_bin()
    if not kubectl:
        return {"ok": False, "nodes": [], "pods": [], "deploys": {}}
    env = dict(os.environ)
    env.setdefault("KUBECONFIG", str(Path.home() / ".kube" / "config"))

    def get(*args):
        try:
            completed = subprocess.run(
                [kubectl, *args], capture_output=True, text=True, timeout=8, check=False, env=env,
            )
        except (subprocess.TimeoutExpired, OSError):
            return None
        if completed.returncode != 0:
            return None
        try:
            return json.loads(completed.stdout)
        except ValueError:
            return None

    nodes_doc = get("get", "nodes", "-o", "json")
    pods_doc = get("get", "pods", "-A", "-o", "json")
    deploys_doc = get("-n", "mining", "get", "deploy", "-o", "json")

    nodes = []
    for node in (nodes_doc or {}).get("items", []):
        alloc = node.get("status", {}).get("allocatable") or {}
        cap = node.get("status", {}).get("capacity") or {}
        gpu_alloc = _int(alloc.get("nvidia.com/gpu"))
        dri_alloc = _int(alloc.get("squat.ai/dri"))
        if not gpu_alloc and not dri_alloc:
            continue
        nodes.append({
            "name": node["metadata"]["name"],
            "gpuAlloc": gpu_alloc or 0, "gpuCap": _int(cap.get("nvidia.com/gpu"), 0),
            "driAlloc": dri_alloc or 0, "driCap": _int(cap.get("squat.ai/dri"), 0),
        })

    gpu_resource = re.compile(r"(nvidia\.com/gpu|squat\.ai/dri|amd\.com/gpu)")
    workload_names = re.compile(r"^(llama-|llmster|comfyui-|yue2-|peakminer-)")
    pods = []
    for pod in (pods_doc or {}).get("items", []):
        meta = pod.get("metadata", {})
        namespace = meta.get("namespace", "")
        name = meta.get("name", "")
        phase = pod.get("status", {}).get("phase", "")
        resources = {}
        for container in pod.get("spec", {}).get("containers", []) or []:
            for key, value in (container.get("resources", {}).get("requests") or {}).items():
                if gpu_resource.search(key):
                    resources[key] = _int(value, 0)
        holds_gpu = bool(resources)
        known_workload = bool(workload_names.match(name)) and namespace in ("mining", "media")
        if not holds_gpu and not known_workload:
            continue
        # Completed/failed job pods (the comfyui watchdog runs every 2 min)
        # are noise unless they actually hold a GPU.
        if not holds_gpu and phase not in ("Running", "Pending"):
            continue
        restarts = 0
        for status in pod.get("status", {}).get("containerStatuses") or []:
            restarts += int(status.get("restartCount") or 0)
        pods.append({
            "ns": namespace, "name": name,
            "node": pod.get("spec", {}).get("nodeName", ""),
            "phase": phase,
            "restarts": restarts,
            "resources": resources,
            "holdsGpu": holds_gpu,
        })
    pods.sort(key=lambda pod: (not pod["holdsGpu"], pod["ns"], pod["name"]))

    deploys = {}
    for deploy in (deploys_doc or {}).get("items", []):
        deploys[deploy["metadata"]["name"]] = deploy.get("spec", {}).get("replicas", 1)

    ok = nodes_doc is not None or pods_doc is not None
    return {"ok": ok, "nodes": nodes, "pods": pods, "deploys": deploys}


# ---------------------------------------------------------------------------
# models
# ---------------------------------------------------------------------------

def _norm(text):
    return re.sub(r"[^a-z0-9]", "", (text or "").lower())


def _loaded_marks(models, workloads):
    """Mark disk files whose model is currently loaded (same host only)."""
    loaded_by_host = {}
    for workload in workloads.get("llm", []):
        for model in workload.get("models") or []:
            if model.get("loaded"):
                loaded_by_host.setdefault(workload["host"], []).append(model["id"])
    for entry in models:
        entry["loaded"] = False
        candidates = loaded_by_host.get(entry["host"]) or []
        name_norm = _norm(entry["name"])
        for model_id in candidates:
            model_norm = _norm(model_id)
            if len(model_norm) < 8:
                continue
            if model_norm in name_norm or name_norm in model_norm:
                entry["loaded"] = True
                break
    return models


def parse_models(host, config, sections):
    records = []
    seen = set()
    for index, root in enumerate(config.get("models") or []):
        lines = sections.get(f"MODELS:{index}") or []
        root_label = str(root.get("path", "")).replace("~", "~")
        for line in lines:
            parts = line.split("\t")
            if len(parts) != 2:
                continue
            size = _int(parts[0])
            path = parts[1]
            if not size or not path:
                continue
            name = _basename(path)
            # The same file reached through two roots (an lmstudio symlink,
            # an HF snapshot) must count once.
            key = (host, name, size)
            if key in seen:
                continue
            seen.add(key)
            records.append({
                "host": host,
                "root": root_label,
                "name": name,
                "path": path,
                "bytes": size,
                "loaded": False,
            })
    records.sort(key=lambda entry: -entry["bytes"])
    return records[:60]


# ---------------------------------------------------------------------------
# caches + composition
# ---------------------------------------------------------------------------

def _read_cache(path, ttl, allow_stale=False):
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            return None
        if allow_stale or time.time() - float(payload.get("ts") or 0) < ttl:
            return payload
    except (OSError, ValueError):
        pass
    return None


def _write_cache(path, payload):
    payload = dict(payload)
    payload["ts"] = time.time()
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(tmp, path)
    except OSError:
        pass


def _try_lock():
    fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        os.close(fd)
        return None


def _probe_all(include_models, k8s):
    """Probe every host in parallel. Returns (probe_bundle, models_or_None)."""
    gpus = []
    gpu_hosts = {}
    workloads = {"llm": [], "image": [], "audio": [], "transcode": []}
    models = [] if include_models else None
    deploy_replicas = (k8s or {}).get("deploys") or {}

    names = list(GPU_FLEET.keys())
    with ThreadPoolExecutor(max_workers=len(names)) as pool:
        futures = {
            pool.submit(_run_probe, name, GPU_FLEET[name], include_models): name
            for name in names
        }
        results = {}
        for future in as_completed(futures):
            name = futures[future]
            try:
                results[name] = future.result()
            except Exception:  # noqa: BLE001 - a broken probe is an absent host
                results[name] = (name, None, False)

    for name, config in GPU_FLEET.items():
        _, sections, reachable = results.get(name, (name, None, False))
        gpu_hosts[name] = {"reachable": bool(reachable), "local": is_local(name, config)}
        if not reachable or sections is None:
            continue
        if config.get("platform") != "windows":
            host_gpus = parse_nvidia(sections.get("NVIDIA"), sections.get("NVIDIA_APPS"))
            # Power fallback: some builds report an N/A instantaneous draw.
            if config.get("powerFallback"):
                samples = parse_power_samples("\n".join(sections.get("NVIDIA_POWER") or []))
                for gpu in host_gpus:
                    if not gpu.get("power") and gpu["index"] is not None and gpu["index"] < len(samples):
                        gpu["power"] = samples[gpu["index"]]
            host_gpus += parse_amd(sections.get("AMD"), name, config)
        else:
            host_gpus = parse_nvidia(sections.get("NVIDIA"), sections.get("NVIDIA_APPS"))
            if config.get("powerFallback"):
                samples = parse_power_samples("\n".join(sections.get("NVIDIA_POWER") or []))
                for gpu in host_gpus:
                    if not gpu.get("power") and gpu["index"] is not None and gpu["index"] < len(samples):
                        gpu["power"] = samples[gpu["index"]]

        deploy_replicas = (k8s or {}).get("deploys") or {}
        if include_models and models is not None:
            models += parse_models(name, config, sections)

        for gpu in host_gpus:
            gpu["host"] = name
            gpu["vendor"] = "nvidia" if (gpu.get("uuid") or "").startswith("GPU-") else "amd"
            gpu["slot"] = len(gpus)
            if gpu["vendor"] == "nvidia":
                gpu["owner"] = owner_from_apps(gpu.get("apps") or [])
            else:
                gpu["owner"] = ""
            reliability = {"temp": True, "fan": True}
            note = ""
            for override in config.get("gpu_notes") or []:
                if override.get("match", "").lower() in (gpu.get("name") or "").lower():
                    if override.get("tempReliable") is False:
                        reliability["temp"] = False
                    if override.get("fanReliable") is False:
                        reliability["fan"] = False
                    note = override.get("note", "")
            gpu["reliable"] = reliability
            gpu["note"] = note
            gpus.append(gpu)

        # Workload records, in config order.
        for index, probe in enumerate(config.get("workloads") or []):
            section = sections.get(f"WL{index}")
            ptype = probe.get("type")
            try:
                if ptype == "llama_server":
                    record = parse_llama_server(name, probe, section)
                elif ptype == "llama_swap":
                    record = parse_llama_swap(name, probe, section)
                elif ptype == "lmstudio":
                    record = parse_lmstudio(name, probe, section)
                elif ptype == "ollama":
                    record = parse_ollama(name, probe, section)
                elif ptype == "comfyui":
                    record = parse_comfyui(name, probe, section)
                elif ptype == "http":
                    record = parse_http(name, probe, section)
                elif ptype == "k8s_deploy":
                    record = parse_k8s_deploy(name, probe, section, deploy_replicas)
                elif ptype == "transcodes":
                    record = parse_transcodes(name, probe, section)
                else:
                    continue
            except Exception:  # noqa: BLE001 - one broken parser never kills the panel
                continue
            bucket = record.get("kind", "other")
            if bucket not in workloads:
                workloads[bucket] = []
            workloads[bucket].append(record)

    # AMD owners + the sentry GPU get their context from the workload side.
    for gpu in gpus:
        if gpu["vendor"] != "amd":
            continue
        if gpu["host"] == "sentry":
            active = 0
            for record in workloads["transcode"]:
                if record["host"] == "sentry":
                    active = max(active, record.get("active", 0))
            gpu["owner"] = "Jellyfin transcode" if active > 0 else "idle"
        elif gpu["host"] == "forge" and (gpu.get("vramUsed") or 0) > 2048:
            gpu["owner"] = "llama.cpp (Vulkan)"

    bundle = {"gpus": gpus, "gpuHosts": gpu_hosts, "workloads": workloads}
    return bundle, models


def _compose(bundle, models):
    """Add derived totals; the shape poll.py embeds in its JSON."""
    gpus = bundle.get("gpus") or []
    workloads = bundle.get("workloads") or {"llm": [], "image": [], "audio": [], "transcode": []}
    models = models or []
    _loaded_marks(models, workloads)

    models_loaded = 0
    for workload in workloads.get("llm", []):
        models_loaded += int(workload.get("loadedCount") or 0)

    vram_used = sum(gpu.get("vramUsed") or 0 for gpu in gpus)
    vram_total = sum(gpu.get("vramTotal") or 0 for gpu in gpus)
    return {
        "gpus": gpus,
        "gpuHosts": bundle.get("gpuHosts") or {},
        "workloads": workloads,
        "k8s": bundle.get("k8s") or {"ok": False, "nodes": [], "pods": [], "deploys": {}},
        "models": models,
        "totals": {
            "gpuTotal": len(gpus),
            "modelsLoaded": models_loaded,
            "modelsOnDisk": len(models),
            "vramUsed": vram_used,
            "vramTotal": vram_total,
        },
    }


def collect(ttl=GPU_TTL_SECONDS, force=False):
    """The dashboard's GPU view. Cached ~20 s; never raises for the caller."""
    if not force:
        cached = _read_cache(GPU_CACHE_PATH, ttl)
        models_cached = _read_cache(MODELS_CACHE_PATH, MODELS_TTL_SECONDS, allow_stale=True)
        if cached is not None and _read_cache(MODELS_CACHE_PATH, MODELS_TTL_SECONDS) is not None:
            cached["models"] = (models_cached or {}).get("models") or []
            return _compose(cached, cached["models"])

    lock = _try_lock()
    if lock is None:
        # A sibling poller is probing. Wait for its result instead of doubling
        # the ssh fan-out; give up and serve the last known cache after ~8 s.
        deadline = time.time() + 8.0
        while time.time() < deadline:
            time.sleep(0.35)
            cached = _read_cache(GPU_CACHE_PATH, GPU_TTL_SECONDS)
            if cached is not None:
                stale_models = _read_cache(MODELS_CACHE_PATH, MODELS_TTL_SECONDS, allow_stale=True)
                return _compose(cached, (stale_models or {}).get("models") or [])
        cached = _read_cache(GPU_CACHE_PATH, 10**9, allow_stale=True)
        stale_models = _read_cache(MODELS_CACHE_PATH, 10**9, allow_stale=True)
        if cached is not None or stale_models is not None:
            cached = cached or {}
            return _compose(cached, (stale_models or {}).get("models") or [])
        return _compose({}, [])

    try:
        models_fresh = _read_cache(MODELS_CACHE_PATH, MODELS_TTL_SECONDS) is not None
        include_models = force or not models_fresh
        try:
            k8s = query_k8s()
        except Exception:  # noqa: BLE001 - kubectl is best-effort
            k8s = {"ok": False, "nodes": [], "pods": [], "deploys": {}}
        bundle, models = _probe_all(include_models, k8s)
        bundle["k8s"] = k8s
        _write_cache(GPU_CACHE_PATH, bundle)
        if include_models and models is not None:
            _write_cache(MODELS_CACHE_PATH, {"models": models})
        return _compose(bundle, models if models is not None
                        else (_read_cache(MODELS_CACHE_PATH, 10**9, allow_stale=True) or {}).get("models") or [])
    finally:
        os.close(lock)


if __name__ == "__main__":
    force = "--force" in sys.argv
    data = collect(ttl=0 if force else GPU_TTL_SECONDS, force=force)
    if "--json" in sys.argv:
        print(json.dumps(data, indent=2))
    else:
        print(f"gpus: {len(data['gpus'])}  models loaded: {data['totals']['modelsLoaded']}"
              f"  models on disk: {data['totals']['modelsOnDisk']}")
        for gpu in data["gpus"]:
            print(f"  {gpu['host']:8} slot={gpu.get('slot')} {gpu['name'][:34]:34}"
                  f" util={gpu.get('util')} vram={gpu.get('vramUsed')}/{gpu.get('vramTotal')}"
                  f" owner={gpu.get('owner')}")
        for workload in data["workloads"].get("llm", []):
            print(f"  llm {workload['host']:8} {workload['name'][:28]:28} {workload['state']:8}"
                  f" loaded={workload.get('loadedCount')} catalog={workload.get('catalogCount')}"
                  f" err={workload.get('error','')}")
