#!/usr/bin/env bash
# =============================================================================
# stop.sh — shut down the noVNC desktop stack cleanly.
#
# Stops ONLY what novnc.sh started:
#   the Isaac Sim GUI instance, websockify, x11vnc, fluxbox, Xvfb.
#
# It deliberately does NOT touch the headless Isaac Sim that the container
# itself started (omni.isaac.sim.headless.*.kit). On the RunPod image that
# process is the container's MAIN process — killing it stops the whole
# container: your SSH session dies, the pod resets, port mappings change.
#
# USAGE:
#   bash stop.sh          stop the desktop, leave the pod running
#
# Start it again with:  bash novnc.sh
# To stop billing entirely, stop/terminate the POD in the RunPod console —
# this script only stops the desktop inside it.
# =============================================================================
set -uo pipefail   # no -e: we want to keep going even if something is already dead

DISPLAY_NUM="${DISPLAY_NUM:-:1}"
WEB_PORT="${WEB_PORT:-8080}"
VNC_PORT="${VNC_PORT:-5900}"
LOG_DIR="${LOG_DIR:-/workspace/novnc-logs}"

log() { echo "[stop] $*"; }

stopped_any=0

# --- Isaac Sim GUI (only the instance novnc.sh launched) ------------------------
if [[ -f "$LOG_DIR/isaac-gui.pid" ]]; then
    pid="$(cat "$LOG_DIR/isaac-gui.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        log "Stopping Isaac Sim GUI (pid $pid)..."
        kill "$pid" 2>/dev/null
        stopped_any=1
    fi
    rm -f "$LOG_DIR/isaac-gui.pid"
fi
# Any GUI kit still on our virtual display (never the headless/native one).
if pgrep -f 'isaac-sim.sh|omni.isaac.sim.kit|isaacsim.exp.full.kit' >/dev/null 2>&1; then
    log "Stopping remaining Isaac Sim GUI process(es)..."
    pkill -f 'isaac-sim.sh|omni.isaac.sim.kit|isaacsim.exp.full.kit' 2>/dev/null
    stopped_any=1
fi

# --- desktop stack ---------------------------------------------------------------
for spec in \
    "websockify --web=/usr/share/novnc ${WEB_PORT}:noVNC web server" \
    "x11vnc -display ${DISPLAY_NUM}:VNC server" \
    "fluxbox:window manager" \
    "Xvfb ${DISPLAY_NUM}:virtual display"
do
    pat="${spec%%:*}"
    name="${spec##*:}"
    if pgrep -f "$pat" >/dev/null 2>&1; then
        log "Stopping ${name}..."
        pkill -f "$pat" 2>/dev/null
        stopped_any=1
    fi
done

sleep 2

# --- anything stubborn gets SIGKILL ----------------------------------------------
for pat in \
    "websockify --web=/usr/share/novnc ${WEB_PORT}" \
    "x11vnc -display ${DISPLAY_NUM}" \
    "Xvfb ${DISPLAY_NUM}"
do
    pgrep -f "$pat" >/dev/null 2>&1 && pkill -9 -f "$pat" 2>/dev/null
done

# --- clean up the display's lock files --------------------------------------------
rm -f "/tmp/.X${DISPLAY_NUM#:}-lock"
rm -rf "/tmp/.X11-unix/X${DISPLAY_NUM#:}" 2>/dev/null

if [[ $stopped_any -eq 1 ]]; then
    log "Desktop stopped."
else
    log "Nothing was running."
fi
log "The container's own Isaac Sim was left alone (killing it would stop the pod)."
log "Start the desktop again with:  bash novnc.sh"
