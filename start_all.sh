#!/usr/bin/env bash
# =============================================================================
# start_all.sh — fully automatic: detects RunPod's port mapping by itself,
#                starts the TURN bridge, starts Isaac Sim streaming, prints
#                the exact URL to open in your browser.
#
# ONE-TIME PREREQUISITE (RunPod console):
#   Edit Pod -> "Expose TCP Ports" -> set to: 3478,8211,49100 -> save (pod
#   restarts). RunPod then injects RUNPOD_PUBLIC_IP and RUNPOD_TCP_PORT_3478 /
#   _8211 / _49100 into the container; this script picks them all up.
#     3478  = TURN relay (media over TCP)
#     8211  = web player page, served over direct TCP (plain http, so the
#             browser is allowed to call the plain-http signaling endpoint)
#     49100 = WebRTC signaling (kit-player.js gets patched to its mapped port)
#
# USAGE — no arguments, no env vars needed:
#   ./start_all.sh
#
# Optional overrides (only if auto-detection is not wanted):
#   TURN_PUBLIC_IP / TURN_PUBLIC_PORT   manual TURN mapping
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

# --- 0. install dependencies (idempotent, fast when already installed) ----------
bash "$DIR/install.sh"

# --- 1. find the TURN port mapping: explicit vars > RunPod auto-detect ----------
RUNPOD_MAPPED_PORT_VAR="RUNPOD_TCP_PORT_${TURN_INTERNAL_PORT}"
RUNPOD_MAPPED_PORT="${!RUNPOD_MAPPED_PORT_VAR:-}"

PAGE_MAPPED_PORT="${RUNPOD_TCP_PORT_8211:-}"
SIGNALING_MAPPED_PORT="${RUNPOD_TCP_PORT_49100:-}"

if [[ -n "${TURN_PUBLIC_IP:-}" && -n "${TURN_PUBLIC_PORT:-}" ]]; then
    log "TURN mode (manual): ${TURN_PUBLIC_IP}:${TURN_PUBLIC_PORT}"
elif [[ -n "${RUNPOD_PUBLIC_IP:-}" && -n "$RUNPOD_MAPPED_PORT" ]]; then
    export TURN_PUBLIC_IP="$RUNPOD_PUBLIC_IP"
    export TURN_PUBLIC_PORT="$RUNPOD_MAPPED_PORT"
    log "TURN mode (auto-detected from RunPod): ${TURN_PUBLIC_IP}:${TURN_PUBLIC_PORT} -> :${TURN_INTERNAL_PORT}"
else
    echo "ERROR: no TURN port mapping found."
    echo ""
    echo "Fix (one time, RunPod console):"
    echo "  Edit Pod -> 'Expose TCP Ports' -> set to: ${TURN_INTERNAL_PORT},8211,49100 -> save (pod restarts)."
    echo "  Then just run ./start_all.sh again — mappings are auto-detected via"
    echo "  RUNPOD_PUBLIC_IP and RUNPOD_TCP_PORT_* env vars."
    echo ""
    echo "Or set manually: TURN_PUBLIC_IP=<ip> TURN_PUBLIC_PORT=<port> ./start_all.sh"
    exit 1
fi

if [[ -z "$PAGE_MAPPED_PORT" || -z "$SIGNALING_MAPPED_PORT" ]]; then
    echo "ERROR: ports 8211 and/or 49100 are not exposed as Direct TCP."
    echo ""
    echo "The web player must be served over plain http (browsers block an https page"
    echo "from calling the plain-http signaling endpoint), and signaling needs its own"
    echo "TCP mapping. Fix (one time, RunPod console):"
    echo "  Edit Pod -> 'Expose TCP Ports' -> set to: ${TURN_INTERNAL_PORT},8211,49100 -> save (pod restarts)."
    echo "  Then run ./start_all.sh again."
    exit 1
fi
export SIGNALING_PUBLIC_PORT="$SIGNALING_MAPPED_PORT"

# --- 2. start the bridge (backgrounds itself, safe to re-run) --------------------
bash "$DIR/turn_bridge.sh"

# --- 3. build and show the URL to open -------------------------------------------
URL="http://${TURN_PUBLIC_IP}:${PAGE_MAPPED_PORT}/streaming/webrtc-demo/?server=${TURN_PUBLIC_IP}"
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
