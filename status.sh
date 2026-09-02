#!/usr/bin/env bash
# =============================================================================
# Linux-Desktop — Status
# Zeigt Dienststatus, Zugangsdaten und laufende Ports.
#
# Verwendung:  bash status.sh   (auch ohne root)
# =============================================================================
set -uo pipefail

CFG_DIR=/etc/linux-desktop

echo "================== Linux-Desktop Status =================="
echo
echo "-- Dienste -------------------------------------------------"
for svc in rustdesk-hbbs rustdesk-hbbr lightdm rustdesk nginx linux-websockify linux-x1vnc; do
    st="$(systemctl is-active "$svc" 2>/dev/null || echo 'unknown')"
    en="$(systemctl is-enabled "$svc" 2>/dev/null || echo 'unknown')"
    printf '  %-18s active=%-8s enabled=%s\n' "$svc" "$st" "$en"
done

echo
echo "-- X-Server ------------------------------------------------"
if [ -e /tmp/.X11-unix/X0 ]; then
    echo "  X-Server :0 läuft"
    if command -v xdpyinfo >/dev/null 2>&1; then
        DISPLAY=:0 XAUTHORITY="/home/$(grep -oP '^DESKTOP_USER=\K.*' "$CFG_DIR/credentials.env" 2>/dev/null || echo user)/.Xauthority" \
            xdpyinfo 2>/dev/null | grep -E 'dimensions|depth of root' | sed 's/^/  /' || true
    fi
else
    echo "  X-Server :0 NICHT vorhanden"
fi

echo
echo "-- Ports ---------------------------------------------------"
ss -tlnp 2>/dev/null | grep -E ':(80|5900|6080|2111[5-7]) ' | sed 's/^/  /' || echo "  (keine relevanten Ports)"

echo
echo "-- Zugangsdaten --------------------------------------------"
if [ -f "$CFG_DIR/credentials.env" ]; then
    . "$CFG_DIR/credentials.env"
    echo "  RustDesk-ID   : ${RUSTDESK_ID:-?}"
    echo "  RD-Passwort   : ${RUSTDESK_PASSWORD:-?}"
    echo "  ID-Server     : ${RUSTDESK_HOST:-?}"
    echo "  noVNC         : http://${RUSTDESK_HOST:-<host>}/  (Passwort: ${VNC_PASSWORD:-?})"
else
    echo "  (Setup noch nicht ausgeführt)"
fi
echo
