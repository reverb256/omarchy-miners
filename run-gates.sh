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

# --- GPU fleet gates (2.2.0) -------------------------------------------------

printf 'G23 gpu view in poll      : '
python3 ./poll.py | python3 -c "import sys,json;d=json.load(sys.stdin);g=d.get('gpus') or [];ok=g and all(k in g[0] for k in ('host','index','name','util','vramUsed','vramTotal'));print(('ok (%d gpus)'%len(g)) if ok else 'FAIL:'+str(g[:1]))"

printf 'G24 workload sections     : '
python3 ./poll.py | python3 -c "import sys,json;d=json.load(sys.stdin);w=d.get('workloads') or {};ok=all(k in w for k in ('llm','image','audio','transcode')) and isinstance(w.get('llm'),list);print('ok' if ok else 'FAIL:'+str(sorted(w.keys())))"

printf 'G25 identity kept         : '
python3 -c "import json;m=json.load(open('manifest.json'));ok=m['id']=='io.github.jkro.miners' and m['name']=='GPU Fleet';print('ok' if ok else 'FAIL:'+str(m.get('id'))+' '+str(m.get('name')))"

# G26/G27: stopping a miner must never be possible without an explicit click
# plus a confirmation. Static markers: the row's armed-stop state (stopConfirm)
# and the keyboard's armed-stop index (cursorConfirmIndex). Counts print; >=1
# is the pass.
printf 'G26 stop needs confirm    : '
grep -c 'stopConfirm' MinerRow.qml

printf 'G27 keyboard confirm      : '
grep -c 'cursorConfirmIndex' Panel.qml

# G28: the dashboard side stays READ-ONLY. poll.py/gpu.py must contain no
# miner-control / ai-control invocation and no kubectl mutation verb.
printf 'G28 dashboard read-only   : '
python3 - <<'PY'
import re
bad = []
for name in ('poll.py', 'gpu.py'):
    source = open(name).read()
    for token in ("'miner-control'", '"miner-control"', "'ai-control'", '"ai-control"'):
        if token in source:
            bad.append(name + ':' + token.strip("'\""))
    for match in re.finditer(r'^\s*[^#\n]*kubectl[^\n]*$', source, re.M):
        if re.search(r'\b(scale|rollout|delete|apply|patch|annotate|edit)\b', match.group(0)):
            bad.append(name + ':kubectl-mutate')
print('ok' if not bad else 'FAIL:' + ','.join(bad))
PY

# G29: the panel is ONE pane that fits the screen — no Flickable, no scrollbar,
# and one row per configured miner drawn from the merged rows list. Regression
# lock: the panel used to stack a per-GPU list on top of a per-miner list and
# needed a Flickable+ScrollBar to be readable at all.
printf 'G29 single pane, no scroll: '
python3 - <<'PY'
import glob
bad = []
for path in ['Panel.qml', 'MinerRow.qml', 'BarWidget.qml'] + sorted(glob.glob('components/*.qml')):
    # Comments may discuss the old scrolling design; only real code counts.
    lines = [line.split('//')[0] for line in open(path).read().splitlines()]
    source = '\n'.join(lines)
    for token in ('Flickable', 'ScrollBar', 'ScrollView', 'contentY', 'flickableDirection'):
        if token in source:
            bad.append(path + ':' + token)
panel = open('Panel.qml').read()
if 'model: root.rows' not in panel or 'MinerRow {' not in panel:
    bad.append('panel:not-one-row-per-miner')
print('ok' if not bad else 'FAIL:' + ','.join(bad))
PY

# --- Windows read-only collector gates (contract §5) ------------------------

# G30: the contract's hard gate — every host with platform == "windows" MUST be
# monitor-only. The collector is report-only by contract; a control affordance
# on a Windows row would offer a verb neither transport can honour.
printf 'G30 windows monitor-only  : '
python3 - <<'PY'
import sys
sys.path.insert(0, '.')
from fleet import FLEET
windows = [h for h, c in FLEET.items() if c.get("platform") == "windows"]
bad = [h for h in windows if FLEET[h].get("control") != "none"]
print(f"ok ({len(windows)} windows hosts, all control=none)" if windows and not bad
      else "FAIL:" + (",".join(bad) if bad else "no windows hosts found"))
PY

# G31: a SAVED status.json fixture parses to the same row values as the ssh
# path for the same miners — one record builder, two transports, no fork. The
# saved fixtures carry the verbatim API payloads captured from krash2/krash3.
printf 'G31 collector fixture     : '
python3 - <<'PY'
import json, sys
sys.path.insert(0, '.')
import poll
from fleet import FLEET

def rows(host, config, summaries):
    out = []
    for i, entry in enumerate(config["miners"]):
        row = poll.miner_record(host, config, entry, i, summaries.get(entry["port"]),
                                True, False, [], session_text="")
        row.pop("sessionText", None)  # collector-only fact, not from the miners
        out.append(row)
    return out

failures = []

# krash2 (peakminer): the ssh read of miners.<port> IS the fixture's verbatim
# payload, so both transports must produce identical rows.
cfg = FLEET["krash2"]
fixture = json.load(open("fixtures/krash2-status.json"))
validated = poll.validate_collector_payload("krash2", cfg, fixture)
if validated is None:
    failures.append("krash2 fixture rejected by §5 validation")
else:
    collected, extras = poll.collector_summaries(cfg, validated)
    ssh_shaped = {m["port"]: fixture["miners"][str(m["port"])] for m in cfg["miners"]}
    if rows("krash2", cfg, collected) != rows("krash2", cfg, ssh_shaped):
        failures.append("krash2 rows differ between collector and ssh inputs")
    if extras["sessionText"] != "none":
        failures.append(f"krash2 sessionText={extras['sessionText']!r}")
    if extras["gpuPower"] != [117.87]:
        failures.append(f"krash2 gpuPower={extras['gpuPower']!r}")

# krash3 (Kryptex rig): the collector path must land on the same
# kryptex_summary() the ssh path uses, with the aux xmrig port (12000) kept.
cfg3 = FLEET["krash3"]
fixture3 = json.load(open("fixtures/krash3-status.json"))
validated3 = poll.validate_collector_payload("krash3", cfg3, fixture3)
if validated3 is None:
    failures.append("krash3 fixture rejected by §5 validation")
else:
    collected3, extras3 = poll.collector_summaries(cfg3, validated3)
    gpu0 = fixture3["gpus"][0]
    ssh_shaped3 = poll.kryptex_summary(
        cfg3["miners"][0]["port"],
        fixture3["miners"]["12008"], fixture3["miners"]["12000"],
        gpu0["power_w"], gpu0["util_pct"],
    )
    if rows("krash3", cfg3, collected3) != rows("krash3", cfg3, ssh_shaped3):
        failures.append("krash3 rows differ between collector and ssh inputs")
    if extras3["sessionText"] != "in use":
        failures.append(f"krash3 sessionText={extras3['sessionText']!r}")
    # Only DECLARED ports survive: a payload carrying a foreign port must not
    # extend the row set beyond the profile's declared ports.
    polluted = json.loads(json.dumps(fixture3))
    polluted["miners"]["1337"] = {"junk": True}
    filtered = poll.validate_collector_payload("krash3", cfg3, polluted)
    if filtered is None or 1337 in filtered["miners"]:
        failures.append("undeclared port 1337 survived validation")
    # The gaming-throttle signal: a 1-minute window collapsed to a quarter of
    # the sustained 1-hour rate must flag the row throttled (and clear again
    # when the windows agree).
    throttled_payload = json.loads(json.dumps(fixture3))
    arm = throttled_payload["miners"]["12008"]["algorithms"][0]["hashrate"]
    arm["1min"] = arm["1hr"] * 0.25
    tap = poll.validate_collector_payload("krash3", cfg3, throttled_payload)
    tsum, _ = poll.collector_summaries(cfg3, tap)
    if not tsum[12008]["throttled"]:
        failures.append("a 1min/1hr collapse did not flag throttled")
    if tsum[12008]["srbWindows"].get("1hr") != fixture3["miners"]["12008"]["algorithms"][0]["hashrate"]["1hr"]:
        failures.append("the throttle windows were reshaped")

print("ok (both hosts: identical rows on both transports)" if not failures
      else "FAIL:" + "; ".join(failures))
PY

# G32: krash2 is quarantined — its payload is HOSTILE input. Served over a real
# HTTP endpoint: an oversized body, a wrong-typed body, a wrong-host body and a
# readonly:false body must each be a FAILED PROBE that falls back to the ssh
# read (monkeypatched to a sentinel), must never raise, and must leak no
# payload data into the result or the extras.
printf 'G32 hostile payloads      : '
python3 - <<'PY'
import http.server, json, sys, threading
sys.path.insert(0, '.')
import poll
from fleet import FLEET

class FixtureServer(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.server.body
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureServer)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}/status.json"

def config_for(url):
    cfg = dict(FLEET["krash2"])
    cfg["collector"] = {"url": url, "timeout": 2.0}
    return cfg

krash2 = json.load(open("fixtures/krash2-status.json"))
oversized = json.loads(json.dumps(krash2))
oversized["gpus"][0]["name"] = "pad " + "x" * (300 * 1024)  # valid JSON, > 256 KB

cases = [
    ("oversized", json.dumps(oversized).encode()),
    ("wrong-type", open("fixtures/hostile-wrong-type.json", "rb").read()),
    ("bad-host", open("fixtures/hostile-bad-host.json", "rb").read()),
    ("readonly-false", open("fixtures/hostile-readonly-false.json", "rb").read()),
]
failures = []

# POSITIVE CONTROL first: a valid payload must be used — the ssh read must NOT
# run (it raises if it does). A gate that rejects everything cannot pass.
def forbidden(_):
    raise AssertionError("ssh read ran although the collector answered")

server.body = open("fixtures/krash2-status.json", "rb").read()
sentinel = poll.query_host_over_ssh
poll.query_host_over_ssh = forbidden
try:
    extras = {}
    result = poll.probe_host("krash2", config_for(base), extras)
finally:
    poll.query_host_over_ssh = sentinel
if result != {4069: krash2["miners"]["4069"]}:
    failures.append("valid payload did not reach the rows")

# Then the hostile bodies: each must degrade to the ssh fallback.
def ssh_fallback(_):
    return {4069: {"sentinel": "ssh-path"}}

poll.query_host_over_ssh = ssh_fallback
try:
    for label, body in cases:
        server.body = body
        extras = {}
        try:
            result = poll.probe_host("krash2", config_for(base), extras)
        except Exception as error:  # noqa: BLE001 - raising IS the failure
            failures.append(f"{label}: raised {error!r}")
            continue
        if result != {4069: {"sentinel": "ssh-path"}}:
            failures.append(f"{label}: no ssh fallback ({result!r})")
        if "HOSTILE_MARKER" in json.dumps(result) or extras:
            failures.append(f"{label}: payload data leaked ({result!r} {extras!r})")
        if poll.query_collector("krash2", config_for(base)) is not None:
            failures.append(f"{label}: not reported as a failed probe")
finally:
    poll.query_host_over_ssh = sentinel
    server.shutdown()

print("ok (4 hostile bodies rejected → probe failed → ssh fallback)" if not failures
      else "FAIL:" + "; ".join(failures))
PY

# --- AI workload control gates (ai-control + poll.py `ai` section) -----------

# G33: failover parity with G21, for ai-control. The pinned apiserver is dead;
# the action must still land via a peer ("retrying via" on stderr proves the
# failover path ran). Also asserts the candidate lists in ai-control and
# miner-control stay IDENTICAL — the copies are deliberate (neither script can
# break the other), and this check is what keeps them from drifting apart.
printf 'G33 ai-control failover    : '
python3 - <<'PY'
import importlib.machinery, importlib.util, json, os, re, subprocess, tempfile
from pathlib import Path

def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module

ai = load("ai_control", "./ai-control")
miner = load("miner_control", "./miner-control")

failures = []
if ai.K8S_API_CANDIDATES != miner.K8S_API_CANDIDATES:
    failures.append(f"candidates drifted: {ai.K8S_API_CANDIDATES} vs {miner.K8S_API_CANDIDATES}")
if ai.UNREACHABLE_MARKERS != miner.UNREACHABLE_MARKERS:
    failures.append("unreachable-marker lists drifted")
if ai.K8S_PROBE_TIMEOUT != miner.K8S_PROBE_TIMEOUT:
    failures.append("probe timeouts drifted")

config = Path.home() / ".kube" / "config"
patched = re.sub(r"https://[0-9.]+:6443", "https://10.1.1.199:6443", config.read_text())
with tempfile.NamedTemporaryFile("w", suffix="-kubeconfig", delete=False) as handle:
    handle.write(patched)
    bad_config = handle.name
try:
    env = dict(os.environ, KUBECONFIG=bad_config)
    run = subprocess.run(
        ["python3", "./ai-control", "status", "llama-nexus-3060ti"],
        capture_output=True, text=True, timeout=60, env=env,
    )
finally:
    os.unlink(bad_config)
try:
    answer = json.loads(run.stdout)
except ValueError:
    answer = {"raw": run.stdout, "err": run.stderr}
if not (answer.get("ok") and answer.get("state") in ("active", "paused")):
    failures.append(f"failover answer: {answer}")
elif "retrying via" not in run.stderr:
    failures.append("no retry breadcrumb on stderr — failover may not have run")
print("ok (failover, candidate lists in step)" if not failures
      else "FAIL:" + "; ".join(failures))
PY

# G34: pause vs failure for AI rows (mirrors G22). A workload scaled to 0 must
# read "paused" in BOTH surfaces (ai-control state and poll.py's per-row
# `paused`/`desired`), agreeing with the Deployment spec — so a deliberate
# pause can never be reported as a failure, and a failure can never hide
# behind `paused`. Works in both states. Probes llama-nexus-3060ti (idle).
printf 'G34 AI pause vs failure   : '
python3 - <<'PY'
import json, os, subprocess, sys
from pathlib import Path
sys.path.insert(0, '.')
from fleet import AI_WORKLOADS

wid = 'llama-nexus-3060ti'
deploy = AI_WORKLOADS[wid]['deploy']

env = dict(os.environ)
env.setdefault('KUBECONFIG', str(Path.home() / '.kube' / 'config'))
raw = subprocess.run(
    ['kubectl', '-n', 'mining', 'get', 'deploy', deploy, '-o', 'json'],
    capture_output=True, text=True, env=env, timeout=30,
).stdout
spec = int(json.loads(raw)['spec']['replicas']) if raw else -1

state = json.loads(subprocess.run(
    ['python3', './ai-control', 'status', wid],
    capture_output=True, text=True, timeout=30,
).stdout).get('state')

poll = json.loads(subprocess.run(
    ['python3', './poll.py'], capture_output=True, text=True, timeout=60,
).stdout)
row = next((x for x in (poll.get('ai') or {}).get('rows', []) if x.get('id') == wid), None)

paused = spec == 0
ok = (row is not None
      and row.get('desired') == spec
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

# G35: stopping/switching an AI workload must never be possible without an
# explicit click plus confirmation (mirrors G26/G27). Static markers: the
# row's armed-stop state (stopConfirm) and the switch chip's armed state
# (switchConfirm). Both present = 2.
printf 'G35 AI stop+switch confirm: '
python3 -c "src=open('AiRow.qml').read();print(int('stopConfirm' in src)+int('switchConfirm' in src))"

# G36: an unknown workload id must be REFUSED before any control surface is
# touched (mirrors G9 — ok:false IS the pass).
printf 'G36 refuses unknown id    : '
python3 ./ai-control stop llama-99999 |
  python3 -c "import sys,json;print(json.load(sys.stdin)['ok'])"

# G37: the poll's `ai` section carries the miner-row contract for every
# registry workload: managed / desired / paused / state, the switch pair is
# marked both ways, and workload probe records are marked managed vs the
# read-only unmanaged endpoints (host llama-swap / LM Studio / ollama).
printf 'G37 AI rows contract      : '
python3 - <<'PY'
import json, subprocess, sys
sys.path.insert(0, '.')
from fleet import AI_WORKLOADS

poll = json.loads(subprocess.run(
    ['python3', './poll.py'], capture_output=True, text=True, timeout=60,
).stdout)
rows = (poll.get('ai') or {}).get('rows') or []
by_id = {row.get('id'): row for row in rows}

failures = []
if len(rows) != len(AI_WORKLOADS) or set(by_id) != set(AI_WORKLOADS):
    failures.append(f"rows {len(rows)} vs registry {len(AI_WORKLOADS)}")
for wid, row in by_id.items():
    for key in ('managed', 'desired', 'paused', 'state', 'switchGroup',
                'switchSiblings', 'host', 'label', 'deploy', 'ns'):
        if key not in row:
            failures.append(f"{wid}: missing {key}")
    if row.get('managed') is not True:
        failures.append(f"{wid}: not managed")
    if row.get('state') not in ('active', 'paused', 'inactive', 'unknown'):
        failures.append(f"{wid}: bad state {row.get('state')!r}")
    if isinstance(row.get('desired'), int):
        if bool(row.get('paused')) != (row['desired'] == 0):
            failures.append(f"{wid}: paused != (desired == 0)")
    elif row.get('paused') is not False:
        failures.append(f"{wid}: no-answer row reads paused")

# The 3090 switch group: the two variants point at each other, and a workload
# without a group has no siblings.
a, b = by_id.get('llama-zephyr-3090'), by_id.get('llama-zephyr-3090-pq2')
if not a or not b \
        or a.get('switchSiblings') != ['llama-zephyr-3090-pq2'] \
        or b.get('switchSiblings') != ['llama-zephyr-3090']:
    failures.append("3090 switch group not paired")
for wid, row in by_id.items():
    if not row.get('switchGroup') and row.get('switchSiblings'):
        failures.append(f"{wid}: siblings without a group")

# Endpoint records: the k8s-managed probes carry the desired/paused view and
# are MARKED managed; the rest are marked unmanaged (read-only).
llm = (poll.get('workloads') or {}).get('llm') or []
managed = [r for r in llm if r.get('managed') is True]
unmanaged = [r for r in llm if r.get('managed') is False]
if not managed or not unmanaged:
    failures.append(f"endpoint marks: {len(managed)} managed / {len(unmanaged)} unmanaged")
if any(r.get('paused') is None for r in managed):
    failures.append("managed endpoint record without the desired/paused view")

print(
    f"ok ({len(rows)} rows, 1 switch pair, {len(managed)} managed + {len(unmanaged)} unmanaged endpoints)"
    if not failures else "FAIL:" + "; ".join(failures)
)
PY

# G38: the switch plan is ordered and refuses non-group workloads. Pure check
# (no cluster calls): the siblings are stopped FIRST (one GPU — free the card
# before the new variant loads), then the picked variant starts.
printf 'G38 switch stops sibling   : '
python3 - <<'PY'
import importlib.machinery, importlib.util

loader = importlib.machinery.SourceFileLoader("ai_control", "./ai-control")
spec = importlib.util.spec_from_loader("ai_control", loader)
ai = importlib.util.module_from_spec(spec)
loader.exec_module(ai)

failures = []
plan = ai.switch_plan('llama-zephyr-3090-pq2', ai.AI_WORKLOADS['llama-zephyr-3090-pq2'])
if plan != [('llama-zephyr-3090', 'stop'), ('llama-zephyr-3090-pq2', 'start')]:
    failures.append(f"pq2 plan {plan!r}")
plan = ai.switch_plan('llama-zephyr-3090', ai.AI_WORKLOADS['llama-zephyr-3090'])
if plan != [('llama-zephyr-3090-pq2', 'stop'), ('llama-zephyr-3090', 'start')]:
    failures.append(f"3090 plan {plan!r}")
if ai.switch_plan('comfyui-zephyr', ai.AI_WORKLOADS['comfyui-zephyr']) is not None:
    failures.append("non-group workload planned a switch")
print("ok (siblings stopped first, then the pick; non-group refused)"
      if not failures else "FAIL:" + "; ".join(failures))
PY
