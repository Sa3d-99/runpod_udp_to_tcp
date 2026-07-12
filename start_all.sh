#!/usr/bin/env bash
# =============================================================================
# start_all.sh — fully automatic: detects RunPod's port mapping by itself,
#                starts the TURN bridge, starts Isaac Sim streaming, prints
#                the exact URL to open in your browser.
#
# ONE-TIME PREREQUISITE (RunPod console):
#   Edit Pod -> "Expose TCP Ports" -> add 3478 -> save (pod restarts).
#   RunPod then injects RUNPOD_PUBLIC_IP and RUNPOD_TCP_PORT_3478 into the
#   container, and this script picks them up automatically.
#
# USAGE — no arguments, no env vars needed:
#   ./start_all.sh
#
# Optional overrides (only if auto-detection is not wanted):
#   TURN_PUBLIC_IP / TURN_PUBLIC_PORT   manual TURN mapping
#   TS_AUTHKEY                          Tailscale mode (own VM/bare metal only;
#                                       RunPod containers lack /dev/net/tun,
#                                       WebRTC media fails there)
#   TURN_INTERNAL_PORT (default 3478)   ISAAC_ROOT (default /isaac-sim)
#
# The bridge is idempotent and stays running in the background; Isaac Sim runs
# in the foreground (Ctrl+C stops Isaac Sim, the bridge keeps running).
# The stream URL is also saved to $LOG_DIR/stream_url.txt.
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISAAC_ROOT="${ISAAC_ROOT:-/isaac-sim}"
LOG_DIR="${LOG_DIR:-/workspace/stream-bridge-logs}"
TURN_INTERNAL_PORT="${TURN_INTERNAL_PORT:-3478}"
export LOG_DIR TURN_INTERNAL_PORT
mkdir -p "$LOG_DIR"

log() { echo "[start-all] $*"; }

# --- 1. pick mode: explicit vars > RunPod auto-detect > Tailscale ---------------
RUNPOD_MAPPED_PORT_VAR="RUNPOD_TCP_PORT_${TURN_INTERNAL_PORT}"
RUNPOD_MAPPED_PORT="${!RUNPOD_MAPPED_PORT_VAR:-}"

if [[ -n "${TURN_PUBLIC_IP:-}" && -n "${TURN_PUBLIC_PORT:-}" ]]; then
    MODE=turn
    log "TURN mode (manual): ${TURN_PUBLIC_IP}:${TURN_PUBLIC_PORT}"
elif [[ -n "${RUNPOD_PUBLIC_IP:-}" && -n "$RUNPOD_MAPPED_PORT" ]]; then
    MODE=turn
    export TURN_PUBLIC_IP="$RUNPOD_PUBLIC_IP"
    export TURN_PUBLIC_PORT="$RUNPOD_MAPPED_PORT"
    log "TURN mode (auto-detected from RunPod): ${TURN_PUBLIC_IP}:${TURN_PUBLIC_PORT} -> :${TURN_INTERNAL_PORT}"
elif [[ -n "${TS_AUTHKEY:-}" ]]; then
    MODE=tailscale
    log "Tailscale mode (note: WebRTC media does not work on RunPod containers)"
else
    echo "ERROR: no TURN port mapping found."
    echo ""
    echo "Fix (one time, RunPod console):"
    echo "  Edit Pod -> 'Expose TCP Ports' -> add ${TURN_INTERNAL_PORT} -> save (pod restarts)."
    echo "  Then just run ./start_all.sh again — the mapping is auto-detected via"
    echo "  RUNPOD_PUBLIC_IP and ${RUNPOD_MAPPED_PORT_VAR}."
    echo ""
    echo "Or set manually: TURN_PUBLIC_IP=<ip> TURN_PUBLIC_PORT=<port> ./start_all.sh"
    exit 1
fi

# --- 2. start the bridge (backgrounds itself, safe to re-run) --------------------
bash "$DIR/${MODE}_bridge.sh"

# --- 3. build and show the URL to open -------------------------------------------
if [[ "$MODE" == "tailscale" ]]; then
    TS_IP="$(tailscale --socket=/tmp/tailscaled.sock ip -4 | head -1)"
    URL="http://${TS_IP}:8211/streaming/webrtc-client?server=${TS_IP}"
else
    POD="${RUNPOD_POD_ID:-<POD_ID>}"
    URL="https://${POD}-8211.proxy.runpod.net/streaming/webrtc-client?server=${POD}-8211.proxy.runpod.net"
fi
echo "$URL" > "$LOG_DIR/stream_url.txt"

echo ""
echo "=============================================================="
echo "  OPEN THIS IN CHROME/CHROMIUM ONCE ISAAC SIM SAYS app ready:"
echo "    $URL"
echo "  (also saved to $LOG_DIR/stream_url.txt)"
echo "=============================================================="
echo ""

# --- 4. launch Isaac Sim streaming (foreground) -----------------------------------
cd "$ISAAC_ROOT"
if [[ -x ./runheadless.webrtc.sh ]]; then
    exec ./runheadless.webrtc.sh -v          # Isaac Sim <= 4.2 containers
elif [[ -x ./runheadless.sh ]]; then
    exec ./runheadless.sh -v                 # Isaac Sim 4.5/5.x containers
elif [[ -x ./isaac-sim.streaming.sh ]]; then
    exec ./isaac-sim.streaming.sh
else
    log "WARNING: no runheadless script found in $ISAAC_ROOT."
    log "Bridge is up — start Isaac Sim streaming manually, then open the URL above."
fi
