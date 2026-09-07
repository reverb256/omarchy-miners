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
quickshell ipc -p /usr/share/omarchy/shell call shell listPlugins 2>/dev/null |
  grep -c io.github.jkro.miners

printf 'G15 zephyr 3060ti          : '
systemctl is-active peakminer-3060ti.service

printf 'G16 zephyr 3090            : '
systemctl is-active peakminer-3090.service
