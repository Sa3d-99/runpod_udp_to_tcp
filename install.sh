#!/usr/bin/env bash
# =============================================================================
# install.sh — installs everything the bridge needs inside the container.
#
# System packages (apt): git, python3, coturn, iproute2 (ss)
# Python packages (pip): none needed — scripts use the standard library only;
#                        requirements.txt is kept for future additions.
#
# Idempotent: skips apt entirely when all tools are already present.
# start_all.sh runs this automatically, so you rarely call it yourself.
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MISSING=()
for cmd in git python3 turnserver ss; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    echo "[install] all dependencies already present"
else
    echo "[install] installing missing tools: ${MISSING[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        git python3 python3-pip coturn iproute2 ca-certificates >/dev/null
    echo "[install] system packages done"
fi

# Install pip requirements only if the file lists any real package.
if [[ -f "$DIR/requirements.txt" ]] && grep -qEv '^\s*(#|$)' "$DIR/requirements.txt"; then
    echo "[install] installing pip requirements"
    python3 -m pip install --quiet -r "$DIR/requirements.txt"
fi

echo "[install] ready"
