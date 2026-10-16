# GPU Fleet

Fleet-wide GPU work management for the Omarchy bar: mining, local LLMs,
image/audio services, Jellyfin transcodes and k3s GPU pods in one panel.

Formerly "Omarchy Miners". The plugin id stays `io.github.jkro.miners` so
existing installs and pins keep working.

## What it does

- **Bar widget**: fleet hashrate plus the number of models currently loaded
  (chip glyph + count). It turns urgent when a GPU runs hot or VRAM is
  nearly full, and the tooltip carries the alert lines.
- **GPUs**: every card in the fleet — model, utilization, VRAM used/total,
  power, temperature/fan, clocks — and the workload that owns it (built from
  nvidia-smi's compute applications plus the fleet's known process set for
  NVIDIA; amdgpu sysfs plus known workload mapping for AMD). Read-only.
- **Miners** (existing): per-GPU hashrate, power, temperature, estimated
  $/day, fleet $/hour · $/day · $/month, with pause/resume. Earnings: PRL
  coins/day from the Kryptex pool's public rate API × the live PRL price,
  converted to the configured fiat currency; the krash3 CPU miner's XMR
  estimate folds into the fleet totals.
- **Model servers (LLMs)**: llama.cpp / llama-swap / LM Studio (llmster) /
  ollama endpoints — loaded model, quant, context, slot usage, catalog size,
  endpoint health.
- **Image & audio**: ComfyUI (busy/idle + queue depth), voice-models, and
  yue2 (stated "asleep" while its k3s deployment is scaled to 0).
- **Transcoding**: Jellyfin on sentry — the number of active
  jellyfin-ffmpeg transcode processes on the media host.
- **K8s GPU**: GPU allocatable per node (`nvidia.com/gpu`, `squat.ai/dri`)
  and the GPU workload pods scheduled on each node.
- **Models on disk**: GGUF/safetensors/ckpt files per host (`~/models`,
  `~/StabilityMatrix/Models`, the HuggingFace cache, `/models`), with sizes
  and which are loaded; VRAM headroom per GPU (used/total per row and in the
  fleet totals).

## Reliability notes

- **zephyr's RTX 3090 (EVGA hybrid)** reports unreliable fan and temperature
  readings. The row shows them dimmed with a trailing `~` and a note, and
  they never drive alerts — the exclusion lives in `fleet.py` (`gpu_notes`).
- **AMD cards** are read from amdgpu sysfs (busy %, VRAM, temp, power, fan
  when the pwm value is real): no clock counters without ROCm. PCI id
  1002:731f covers the RX 5600/5700 (Navi 10) family; the product name
  sysfs node is empty on these builds.
- **Power**: some drivers report an N/A instantaneous draw (forge, the krash
  boxes) — the nvidia-smi Power Samples average is the fallback there.
- A service shown `down` (e.g. forge's ollama answering "no active node
  selected or available") is a real endpoint state, not a plugin error.

## Installation

```bash
omarchy plugin add https://github.com/reverb256/omarchy-miners.git --enable
```

## Configuration

The fleet is defined in `fleet.py` — one source of truth for the panel and
the CLIs:

- `FLEET` — the miners: hosts, connection facts, and each miner's EXACT unit
  name (DATA, never derived from a port — see the header comment).
- `GPU_FLEET` — the GPU view: per host its ssh alias, on-disk model roots
  (with scan depth), workload endpoint probes, the nvidia power fallback
  flag, and per-GPU reliability notes.

Miners by host (unchanged):

| Host | Platform | Units |
|------|----------|-------|
| zephyr | Omarchy | k3s `peakminer-zephyr-3060ti`, `peakminer-zephyr-3090` (rollback units: peakminer-3060ti.service, peakminer-3090.service) |
| nexus | Omarchy | k3s `peakminer-nexus-3060ti` (rollback unit: peakminer-nexus-3060ti.service) |
| forge | Omarchy | k3s `peakminer-forge-4060-0/1` (rollback units: peakminer-forge-4060-0/1.service) |
| krash2 | Windows 11 | pearlhash (NSSM service) |
| krash3 | Windows 11 | Kryptex desktop app — **monitor-only** (no unit) |

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

- **Read-only by default**: the GPU, workload, k8s and model sections only
  read — nvidia-smi queries, amdgpu sysfs reads, `curl` GETs against the
  host's own loopback, `kubectl get`, and bounded `find` listings. `gpu.py`
  and `poll.py` contain no control verb at all (gate G28 enforces this).
- **Service management — miners only, unchanged**: the plugin manages miners
  through `miner-control` (start/stop/restart/status). The five Linux miners
  are k3s Deployments (namespace `mining`) — control routes through kubectl
  (runtime only; config = git + ArgoCD, repo `reverb256/mining-k8s`).
  Non-migrated units fall back to systemd/NSSM. Targets are validated
  against the fleet definition before any control call. If the kubeconfig's
  pinned apiserver is unreachable, `miner-control` probes the other cluster
  endpoints (10.1.1.100 VIP → sentry → forge → nexus) and retries the
  action once against the first that answers. A status read against an
  unreachable API reports `state: unknown`, never a fake `inactive`.
- **Stopping requires an explicit click plus a confirmation**: flipping a
  miner OFF (the pause direction) arms the row first — the checkbox turns
  urgent and shows `!` — and only a second click within 5 seconds commits
  the stop through `miner-control`. Keyboard activation follows the same
  two-step rule (Enter arms, Enter confirms). Resuming stays one click.
  Nothing in the panel can stop a miner on a single click.
- **State vocabulary (pause vs failure)**: `active` = ready and mining;
  `paused` = scaled to 0 **by the user** — a deliberate stop (the panel's
  Pause writes it; ArgoCD carries `ignoreDifferences` on `spec.replicas` so
  it sticks, and it survives reboots); `inactive` = should be running but is
  not ready (a failure); `unknown` = no apiserver answered. `poll.py` marks
  each k3s miner `paused: true` from the Deployment spec — a paused miner
  reads "Paused", a failed one "Offline".
- **Privilege**: Local hosts use polkit (no sudo). Remote hosts use
  `sudo systemctl` over SSH with touchless key auth (no password prompt).
- **No secrets in argv**: All SSH connections use key-based auth via
  `~/.ssh/config` aliases. The market-data fetches need no API key. The
  GPU probes need no credential of any kind.
- **Bounded output**: All subprocess calls have timeouts and bounded output.

## Architecture

- **`BarWidget.qml`** — Bar entry point, owns the Main data instance
- **`Panel.qml`** — Panel presentation and keyboard handling
- **`Main.qml`** — Data model, owns the polling process and the revenue fetch
- **`Model.js`** — Thresholds and the GPU alert rules (heat/VRAM; unreliable
  sensors excluded)
- **`fleet.py`** — Fleet definition (one source of truth): miners (`FLEET`)
  and the GPU view (`GPU_FLEET`), plus the shared ssh mux options
- **`poll.py`** — Polls all miners and embeds the GPU view; emits one JSON
- **`gpu.py`** — Read-only GPU/workload/k8s/model probes: one ssh session
  per host per refresh (loopback curls run ON the host), ~20 s cache for the
  live sections and ~300 s for the model-file scan
- **`prl-revenue`** — Pool rate + PRL price → $/hour · $/day · $/month
- **`xmr-revenue`** — Pool rate + XMR price → the krash3 CPU miner's $/day
- **`miner-control`** — Privileged entry point for miner control (kubectl /
  systemd / NSSM)
- **`components/`** — `GpuRow`, `WorkloadRow`, `ModelRow`, `SectionLabel`,
  plus the existing `ErrorBanner` / `StatPill`
- **`run-gates.sh`** — Plugin gates (G1–G28)

### Polling budget

Miners refresh every `refreshIntervalSec` (default 10 s; broker-first via
miner-telemetry). The GPU view is served from a ~20 s cache inside `gpu.py`;
the model-file scan refreshes every ~300 s (forge's 15 GB RAM never sees a
heavier load than that). All probes share the SSH multiplexing master
connection, so repeat cycles are cheap.

## License

MIT — see [LICENSE](./LICENSE)

## Removing

To uninstall:

```bash
omarchy plugin remove io.github.jkro.miners
```

What remains after removal:
- **Kept**: None. The plugin registers no keyring entries, systemd units,
  sudoers rules, or persistent daemons. It only reads GPU/miner/model state;
  it does not write state files.
- **Removed with the plugin**: the bar widget, panel, and helper scripts. No
  hooks are left behind in `theme-set.d/` (this plugin does not install any).
- **Persists**: The miners themselves and their systemd/NSSM units are owned
  by the hosts — the plugin only queries and controls them, so they keep
  running untouched. Your `~/.ssh/config` aliases (`zephyr`, `nexus`,
  `forge`, `sentry`, `krash2`, `krash3`) used for remote reads are not
  modified by this plugin.
