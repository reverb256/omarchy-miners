#!/usr/bin/env bash
# Run the miners plugin gates. Kept as a file: the inline form trips the
# agent's command-payload limit.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
rm -rf __pycache__
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export WAYLAND_DISPLAY=wayland-1

printf 'G1  entrypoint exists      : '
python3 -c "import json,os;m=json.load(open('manifest.json'));print(os.path.exists(m['entryPoints']['barWidget']))"

printf 'G2  bar-widget kind        : '
python3 -c "import json;print('bar-widget' in json.load(open('manifest.json'))['kinds'])"

printf 'G3  Panel root             : '
grep -c '^Panel {' Panel.qml

printf 'G4  hardcoded colors (0)   : '
grep -h -o '#[0-9a-fA-F]\{6\}' ./*.qml 2>/dev/null | wc -l

printf 'G5  poller JSON valid      : '
python3 poll.py | python3 -c "import sys,json;json.load(sys.stdin);print('valid')"

printf 'G6  fleet single-sourced   : '
grep -c '"unit"' poll.py

printf 'G9  refuses bad unit       : '
python3 ./miner-control stop zephyr peakminer-99999.service |
  python3 -c "import sys,json;print(json.load(sys.stdin)['ok'])"

printf 'G10 reads real unit        : '
python3 ./miner-control status zephyr peakminer-3090.service |
  python3 -c "import sys,json;print(json.load(sys.stdin)['ok'])"

printf 'G10b reads win unit       : '
python3 ./miner-control status krash2 pearlhash |
  python3 -c "import sys,json;print(json.load(sys.stdin)['ok'])"

printf 'G12 in shell.json          : '
grep -c io.github.jkro.miners ~/.config/omarchy/shell.json

printf 'G13 shell discovers it     : '
# Target the RUNNING shell's config path: this box runs a custom clone
# (~/omarchy/shell), not /usr/share/omarchy/shell. Fall back to the stock
# path only when no running instance is found.
QS_PATH=$(pgrep -a quickshell 2>/dev/null | sed -n 's/.*-p \([^ ]*\).*/\1/p' | head -1)
[ -z "$QS_PATH" ] && QS_PATH=/usr/share/omarchy/shell
quickshell ipc -p "$QS_PATH" call shell listPlugins 2>/dev/null |
  grep -c io.github.jkro.miners

# G15/G16: a user pause (deployment scaled to 0) is a NORMAL state; the gates
# accept active OR paused and fail only on unknown/malformed answers.
printf 'G15 zephyr 3060ti (k3s)    : '
python3 ./miner-control status zephyr peakminer-3060ti.service |
  python3 -c "import sys,json;d=json.load(sys.stdin);s=d.get('state','?');print('ok ('+s+')' if d.get('ok') and s in ('active','paused') else 'FAIL:'+json.dumps(d))"

printf 'G16 zephyr 3090 (k3s)      : '
python3 ./miner-control status zephyr peakminer-3090.service |
  python3 -c "import sys,json;d=json.load(sys.stdin);s=d.get('state','?');print('ok ('+s+')' if d.get('ok') and s in ('active','paused') else 'FAIL:'+json.dumps(d))"

printf 'G17 forge 4060-0           : '
python3 ./miner-control status forge peakminer-forge-4060-0.service |
  python3 -c "import sys,json;print(json.load(sys.stdin)['ok'])"

printf 'G18 forge 4060-1           : '
python3 ./miner-control status forge peakminer-forge-4060-1.service |
  python3 -c "import sys,json;print(json.load(sys.stdin)['ok'])"

printf 'G19 revenue feed works    : '
python3 ./prl-revenue --hashrate 1000000000000 |
  python3 -c "import sys,json;d=json.load(sys.stdin);print('ok' if d.get('rateCoinsPerHsDay',0)>0 and d.get('price',0)>0 else 'FAIL:'+str(d.get('error','')))"

printf 'G20 krash3 rig readable    : '
# The rig's mining is toggled on/off by the box's user (gaming machine), so an
# idle rig is a normal state: readability = the row is present and the host
# answered. The mining state prints as info (ok (idle) vs ok (mining)).
python3 ./poll.py | python3 -c "import sys,json;d=json.load(sys.stdin);m=[x for x in d.get('miners',[]) if x['host']=='krash3'];ok=bool(m) and m[0]['hostReachable'];print(('ok (mining)' if m[0]['hashrate']>0 else 'ok (idle)') if ok else 'FAIL:'+json.dumps(m))"

printf 'G21 control failover       : '
# The pinned apiserver (kubeconfig server) is dead; the action must still land
# via a peer. 2026-09-24 nexus-k3s outage regression lock. paused is a valid
# state here: the point is that the FAILOVER answered, not what the miner does.
BADCFG=$(mktemp)
sed 's|https://[0-9.]*:6443|https://10.1.1.199:6443|' ~/.kube/config > "$BADCFG"
KUBECONFIG="$BADCFG" python3 ./miner-control status zephyr peakminer-3060ti.service 2>/dev/null |
  python3 -c "import sys,json;d=json.load(sys.stdin);print('ok (failover)' if d.get('ok') and d.get('state') in ('active','paused') else 'FAIL:'+str(d))"
rm -f "$BADCFG"

printf 'G22 pause vs failure       : '
# User intent must be stated, never inferred: a miner scaled to 0 reads
# "paused" in BOTH surfaces (miner-control's state and poll.py's per-miner
# `paused` flag) — and that must agree with the Deployment spec, so a
# deliberate pause can never be reported as a failure, and a failure can
# never hide behind `paused`. Works in both states (paused or running).
python3 - <<'PY'
import json, os, subprocess, sys
from pathlib import Path
sys.path.insert(0, '.')
from fleet import FLEET

miner = FLEET['zephyr']['miners'][0]
deploy = miner['k8s']['deploy']

env = dict(os.environ)
env.setdefault('KUBECONFIG', str(Path.home() / '.kube' / 'config'))
raw = subprocess.run(
    ['kubectl', '-n', 'mining', 'get', 'deploy', deploy, '-o', 'json'],
    capture_output=True, text=True, env=env, timeout=30,
).stdout
spec = int(json.loads(raw)['spec']['replicas']) if raw else -1

state = json.loads(subprocess.run(
    ['python3', './miner-control', 'status', 'zephyr', miner['unit']],
    capture_output=True, text=True, timeout=30,
).stdout).get('state')

poll = json.loads(subprocess.run(
    ['python3', './poll.py'], capture_output=True, text=True, timeout=60,
).stdout)
row = next((x for x in poll.get('miners', [])
            if x['host'] == 'zephyr' and x['port'] == miner['port']), None)

paused = spec == 0
ok = (row is not None
      and isinstance(row.get('paused'), bool)
      and state in ('active', 'paused', 'inactive')
      and ((state == 'paused') == paused)
      and (bool(row.get('paused')) == paused)
      and ((row.get('state') == 'paused') == paused))
print(
    f"ok (spec={spec} state={state} poll={'paused' if row and row.get('paused') else 'running'})"
    if ok else f"FAIL spec={spec} state={state} row={row}"
)
PY
