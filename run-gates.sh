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

printf 'G15 zephyr 3060ti          : '
systemctl is-active peakminer-3060ti.service

printf 'G16 zephyr 3090            : '
systemctl is-active peakminer-3090.service

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
python3 ./poll.py | python3 -c "import sys,json;d=json.load(sys.stdin);m=[x for x in d.get('miners',[]) if x['host']=='krash3'];print('ok' if m and m[0]['online'] and m[0]['hashrate']>0 else 'FAIL:'+json.dumps(m))"
