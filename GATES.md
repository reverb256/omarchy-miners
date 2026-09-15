# Miners Plugin Gates

Validation checklist for the miners plugin. Run from the plugin root (as
`run-gates.sh` does); paths are relative so the checklist works on any install.

## Gate reference

| # | Check | How it runs | Expect |
|---|-------|-------------|--------|
| G1 | Bar-widget entry point exists | `manifest.json` `entryPoints.barWidget` path exists on disk | `True` |
| G2 | Plugin declares `bar-widget` kind | manifest `kinds` | `True` |
| G3 | Panel.qml defines the `Panel` root | `grep -c '^Panel {' Panel.qml` | `1` |
| G4 | No hardcoded colors in QML | `grep -o '#[0-9a-fA-F]\{6\}' ./*.qml` | `0` |
| G5 | poll.py emits valid JSON | `python3 poll.py` parses | `valid` |
| G6 | Unit names single-sourced | `grep -c '"unit"' poll.py` — `fleet.py` is the one source | `1` |
| G9 | Refuses a bogus unit | `miner-control stop zephyr peakminer-99999.service` | `False` (`ok:false` IS the pass) |
| G10 | Reads a real local unit | `miner-control status zephyr peakminer-3090.service` | `True` |
| G10b | Reads the Windows unit | `miner-control status krash2 pearlhash` | `True` |
| G12 | Plugin present in shell.json | `grep -c io.github.jkro.miners ~/.config/omarchy/shell.json` | `>= 1` |
| G13 | Running shell discovers it | `listPlugins` on the RUNNING shell's config path (pgrep-derived; falls back to `/usr/share/omarchy/shell`). This box runs a custom clone at `~/omarchy/shell`. | `1` |
| G15 | zephyr 3060 Ti unit live | `systemctl is-active peakminer-3060ti.service` | `active` |
| G16 | zephyr 3090 unit live | `systemctl is-active peakminer-3090.service` | `active` |
| G17 | forge 4060-0 controllable | `miner-control status forge peakminer-forge-4060-0.service` | `True` |
| G18 | forge 4060-1 controllable | `miner-control status forge peakminer-forge-4060-1.service` | `True` |
| G19 | Revenue feed works | `./prl-revenue --hashrate 1000000000000` returns `rateCoinsPerHsDay` and `price` | `ok` |

forge runs PERSISTENT units (`peakminer-forge-4060-0/1.service`) whose
ExecStart is redirected by a `/usr/local/lib/systemd/system` drop-in
(`bump.conf` → `imp.sh`). The transient systemd-run drop-in path is dead:
stopping a transient unit deletes it, so the panel could never start a paused
miner again. Keep the units in step with `fleet.py`.

## Running the gates

```bash
./run-gates.sh
```

`run-gates.sh` also works from any cwd — it `cd`s to the plugin root first.

## Notes

- After any file change under the plugin dir the shell hot-reloads the plugin;
  bar widgets re-register during the reload cycle. If `summon` reports
  `no live bar widget` right after an edit, wait a moment or run
  `omarchy-restart-shell`, then re-check.
- `miner-control status` for a stopped unit returns `ok:true` with
  `state:inactive` — that is a valid answer, not a failure.
