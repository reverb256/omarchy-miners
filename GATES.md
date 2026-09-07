# Miners Plugin Gates

Validation checklist for the miners plugin. Run from the plugin root (as
`run-gates.sh` does); paths are relative so the checklist works on any install.

## Gate reference

| # | Check | Command (run from plugin root) | Expect |
|---|-------|--------------------------------|--------|
| G1 | Model.js exists with pure logic exports | `test -f Model.js && grep -c "assessHealth" Model.js` | `[1-9]+` |
| G2 | util/format.js exists with number helpers | `test -f util/format.js && grep -c "scaleNumber" util/format.js` | `[1-9]+` |
| G3 | ErrorBanner.qml exists | `test -f components/ErrorBanner.qml && echo "exists"` | `exists` |
| G4 | StatPill.qml exists | `test -f components/StatPill.qml && echo "exists"` | `exists` |
| G5 | BarWidget.qml exists with BarWidget from qs.Ui | `test -f BarWidget.qml && grep -c "BarWidget" BarWidget.qml` | `[1-9]+` |
| G6 | Panel.qml uses PanelHero from qs.Ui | `grep -c "PanelHero" Panel.qml` | `[1-9]+` |
| G7 | Main.qml imports util/format.js | `grep -c "util/format.js" Main.qml` | `[1-9]+` |
| G8 | Main.qml no longer defines formatHashrate | `grep -c "function formatHashrate" Main.qml` | `0` |
| G9 | Plugin loads without QML errors | `export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=wayland-1 && MARK=$(date '+%Y-%m-%d %H:%M:%S') && quickshell ipc -p /usr/share/omarchy/shell call shell summon io.github.jkro.miners '{}' >/dev/null 2>&1 && sleep 3 && journalctl --user --since "$MARK" 2>/dev/null | grep -i "jkro.miners" | grep -viE "another handler" | grep -cE "WARN\\|ERROR"` | `0` |
| G10 | Bar widget enabled in shell | `quickshell ipc -p /usr/share/omarchy/shell call shell listPlugins 2>&1 | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d if 'miners' in p['id']][0]; print(m['enabled'])"` | `True` |

## Running the gates

```bash
./run-gates.sh
```

`run-gates.sh` also works from any cwd — it `cd`s to the plugin root first.