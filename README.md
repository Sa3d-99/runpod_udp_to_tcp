# Isaac Sim on RunPod — browser access that actually works (noVNC)

Run NVIDIA Isaac Sim on a RunPod pod and use its **full GUI in your browser**.
Works on **all Isaac Sim versions** (4.0 → 5.x). No UDP, no WebRTC, no ICE, no
TURN, no Direct-TCP ports — one HTTP port and you're done.

One script. One command. That's the whole repo.

## Easiest way — deploy the ready-made template

A public RunPod template is already set up with everything below. **Nothing to
install, nothing to configure.**

### 👉 [**Deploy: Isaac-Sim-Official**](https://console.runpod.io/deploy?template=4qyomso891)

Or find it manually: RunPod → **Templates** → search **`Isaac-Sim-Official`**
(template id `4qyomso891`).

1. **Pick an RTX 4090.** (RTX 50-series does **not** work — see below.)
2. **Deploy.** Wait ~2–3 minutes for boot + Isaac Sim to load.
3. **Connect → HTTP Service → port 8080.**

The Isaac Sim desktop opens in your browser. Load your scene with
**File → Open**. Done.

> Building your own template instead? The exact settings are in
> [TEMPLATE.md](TEMPLATE.md).

### ⚠️ GPU: use an RTX 4090, not a 5080/5090

Isaac Sim 4.0.0 predates the RTX 50-series (Blackwell, compute capability 12.0).
On a 5080/5090 it logs `unsupported by this version` and the viewport never
renders — a grey window, no matter how healthy the desktop is. Ada/Ampere cards
(**RTX 4090**, 3090, A6000, L40S) work.

Blackwell support needs Isaac 4.5+/5.x/6.x — but those images run as an
unprivileged user with no sudo and a read-only `/usr`, so the desktop can't be
installed there. **RTX 4090 + Isaac 4.0.0 is the combination that works.**

## Manual install — one command, nothing pre-installed

If you're on your own pod rather than the template:

```bash
curl -fsSL https://raw.githubusercontent.com/Sa3d-99/runpod_noVNC_isaac_sim/main/bootstrap.sh | bash
```

Downloads the repo (no git needed), installs every dependency, starts the
desktop, launches Isaac Sim, and **prints your real URL** — no placeholder to
fill in. It's also saved to `/workspace/novnc-logs/novnc_url.txt`.

**Requirements:** port **8080** exposed as an **HTTP** port, and an Isaac image
that runs as **root** — use `nvcr.io/nvidia/isaac-sim:4.0.0`. Isaac 5.x/6.x
images run as an unprivileged user with no sudo and a read-only `/usr`, so
nothing can be installed there and the desktop can't start.

Already have the repo on the pod?

```bash
cd /workspace/runpod_noVNC_isaac_sim && bash novnc.sh
```

## Stopping it

```bash
cd /workspace/runpod_noVNC_isaac_sim && bash stop.sh
```

Stops the desktop and the Isaac Sim GUI, and leaves the pod running. Start it
again any time with `bash novnc.sh`.

`stop.sh` deliberately leaves the container's *own* Isaac process alone — that
one is the container's main process, and killing it would stop the whole pod.

**To stop paying, stop the POD itself** in the RunPod console. `stop.sh` only
shuts down the desktop inside the pod; the pod keeps billing until you stop or
terminate it.

## How it works

```
Isaac Sim GUI  →  renders into a virtual X screen (Xvfb, on the GPU)
                       ↓
                  x11vnc  exposes that screen as VNC on localhost:5900
                       ↓
              websockify + noVNC  serve it as a web page on :8080
                       ↓
        RunPod HTTP proxy (TCP)  →  your browser
```

Isaac Sim never streams anything itself, and is never modified. We let it draw
its normal GUI into a virtual screen and ship those pixels over HTTP — the one
thing RunPod's network does well.

## Why Isaac's own streaming can't work on RunPod

| | Isaac WebRTC / native streaming | noVNC (this repo) |
|---|---|---|
| Transport | **UDP** (SRTP media) + ICE | **TCP** (HTTP + WebSocket) |
| RunPod support | ❌ no inbound UDP at all, ever | ✅ exactly what the HTTP proxy carries |
| Needs reachable public IPs | ✅ — but Isaac only advertises `127.0.0.1` / `172.18.0.2` | ❌ irrelevant |
| Ports to expose | 3+ Direct TCP ports, remapped every restart | 1 HTTP port (already there) |
| Isaac version differences | config keys move, and were removed in 5.x | ❌ none — Isaac isn't touched |
| Load your own scene | ❌ | ✅ full mouse/keyboard |

The full investigation — every approach tried, the exact failure of each, and why
noVNC wins — is in **[POSTMORTEM.md](POSTMORTEM.md)**.

## Automatic on pod boot

RunPod console → Edit Pod → **Container Start Command**:

```bash
bash -c "curl -fsSL https://raw.githubusercontent.com/Sa3d-99/runpod_noVNC_isaac_sim/main/bootstrap.sh | bash; sleep infinity"
```

That's the whole thing. No git, no root assumption, nothing to pre-install — it
downloads, installs, and starts the desktop on every boot. Pod start =
browser-ready Isaac Sim, and the URL is waiting in
`/workspace/novnc-logs/novnc_url.txt`.

The `sleep infinity` keeps the container alive after the script detaches.

## Options

```bash
WEB_PORT=8080          # HTTP port noVNC is served on (must be exposed as HTTP)
RES=1920x1080          # virtual screen resolution
VNC_PASSWORD=secret    # add a VNC password (default: none — pod is private)
NO_ISAAC=1             # bring up the desktop only, launch Isaac yourself
ISAAC_ROOT=/isaac-sim  # where Isaac lives
```

Example: `RES=2560x1440 VNC_PASSWORD=hunter2 bash novnc.sh`

## Troubleshooting

Everything is detached (`setsid`) — SSH/terminal drops will **not** kill it.

```bash
# is the whole stack up?
ss -ltn | grep -E ':(5900|8080) '        # VNC + noVNC listening
pgrep -af 'Xvfb|x11vnc|websockify'       # display + VNC + web
tail -20 /workspace/novnc-logs/isaac-gui.log
```

| Symptom | Cause / fix |
|---|---|
| Page loads, grey/empty desktop | Isaac still starting (1–2 min). Check `isaac-gui.log`. |
| Page won't load at all | 8080 not exposed as HTTP in the pod config, or websockify died — see `websockify.log`. |
| Isaac window never appears | Look for a Vulkan/GL error in `isaac-gui.log` — the GPU couldn't present to the virtual display. |
| Everything died after a restart | Re-run `bash novnc.sh` — it's idempotent and cleans up its own previous run. |

⚠️ **Never kill the Isaac process the container itself started**
(`omni.isaac.sim.headless.*.kit`, usually PID ~54). On the RunPod image it is the
container's **main process** — killing it stops the whole container: SSH drops,
your work is gone, port mappings change. `novnc.sh` only ever touches the desktop
stack and the GUI instance it launched itself.

## Files

| File | Purpose |
|---|---|
| `bootstrap.sh` | **Start here.** Downloads the repo without git, then runs `novnc.sh`. |
| `novnc.sh` | The method. Virtual display + VNC + noVNC + Isaac GUI. |
| `stop.sh` | Stops the desktop cleanly (leaves the pod and its main process alive). |
| `install.sh` | Installs all dependencies via apt + pip. Called automatically; idempotent. |
| `requirements.txt` | Python dependencies (`websockify`). Also documents the apt-only system packages. |
| `TEMPLATE.md` | RunPod template settings + the description text to paste. |
| `POSTMORTEM.md` | Every approach tried, why each failed, why noVNC won. |

## Security

The noVNC endpoint has **no authentication by default** — anyone with the URL can
view and control the sim. Set `VNC_PASSWORD=...` if the pod URL might be shared,
and stop the pod when you're not using it.
