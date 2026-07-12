# Isaac Sim on RunPod — working browser access (noVNC)

Run NVIDIA Isaac Sim on a RunPod pod and use its **full GUI in your browser**.
Works on **all Isaac Sim versions** (4.0 → 5.x). No UDP, no WebRTC, no ICE, no
TURN, no Direct-TCP ports.

> **Status:** ✅ noVNC is the working, supported method.
> The WebRTC/TURN approach (`turn_bridge.sh`, `start_all.sh`) is kept only as a
> reference for what was tried — see [POSTMORTEM.md](POSTMORTEM.md). Don't start there.

## Quick start

```bash
# on the pod (SSH is more reliable than the web terminal)
cd /workspace
git clone https://github.com/Sa3d-99/runpod_noVNC_isaac_sim.git
cd runpod_noVNC_isaac_sim && chmod +x *.sh
bash novnc.sh
```

Open the URL it prints:

```
https://<POD_ID>-8080.proxy.runpod.net/vnc.html?autoconnect=1&resize=remote
```

(also saved to `/workspace/novnc-logs/novnc_url.txt`)

Isaac Sim's GUI appears on the desktop after 1–2 minutes. Load your scene with
**File → Open**. Mouse and keyboard work normally.

Requirements: port **8080** exposed as an **HTTP** port (default on the Isaac
images). Nothing else to configure — no Direct TCP ports, no TURN, no port
mapping to copy.

## Why this works when Isaac's own streaming doesn't

| | Isaac WebRTC / native streaming | noVNC (this repo) |
|---|---|---|
| Transport | **UDP** (SRTP media) + ICE | **TCP** (HTTP + WebSocket) |
| RunPod support | ❌ no inbound UDP at all | ✅ exactly what the HTTP proxy carries |
| Needs reachable public IPs | ✅ (Isaac only advertises `127.0.0.1`, `172.18.0.2`) | ❌ irrelevant |
| Ports to expose | 3+ Direct TCP ports, remapped on every restart | 1 HTTP port (already there) |
| Isaac version differences | config keys move/disappear across 4.0/4.2/5.x | ❌ none — Isaac isn't modified |

**The mechanism:**

```
Isaac Sim GUI  →  renders into a virtual X screen (Xvfb, on the GPU)
                       ↓
                  x11vnc  exposes that screen as VNC on localhost:5900
                       ↓
              websockify + noVNC  serve it as a web page on :8080
                       ↓
        RunPod HTTP proxy (TCP)  →  your browser
```

Isaac Sim never streams anything itself. We just capture the desktop it draws
and ship the pixels over HTTP — the one thing RunPod's network does well.

## Automatic on pod boot

RunPod console → Edit Pod → **Container Start Command**:

```bash
bash -c "command -v git >/dev/null || (apt-get update && apt-get install -y git); cd /workspace && (test -d runpod_noVNC_isaac_sim || git clone https://github.com/Sa3d-99/runpod_noVNC_isaac_sim.git) && cd runpod_noVNC_isaac_sim && chmod +x *.sh && bash novnc.sh && sleep infinity"
```

Clones on first boot, reuses after (`/workspace` is the persistent volume), then
brings the desktop up. Pod start = browser-ready Isaac Sim.

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
| noVNC page loads, grey/empty desktop | Isaac still starting (1–2 min). Check `isaac-gui.log`. |
| Page won't load at all | 8080 not exposed as HTTP in the pod config, or websockify died — see `websockify.log`. |
| Isaac window never appears | Look for a Vulkan/GL error in `isaac-gui.log` — the GPU couldn't present to the virtual display. |
| Everything died after a restart | Just re-run `bash novnc.sh` — it's idempotent and cleans up its own previous run. |

**Never** kill the Isaac process that the container itself started
(`omni.isaac.sim.headless.*.kit`, usually PID ~54). On the RunPod image it is the
container's **main process** — killing it stops the whole container (SSH, your
work, everything). `novnc.sh` only ever touches the desktop stack and the GUI
instance it launched itself.

## Files

| File | Purpose |
|---|---|
| `novnc.sh` | **The method.** Desktop + VNC + noVNC + Isaac GUI. Run this. |
| `POSTMORTEM.md` | Every approach tried, why each failed, and why noVNC won. |
| `turn_bridge.sh`, `start_all.sh`, `install.sh` | Legacy WebRTC/TURN attempt. Kept for reference only — see the postmortem. |

## Security

The noVNC endpoint has **no authentication by default** — anyone with the URL
can view and control the sim. Set `VNC_PASSWORD=...` if the pod URL might be
shared, and stop the pod when you're not using it.
