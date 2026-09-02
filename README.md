# Linux-Desktop — Debian + LXQt + X11 + RustDesk (self-hosted)

Ein vollständiger, schlanker **Linux-Desktop für den Remote-Betrieb** — komplett
**Open Source**, ohne jede proprietäre Software (kein NoMachine, kein TeamViewer,
kein kommerzieller VNC-Server):

| Baustein | Technologie | Lizenz |
|---|---|---|
| Betriebssystem | **Debian Stable** (aktuell, 12/13) | DFSG-frei |
| Desktop-Umgebung | **LXQt** | GPL-2.0+ |
| Display-Server | **X11** (X.Org) | X11/XFree86 |
| Display-Manager | **LightDM** (Autologin) | GPL-3.0+ |
| Remote-Desktop | **RustDesk** (Client + eigener Server `hbbs`/`hbbr`) | MPL-2.0 |
| Browser-Zugriff | **noVNC** + **x11vnc** + **nginx** | LGPL / X11 / BSD |

## Architektur

```
                       ┌──────────────────────────── VM (Debian Stable) ───────────────────────────┐
                       │                                                                            │
  Native-Clients       │  ┌─────────────┐  21115/21116/21117  ┌──────────────────────────┐          │
  (Windows, macOS,     │  │  hbbs (ID)  │◄────────────────────┤                            │          │
   Linux, Android,     ├─►│  hbbr(Relay)│                      │  RustDesk-Client (Service)│          │
   iOS)  ──────────────┼─►└─────────────┘  (eigener, self-     │  root, DISPLAY=:0        │          │
                       │                      gehosteter       │         │                │          │
                       │                      RustDesk-Server) └─────────┼────────────────┘          │
                       │                                                 ▼                          │
  Browser (jedes       │  ┌─────────┐  /websockify  ┌───────────┐  :0   ┌──────────────────────┐    │
   Gerät, kein         ├─►│  nginx  │──────────────►│ websockify│───────►  x11vnc              │    │
   Install)            │  │   :80   │  WebSocket    │   :6080   │        │  :5900              │    │
                       │  └─────────               └───────────┘        └──────────┬───────────┘    │
                       │                                                           ▼               │
                       │                                         ┌───────────────────────────┐       │
                       │                                         │  LightDM → LXQt-Sitzung   │       │
                       │                                         │  Xorg :0 (dummy/modeset)  │       │
                       │                                         │  KEIN Compositor          │       │
                       │                                         └───────────────────────────┘       │
                       └────────────────────────────────────────────────────────────────────────────┘
```

* **RustDesk** = primärer Zugriff: verschlüsselt (eigener Key), funktioniert mit
  den nativen Clients auf **allen Geräten** (Windows, macOS, Linux, Android, iOS)
  — auch hinter NAT, da eigener `hbbs`/`hbbr`-Server auf der Maschine läuft.
* **noVNC** = Zugriff **direkt im Browser** auf jedem Gerät, ohne Installation
  (100 % Open Source, da der offizielle RustDesk-Web-Client nur noch lizenziert
  self-hostbar ist — Details im [FAQ](#faq)).

---

## Voraussetzungen

* VM/Server mit **Debian Stable** (12 „bookworm“ oder 13 „trixie“), 64-Bit
* Mindestens **1 vCPU, 2 GB RAM, 10 GB Disk** (empfohlen: 2 vCPU / 4 GB)
* Ausgehendes Internet (einmalig für Pakete/Debs), offene Eingangs-Ports (Tabelle unten)
* `sudo`/root auf der Maschine

## Port-Übersicht

| Port | Protokoll | Dienst | Zweck |
|---|---|---|---|
| 80 | TCP | nginx | noVNC im Browser |
| 5900 | TCP | x11vnc | Direkt-VNC (Default nur Loopback, `VNC_LISTEN=0.0.0.0` öffnet) |
| 21115 | TCP | hbbs | NAT-Type-Test |
| 21116 | **TCP + UDP** | hbbs | ID-Registrierung/Heartbeat, Hole-Punching |
| 21117 | TCP | hbbr | Relay |

> Ports 21118/21119 (RustDesk-Web-Client-WebSocket) bleiben **bewusst zu**, da
> für den Browser noVNC genutzt wird — weniger offene Fläche.

---

## Schnellstart

### Variante A: Lightning AI (empfohlen)

1. Studio/VM aus diesem Repo erstellen.
2. SSH vom eigenen Terminal einrichten (einmalig, von Lightning bereitgestellt):
   ```bash
   curl -s "https://lightning.ai/setup/ssh?t=<token>&s=<studio-id>" | bash
   ```
3. Auf der Instanz anmelden und das Repo aktuell halten:
   ```bash
   ssh <studio-id>@ssh.lightning.ai
   cd <pfad-zum-repo>          # z. B. ~/Linux-Desktop
   git pull
   ```
4. Setup + Start (Setup ist idempotent — darf auch mehrfach laufen):
   ```bash
   sudo bash setup.sh
   sudo bash start.sh          # gibt am Ende alle Zugangsdaten aus
   ```
5. Zugriff:
   * **Browser:** `http://<VM-IP-oder-Lightning-URL>/` → Passwort aus der Ausgabe
   * **RustDesk-App:** ID + Passwort aus der Ausgabe (Server-Werte s. u.)

> `lightning.yaml` in der Repo-Root beschreibt Setup/Start/Ports zusätzlich
> deklarativ — falls dein Lightning-Flow ihn automatisch verarbeitet.
> Andernfalls sind die Shell-Befehle oben der verbindliche Weg.

### Variante B: Eigener Debian-Server

```bash
git clone <repo-url> Linux-Desktop && cd Linux-Desktop
sudo bash setup.sh     # dauert je nach Internet ~5–15 min
# setup.sh ruft am Ende automatisch start.sh auf
```

Konfiguration per Umgebungsvariablen (optional, vor `setup.sh`):

```bash
DESKTOP_USER=meinuser \
DESKTOP_USER_PASSWORD='...' \
RUSTDESK_PASSWORD='mein-rd-passwort' \
VNC_PASSWORD='max8Zeichen' \
RUSTDESK_HOST=vm.beispiel.de \
X_WIDTH=1920 X_HEIGHT=1080 \
VNC_LISTEN=0.0.0.0 \
sudo bash setup.sh
```

Unverändert gelassene Werte werden **zufällig generiert** und in
`/etc/linux-desktop/credentials.env` (0600) bzw. `/etc/linux-desktop/SUMMARY.txt`
gespeichert — **beide Dateien sichern, das ist der einzige Ort der Secrets.**

---

## Zugriff

### 1) Native RustDesk-Clients (Windows / macOS / Linux / Android / iOS)

In jeder RustDesk-App (aus den offiziellen Kanälen, z. B.
[GitHub-Release](https://github.com/rustdesk/rustdesk/releases)) einmalig
einstellen — unter **⋮ → Network** (bzw. Einstellungen → Netzwerk, mit
Entsperren/Root):

| Feld | Wert |
|---|---|
| ID Server | `<RUSTDESK_HOST>` aus `SUMMARY.txt` (z. B. `203.0.113.10` oder eine Domain) |
| Key | `<RUSTDESK_KEY>` aus `SUMMARY.txt` |
| Relay Server | leer lassen (wird abgeleitet) oder `<RUSTDESK_HOST>:21117` |

Danach in der App: **ID** = `RUSTDESK_ID` aus `SUMMARY.txt`, Passwort =
`RUSTDESK_PASSWORD`. Fertig — verschlüsselt über deinen eigenen Server.

> Der lokale Client auf der Desktop-Maschine selbst ist bereits vorkonfiguriert
> (verbindet mit `127.0.0.1`, kein NAT-Loopback-Problem).

### 2) Browser (jedes Gerät, keine Installation)

* **URL:** `http://<RUSTDESK_HOST>/` (bzw. Lightning-URL der Instanz)
* **Passwort:** `VNC_PASSWORD` aus `SUMMARY.txt`

noVNC zeigt die exakt gleiche LXQt-Sitzung wie der RustDesk-Client.

---

## Optimierungen & LXQt-Best-Practices

Dieses Setup ist bewusst auf **Performance im Remote-Betrieb** und
**minimale Server-Ressourcen** zugeschnitten:

* **Kein Compositor** — LXQt-Best-Practice: Es werden *weder* `picom`/`compton`
  *noch* `kwin_x11` installiert; die LXQt-Sitzung läuft ohne Window-Compositor
  (keine Transparenzen/Blur → kein doppelter Framebuffer, kein GL-Overhead).
* **Xorg deterministisch ohne GPU**:
  * Virtuelle GPU vorhanden → `modesetting`,
  * sonst → `xf86-video-dummy` mit fester Auflösung (Default **1920×1080@24bit**).
  * Damit startet X zuverlässig auf jeder Headless-VM; Screen-Sharing via X11
    braucht keine GPU-Beschleunigung.
* **Einfarbiger Desktop** statt Desktop-Hintergrundbild (pcmanfm-qt Solid-Mode) —
  weniger RAM, ruhigere Frames im Remote-Stream.
* **Kein Audio-Stack im Betrieb**: `pipewire`/`pulseaudio`-Services sind gemaskt,
  Bluetooth/AVahi/CUPS/ModemManager werden deaktiviert.
* **LightDM-Autologin** direkt in die LXQt-Sitzung (kein Greeter-Bildschirm,
  Sitzungs-Crash-Resilienz durch LightDM).
* **Konservatives Sysctl-Tuning** (`vm.swappiness=10`, …) in `/etc/sysctl.d/99-linux-desktop.conf`.
* Typischer Idle-Verbrauch: **~350–600 MB RAM** auf 1 vCPU (je nach Auflösung).

Auflösung ändern: `X_WIDTH`/`X_HEIGHT` setzen und `sudo bash setup.sh` erneut
ausführen (nur die X-Konfiguration wird neu geschrieben), dann
`sudo bash start.sh`.

---

## Betrieb

| Befehl | Wirkung |
|---|---|
| `sudo bash setup.sh` | Provisionierung (idempotent, auch für Updates) |
| `sudo bash start.sh` | Alle Dienste starten, Bereitschaft prüfen, Daten ausgeben |
| `bash status.sh` | Dienststatus, X-Info, Ports, Zugangsdaten |
| `sudo bash stop.sh` | Desktop + Remote-Access stoppen (RustDesk-Server bleibt) |

Weitere Befehle:

```bash
# Logs
journalctl -u rustdesk -f            # RustDesk-Client
journalctl -u rustdesk-hbbs -f       # ID-Server
journalctl -u linux-x1vnc -f         # VNC
journalctl -u lightdm -f             # Display-Manager

# Passwörter ändern
rustdesk --password 'neu'                    # RustDesk (als root)
x11vnc -storepasswd 'neu' /etc/linux-desktop/x11vnc.passwd && systemctl restart linux-x1vnc

# RustDesk-Server neu starten
systemctl restart rustdesk-hbbs rustdesk-hbbr
```

**RustDesk-Server aktualisieren:** neuere Version von
[rustdesk/rustdesk-server Releases](https://github.com/rustdesk/rustdesk-server/releases)
herunterladen, `dpkg -i` über die bestehenden Pakete fahren — der Key in
`/var/lib/rustdesk-server/` bleibt erhalten, Clients müssen nicht neu
konfiguriert werden. Client analog über
[rustdesk/rustdesk Releases](https://github.com/rustdesk/rustdesk/releases).

---

## Sicherheitshinweise

* **Secrets** liegen nur in `/etc/linux-desktop/credentials.env` + `SUMMARY.txt`
  (0600). Nicht in Git committen, nicht teilen.
* **RustDesk-Verbindungen sind verschlüsselt** (Ed25519-Key + AES, Key =
  `id_ed25519.pub` aus dem Setup). Ohne `RUSTDESK_PASSWORD` + ID kein Zugriff.
* **noVNC läuft standardmäßig im Klartext** (RFB/DES). Für den Betrieb im
  eigenen Netzwerk/Lightning-Preview ausreichend; für Dauerbetrieb im Internet
  vor nginx TLS (z. B. via Let's Encrypt/Reverse-Proxy) + Zugriffsschutz
  (IP-Allowlist/Auth) schalten. `x11vnc` lauscht per Default nur auf Loopback;
  Direkte VNC-Ports sind also nur bei `VNC_LISTEN=0.0.0.0` erreichbar.
* Firewall: nur die Port-Tabelle oben öffnen, 21116 **TCP und UDP**.

---

## Dateien im Repo

```
setup.sh                     # Haupt-Setup (idempotent)
start.sh                     # Start + Bereitschafts-Check + Ausgabe
stop.sh                      # Stop (RustDesk-Server bleibt aktiv)
status.sh                    # Status & Zugangsdaten
lightning.yaml               # Lightning-AI-Definition (best-effort)
config/
├── xorg-dummy.conf.template       # Xorg ohne GPU (feste Auflösung)
├── xorg-modesetting.conf          # Xorg mit virtueller GPU
├── lightdm-autologin.conf.template
├── pcmanfm-qt/pcmanfm.conf        # Solid-Desktop-Hintergrund
├── autostart/rustdesk.desktop     # RustDesk-Tray in der Sitzung
├── systemd/
│   ├── x11vnc.service.template
│   ├── websockify.service
│   └── rustdesk-client-override.conf.template   # X-Zugriff für den Service
├── nginx-linux-desktop.conf       # noVNC auf Port 80
└── sysctl-99-linux-desktop.conf
```

---

## Troubleshooting

| Symptom | Ursache / Lösung |
|---|---|
| X startet nicht (schwarzes Terminal) | `journalctl -u lightdm`, `journalctl -u xorg` bzw. `/var/log/Xorg.0.log`; Treiber prüfen (`XORG_DRIVER` in `SUMMARY.txt`). Bei Modesetting-Problemen: `sudo bash setup.sh` nach Entfernung `/dev/dri`-Erwartung → erzwingen: `rm /etc/X11/xorg.conf.d/10-linux-desktop.conf` + neu mit dummy (siehe `config/xorg-dummy.conf.template`) |
| RustDesk-ID leer/Client offline | `journalctl -u rustdesk`, `journalctl -u rustdesk-hbbs`; hbbs muss auf 21116/udp erreichbar sein; Key in den Clients = `RUSTDESK_KEY` aus `SUMMARY.txt` (ohne Leerzeichen/Zeilenumbrüche) |
| Verbindung baut nicht auf (Client) | Firewall: **21116 TCP + UDP**, 21115 TCP, 21117 TCP öffnen; NAT hinter dem Client → Relay 21117 muss frei sein |
| noVNC connectet nicht | `systemctl status linux-x1vnc linux-websockify nginx`; `ss -tlnp \| grep -E '5900\|6080\|:80 '`; X-Socket `/tmp/.X11-unix/X0` vorhanden? |
| VNC-Auth fehlgeschlagen | Passwort max. **8 Zeichen** (RFB/DES); `x11vnc -storepasswd` erneut + `systemctl restart linux-x1vnc` |
| Bildschirm flackert/langsam (VNC) | Auflösung senken (`X_WIDTH=1280 X_HEIGHT=720`, `setup.sh` erneut) — VNC skaliert schlechter als RustDesk |
| Hohe CPU-Last beim Teilen | RustDesk-Client: Einstellungen → Video → Codec/Auflösung/Refresh senken (z. B. 15–20 fps) |
| Nach Reboot nicht da | `sudo bash start.sh`; Dienste sind enabled — sollte automatisch laufen |

---

## FAQ

**Warum noVNC und nicht der RustDesk-Web-Client?**
Der offene RustDesk-Web-Client (WASM) ist nicht mehr selbst hostbar — der neue
Web-Client V2 (rustdesk.com/web) ist nur mit **Pro-Abo** self-hostbar, also
proprietary. noVNC + x11vnc ist dagegen vollständig Open Source, extrem
stabil und zeigt dieselbe X11-Sitzung. RustDesk bleibt damit der
primäre (nativer) Client für alle Geräte.

**Warum kein Wayland?**
X11 ist explizit gefordert und für Headless-Remote-Setups (x11vnc, RustDesk
X11-Capture) am reifsten und ressourcenschonendsten.

**Läuft das ohne GPU?**
Ja — der Dummy-Treiber erzeugt einen virtuellen Framebuffer; Rendering erfolgt
per Software. Für reine Remote-Nutzung optimal.

**Wie viel RAM braucht das?**
Idle ca. 350–600 MB (X11 + LXQt + RustDesk + x11vnc + nginx). 2 GB ist
ausreichend, 4 GB komfortabel.

---

*Alle Komponenten sind Open Source — siehe Lizenz-Tabelle oben. Generiert mit
`setup.sh` (Debian Stable), Stand September 2026: RustDesk-Client 1.4.9,
RustDesk-Server 1.1.16.*
