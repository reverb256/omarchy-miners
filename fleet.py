#!/usr/bin/env python3
"""The fleet definition. One source of truth for the panel and the CLI.

Unit names are DATA, never derived. Each host names its miners its own way:

  zephyr  Omarchy. Units are hand-managed in /etc/systemd/system, so LIVE
          SYSTEMD is the truth for this host — not any Nix config.
          -> peakminer-3060ti.service, peakminer-3090.service
  nexus   Omarchy (converted from NixOS). Hand-managed unit.
          -> peakminer-nexus-3060ti.service
  forge   NixOS. Persistent units peakminer-forge-4060-0/1.service whose
          ExecStart is redirected by a /usr/local/lib/systemd/system drop-in
          (bump.conf -> imp.sh -> hand-installed binary in /home/j_kro).
          The old transient systemd-run drop-ins are dead: stopping one
          deletes it (the panel could never restart it), and reboots lose
          them — do not bring them back.
          -> peakminer-forge-4060-0.service, peakminer-forge-4060-1.service
  krash2  Windows 11, NSSM service (krash2 SSH alias, user 'krash')
          -> pearlhash (NSSM service name)

Forge runs PERSISTENT units — standard systemctl-managed service files.
The old transient drop-in path (systemd-run + imp.sh scripts) is dead.

Deriving a unit from the API port (what this plugin used to do) matched no
unit on any host, so every pause silently did nothing. Verify a name against
the host with `systemctl is-active <unit>` before you change it here.
"""

from __future__ import annotations

# host -> connection facts + configured miners.
#   local     run systemctl here instead of over ssh
#   unit      the EXACT systemd unit, verified on the host
#   platform  "linux" (default) or "windows" (NSSM services)
#   transient units are created via systemd-run, not as persistent files (forge)
#   script    path to the imp.sh script on the host (transient units only)
#   conflicts unit to Conflicts= against so the Nix unit stays dormant (transient)
FLEET = {
    "zephyr": {
        "ip": "localhost",
        "local": True,
        "user": "j_kro",
        "miners": [
            {
                "port": 21553,
                "unit": "peakminer-3060ti.service",
                "label": "RTX 3060 Ti",
                "powerLimit": 120,
            },
            {
                "port": 21554,
                "unit": "peakminer-3090.service",
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
                "label": "RTX 3060 Ti",
                "powerLimit": 120,
            },
        ],
    },
    "forge": {
        "ip": "10.1.1.130",
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
                "label": "RTX 4060 #1",
                "powerLimit": 118,
            },
            {
                "port": 21552,
                "unit": "peakminer-forge-4060-1.service",
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
        "miners": [
            {
                "port": 4069,
                "unit": "pearlhash",
                "label": "RTX 4060",
                "powerLimit": 115,
            },
        ],
    },
}


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
