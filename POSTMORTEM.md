# Postmortem: getting Isaac Sim's UI into a browser on RunPod

**Problem.** NVIDIA Isaac Sim (`nvcr.io/nvidia/isaac-sim:4.0.0`) runs fine in a
RunPod container, but every attempt to view its live stream in a browser gave a
blank/grey screen and clicks did nothing.

**Outcome.** After four failed approaches, **noVNC works**. This document records
what was tried, why each failed, and why the winner wins — so nobody (including
future us) repeats the dead ends.

---

## The root constraint

Everything below follows from one fact:

> **RunPod forwards no inbound UDP. Its proxy carries HTTP/WebSocket over TCP;
> its "Direct TCP Ports" carry raw TCP. There is no UDP path into a pod, ever.**

Isaac Sim's livestreaming is **WebRTC**:

| Traffic | Protocol | Gets into a RunPod pod? |
|---|---|---|
| Client web page, signaling | TCP / HTTP / WebSocket | ✅ yes — this is why the page always loaded |
| Video/audio media (SRTP) | **UDP** | ❌ never |

That single mismatch produced the grey screen: the browser successfully
negotiated a session and then waited forever for frames that could not arrive.

---

## Attempt 1 — `socat` UDP↔TCP tunnel (the original idea)

**Idea.** Capture Isaac's outgoing UDP media, wrap it in TCP, forward it to a
RunPod-exposed TCP port.

**Why it can't work.** The receiver of that UDP is the **browser's own WebRTC
stack**. It only speaks ICE/DTLS/SRTP on ports it negotiated itself. There is
nothing on the client side to *unwrap* a homemade TCP stream — you would have to
rewrite Chrome's networking. A generic byte-tunnel is invisible to WebRTC.

**Verdict.** ❌ Dead on arrival. Rejected before writing it. Any UDP→TCP fix must
be something the browser natively understands — which is what led to TURN.

---

## Attempt 2 — Tailscale (WireGuard mesh)

**Idea.** Put the pod and the laptop on one private network; the browser then
reaches Isaac's real UDP ports directly.

**What happened.** Both devices showed "Connected" in the Tailscale admin
console. The browser still timed out (`ERR_CONNECTION_TIMED_OUT` on `100.65.20.166`).

**Why it failed.** Two independent blockers:

1. RunPod containers have **no `/dev/net/tun`** and no `CAP_NET_ADMIN`. Tailscale
   registers with the coordination server (so it *looks* online) but cannot
   create the tunnel device — `tailscaled` logs `CreateTUN failed` and **routes
   nothing**. Connected status, zero data path.
2. The only mode that runs there, `--tun=userspace-networking`, **terminates and
   re-originates** flows: UDP source addresses get rewritten and the pod cannot
   send raw outbound UDP to tailnet IPs. Both break WebRTC's ICE handshake.

**Verdict.** ❌ Tailscale on a RunPod *container* is fine for TCP (SSH, HTTP,
Jupyter) and useless for WebRTC media. Removed from the repo at the user's request.

---

## Attempt 3 — TURN relay over TCP (coturn)

**Idea.** The standards-compliant way to force WebRTC media over TCP: run a TURN
server in the pod and give the browser `turn:<ip>:<port>?transport=tcp`.
Path: `browser ⇄ TCP ⇄ RunPod Direct-TCP ⇄ coturn ⇄ UDP (pod-internal) ⇄ Isaac`.

This one *nearly* worked, and produced most of the hard-won knowledge in this repo.

### Sub-problems found and fixed along the way

| # | Problem | Fix |
|---|---|---|
| 1 | `/streaming/webrtc-client` 307-redirects to the pod's internal IP (unreachable) | Use `/streaming/webrtc-demo/` directly |
| 2 | `kit-player.js` **hardcodes signaling to port 49100** | `sed` the constant to RunPod's mapped external port |
| 3 | An HTTPS page can't call the plain-HTTP signaling endpoint (mixed content) | Serve the player over a **plain-http Direct TCP** port, not the RunPod HTTPS proxy |
| 4 | `/streaming/ice-servers` kept returning Google STUN only | The endpoint reads the setting **`ice_servers`** (snake_case), not `iceServers`; and the defaults are a TOML **array-of-tables** — the patcher had to match that exact shape |
| 5 | Browser allocated the TURN relay but never used it (`peer usage: rp=0 rb=0 sp=0 sb=0`) | Force `iceTransportPolicy:"relay"` into the player's `RTCPeerConnection` |

### Why it still failed

Isaac Sim's WebRTC server advertises **only private ICE candidates** —
`127.0.0.1` and `172.18.0.2` (the container's internal address). A remote browser
can never reach those. Chrome's ICE therefore burns its timeout on unreachable
candidate pairs and never falls back to the relay; coturn's own accounting proved
the media path was completely unused:

```
session ...: usage:      rp=3, rb=220, sp=3, sb=308     ← just the ALLOCATE handshake
session ...: peer usage: rp=0, rb=0,   sp=0, sb=0       ← zero bytes ever reached Isaac
```

Forcing relay-only ICE then tripped Isaac's *own* watchdogs, which fire before ICE
can complete over TCP:

- `Stream timed out before starting` (`0xC0F22219`) — no frames within 30 s.
- A sleep-detector whose recovery path does a connectivity check against
  `http://<public-ip>` — **port 80, which RunPod never exposes on the raw IP** — so
  the check always fails and converts a recoverable state into a fatal stop
  (`0x00F22003`).

And a final clue from the server log that explains the black frames even when a
session did connect:

```
[carb.livestream-rtc.plugin] Stream Server: streaming at 0 x 0.
```

The render viewport was **0×0** — Isaac was producing no pixels to encode at all.

**Verdict.** ❌ Abandoned. Every fix uncovered another layer: private-only ICE
candidates, hardcoded ports, mixed content, snake_case config keys, watchdogs
that assume a normal network, a 0×0 viewport. NVIDIA's WebRTC stack assumes real
UDP networking with reachable addresses; RunPod provides neither. Fighting it is
whack-a-mole.

*(The coturn/TURN scripts have been deleted from this repo — they never worked
end to end and keeping them around would only invite someone to retry a dead end.
This document is what remains of them.)*

---

## Also learned the hard way

Two container facts that cost real time:

- **The Isaac process the container starts (`omni.isaac.sim.headless.native.kit`,
  ~PID 54) is the container's MAIN process** (child of `docker-init`). `kill -9`
  on it **stops the entire container** — SSH drops, everything resets, port
  mappings change. Never kill it.
- **RunPod's web terminal kills its whole process group on disconnect.** Anything
  backgrounded normally dies with it. All long-lived processes must be launched
  with `setsid` — and prefer SSH over the web terminal.

---

## The winner — noVNC

**Idea.** Stop trying to make Isaac stream. Let it draw its normal GUI into a
**virtual screen**, and ship that screen to the browser over HTTP.

```
Isaac Sim GUI  →  renders into a virtual X display (Xvfb, on the GPU)
                       ↓
                  x11vnc     exposes that display as VNC on localhost:5900
                       ↓
            websockify + noVNC   serve it as a web page on :8080
                       ↓
         RunPod HTTP proxy (TCP)  →  browser
```

### Why it succeeds where everything else failed

1. **It is pure TCP.** HTTP + WebSocket — precisely the transport RunPod's proxy
   is built to carry. There is no UDP anywhere in the path, so the root
   constraint simply doesn't apply.
2. **No ICE, no NAT traversal, no candidates.** Nothing needs a reachable public
   IP or a peer-to-peer handshake. The private `172.18.0.2` address that doomed
   WebRTC is irrelevant — the browser talks to a plain web server.
3. **Isaac Sim is not modified and not fought.** It just opens a window like it
   would on a desktop. No hardcoded ports, no config keys that move between
   versions, no encoder, no watchdogs. That's why it works on **every** Isaac
   version (4.0 → 5.x) while the WebRTC config keys were version-specific and
   removed outright in 5.x.
4. **One port, already exposed.** noVNC rides the HTTP port the pod already has —
   no Direct-TCP ports to add, and nothing to re-copy after every pod restart.
5. **Full interaction.** Real mouse and keyboard on the real Isaac Sim UI, so you
   can load your own scene with File → Open — which the streaming clients never
   let us do.

**Trade-off:** VNC ships compressed framebuffer updates, not a hardware-encoded
video stream, so it's a little less smooth than WebRTC *would* be if WebRTC
worked. In exchange it actually works, on any version, with no ports to babysit.

**Verdict.** ✅ Working. This is the supported method — `novnc.sh`.

---

## One-line summary

> Isaac Sim's built-in streaming needs UDP and reachable IPs. RunPod gives you
> neither and never will. Rather than tunnel UDP into a network that refuses it,
> stop streaming: render the GUI to a virtual display and serve the pixels over
> the HTTP that RunPod already speaks.
