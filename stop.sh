#!/usr/bin/env bash
# =============================================================================
# Linux-Desktop — Stop
# Stoppt den Desktop (X11/LXQt) und die Remote-Zugänge, behält aber den
# RustDesk-Server (hbbs/hbbr) aktiv, damit die Maschine verwaltbar bleibt.
#
# Verwendung:  sudo bash stop.sh
# =============================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        exec sudo bash "$0" "$@"
    fi
    echo "Bitte als root ausführen (sudo bash $0)" >&2
    exit 1
fi

echo "Stoppe Linux-Desktop-Dienste (RustDesk-Server bleibt aktiv) ..."
systemctl stop linux-x1vnc linux-websockify rustdesk 2>/dev/null || true
systemctl stop lightdm 2>/dev/null || true
echo "Fertig."
echo "  → neu starten mit: sudo bash start.sh"
