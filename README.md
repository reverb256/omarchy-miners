# Omarchy Miners

Fleet-wide GPU miner monitoring for the Omarchy bar.

## What it does

- **Bar widget**: Shows total hashrate, power, and active GPU count across the mining fleet — or earnings per day
- **Panel**: Per-GPU hashrate, power, temperature, estimated $/day per GPU, fleet $/hour · $/day · $/month, with pause/resume controls
- **Earnings estimate**: PRL coins/day from the Kryptex pool's public rate API × the live PRL price, converted to the configured fiat currency. Refresh interval and currency are settings; the estimate scales live with the fleet's current hashrate.

## Installation

```bash
omarchy plugin add https://github.com/reverb256/omarchy-miners.git --enable
```

## Configuration

The fleet is defined in `fleet.py` — one source of truth for the panel and CLI. Each host names its miners its own way:

| Host | Platform | Units |
|------|----------|-------|
| zephyr | Omarchy | peakminer-3060ti.service, peakminer-3090.service |
| nexus | Omarchy | peakminer-nexus-3060ti.service |
| forge | NixOS | Persistent units (`peakminer-forge-4060-0/1.service`) with a bump-managed ExecStart override |
| krash2 | Windows 11 | pearlhash (NSSM service) |

### Earnings estimate

`prl-revenue` fetches, keylessly, from the same public endpoints the pool's own
web calculator uses:

- `https://pool.kryptex.com/api/v1/rates` — live PRL price (USD) plus fiat rates
- `https://pool.kryptex.com/api/v2/daily-revenue/PRL?hashrate=…` — coins/day the
  pool pays for a hashrate (probed at 1 TH/s; the pool pays linearly per share,
  so the rate scales to any hashrate)

CoinGecko (`pearl-2`) is the price fallback if the pool feed is down. The
estimate is gross of pool fees; it is an estimate, not a promise.

## Security

- **Service management**: The plugin manages systemd services (start/stop/restart/status) on local and remote hosts. Units are validated against the fleet definition before any systemctl call.
- **Privilege**: Local hosts use polkit (no sudo). Remote hosts use `sudo systemctl` over SSH with touchless key auth (no password prompt).
- **No secrets in argv**: All SSH connections use key-based auth via `~/.ssh/config` aliases. The market-data fetches need no API key.
- **Bounded output**: All subprocess calls have timeouts and bounded output.

## Architecture

- **`BarWidget.qml`** — Bar entry point, owns the Main data instance
- **`Panel.qml`** — Panel presentation and keyboard handling
- **`Main.qml`** — Data model, owns the polling process and the revenue fetch
- **`fleet.py`** — Fleet definition (one source of truth)
- **`poll.py`** — Polls all miners, emits JSON for QML binding
- **`prl-revenue`** — Pool rate + PRL price → $/hour · $/day · $/month
- **`miner-control`** — Privileged entry point for systemctl operations
- **`run-gates.sh`** — Plugin gates (validation tests)

## License

MIT — see [LICENSE](./LICENSE)

## Removing

To uninstall:

```bash
omarchy plugin remove io.github.jkro.miners
```

What remains after removal:
- **Kept**: None. The plugin registers no keyring entries, systemd units, sudoers rules, or persistent daemons. It only reads miner state; it does not write state files.
- **Removed with the plugin**: the bar widget, panel, and helper scripts. No hooks are left behind in `theme-set.d/` (this plugin does not install any).
- **Persists**: The miners themselves and their systemd/NSSM units are owned by the hosts — the plugin only queries and controls them, so they keep running untouched. Your `~/.ssh/config` aliases (`zephyr`, `nexus`, `forge`, `krash2`) used for remote control are not modified by this plugin.
