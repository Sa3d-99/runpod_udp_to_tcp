# Isaac Sim on RunPod — fixing the blank/gray live stream

UDP-to-TCP bridge so the Isaac Sim WebRTC live stream works through RunPod's
TCP-only networking. Tested target: `nvcr.io/nvidia/isaac-sim:4.0.0`.

## Root cause (30 seconds)

Isaac Sim streams with **WebRTC**:

| Traffic | Protocol | Through RunPod HTTP proxy (80/8080/8211)? |
|---|---|---|
| Client web page + signaling | TCP / HTTP / WebSocket | ✅ works — that's why the page loads |
| Video/audio media (SRTP) | **UDP 47998** (+ neighbors) | ❌ RunPod forwards **no inbound UDP at all** |

So the browser negotiates a session, then never receives a frame → gray canvas, dead clicks.

A raw `socat` UDP→TCP wrap can't fix it: the receiving end is your *browser's*
WebRTC stack, which only speaks ICE/DTLS/SRTP. The standards-compliant way to
force WebRTC media over TCP is a **TURN relay** with `?transport=tcp` — that is
what this repo sets up:

```
browser ⇄ TCP ⇄ RunPod Direct-TCP port ⇄ coturn (in pod) ⇄ UDP (pod-internal) ⇄ Isaac Sim
```

## Quick start

### 1. One-time pod setup

RunPod console → your Pod → **Edit Pod** → *Expose TCP Ports* → add `3478` → save
(pod restarts). RunPod then injects `RUNPOD_PUBLIC_IP` and `RUNPOD_TCP_PORT_3478`
into the container — the scripts auto-detect them, you never type an IP.

### 2. Run

In the pod web terminal (or SSH):

```bash
cd /workspace
git clone https://github.com/Sa3d-99/runpod_udp_to_tcp.git
cd runpod_udp_to_tcp && chmod +x *.sh
./start_all.sh
```

`start_all.sh` does everything: installs dependencies (`install.sh`: git,
python3, coturn, iproute2), starts the coturn TURN relay supervised in the
background, patches the Isaac Sim WebRTC extension's `iceServers` (backup kept
as `extension.toml.bak`), prints your stream URL, launches
`runheadless.webrtc.sh`.

### 3. Open the stream

Wait for Isaac Sim to finish loading, then open the printed URL in
**Chrome/Chromium** (Firefox unreliable per NVIDIA docs):

```
https://<POD_ID>-8211.proxy.runpod.net/streaming/webrtc-client?server=<POD_ID>-8211.proxy.runpod.net
```

Also saved to `/workspace/stream-bridge-logs/stream_url.txt`
(`cat` it any time).

## Fully automatic on pod boot

RunPod console → Edit Pod → **Container Start Command**:

```bash
bash -c "command -v git >/dev/null || (apt-get update && apt-get install -y git); cd /workspace && (test -d runpod_udp_to_tcp || git clone https://github.com/Sa3d-99/runpod_udp_to_tcp.git) && cd runpod_udp_to_tcp && chmod +x *.sh && ./start_all.sh"
```

Installs git if the image lacks it, clones on first boot, reuses on later boots
(`/workspace` is the persistent volume), then runs everything.

## Verify / troubleshoot

- `ss -ltn | grep 3478` → coturn listening.
- `tail -f /workspace/stream-bridge-logs/coturn.log` → `allocation` lines appear
  when the browser connects.
- Chrome `chrome://webrtc-internals` → the succeeded candidate pair must show
  type `relay`, and the peer connection config must list your `turn:` URL.
- `env | grep -E 'RUNPOD_PUBLIC_IP|RUNPOD_TCP_PORT'` → both must exist; if
  `RUNPOD_TCP_PORT_3478` is missing, step 1 was not done.
- Isaac Sim UDP media ports: `ss -lunp | grep -i kit`.
- Config patch applied:
  `grep -r iceServers /isaac-sim/extscache/*streamclient.webrtc*/config/extension.toml`

## Files

| File | Purpose |
|---|---|
| `start_all.sh` | One command: deps + bridge + Isaac Sim + prints URL |
| `turn_bridge.sh` | Installs/configures/supervises coturn, patches `iceServers` |
| `install.sh` | apt dependencies (git, python3, coturn, iproute2), idempotent |
| `requirements.txt` | pip dependencies (currently none — stdlib only) |

## Security note

Isaac Sim's streaming endpoints have **no authentication or encryption**. The
TURN relay is credential-protected (random secret in `/workspace/.turn_secret`),
but the 8211 signaling endpoint behind the RunPod proxy is reachable by anyone
with the URL. Don't leave it running unattended longer than needed.
