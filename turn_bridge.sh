#!/usr/bin/env bash
# =============================================================================
# turn_bridge.sh — UDP-to-TCP media bridge for Isaac Sim WebRTC on RunPod
#
# WHY THIS EXISTS
#   Isaac Sim's live stream is WebRTC: the page/signaling ride TCP (port 8211,
#   works through RunPod's HTTP proxy), but the actual video frames are
#   encrypted SRTP over UDP (port 47998 by default). RunPod does not forward
#   inbound UDP at all, so the browser negotiates a session, then never
#   receives a single frame -> blank/gray screen.
#
#   You cannot fix this with a raw socat UDP->TCP wrap: the browser's WebRTC
#   stack is the receiving end, and it only speaks ICE/SRTP — it has no way
#   to unwrap a homemade TCP stream. The standards-compliant way to force
#   WebRTC media over TCP is a TURN relay with ?transport=tcp, which is
#   exactly what this script sets up:
#
#     browser --(TURN over TCP, via RunPod Direct-TCP port)--> coturn (in pod)
#             --(plain UDP, pod-internal where UDP is fine)--> Isaac Sim
#
# WHAT IT DOES
#   1. Installs coturn (TURN server) if missing.
#   2. Detects the Isaac Sim UDP streaming ports actually in use (logged).
#   3. Configures coturn TCP-only on the client side, UDP relay internally.
#   4. Patches Isaac Sim's WebRTC streaming extension so the browser client
#      is told to relay media through this TURN server.
#   5. Runs coturn supervised in the background (auto-restart, quiet, logs).
#
# REQUIREMENTS
#   - Isaac Sim <= 4.2 (the version that serves the browser client on 8211
#     and lets you configure iceServers). Isaac Sim 5.x removed the ICE/TURN
#     configuration entirely (confirmed by NVIDIA); there the workaround is a
#     custom web client (NVIDIA web-viewer-sample) with browser-side iceServers.
#   - ONE RunPod "Direct TCP" exposed port. In the RunPod console:
#       Pod -> Edit Pod -> "Expose TCP Ports" -> add 3478 -> save (pod restarts).
#     Then under Connect -> "Direct TCP Ports" RunPod shows a mapping like
#       203.0.113.7:14523 -> :3478
#     That PUBLIC ip/port is what you pass to this script. The HTTP proxy
#     ports (80/8080/8211) cannot carry TURN — the proxy only speaks HTTP.
#
# USAGE (inside the Isaac Sim container)
#   TURN_PUBLIC_IP=203.0.113.7 TURN_PUBLIC_PORT=14523 bash turn_bridge.sh
#
# Optional env overrides:
#   TURN_INTERNAL_PORT (default 3478)   ISAAC_ROOT (default /isaac-sim)
#   LOG_DIR (default /workspace/stream-bridge-logs)
# =============================================================================
set -euo pipefail

TURN_PUBLIC_IP="${TURN_PUBLIC_IP:?Set TURN_PUBLIC_IP to the public IP RunPod shows under Direct TCP Ports}"
TURN_PUBLIC_PORT="${TURN_PUBLIC_PORT:?Set TURN_PUBLIC_PORT to the external port RunPod shows under Direct TCP Ports}"
TURN_INTERNAL_PORT="${TURN_INTERNAL_PORT:-3478}"
ISAAC_ROOT="${ISAAC_ROOT:-/isaac-sim}"
LOG_DIR="${LOG_DIR:-/workspace/stream-bridge-logs}"
SECRET_FILE="${SECRET_FILE:-/workspace/.turn_secret}"
TURN_USER="isaac"

mkdir -p "$LOG_DIR"

log() { echo "[turn-bridge] $*"; }

# --- 1. install coturn --------------------------------------------------------
if ! command -v turnserver >/dev/null 2>&1; then
    log "Installing coturn..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq coturn iproute2 >/dev/null
fi

# --- 2. show which UDP ports Isaac Sim is actually streaming on ---------------
log "Isaac Sim UDP listeners currently open (media ports):"
ss -lunp 2>/dev/null | grep -Ei 'kit|isaac|4799[0-9]|480[0-9][0-9]' || \
    log "  (none yet — start Isaac Sim with ./runheadless.webrtc.sh, this is informational only)"

# --- 3. stable credentials -----------------------------------------------------
if [[ -f "$SECRET_FILE" ]]; then
    TURN_PASS="$(cat "$SECRET_FILE")"
else
    TURN_PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)"
    printf '%s' "$TURN_PASS" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
fi

# --- 4. coturn config: clients over TCP only, relay over pod-internal UDP -----
CONF="$LOG_DIR/turnserver.conf"
cat > "$CONF" <<EOF
listening-port=${TURN_INTERNAL_PORT}
# RunPod cannot deliver inbound UDP, so refuse UDP client transport entirely;
# browsers will connect with ?transport=tcp.
no-udp
# The relay legs to Isaac Sim stay inside the pod, where UDP works fine.
# Deliberately NO external-ip here: relay candidates must advertise the pod's
# own address so the Isaac Sim process can reach them locally.
min-port=49152
max-port=65535
fingerprint
lt-cred-mech
user=${TURN_USER}:${TURN_PASS}
realm=isaacsim
no-tls
no-dtls
no-cli
simple-log
log-file=${LOG_DIR}/coturn.log
pidfile=${LOG_DIR}/coturn.pid
EOF

# --- 5. patch the WebRTC extension so the browser uses our TURN relay ---------
EXT_TOML="$(find "$ISAAC_ROOT" -path '*omni.services.streamclient.webrtc*/config/extension.toml' 2>/dev/null | head -1 || true)"
if [[ -z "$EXT_TOML" ]]; then
    log "WARNING: could not find omni.services.streamclient.webrtc extension under $ISAAC_ROOT."
    log "         If you run Isaac Sim 5.x this is expected — TURN config was removed by NVIDIA."
    log "         Otherwise set ISAAC_ROOT and re-run."
else
    cp -n "$EXT_TOML" "${EXT_TOML}.bak" || true
    TURN_URL="turn:${TURN_PUBLIC_IP}:${TURN_PUBLIC_PORT}?transport=tcp" \
    TURN_USER="$TURN_USER" TURN_PASS="$TURN_PASS" EXT_TOML="$EXT_TOML" \
    python3 - <<'PYEOF'
import os, re

path = os.environ["EXT_TOML"]
url = os.environ["TURN_URL"]
user = os.environ["TURN_USER"]
pw = os.environ["TURN_PASS"]

server = f'{{ urls = ["{url}"], username = "{user}", credential = "{pw}" }}'
text = open(path).read()

# 1) Replace an existing iceServers assignment (single- or multi-line list),
#    matching the closing bracket by depth so nested lists survive.
# 2) Else insert a dotted key right after the [settings] header, matching the
#    file's existing style so the TOML stays valid.
# 3) Else append a fresh [settings] section.
key_pat = re.compile(r'^(\s*(?:exts\."[^"]+"\.)?)iceServers\s*=\s*\[', re.M)
m = key_pat.search(text)
if m:
    depth, end = 0, -1
    for i in range(m.end() - 1, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end < 0:
        raise SystemExit(f"[turn-bridge] ERROR: unbalanced iceServers list in {path}")
    entry = f"{m.group(1)}iceServers = [ {server} ]"
    text = text[: m.start()] + entry + text[end:]
else:
    entry = f'exts."omni.services.streamclient.webrtc".iceServers = [ {server} ]'
    settings_hdr = re.compile(r"^\[settings\]\s*$", re.M)
    if settings_hdr.search(text):
        text = settings_hdr.sub("[settings]\n" + entry, text, count=1)
    else:
        text += "\n[settings]\n" + entry + "\n"
open(path, "w").write(text)
print(f"[turn-bridge] patched {path}:")
print(f"[turn-bridge]   {entry.replace(pw, '****')}")
PYEOF
    log "Backup of original config at ${EXT_TOML}.bak"
    log "Restart Isaac Sim for the patch to take effect."
fi

# --- 5b. patch the web client so signaling uses the RunPod-mapped port ----------
# The stock kit-player.js hardcodes signaling to <server>:49100. RunPod's Direct
# TCP mapping gives 49100 a different external port, so rewrite the constant.
# Idempotent: always regenerates from the pristine .orig copy.
KIT_PLAYER="$(find "$ISAAC_ROOT" -path '*streamclient.webrtc*' -name 'kit-player.js' 2>/dev/null | head -1 || true)"
if [[ -z "${SIGNALING_PUBLIC_PORT:-}" ]]; then
    log "NOTE: SIGNALING_PUBLIC_PORT not set — skipping kit-player.js signaling patch."
elif [[ -z "$KIT_PLAYER" ]]; then
    log "WARNING: kit-player.js not found under $ISAAC_ROOT — cannot patch signaling port."
else
    cp -n "$KIT_PLAYER" "${KIT_PLAYER}.orig" || true
    sed "s/49100/${SIGNALING_PUBLIC_PORT}/g" "${KIT_PLAYER}.orig" > "$KIT_PLAYER"
    log "Patched web client signaling port: 49100 -> ${SIGNALING_PUBLIC_PORT}"
fi

# --- 6. run coturn supervised in the background --------------------------------
if [[ -f "$LOG_DIR/supervisor.pid" ]] && kill -0 "$(cat "$LOG_DIR/supervisor.pid")" 2>/dev/null; then
    log "Bridge already running (pid $(cat "$LOG_DIR/supervisor.pid")). Restarting it."
    kill "$(cat "$LOG_DIR/supervisor.pid")" 2>/dev/null || true
    pkill -f "turnserver -c $CONF" 2>/dev/null || true
    sleep 1
fi

nohup bash -c "
    while true; do
        turnserver -c '$CONF' --no-stdout-log >>'$LOG_DIR/supervisor.log' 2>&1
        echo \"[turn-bridge] coturn exited, restarting in 2s\" >>'$LOG_DIR/supervisor.log'
        sleep 2
    done
" >/dev/null 2>&1 &
echo $! > "$LOG_DIR/supervisor.pid"
disown

sleep 2
if ss -ltn 2>/dev/null | grep -q ":${TURN_INTERNAL_PORT} "; then
    log "OK: TURN relay listening on TCP :${TURN_INTERNAL_PORT} (supervisor pid $(cat "$LOG_DIR/supervisor.pid"))."
else
    log "ERROR: coturn is not listening on :${TURN_INTERNAL_PORT} — check $LOG_DIR/coturn.log"
    exit 1
fi

log ""
log "Done. Next steps:"
log "  1. (Re)start Isaac Sim streaming:  cd $ISAAC_ROOT && ./runheadless.webrtc.sh -v"
log "  2. Open in Chrome/Chromium:"
log "       https://<POD_ID>-8211.proxy.runpod.net/streaming/webrtc-client?server=<POD_ID>-8211.proxy.runpod.net"
log "  3. Media now relays via turn:${TURN_PUBLIC_IP}:${TURN_PUBLIC_PORT}?transport=tcp"
log "  Logs: $LOG_DIR/coturn.log"
