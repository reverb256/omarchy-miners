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
| zephyr | Omarchy | k3s `peakminer-zephyr-3060ti`, `peakminer-zephyr-3090` (rollback units: peakminer-3060ti.service, peakminer-3090.service) |
| nexus | Omarchy | k3s `peakminer-nexus-3060ti` (rollback unit: peakminer-nexus-3060ti.service) |
| forge | Omarchy | k3s `peakminer-forge-4060-0/1` (rollback units: peakminer-forge-4060-0/1.service) |
| krash2 | Windows 11 | pearlhash (NSSM service) |
| krash3 | Windows 11 | Kryptex desktop app — **monitor-only** (no unit) |

The krash3 row is read-only: its numbers come from the Kryptex app's bundled
SRBMiner API (PRL), xmrig API (XMR) and nvidia-smi. There is no unit to pause,
so the panel hides its control. The xmrig readout is shown under the row:
XMR hashrate, accepted shares, algorithm, pool, CPU, and an estimated $/day
for the CPU hashrate (see "Earnings estimate").

### Earnings estimate

`prl-revenue` fetches, keylessly, from the same public endpoints the pool's own
web calculator uses:

- `https://pool.kryptex.com/api/v1/rates` — live PRL price (USD) plus fiat rates
- `https://pool.kryptex.com/api/v2/daily-revenue/PRL?hashrate=…` — coins/day the
  pool pays for a hashrate (probed at 1 TH/s; the pool pays linearly per share,
  so the rate scales to any hashrate)

CoinGecko (`pearl-2`) is the price fallback if the pool feed is down. The
estimate is gross of pool fees; it is an estimate, not a promise.

`xmr-revenue` does the same for the krash3 CPU miner's XMR hashrate, from the
same keyless sources — `crypto.XMR` on `/api/v1/rates` and
`/api/v2/daily-revenue/XMR` (probed at 100 kH/s). Fallbacks: CoinGecko
(`monero`) for price and `xmrchain.net/api/networkinfo` chain stats — the
fixed 0.6 XMR/block tail emission over the network hashrate — for the rate.

The fleet totals (panel hero pills, bar earnings text, tooltip) fold both
together: all-in $/day = PRL fleet + krash3 XMR. Per-row figures stay
per-coin; the price caption lists both pool rates.

## Security

- **Service management**: The plugin manages miners through `miner-control` (start/stop/restart/status). The five Linux miners are k3s Deployments (namespace `mining`) — control routes through kubectl (runtime only; config = git + ArgoCD, repo `reverb256/mining-k8s`). Non-migrated units fall back to systemd/NSSM. Targets are validated against the fleet definition before any control call.
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
- **`xmr-revenue`** — Pool rate + XMR price → the krash3 CPU miner's $/day
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
