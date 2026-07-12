#!/usr/bin/env bash
# =============================================================================
# novnc.sh — PRIMARY METHOD: view Isaac Sim's full GUI in a browser on RunPod.
#
# Works on ALL Isaac Sim versions (4.0, 4.1, 4.2, 4.5, 5.x) because it does not
# touch Isaac's streaming stack at all — it renders Isaac into a virtual X
# display and ships that display to the browser over plain HTTP + WebSocket,
# which is exactly what RunPod's proxy already carries.
#
#   Xvfb (virtual screen)  <- Isaac Sim GUI renders here (GPU / Vulkan)
#        ^-- x11vnc          exposes that screen as VNC on :5900 (localhost)
#              ^-- websockify+noVNC  serve it as a web page on :$WEB_PORT
#                    ^-- browser: https://<POD>-<WEB_PORT>.proxy.runpod.net/vnc.html
#
# No UDP. No WebRTC. No ICE. No TURN. No Direct-TCP ports. Nothing to expose
# beyond the HTTP port RunPod already gives you.
#
# USAGE (inside the container; SSH is more stable than the web terminal):
#   bash novnc.sh
# Then open the URL it prints. Load your scene with File > Open in the GUI.
#
# Env overrides:
#   WEB_PORT=8080        HTTP port noVNC is served on (must be exposed as HTTP)
#   RES=1920x1080        virtual screen resolution
#   ISAAC_ROOT=/isaac-sim
#   VNC_PASSWORD=...     set a VNC password (default: none, pod is private)
#   NO_ISAAC=1           only bring up the desktop, don't launch Isaac
#   LOG_DIR=/workspace/novnc-logs
# =============================================================================
set -euo pipefail

WEB_PORT="${WEB_PORT:-8080}"
RES="${RES:-1920x1080}"
ISAAC_ROOT="${ISAAC_ROOT:-/isaac-sim}"
DISPLAY_NUM="${DISPLAY_NUM:-:1}"
LOG_DIR="${LOG_DIR:-/workspace/novnc-logs}"
VNC_PORT="${VNC_PORT:-5900}"
mkdir -p "$LOG_DIR"

log() { echo "[novnc] $*"; }
die() { echo "[novnc] ERROR: $*" >&2; exit 1; }

# --- 1. dependencies (git, python3, Xvfb, x11vnc, fluxbox, noVNC, websockify) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/install.sh"

# --- 2. stop only OUR previous stack (never the container's main Isaac) ---------
# The RunPod Isaac image runs a headless Isaac as the container's MAIN process
# (child of docker-init). Killing that stops the whole container, so we only ever
# touch the desktop stack and the GUI instance this script itself starts.
log "Cleaning up any previous noVNC stack..."
[[ -f "$LOG_DIR/isaac-gui.pid" ]] && kill "$(cat "$LOG_DIR/isaac-gui.pid")" 2>/dev/null || true
pkill -f "Xvfb ${DISPLAY_NUM}" 2>/dev/null || true
pkill -f "x11vnc -display ${DISPLAY_NUM}" 2>/dev/null || true
pkill -f "websockify --web=/usr/share/novnc ${WEB_PORT}" 2>/dev/null || true
sleep 2
rm -f "/tmp/.X${DISPLAY_NUM#:}-lock"
rm -rf "/tmp/.X11-unix/X${DISPLAY_NUM#:}" 2>/dev/null || true

export DISPLAY="$DISPLAY_NUM"

# --- 3. virtual display + window manager ---------------------------------------
log "Starting virtual display ${DISPLAY_NUM} at ${RES}..."
setsid Xvfb "$DISPLAY_NUM" -screen 0 "${RES}x24" +extension GLX +render -noreset \
    </dev/null >"$LOG_DIR/xvfb.log" 2>&1 &
for _ in $(seq 1 15); do
    xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 && break
    sleep 1
done
xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 \
    || die "Xvfb failed to start — see $LOG_DIR/xvfb.log"
log "Virtual display up."

setsid fluxbox </dev/null >"$LOG_DIR/fluxbox.log" 2>&1 &
sleep 1

# --- 4. VNC server on that display ----------------------------------------------
if [[ -n "${VNC_PASSWORD:-}" ]]; then
    x11vnc -storepasswd "$VNC_PASSWORD" "$LOG_DIR/vncpass" >/dev/null 2>&1
    AUTH=(-rfbauth "$LOG_DIR/vncpass")
    log "VNC password enabled."
else
    AUTH=(-nopw)
fi
log "Starting VNC server on localhost:${VNC_PORT}..."
setsid x11vnc -display "$DISPLAY_NUM" -forever -shared "${AUTH[@]}" \
    -rfbport "$VNC_PORT" -localhost -noxdamage \
    </dev/null >"$LOG_DIR/x11vnc.log" 2>&1 &
sleep 2
ss -ltn 2>/dev/null | grep -q ":${VNC_PORT} " \
    || die "x11vnc failed to bind :${VNC_PORT} — see $LOG_DIR/x11vnc.log"

# --- 5. noVNC web front-end (HTTP + WebSocket, rides RunPod's HTTP proxy) -------
log "Starting noVNC web server on :${WEB_PORT}..."
setsid websockify --web=/usr/share/novnc "$WEB_PORT" "localhost:${VNC_PORT}" \
    </dev/null >"$LOG_DIR/websockify.log" 2>&1 &
sleep 2
ss -ltn 2>/dev/null | grep -q ":${WEB_PORT} " \
    || die "websockify failed to bind :${WEB_PORT} — see $LOG_DIR/websockify.log"

# --- 6. launch the Isaac Sim GUI on the virtual display -------------------------
# Launcher name differs across versions, so probe for whichever exists:
#   4.x            -> isaac-sim.sh / runapp.sh
#   5.x / variants -> isaac-sim.selector.sh, or kit with the GUI .kit app
if [[ "${NO_ISAAC:-0}" == "1" ]]; then
    log "NO_ISAAC=1 — desktop only, skipping Isaac launch."
else
    cd "$ISAAC_ROOT"
    GUI_LAUNCHER=""
    for cand in ./isaac-sim.sh ./runapp.sh ./isaac-sim.selector.sh; do
        [[ -x "$cand" ]] && { GUI_LAUNCHER="$cand"; break; }
    done
    if [[ -z "$GUI_LAUNCHER" ]]; then
        # last resort: run the GUI .kit app directly through kit
        GUI_KIT="$(ls apps/*isaac.sim.kit apps/isaacsim.exp.full.kit 2>/dev/null | head -1 || true)"
        if [[ -n "$GUI_KIT" && -x ./kit/kit ]]; then
            log "Launching Isaac Sim GUI via kit + ${GUI_KIT}..."
            setsid env DISPLAY="$DISPLAY_NUM" ./kit/kit "$GUI_KIT" \
                --ext-folder ./apps --allow-root \
                </dev/null >"$LOG_DIR/isaac-gui.log" 2>&1 &
            echo $! > "$LOG_DIR/isaac-gui.pid"
        else
            log "WARNING: no Isaac GUI launcher found under $ISAAC_ROOT."
            log "Desktop is up — start Isaac yourself with: DISPLAY=$DISPLAY_NUM <launcher>"
        fi
    else
        log "Launching Isaac Sim GUI (${GUI_LAUNCHER}) on ${DISPLAY_NUM}..."
        setsid env DISPLAY="$DISPLAY_NUM" "$GUI_LAUNCHER" --allow-root \
            </dev/null >"$LOG_DIR/isaac-gui.log" 2>&1 &
        echo $! > "$LOG_DIR/isaac-gui.pid"
    fi
fi

# --- 7. print the URL ------------------------------------------------------------
POD="${RUNPOD_POD_ID:-<POD_ID>}"
URL="https://${POD}-${WEB_PORT}.proxy.runpod.net/vnc.html?autoconnect=1&resize=remote"
echo "$URL" > "$LOG_DIR/novnc_url.txt"

echo ""
echo "=================================================================="
echo "  noVNC desktop is UP. Open in your browser:"
echo ""
echo "    $URL"
echo ""
echo "  (also saved to $LOG_DIR/novnc_url.txt)"
echo "  Isaac Sim GUI takes 1-2 min to appear on the desktop."
echo "  Then load your scene with  File > Open  inside the GUI."
echo "=================================================================="
echo ""
log "Everything is detached (setsid) — survives terminal/SSH disconnect."
log "Logs: $LOG_DIR/{xvfb,x11vnc,websockify,fluxbox,isaac-gui}.log"
