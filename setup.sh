#!/usr/bin/env bash
# =============================================================================
# Linux-Desktop — Setup-Skript
# Debian Stable + LXQt + X11 + RustDesk (self-hosted) + noVNC (Browser)
#
# Alles Open Source, optimiert für Remote-Nutzung:
#   - Kein Compositor (kein picom/compton/kwin) — LXQt-Best-Practice
#   - Xorg mit Dummy- oder Modesetting-Treiber (deterministisch, headless-sicher)
#   - Minimaler Paket- und Service-Fußabdruck
#
# Verwendung:  sudo bash setup.sh
# Idempotent:  kann mehrfach ausgeführt werden (auch nach Updates)
#
# Konfiguration per Umgebungsvariablen (optional):
#   DESKTOP_USER            Benutzername des Desktop-Users (Default: user)
#   DESKTOP_USER_PASSWORD   Passwort des Desktop-Users  (Default: zufällig)
#   RUSTDESK_PASSWORD       RustDesk-Zugriffspasswort   (Default: zufällig)
#   VNC_PASSWORD            noVNC/VNC-Passwort, max. 8 Zeichen (Default: zufällig)
#   RUSTDESK_HOST           Externer Host/IP für fremde RustDesk-Clients
#                           (Default: automatisch, öffentliche IP)
#   X_WIDTH / X_HEIGHT      Auflösung des X-Displays   (Default: 1920x1080)
#   VNC_LISTEN              x11vnc-Bind-Adresse (Default: 127.0.0.1, 0.0.0.0 = offen)
#   RD_CLIENT_VER           RustDesk-Client-Version (Default: 1.4.9)
#   RD_SERVER_VER           RustDesk-Server-Version (Default: 1.1.16)
# =============================================================================
set -euo pipefail

# ----------------------------- Konfiguration --------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$SCRIPT_DIR/config"

DESKTOP_USER="${DESKTOP_USER:-user}"
X_WIDTH="${X_WIDTH:-1920}"
X_HEIGHT="${X_HEIGHT:-1080}"
VNC_LISTEN="${VNC_LISTEN:-127.0.0.1}"
RD_CLIENT_VER="${RD_CLIENT_VER:-1.4.9}"
RD_SERVER_VER="${RD_SERVER_VER:-1.1.16}"

CFG_DIR=/etc/linux-desktop

# ------------------------------- Helfer -------------------------------------
log()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
ok()   { echo -e "  [OK] $*"; }
fail() { echo -e "  [FEHLER] $*" >&2; }
die()  { fail "$*"; exit 1; }

rand_pw() { openssl rand -hex $(( $1 / 2 )) | cut -c1-"$1"; }

# Root-Rechte sicherstellen (evtl. via sudo neu ausführen)
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        log "Re-Eskalation via sudo ..."
        exec sudo env "DESKTOP_USER=$DESKTOP_USER" "DESKTOP_USER_PASSWORD=${DESKTOP_USER_PASSWORD:-}" \
            "RUSTDESK_PASSWORD=${RUSTDESK_PASSWORD:-}" "VNC_PASSWORD=${VNC_PASSWORD:-}" \
            "RUSTDESK_HOST=${RUSTDESK_HOST:-}" "X_WIDTH=$X_WIDTH" "X_HEIGHT=$X_HEIGHT" \
            "VNC_LISTEN=$VNC_LISTEN" "RD_CLIENT_VER=$RD_CLIENT_VER" "RD_SERVER_VER=$RD_SERVER_VER" \
            bash "$0" "$@"
    fi
    die "Bitte als root ausführen (sudo bash $0)"
fi

# systemd-System erforderlich (VM, kein Container)
if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    die "systemd nicht erkannt — dieses Setup benötigt ein systemd-System (VM, kein Container)"
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64)  RD_ARCH=amd64 ;;
    arm64)  RD_ARCH=arm64 ;;
    armhf)  RD_ARCH=armhf ;;
    *) die "Nicht unterstützte Architektur: $ARCH" ;;
esac

# ------------------------------ 1. Grundlagen -------------------------------
log "=== [1/12] APT-Pakete installieren ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || die "apt-get update fehlgeschlagen (Netzwerk?)"

# Basis-Werkzeuge
apt-get install -y -qq \
    ca-certificates curl wget gnupg unzip vim \
    sysstat iproute2 iputils-ping >/dev/null \
    || die "APT-Basisinstallation fehlgeschlagen"
ok "Basis-Werkzeuge"

# LXQt (Metapaket; Fallback auf die Kernkomponenten)
if apt-get install -y -qq lxqt >/dev/null; then
    ok "LXQt (Metapaket)"
else
    log "WARNUNG: Metapaket 'lxqt' nicht verfügbar — installiere Kernkomponenten ..."
    apt-get install -y -qq \
        lxqt-session lxqt-panel pcmanfm-qt lxqt-settings lxqt-quicksettings \
        lxqt-screenshooter lxqt-archiver lxqt-globalkeys \
        || die "LXQt-Kernkomponenten konnten nicht installiert werden"
    ok "LXQt (Kernkomponenten)"
fi

# X11 + LightDM
apt-get install -y -qq \
    lightdm lightdm-gtk-greeter \
    xserver xserver-xorg xserver-xorg-video-dummy xserver-xorg-video-fbdev \
    x11-xserver-utils dbus-x11 \
    fonts-dejavu-core fonts-liberation \
    || die "X11/LightDM konnten nicht installiert werden"
ok "X11 + LightDM"

# Remote-Zugriff (x11vnc + noVNC + nginx)
apt-get install -y -qq x11vnc novnc websockify nginx \
    || die "x11vnc/noVNC/nginx konnten nicht installiert werden"
ok "x11vnc + noVNC + websockify + nginx"

# Andere Display-Manager deaktivieren, falls vorhanden (z. B. von Ubuntu-Basys)
for dm in gdm3 gdm sddm; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${dm}\.service"; then
        systemctl disable --now "$dm" >/dev/null 2>&1 || true
        ok "Deaktiviert: $dm"
    fi
done

# ------------------------- 2. Desktop-User & Zutraege -----------------------
log "=== [2/12] Desktop-User und Credentials ==="
mkdir -p "$CFG_DIR"

if [ -z "${DESKTOP_USER_PASSWORD:-}" ]; then
    DESKTOP_USER_PASSWORD="$(rand_pw 16)"
fi
[ -z "${RUSTDESK_PASSWORD:-}" ] && RUSTDESK_PASSWORD="$(rand_pw 16)"
# VNC/DES: effektiv max. 8 Zeichen
[ -z "${VNC_PASSWORD:-}" ] && VNC_PASSWORD="$(rand_pw 8)"
VNC_PASSWORD="${VNC_PASSWORD:0:8}"

if id "$DESKTOP_USER" >/dev/null 2>&1; then
    ok "User '$DESKTOP_USER' existiert bereits"
else
    useradd -m -s /bin/bash "$DESKTOP_USER"
    ok "User '$DESKTOP_USER' angelegt"
fi
echo "$DESKTOP_USER:$DESKTOP_USER_PASSWORD" | chpasswd
usermod -aG video,audio "$DESKTOP_USER" 2>/dev/null || true

# Externen Host für fremde RustDesk-Clients ermitteln
if [ -z "${RUSTDESK_HOST:-}" ]; then
    RUSTDESK_HOST="$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [ -z "$RUSTDESK_HOST" ] && RUSTDESK_HOST="$(curl -s --max-time 8 https://ifconfig.me 2>/dev/null || true)"
    if [ -z "$RUSTDESK_HOST" ]; then
        RUSTDESK_HOST="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
        [ -z "$RUSTDESK_HOST" ] && RUSTDESK_HOST="127.0.0.1"
        log "WARNUNG: keine öffentliche IP ermittelbar, nutze $RUSTDESK_HOST (via RUSTDESK_HOST überschreibbar)"
    fi
fi
ok "RustDesk-Host (extern): $RUSTDESK_HOST"

# ------------------------- 3. Xorg: Display ohne Compositor ------------------
log "=== [3/12] Xorg-Konfiguration (ohne Compositor) ==="
XORG_DIR=/etc/X11/xorg.conf.d
mkdir -p "$XORG_DIR"

if [ -e /dev/dri/card0 ] || [ -e /dev/fb0 ]; then
    XORG_DRIVER="modesetting"
    install -m 0644 "$CONF_DIR/xorg-modesetting.conf" "$XORG_DIR/10-linux-desktop.conf"
else
    XORG_DRIVER="dummy"
    sed -e "s/@WIDTH@/$X_WIDTH/g" -e "s/@HEIGHT@/$X_HEIGHT/g" \
        "$CONF_DIR/xorg-dummy.conf.template" > "$XORG_DIR/10-linux-desktop.conf"
    chmod 0644 "$XORG_DIR/10-linux-desktop.conf"
fi
ok "Xorg-Treiber: $XORG_DRIVER (Compositor: bewusst NICHT installiert — kein picom/kwin)"

# ---------------------------- 4. LightDM: Autologin --------------------------
log "=== [4/12] LightDM Autologin (Sitzung: LXQt) ==="
sed "s/@USER@/$DESKTOP_USER/g" "$CONF_DIR/lightdm-autologin.conf.template" \
    > /etc/lightdm/lightdm.conf.d/05-linux-desktop.conf
chmod 0644 /etc/lightdm/lightdm.conf.d/05-linux-desktop.conf
systemctl set-default graphical.target
systemctl enable lightdm >/dev/null 2>&1 || true
systemctl start lightdm 2>/dev/null || true
# Warten, bis die LXQt-Sitzung den X-Server :0 gestartet hat
i=0
until [ -e /tmp/.X11-unix/X0 ] || [ $i -ge 60 ]; do sleep 2; i=$((i+1)); done
if [ -e /tmp/.X11-unix/X0 ]; then
    ok "LightDM Autologin → $DESKTOP_USER → lxqt (X-Server :0 aktiv)"
else
    log "WARNUNG: X-Server :0 noch nicht bereit — start.sh verfolgt das weiter"
fi

# ------------------------- 5. LXQt-Optimierungen (User) ----------------------
log "=== [5/12] LXQt-Optimierungen ==="
UHOME="/home/$DESKTOP_USER"

# Einfarbiger Desktop statt Bild (weniger RAM, sauberer Remote-Look)
mkdir -p "$UHOME/.config/pcmanfm-qt"
install -m 0644 "$CONF_DIR/pcmanfm-qt/pcmanfm.conf" "$UHOME/.config/pcmanfm-qt/pcmanfm.conf"

# RustDesk-Tray beim Sitzungsstart (UI neben dem root-Service)
mkdir -p "$UHOME/.config/autostart"
install -m 0644 "$CONF_DIR/autostart/rustdesk.desktop" "$UHOME/.config/autostart/rustdesk.desktop"

chown -R "$DESKTOP_USER:$DESKTOP_USER" \
    "$UHOME/.config/pcmanfm-qt" "$UHOME/.config/autostart"
ok "Desktop-Hintergrund (Solid) + RustDesk-Autostart"

# ----------------------- 6. RustDesk Server (hbbs/hbbr) ----------------------
log "=== [6/12] RustDesk Server (hbbs + hbbr, self-hosted) ==="
RD_TMP="$(mktemp -d)"
RD_SERVER_URL="https://github.com/rustdesk/rustdesk-server/releases/download/$RD_SERVER_VER"
wget -q --tries=3 --timeout=60 -O "$RD_TMP/hbbs.deb" \
    "$RD_SERVER_URL/rustdesk-server-hbbs_${RD_SERVER_VER}_${RD_ARCH}.deb" \
    || die "hbbs.deb $RD_SERVER_VER nicht ladbar"
wget -q --tries=3 --timeout=60 -O "$RD_TMP/hbbr.deb" \
    "$RD_SERVER_URL/rustdesk-server-hbbr_${RD_SERVER_VER}_${RD_ARCH}.deb" \
    || die "hbbr.deb $RD_SERVER_VER nicht ladbar"
dpkg -i "$RD_TMP/hbbs.deb" "$RD_TMP/hbbr.deb" >/dev/null || \
    die "Installation der RustDesk-Server-Pakete fehlgeschlagen"
ok "hbbs + hbbr $RD_SERVER_VER installiert"

# Server starten (postinst macht das oft schon), warten auf ID/Key
systemctl enable rustdesk-hbbs rustdesk-hbbr >/dev/null 2>&1 || true
systemctl restart rustdesk-hbbs rustdesk-hbbr || true
RD_KEY_FILE=/var/lib/rustdesk-server/id_ed25519.pub
i=0
until [ -s "$RD_KEY_FILE" ] || [ $i -ge 30 ]; do sleep 1; i=$((i+1)); done
[ -s "$RD_KEY_FILE" ] || { systemctl restart rustdesk-hbbs; sleep 5; }
[ -s "$RD_KEY_FILE" ] || die "RustDesk-Key wurde nicht generiert ($RD_KEY_FILE)"
RD_PUBKEY="$(tr -d '[:space:]' < "$RD_KEY_FILE")"
ok "RustDesk-Server läuft, öffentlicher Key: ${RD_PUBKEY:0:24}..."

# ------------------------ 7. RustDesk Client (Deb) ---------------------------
log "=== [7/12] RustDesk Client installieren ==="
RD_CLIENT_URL="https://github.com/rustdesk/rustdesk/releases/download/$RD_CLIENT_VER/rustdesk-$RD_CLIENT_VER-${ARCH}.deb"
wget -q --tries=3 --timeout=120 -O "$RD_TMP/rustdesk.deb" "$RD_CLIENT_URL" || \
    die "RustDesk-Client $RD_CLIENT_VER konnte nicht geladen werden ($RD_CLIENT_URL)"
dpkg -i "$RD_TMP/rustdesk.deb" >/dev/null || die "Installation des RustDesk-Clients fehlgeschlagen"
rm -rf "$RD_TMP"
ok "RustDesk Client $RD_CLIENT_VER installiert"

# Systemd-Unit sicherstellen (deb liefert sie unter /usr/share/rustdesk/files/systemd/)
if ! systemctl cat rustdesk >/dev/null 2>&1; then
    if [ -f /usr/share/rustdesk/files/systemd/rustdesk.service ]; then
        install -m 0644 /usr/share/rustdesk/files/systemd/rustdesk.service /etc/systemd/system/rustdesk.service
        systemctl daemon-reload
        ok "rustdesk.service-Unit installiert"
    fi
fi

# Service (root) installieren/enabled + X-Zugriff via Override
rustdesk --install-service >/dev/null 2>&1 || true
mkdir -p /etc/systemd/system/rustdesk.service.d
sed "s/@USER@/$DESKTOP_USER/g" \
    "$CONF_DIR/systemd/rustdesk-client-override.conf.template" \
    > /etc/systemd/system/rustdesk.service.d/linux-desktop.conf
systemctl daemon-reload
systemctl enable rustdesk >/dev/null 2>&1 || true
systemctl restart rustdesk || true
i=0
until systemctl is-active --quiet rustdesk || [ $i -ge 60 ]; do sleep 1; i=$((i+1)); done
systemctl is-active --quiet rustdesk || die "RustDesk-Service startet nicht (journalctl -u rustdesk)"
ok "RustDesk-Service aktiv (mit DISPLAY=:0 + XAUTHORITY)"

# ------------------------ 8. RustDesk Client konfigurieren -------------------
log "=== [8/12] RustDesk Client konfigurieren (eigener Server) ==="
# Lokaler Client verbindet mit 127.0.0.1 (kein NAT-Loopback-Problem);
# externe Clients nutzen $RUSTDESK_HOST (wird unten ausgegeben).

rd_wait_id() {
    RD_ID=""
    local i=0
    until RD_ID="$(rustdesk --get-id 2>/dev/null | tr -d '[:space:]')" && [ -n "$RD_ID" ] && ! [[ "$RD_ID" == *"..."* ]] || [ $i -ge 60 ]; do
        sleep 1; i=$((i+1))
    done
}

# Primärweg: offizielle IPC-CLI (versionunabhängig)
rustdesk --option custom-rendezvous-server 127.0.0.1    >/dev/null || true
rustdesk --option relay-server "127.0.0.1:21117"        >/dev/null || true
rustdesk --option key "$RD_PUBKEY"                       >/dev/null || true
rustdesk --password "$RUSTDESK_PASSWORD"                 >/dev/null || true
systemctl restart rustdesk || true
rd_wait_id

# Fallback: Konfigurationsdateien direkt schreiben (TOML), falls IPC nichts
# durchgelassen hat
if [ -z "$RD_ID" ]; then
    log "IPC-Konfiguration wirkte nicht — schreibe Konfig-Dateien direkt (TOML) ..."
    RD_CONF_DIR=/root/.config/rustdesk
    mkdir -p "$RD_CONF_DIR"
    toml_set() {
        local k="$1" v="$2" f="$3"
        [ -f "$f" ] || : > "$f"
        if grep -q "^${k}\s*=" "$f" 2>/dev/null; then
            sed -i "s|^${k}\s*=.*|$k = \"$v\"|" "$f"
        else
            echo "$k = \"$v\"" >> "$f"
        fi
    }
    toml_set custom-rendezvous-server "127.0.0.1"    "$RD_CONF_DIR/rustdesk.toml"
    toml_set relay-server             "127.0.0.1:21117" "$RD_CONF_DIR/rustdesk.toml"
    toml_set key                      "$RD_PUBKEY"    "$RD_CONF_DIR/rustdesk.toml"
    toml_set password                 "$RUSTDESK_PASSWORD" "$RD_CONF_DIR/rustdesk2.toml"
    systemctl restart rustdesk || true
    rd_wait_id
fi

[ -n "$RD_ID" ] || die "RustDesk-ID konnte nicht abgerufen werden (journalctl -u rustdesk rustdesk-hbbs)"
ok "RustDesk-ID: $RD_ID"

# ------------------------------ 9. noVNC/VNC ---------------------------------
log "=== [9/12] noVNC + x11vnc (Browser-Zugriff) ==="
# VNC-Passwort (DES-Hash, effektiv max. 8 Zeichen)
x11vnc -storepasswd "$VNC_PASSWORD" "$CFG_DIR/x11vnc.passwd" >/dev/null 2>&1
chmod 0600 "$CFG_DIR/x11vnc.passwd"

VNC_AUTH_OPT="-rfbauth $CFG_DIR/x11vnc.passwd"
VNC_LISTEN_OPT="-listen $VNC_LISTEN"
sed -e "s/@USER@/$DESKTOP_USER/g" \
    -e "s|@VNC_LISTEN_OPT@|$VNC_LISTEN_OPT|g" \
    -e "s|@VNC_AUTH_OPT@|$VNC_AUTH_OPT|g" \
    "$CONF_DIR/systemd/x11vnc.service.template" > /etc/systemd/system/linux-x11vnc.service
install -m 0644 "$CONF_DIR/systemd/websockify.service" /etc/systemd/system/linux-websockify.service
systemctl daemon-reload
systemctl enable linux-x11vnc linux-websockify >/dev/null 2>&1 || true
ok "x11vnc (Passwort) + websockify + noVNC (via nginx, Port 80)"

# ------------------------------ 10. nginx ------------------------------------
log "=== [10/12] nginx (noVNC auf Port 80) ==="
install -m 0644 "$CONF_DIR/nginx-linux-desktop.conf" /etc/nginx/sites-available/linux-desktop.conf
mkdir -p /etc/nginx/sites-enabled
ln -sf /etc/nginx/sites-available/linux-desktop.conf /etc/nginx/sites-enabled/linux-desktop.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || die "nginx-Konfiguration ungültig"
systemctl enable nginx >/dev/null 2>&1 || true
ok "nginx bereit (noVNC unter http://<host>/)"

# ------------------------ 11. Ressourcen minimieren --------------------------
log "=== [11/12] Unnötige Services deaktivieren ==="
for svc in bluetooth cups avahi-daemon ModemManager pipewire pipewire-pulse; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        systemctl mask "$svc" >/dev/null 2>&1 || true
        ok "Masked: $svc"
    fi
done
install -m 0644 "$CONF_DIR/sysctl-99-linux-desktop.conf" /etc/sysctl.d/99-linux-desktop.conf
sysctl --system >/dev/null 2>&1 || true
ok "Sysctl-Tuning"

# ----------------------------- 12. Credentials -------------------------------
log "=== [12/12] Credentials & Zusammenfassung ==="
cat > "$CFG_DIR/credentials.env" <<EOF
# Linux-Desktop — generiert von setup.sh (Nicht weiterleiten!)
DESKTOP_USER=$DESKTOP_USER
DESKTOP_USER_PASSWORD=$DESKTOP_USER_PASSWORD
RUSTDESK_ID=$RD_ID
RUSTDESK_PASSWORD=$RUSTDESK_PASSWORD
RUSTDESK_KEY=$RD_PUBKEY
RUSTDESK_HOST=$RUSTDESK_HOST
VNC_PASSWORD=$VNC_PASSWORD
X_RESOLUTION=${X_WIDTH}x${X_HEIGHT}
XORG_DRIVER=$XORG_DRIVER
EOF
chmod 0600 "$CFG_DIR/credentials.env"

cat > "$CFG_DIR/SUMMARY.txt" <<EOF
=====================================================================
 Linux-Desktop — Konfiguration
=====================================================================
 Desktop-User    : $DESKTOP_USER
 Desktop-Passwort: $DESKTOP_USER_PASSWORD

 RustDesk (native Clients: Windows/macOS/Linux/Android/iOS)
   ID            : $RD_ID
   Passwort      : $RUSTDESK_PASSWORD
   ID-Server     : $RUSTDESK_HOST   (Port 21116, zusätzlich 21115/tcp, 21116/udp)
   Relay         : $RUSTDESK_HOST   (Port 21117)
   Key           : $RD_PUBKEY

 Browser (noVNC, 100% Open Source)
   URL           : http://$RUSTDESK_HOST/
   VNC-Passwort  : $VNC_PASSWORD

 Display         : ${X_WIDTH}x${X_HEIGHT} (X11, Treiber: $XORG_DRIVER, kein Compositor)
=====================================================================
EOF
chmod 0600 "$CFG_DIR/SUMMARY.txt"

echo
cat "$CFG_DIR/SUMMARY.txt"
echo
log "Setup fertig. Alle Dienste werden jetzt gestartet (start.sh) ..."
bash "$SCRIPT_DIR/start.sh"
