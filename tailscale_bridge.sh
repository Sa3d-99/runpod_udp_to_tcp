#!/usr/bin/env bash
# =============================================================================
# tailscale_bridge.sh — UDP-over-TCP tunnel for Isaac Sim on RunPod, any version
#
# ============================ IMPORTANT CAVEAT ==============================
#   On RunPod CONTAINERS this gives you TCP access only (SSH, HTTP, Jupyter).
#   Isaac Sim's WebRTC MEDIA will NOT flow:
#     - RunPod containers have no /dev/net/tun, so only userspace-networking
#       mode runs. A default install even *looks* connected in the admin
#       console while `tailscaled` logs "CreateTUN failed" and routes nothing.
#     - Userspace mode terminates and re-originates flows: UDP source
#       addresses get rewritten and the pod cannot send raw outbound UDP to
#       tailnet IPs — both break WebRTC's ICE handshake.
#   For Isaac Sim streaming on RunPod use turn_bridge.sh instead.
#
#   This script IS the right tool on hosts with a real TUN device (your own
#   VM, EC2, workstation): there the browser reaches the machine's real TCP
#   signaling AND UDP media ports directly over the tailnet, no port setup.
#
# USAGE (inside the Isaac Sim container)
#   1. Get a reusable auth key: https://login.tailscale.com/admin/settings/keys
#   2. TS_AUTHKEY=tskey-auth-XXXXX bash tailscale_bridge.sh
#   3. Install Tailscale on your laptop, log into the same tailnet.
#   4. Open the URL the script prints.
#
# State persists in /workspace so it survives pod restarts.
# =============================================================================
set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:?Set TS_AUTHKEY (create one at https://login.tailscale.com/admin/settings/keys)}"
LOG_DIR="${LOG_DIR:-/workspace/stream-bridge-logs}"
STATE_FILE="${STATE_FILE:-/workspace/tailscaled.state}"
SOCKET="/tmp/tailscaled.sock"
HOSTNAME_TS="${HOSTNAME_TS:-runpod-isaacsim}"

mkdir -p "$LOG_DIR"
log() { echo "[ts-bridge] $*"; }

# --- 1. install ----------------------------------------------------------------
if ! command -v tailscaled >/dev/null 2>&1; then
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
fi

# --- 2. run tailscaled in userspace mode (no /dev/net/tun on RunPod) -----------
if [[ -f "$LOG_DIR/tailscaled.pid" ]] && kill -0 "$(cat "$LOG_DIR/tailscaled.pid")" 2>/dev/null; then
    log "tailscaled already running."
else
    nohup tailscaled \
        --tun=userspace-networking \
        --state="$STATE_FILE" \
        --socket="$SOCKET" \
        >>"$LOG_DIR/tailscaled.log" 2>&1 &
    echo $! > "$LOG_DIR/tailscaled.pid"
    disown
    sleep 3
fi

# --- 3. join the tailnet --------------------------------------------------------
tailscale --socket="$SOCKET" up \
    --auth-key="$TS_AUTHKEY" \
    --hostname="$HOSTNAME_TS" \
    --accept-dns=false

TS_IP="$(tailscale --socket="$SOCKET" ip -4 | head -1)"

log ""
log "OK: pod is on your tailnet as '$HOSTNAME_TS' with IP $TS_IP"
log ""
log "Next steps:"
log "  1. Install Tailscale on your own machine and log into the same account:"
log "       https://tailscale.com/download"
log "  2. (Re)start Isaac Sim streaming in the container, e.g.:"
log "       ./runheadless.webrtc.sh -v            # Isaac Sim <= 4.2"
log "       ./isaac-sim.streaming.sh              # Isaac Sim 5.x"
log "  3. Open the stream against the tailnet IP:"
log "       Isaac <= 4.2 browser client:"
log "         http://$TS_IP:8211/streaming/webrtc-client?server=$TS_IP"
log "       Isaac 4.5/5.x: use the 'Isaac Sim WebRTC Streaming Client' app,"
log "         server address: $TS_IP"
log ""
log "All UDP media ports (47998 etc.) now flow through the tunnel."
log "Logs: $LOG_DIR/tailscaled.log"
