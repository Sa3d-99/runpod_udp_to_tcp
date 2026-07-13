# RunPod template — description text

**Live template:** [Isaac-Sim-Official](https://console.runpod.io/deploy?template=4qyomso891)
· id `4qyomso891` · public

Paste the block below into the template's **README / description** field.
Everything above the line is notes for you, not for the template.

**Template settings to match it:**

| Setting | Value |
|---|---|
| Container image | `nvcr.io/nvidia/isaac-sim:4.0.0` |
| HTTP Ports | `8080` (label: `novnc`) |
| TCP Ports | `22` (label: `ssh`) |
| Container Start Command | `bash -c "curl -fsSL https://raw.githubusercontent.com/Sa3d-99/runpod_noVNC_isaac_sim/main/bootstrap.sh \| bash; sleep infinity"` |
| Container Disk | 40 GB+ |
| Volume | `/workspace`, 50 GB+ |

> Use the **4.0.0** image. Newer Isaac images (5.x / 6.x) run as an unprivileged
> user with no sudo and a read-only `/usr`, so nothing can be installed and the
> desktop cannot start.

---

## 📋 Template description (copy from here down)

**Isaac Sim with a full GUI in your browser — no setup, no streaming client.**

NVIDIA Isaac Sim's built-in livestreaming needs UDP, which RunPod does not
forward — so the usual result is a grey screen that never loads. This template
solves that a different way: Isaac Sim renders into a virtual display, and you
get the **complete Isaac Sim desktop in your browser** over plain HTTP.

### How to use

1. Pick a GPU and deploy. **Use an RTX 4090** (see GPU note below).
2. Wait ~2–3 minutes for the pod to boot and Isaac Sim to load.
3. Open **Connect → HTTP Service → port 8080**.
4. The Isaac Sim desktop appears. Load your scene with **File → Open**.

That's it. Everything installs and starts automatically on boot.

### What you get

- ✅ The **real Isaac Sim GUI** — full mouse and keyboard, load your own USD scenes
- ✅ Works entirely over **HTTP** — no UDP, no WebRTC, no streaming client, no VPN
- ✅ **Nothing to configure** — one HTTP port, no port mappings to copy after a restart
- ✅ Survives terminal/SSH disconnects (everything runs detached)

### ⚠️ GPU compatibility — read this

| GPU | Works? |
|---|---|
| **RTX 4090**, RTX 3090, A6000, L40S (Ada/Ampere) | ✅ yes |
| RTX 5080 / 5090 (Blackwell) | ❌ **no** |

Isaac Sim 4.0.0 predates the RTX 50-series. On a 5080/5090 it reports
`compute capability 12.0 is unsupported` and the viewport never renders — you get
a grey window. **Pick an RTX 4090.**

(Blackwell needs Isaac 4.5+, but those images run as an unprivileged user where
the desktop cannot be installed — so 4090 is the supported combination.)

### Ports

| Port | Purpose |
|---|---|
| 8080 (HTTP) | The Isaac Sim desktop (noVNC) — this is the one you open |
| 22 (TCP) | SSH, if you want a shell |

### Troubleshooting

- **Grey/empty desktop?** Isaac is still loading — give it 1–2 minutes.
- **Page won't open?** The pod is still booting. Retry after a minute.
- **Restart the desktop:**
  `cd /workspace/runpod_noVNC_isaac_sim && bash novnc.sh`
- **Stop the desktop** (pod keeps running):
  `cd /workspace/runpod_noVNC_isaac_sim && bash stop.sh`
- **Stop being charged:** stop or terminate the **pod** in the RunPod console.

### Security

The desktop has **no password by default** — anyone with the pod URL can control
the sim. Set a `VNC_PASSWORD` environment variable on the pod to require one, and
stop the pod when you're not using it.

### Deploy

[**Deploy this template**](https://console.runpod.io/deploy?template=4qyomso891)
· or search RunPod Templates for **`Isaac-Sim-Official`**

### Source & details

Scripts, and a full write-up of why Isaac's own streaming can't work on RunPod:
https://github.com/Sa3d-99/runpod_noVNC_isaac_sim
