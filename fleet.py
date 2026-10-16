#!/usr/bin/env python3
"""The fleet definition. One source of truth for the panel and the CLI.

Unit names are DATA, never derived. Each host names its miners its own way:

  zephyr  Omarchy. Units are hand-managed in /etc/systemd/system, so LIVE
          SYSTEMD is the truth for this host — not any Nix config.
          -> peakminer-3060ti.service, peakminer-3090.service
  nexus   Omarchy (converted from NixOS). Hand-managed unit.
          -> peakminer-nexus-3060ti.service
  forge   Omarchy (reinstalled 2026-09-17). Persistent units
          peakminer-forge-4060-0/1.service with a direct ExecStart:
          /usr/local/bin/peakminer (fleet-consistent binary), no drop-ins.
          The old transient systemd-run drop-ins are dead: stopping one
          deletes it (the panel could never restart it), and reboots lose
          them — do not bring them back.
          -> peakminer-forge-4060-0.service, peakminer-forge-4060-1.service
  krash2  Windows 11, NSSM service (krash2 SSH alias, user 'krash')
          -> pearlhash (NSSM service name)
          Row data comes from the read-only collector (source=collector,
          windows-collector-contract.md); the ssh read stays as the fallback.
          The box is virus-quarantined: collector data is HOSTILE input and
          poll.py validates it before use. MONITOR-ONLY (control=none).
  krash3  Windows 11, the Kryptex desktop app (krash3 SSH alias, user j_kro).
          Monitor-only — there is no unit to control. Data comes from the
          collector first (source=collector), falling back to the ssh read:
          the app's bundled miners — SRBMiner HTTP API for PRL,
          xmrig HTTP API for XMR (127.0.0.1 only; read over ssh), and
          nvidia-smi for the GPU.

Forge runs PERSISTENT units — standard systemctl-managed service files.
The old transient drop-in path (systemd-run + imp.sh scripts) is dead.

Deriving a unit from the API port (what this plugin used to do) matched no
unit on any host, so every pause silently did nothing. Verify a name against
the host with `systemctl is-active <unit>` before you change it here.

k3s MIGRATION (2026-09-21): the five Linux miners now run as k3s Deployments
in namespace `mining` (repo reverb256/mining-k8s + ArgoCD, root app
`mining-helm`). Each of those miners carries a "k8s" mapping; when present,
miner-control routes start/stop/restart/status through kubectl (runtime
control only — config changes go through git + ArgoCD). The systemd units are
stopped+disabled and remain the documented rollback path.
"""

from __future__ import annotations

import os

# host -> connection facts + configured miners.
#   local     run systemctl here instead of over ssh
#   unit      the EXACT systemd unit, verified on the host
#   platform  "linux" (default) or "windows" (NSSM services)
#   kind      "peakminer" (default) or "kryptex" (the Kryptex app rig)
#   control   "none" makes a host monitor-only (no unit to start/stop)
#   source    "collector" reads the host's read-only collector FIRST, with
#             the ssh probe as the fallback (windows-collector contract §5).
#             Any collector failure — timeout, non-200, oversized, bad JSON,
#             or a payload that fails validation — falls back to ssh, and
#             only when both fail does the host read as offline.
#   collector {"url", "timeout"}: endpoint facts for source=collector
#   auxPorts  ports the host's probe reads beyond its row miners (data, like
#             unit names — never derived from anything else)
FLEET = {
    "zephyr": {
        "ip": "localhost",
        "local": True,
        # Read locally only when the poller runs ON zephyr (is_local() in
        # poll.py); from any other host it reads over this alias — the alias
        # must exist in that host's ~/.ssh/config (nexus has it).
        "ssh": "zephyr",
        "user": "j_kro",
        "miners": [
            {
                "port": 21553,
                "unit": "peakminer-3060ti.service",
                "k8s": {"ns": "mining", "deploy": "peakminer-zephyr-3060ti"},
                "label": "RTX 3060 Ti",
                "powerLimit": 120,
            },
            {
                "port": 21554,
                "unit": "peakminer-3090.service",
                "k8s": {"ns": "mining", "deploy": "peakminer-zephyr-3090"},
                "label": "RTX 3090",
                "powerLimit": 250,
            },
        ],
    },
    "nexus": {
        "ip": "10.1.1.120",
        # The ssh alias, not the IP: ~/.ssh/config maps it to the touchless key.
        "ssh": "nexus",
        "local": False,
        "user": "j_kro",
        "miners": [
            {
                "port": 21551,
                # Verified with `systemctl list-units` on the host: the unit is
                # hand-managed under Omarchy, not a NixOS drop-in.
                "unit": "peakminer-nexus-3060ti.service",
                "k8s": {"ns": "mining", "deploy": "peakminer-nexus-3060ti"},
                "label": "RTX 3060 Ti",
                "powerLimit": 120,
            },
        ],
    },
    "forge": {
        # Tailnet address since the Omarchy install: LAN :22 refuses and the
        # old 10.1.1.130 path no longer answers.
        "ip": "100.85.63.36",
        "ssh": "forge",
        "local": False,
        "user": "j_kro",
        # Persistent units: peakminer-forge-4060-0/1.service (NOT transient dropins).
        # The old transient imp.sh + systemd-run path is dead; these are standard
        # systemctl-managed units now.
        "miners": [
            {
                "port": 21550,
                "unit": "peakminer-forge-4060-0.service",
                "k8s": {"ns": "mining", "deploy": "peakminer-forge-4060-0"},
                "label": "RTX 4060 #1",
                "powerLimit": 118,
            },
            {
                "port": 21552,
                "unit": "peakminer-forge-4060-1.service",
                "k8s": {"ns": "mining", "deploy": "peakminer-forge-4060-1"},
                "label": "RTX 4060 #2",
                "powerLimit": 115,
            },
        ],
    },
    "krash2": {
        "ip": "10.1.1.79",
        "ssh": "krash2",
        "local": False,
        "user": "krash",
        "platform": "windows",
        # Read-only collector (windows-collector-contract.md §4/§5). krash2 is
        # virus-quarantined: its payload is HOSTILE input, validated in poll.py
        # before use and never interpolated into a shell, a path, or a unit
        # name. Any collector failure falls back to the ssh probe below.
        "source": "collector",
        "collector": {"url": "http://10.1.1.79:9700/status.json", "timeout": 2.5},
        # Monitor-only: the collector is report-only by contract and this box's
        # NSSM unit is a host-side fact the panel must not offer a control for.
        "control": "none",
        "miners": [
            {
                "port": 4069,
                "unit": "pearlhash",
                "label": "RTX 4060",
                "powerLimit": 115,
            },
        ],
    },
    "krash3": {
        "ip": "10.1.1.150",
        "ssh": "krash3",
        "local": False,
        "user": "j_kro",
        "platform": "windows",
        # The Kryptex desktop app, not peakminer: monitor-only. There is no
        # systemd/NSSM unit, so the panel hides this row's pause/resume.
        "control": "none",
        "kind": "kryptex",
        # Read-only collector first (same rules as krash2), ssh read as the
        # fallback.
        "source": "collector",
        "collector": {"url": "http://10.1.1.150:9700/status.json", "timeout": 2.5},
        # The bundled CPU xmrig's API port: the probe reads it over ssh today,
        # and the collector carries it verbatim as miners."12000". Declared so
        # a collector payload's ports are checked against a known set.
        "auxPorts": [12000],
        "miners": [
            {
                # The bundled SRBMiner's API port on the host (the PRL miner).
                "port": 12008,
                # No unit exists; this is the row's display identity.
                "unit": "kryptex-app",
                "label": "RTX 4060",
                "powerLimit": 115,
            },
        ],
    },
}


# Same mux options as poll.py: every bar on every monitor runs its own copy,
# so sessions to one host overlap several times a minute. One shared master
# connection removes the connect/kex/auth churn and makes repeat probes fast.
SSH_OPTIONS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=6",
    # One connection per host instead of one per miner. The miner APIs bind
    # 127.0.0.1 only, so each remote host needs a curl run on the host itself;
    # opening a session per port trips sshd's MaxStartups throttling
    # (kex_exchange_identification: Connection reset by peer) and every probe
    # after the first fails.
    "-o", "ServerAliveInterval=5",
    "-o", "ControlMaster=auto",
    "-o", f"ControlPath=/run/user/{os.getuid()}/ssh-miners-%C",
    "-o", "ControlPersist=60",
]


# ---------------------------------------------------------------------------
# GPU + workload inventory (read-only) — one source of truth for gpu.py.
#
# This is DATA about where things live, not code. gpu.py probes each host in
# ONE ssh session per refresh: nvidia-smi, amdgpu sysfs, model-server
# endpoints on 127.0.0.1 (the same loopback rule the miner APIs follow), and
# a bounded model-file find where roots are configured.
#
#   gpu_note          per-GPU reliability overrides (matched on the GPU name)
#   powerFallback     true = also run `nvidia-smi -q -d POWER`; some builds
#                     report an N/A instantaneous draw and the Power Samples
#                     average is the only usable number
#   models            on-disk model roots; depth = find -maxdepth
#   workloads         endpoint probes. type:
#                     llama_server / llama_swap / lmstudio / ollama /
#                     comfyui / http / transcodes / k8s_deploy
# ---------------------------------------------------------------------------
GPU_FLEET = {
    "zephyr": {
        "ssh": "zephyr",
        "local": True,
        "user": "j_kro",
        "gpu_notes": [
            {
                "match": "3090",
                "tempReliable": False,
                "fanReliable": False,
                "note": "EVGA hybrid: onboard fan/temp sensors are unreliable — not alerted on",
            },
        ],
        "models": [
            {"path": "~/models", "depth": 3},
            {"path": "~/StabilityMatrix/Models", "depth": 3},
            {"path": "~/.cache/huggingface/hub", "depth": 4},
        ],
        "workloads": [
            # The one loopback endpoint that fans out to every locally
            # reachable model server (llama-swap `peers`; pair-aggregator).
            {"type": "llama_swap", "name": "PAIR aggregator", "kind": "llm", "port": 1235},
            # The k3s llama-zephyr-3090 pod's in-pod llama-swap.
            {"type": "llama_swap", "name": "llama-zephyr-3090", "kind": "llm", "port": 21590},
            # k3s ComfyUI on the 3090 (NodePort published on every node).
            {"type": "comfyui", "name": "ComfyUI", "kind": "image", "port": 32188},
            # k3s voice-models (TTS) on the 3060 Ti (NodePort).
            {"type": "http", "name": "voice-models", "kind": "audio", "port": 30805,
             "healthPath": "/health"},
            # k3s YuE2 music generator — scaled to 0 when idle (deployment spec
            # is the truth; the service is only probed while replicas > 0).
            {"type": "k8s_deploy", "name": "yue2", "kind": "audio",
             "namespace": "mining", "deploy": "yue2-zephyr",
             "serviceIP": "10.43.95.191", "port": 8080},
        ],
    },
    "nexus": {
        "ssh": "nexus",
        "local": False,
        "user": "j_kro",
        "models": [
            {"path": "~/models", "depth": 3},
            {"path": "~/.lmstudio/models", "depth": 4},
        ],
        "workloads": [
            # LM Studio server managed by the llmster pod (hostNetwork).
            {"type": "lmstudio", "name": "LM Studio (llmster)", "kind": "llm", "port": 1235},
            {"type": "ollama", "name": "ollama", "kind": "llm", "port": 11434},
        ],
    },
    "forge": {
        "ssh": "forge",
        "local": False,
        "user": "j_kro",
        "powerFallback": True,
        "models": [
            {"path": "~/models", "depth": 3},
            {"path": "/models", "depth": 3},
        ],
        "workloads": [
            # llama-server trio: 4060 #0, 4060 #1, and the AMD (Vulkan) card.
            {"type": "llama_server", "name": "llama-forge-4060-0", "kind": "llm", "port": 21582},
            {"type": "llama_server", "name": "llama-forge-4060-1", "kind": "llm", "port": 21583},
            {"type": "llama_server", "name": "llama-forge-5700xt", "kind": "llm", "port": 21580},
            {"type": "lmstudio", "name": "LM Studio (llmster)", "kind": "llm", "port": 1235},
            {"type": "ollama", "name": "ollama", "kind": "llm", "port": 11434},
        ],
    },
    "sentry": {
        "ssh": "sentry",
        "local": False,
        "user": "j_kro",
        "transcodes": True,
        "models": [],
        "workloads": [
            # Jellyfin runs as a k3s pod on sentry-agent; each transcode is a
            # jellyfin-ffmpeg process visible to the host (`pgrep -x ffmpeg`).
            {"type": "transcodes", "name": "Jellyfin", "kind": "transcode"},
        ],
    },
    "krash2": {
        "ssh": "krash2",
        "local": False,
        "user": "krash",
        "platform": "windows",
        "powerFallback": True,
        "models": [],
        "workloads": [],
    },
    "krash3": {
        "ssh": "krash3",
        "local": False,
        "user": "j_kro",
        "platform": "windows",
        "powerFallback": True,
        # Monitor-only (Kryptex app): GPU row only.
        "models": [],
        "workloads": [],
    },
}


# ---------------------------------------------------------------------------
# AI workload registry — the k3s Deployments in namespace `mining` that serve
# models (llama.cpp, ComfyUI, YuE2). One source of truth for ai-control,
# poll.py and the panel: workload ids are DATA, never derived.
#
# Runtime control only (start/stop/restart/switch); config changes go through
# git (reverb256/mining-k8s) + ArgoCD, same rule as the miners.
#
#   host         the fleet host whose GPU runs it
#   gpu          the card (display)
#   label        human label (row tooltip / detail)
#   kind         llm | image | audio — display grouping
#   probe        the GPU_FLEET workload probe (host + probe name) this
#                deployment answers as, when one exists — its health and
#                loaded-model detail ride along on the panel row
#   switchGroup  mutually-exclusive model variants that share ONE GPU:
#                starting one is meant to stop the others (the panel's
#                switch action; `ai-control switch <id>`). Only variants of
#                the same card may share a group.
#   variant      the short label the switch chip shows for this member
AI_WORKLOADS = {
    "llama-forge-4060-0": {
        "ns": "mining", "deploy": "llama-forge-4060-0",
        "host": "forge", "gpu": "RTX 4060 #1",
        "label": "llama.cpp · 4060 #1", "kind": "llm",
        "probe": {"host": "forge", "name": "llama-forge-4060-0"},
    },
    "llama-forge-4060-1": {
        "ns": "mining", "deploy": "llama-forge-4060-1",
        "host": "forge", "gpu": "RTX 4060 #2",
        "label": "llama.cpp · 4060 #2", "kind": "llm",
        "probe": {"host": "forge", "name": "llama-forge-4060-1"},
    },
    "llama-forge-5700xt": {
        "ns": "mining", "deploy": "llama-forge-5700xt",
        "host": "forge", "gpu": "RX 5600/5700 (Navi 10)",
        "label": "llama.cpp · RX 5700 XT (Vulkan)", "kind": "llm",
        "probe": {"host": "forge", "name": "llama-forge-5700xt"},
    },
    "llama-nexus-3060ti": {
        "ns": "mining", "deploy": "llama-nexus-3060ti",
        "host": "nexus", "gpu": "RTX 3060 Ti",
        "label": "llama.cpp · 3060 Ti", "kind": "llm",
        # This card is ARBITRATED by the pause machinery (miner-pause-watchdog,
        # ns mining): the miner and this member cannot share the card, the
        # miner wins, and a member scaled up while peakminer-nexus-3060ti runs
        # is force-scaled back to 0 within one 30 s sweep (reason=miner-running,
        # seen 2026-10-16). Not a plugin rule — the panel only says so.
        "hint": "arbitrated card: the pause machinery scales this back to 0 "
                "while peakminer-nexus-3060ti runs (miner wins)",
    },
    # The 3090 hosts two llama.cpp variants (the pq2 quant is the second).
    # One card: they share a switch group, so the panel starts the picked
    # variant and stops its sibling in ONE confirmed action.
    "llama-zephyr-3090": {
        "ns": "mining", "deploy": "llama-zephyr-3090",
        "host": "zephyr", "gpu": "RTX 3090",
        "label": "llama.cpp · 3090", "kind": "llm",
        "probe": {"host": "zephyr", "name": "llama-zephyr-3090"},
        "switchGroup": "zephyr-3090", "variant": "3090",
    },
    "llama-zephyr-3090-pq2": {
        "ns": "mining", "deploy": "llama-zephyr-3090-pq2",
        "host": "zephyr", "gpu": "RTX 3090",
        "label": "llama.cpp · 3090 pq2", "kind": "llm",
        "switchGroup": "zephyr-3090", "variant": "pq2",
    },
    "yue2-zephyr": {
        "ns": "mining", "deploy": "yue2-zephyr",
        "host": "zephyr", "gpu": "RTX 3090",
        "label": "YuE2 music", "kind": "audio",
        "probe": {"host": "zephyr", "name": "yue2"},
    },
    "comfyui-zephyr": {
        "ns": "mining", "deploy": "comfyui-zephyr",
        "host": "zephyr", "gpu": "RTX 3090",
        "label": "ComfyUI", "kind": "image",
        "probe": {"host": "zephyr", "name": "ComfyUI"},
    },
}


def switch_siblings(workload_id):
    """Workload ids that share a switchGroup with `workload_id` (in registry
    order). Empty when the workload has no group — a switch is then refused."""
    entry = AI_WORKLOADS.get(workload_id) or {}
    group = entry.get("switchGroup")
    if not group:
        return []
    return [
        other for other, config in AI_WORKLOADS.items()
        if other != workload_id and config.get("switchGroup") == group
    ]


def hosts():
    """Host names in a stable order."""
    return list(FLEET.keys())


def find_miner(host, unit):
    """The configured miner for one host/unit pair, or None."""
    config = FLEET.get(host)
    if not config:
        return None
    for miner in config["miners"]:
        if miner["unit"] == unit or miner["unit"] == f"{unit}.service":
            return miner
    return None
