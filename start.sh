#!/usr/bin/env bash
# =============================================================================
# Linux-Desktop — Start
# Startet alle benötigten Dienste und prüft die Bereitschaft.
# Idempotent: kann jederzeit erneut ausgeführt werden (auch nach Neustart).
#
# Verwendung:  sudo bash start.sh   (oder einfach:  bash start.sh)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR=/etc/linux-desktop

log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Root sicherstellen
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        exec sudo bash "$0" "$@"
    fi
    echo "Bitte als root ausführen (sudo bash $0)" >&2
    exit 1
fi

# Setup muss einmalig ausgeführt sein
[ -f "$CFG_DIR/credentials.env" ] || {
    echo "Setup fehlt — zuerst ausführen:  sudo bash $SCRIPT_DIR/setup.sh" >&2
    exit 1
}
. "$CFG_DIR/credentials.env"

log "Starte Linux-Desktop-Dienste ..."

# Reihenfolge: RustDesk-Server → Display-Manager → Web/Remote-Zugriff
systemctl enable rustdesk-hbbs rustdesk-hbbr >/dev/null 2>&1 || true
systemctl restart rustdesk-hbbs
systemctl restart rustdesk-hbbr
systemctl enable --now lightdm || true
sleep 2
systemctl enable --now nginx || true
systemctl enable --now linux-websockify || true
systemctl enable --now linux-x11vnc || true
systemctl enable rustdesk >/dev/null 2>&1 || true
systemctl restart rustdesk || true

# Warten, bis der X-Server läuft (LightDM autologin → LXQt)
log "Warte auf X-Server :0 ..."
i=0
until [ -e /tmp/.X11-unix/X0 ] || [ $i -ge 90 ]; do sleep 2; i=$((i+1)); done
[ -e /tmp/.X11-unix/X0 ] || echo "  WARNUNG: X-Server noch nicht da (journalctl -u lightdm)"

# Warten, bis VNC Port 5900 lauscht
i=0
until ss -tlnp 2>/dev/null | grep -q ':5900 ' || [ $i -ge 60 ]; do sleep 2; i=$((i+1)); done

# Status-Übersicht
echo
log "Bereitschaft:"
for svc in rustdesk-hbbs rustdesk-hbbr lightdm rustdesk nginx linux-websockify linux-x1vnc; do
    st="$(systemctl is-active "$svc" 2>/dev/null || true)"
    printf '  %-18s %s\n' "$svc" "${st:-unknown}"
done
ss -tln 2>/dev/null | grep -E ':(80|5900|2111[5-7]) ' | sed 's/^/  /' || true

echo
echo "=============================================================="
echo " Linux-Desktop ist bereit."
echo "--------------------------------------------------------------"
echo " RustDesk-ID   : ${RUSTDESK_ID}"
echo " RD-Passwort   : ${RUSTDESK_PASSWORD}"
echo " ID-Server     : ${RUSTDESK_HOST}  (21116/tcp+udp, 21115/tcp, Relay 21117/tcp)"
echo " RD-Key        : ${RUSTDESK_KEY:0:32}..."
echo
echo " Browser (noVNC): http://${RUSTDESK_HOST}/"
echo " VNC-Passwort  : ${VNC_PASSWORD}"
echo "=============================================================="
echo " Details: cat /etc/linux-desktop/SUMMARY.txt"
