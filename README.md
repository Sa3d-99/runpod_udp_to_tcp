# Isaac Sim on RunPod — fixing the blank/gray live stream

## Root cause (30 seconds)

Isaac Sim streams with **WebRTC**:

| Traffic | Protocol | Through RunPod HTTP proxy (80/8080/8211)? |
|---|---|---|
| Client web page + signaling | TCP / HTTP / WebSocket | ✅ works — that's why the page loads |
| Video/audio media (SRTP) | **UDP 47998** (+ neighbors) | ❌ RunPod forwards **no inbound UDP at all** |

So the browser negotiates a session, then never receives a frame → gray canvas, dead clicks.

**Why a raw `socat` UDP→TCP wrap can't fix it:** the receiving end of that UDP is your *browser's* WebRTC stack. It only speaks ICE/DTLS/SRTP on ports it negotiated itself — there is nothing on your laptop to unwrap a homemade TCP stream. The tunnel has to be something the browser natively understands. There are exactly two standards-compliant options, both scripted here.

## Option A — `turn_bridge.sh` (Isaac Sim ≤ 4.2, browser-only, best latency)

A TURN relay (coturn) runs inside the pod. Browsers know how to push WebRTC media through TURN **over TCP** (`?transport=tcp`). Path:

```
browser ⇄ TCP ⇄ RunPod Direct-TCP port ⇄ coturn (in pod) ⇄ UDP (pod-internal) ⇄ Isaac Sim
```

This *is* the UDP-to-TCP tunnel you asked for — done with the one protocol the browser accepts.

### Steps

1. **Expose one Direct TCP port** (the HTTP proxy cannot carry TURN — it only speaks HTTP):
   RunPod console → your Pod → **Edit Pod** → *Expose TCP Ports* → add `3478` → save (pod restarts).
   Then **Connect → Direct TCP Ports** shows e.g. `203.0.113.7:14523 → :3478`.

2. **Run the bridge** inside the container, with the values from step 1:

   ```bash
   TURN_PUBLIC_IP=203.0.113.7 TURN_PUBLIC_PORT=14523 bash turn_bridge.sh
   ```

   It installs coturn, patches the Isaac Sim WebRTC extension's `iceServers`
   (backup kept as `extension.toml.bak`), and leaves coturn running supervised
   in the background.

3. **Restart Isaac Sim streaming**:

   ```bash
   cd /isaac-sim && ./runheadless.webrtc.sh -v
   ```

4. **Open in Chrome/Chromium** (Firefox unreliable per NVIDIA docs):

   ```
   https://<POD_ID>-8211.proxy.runpod.net/streaming/webrtc-client?server=<POD_ID>-8211.proxy.runpod.net
   ```

### Verify / troubleshoot

- `ss -ltn | grep 3478` → coturn listening.
- `tail -f /workspace/stream-bridge-logs/coturn.log` → you should see `allocation` lines when the browser connects.
- In Chrome open `chrome://webrtc-internals` → the succeeded candidate pair must show type `relay`.
- Isaac Sim UDP media ports visible with `ss -lunp | grep -i kit`.

## Option B — `tailscale_bridge.sh` (⚠️ limited on RunPod — read this first)

**Why "both devices connected" still gives a gray screen on RunPod:**

1. RunPod containers have **no `/dev/net/tun`** and no `CAP_NET_ADMIN`. A normal
   Tailscale install (`curl … | sh && tailscale up`) starts, registers the device
   (so it shows *Connected* in the admin console), but the kernel tunnel device
   cannot be created — `tailscaled` logs `CreateTUN failed` and there is **no data
   path**. The device looks online; nothing routes.
2. The only mode that runs at all is `--tun=userspace-networking` (what this
   script uses). That mode proxies traffic through a userspace network stack:
   inbound connections are *terminated and re-originated*, so the **UDP source
   address Isaac Sim sees is rewritten**, and the pod **cannot send raw outbound
   UDP** to tailnet IPs. WebRTC's ICE handshake requires both — coherent peer
   addresses and server-originated UDP checks — so **WebRTC media fails even
   though `tailscale ping` and SSH work fine**.

Net result: Tailscale on a RunPod *container* is good for TCP (SSH, HTTP APIs,
Jupyter) but **not for Isaac Sim's WebRTC stream**. On a real VM or bare-metal
host with `/dev/net/tun` (your own server, EC2, etc.) this option works fully —
that's where the script is worth using. On RunPod, use **Option A (TURN)**.

### If you're on Isaac Sim 5.x (no TURN config, on RunPod)

Realistic paths, in order of effort:

1. **Run the ≤ 4.2 streaming container** for remote viewing (e.g.
   `nvcr.io/nvidia/isaac-sim:4.2.0`) and use Option A.
2. **Browser-side TURN with NVIDIA's open web viewer**: only the *browser* needs
   the TURN relay — the relay candidate lives on the pod's own IP, which the
   Isaac Sim server can reach locally. Build NVIDIA's
   [web-viewer-sample](https://github.com/NVIDIA-Omniverse/web-viewer-sample)
   with `iceServers: [{ urls: "turn:<PUBLIC_IP>:<PORT>?transport=tcp", … }]` in
   its RTC config, serve it on port 8080 (RunPod HTTP proxy), and keep coturn
   from `turn_bridge.sh` running.
3. **Move off RunPod's proxy** to a provider that gives a full VM / UDP ingress.

### Steps

1. Create a reusable auth key: https://login.tailscale.com/admin/settings/keys
2. In the container:

   ```bash
   TS_AUTHKEY=tskey-auth-XXXXX bash tailscale_bridge.sh
   ```

3. Install Tailscale on your laptop (https://tailscale.com/download), same account.
4. Restart Isaac Sim streaming, then open the URL the script prints, e.g.

   ```
   http://100.x.y.z:8211/streaming/webrtc-client?server=100.x.y.z     # ≤ 4.2
   ```

   For Isaac Sim 4.5/5.x use the *Isaac Sim WebRTC Streaming Client* desktop app with server = the tailnet IP.

## Auto-start: `start_all.sh` (recommended)

Fully automatic — no arguments, no env vars. After the one-time TCP-port step
(Option A step 1), RunPod injects `RUNPOD_PUBLIC_IP` and `RUNPOD_TCP_PORT_3478`
into the container; the script detects them, starts the TURN bridge, starts
Isaac Sim, and prints your personal stream URL:

```bash
./start_all.sh
```

The URL is printed in a banner and saved to `/workspace/stream-bridge-logs/stream_url.txt`:

```
https://<POD_ID>-8211.proxy.runpod.net/streaming/webrtc-client?server=<POD_ID>-8211.proxy.runpod.net
```

(`<POD_ID>` filled in automatically from `RUNPOD_POD_ID`.)

Manual overrides if ever needed: `TURN_PUBLIC_IP=<ip> TURN_PUBLIC_PORT=<port> ./start_all.sh`,
or `TS_AUTHKEY=…` for Tailscale mode on non-RunPod hosts.

### Fully automatic on pod boot

RunPod console → Edit Pod → **Container Start Command**:

```bash
bash -c "cd /workspace && (test -d isaac-stream-bridge || git clone https://github.com/<YOUR_USER>/isaac-stream-bridge.git) && cd isaac-stream-bridge && chmod +x *.sh && ./start_all.sh"
```

Clones on first boot, reuses on later boots (`/workspace` is the persistent volume), then runs everything.

## Deploy via GitHub

On your machine:

```bash
cd ~/Documents/Runpod/isaac-stream-bridge
git init && git add . && git commit -m "Isaac Sim RunPod stream bridge"
# create an empty repo named isaac-stream-bridge on github.com, then:
git remote add origin https://github.com/<YOUR_USER>/isaac-stream-bridge.git
git branch -M main && git push -u origin main
```

On the pod (web terminal or SSH):

```bash
cd /workspace
git clone https://github.com/<YOUR_USER>/isaac-stream-bridge.git
cd isaac-stream-bridge && chmod +x *.sh
./start_all.sh        # everything auto-detected (TURN port must be exposed once, see Option A)
```

> Never commit your `TS_AUTHKEY` or TURN credentials to the repo — pass them
> as environment variables at run time only.

## Which one?

| | Option A (TURN) | Option B (Tailscale) |
|---|---|---|
| Isaac Sim version | ≤ 4.2 (or 5.x via web-viewer-sample) | any |
| Works on RunPod containers | ✅ | ❌ WebRTC media (TCP-only there) |
| Works on own VM / bare metal | ✅ | ✅ |
| Pod config change | 1 Direct-TCP port | none |
| Extra account | none | free Tailscale account |

On RunPod: use **A**. Option B is for hosts with `/dev/net/tun` (own VM, EC2, workstation).

## Security note

Isaac Sim's streaming endpoints have **no authentication or encryption**. The TURN relay is credential-protected (random secret in `/workspace/.turn_secret`), but the 8211 signaling endpoint behind the RunPod proxy is reachable by anyone with the URL. Don't leave it running unattended; Option B keeps everything inside your private tailnet and is the safer default.
