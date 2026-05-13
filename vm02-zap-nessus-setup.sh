#!/bin/bash
###############################################################################
# VM-02: DAST Attack Node — OWASP ZAP + Nessus Essentials
# Master Kit Setup Script
# OS: Ubuntu 22.04 LTS | CPU: 4 vCPU | RAM: 8 GB | Disk: 80 GB SSD
#
# This script installs and configures:
#   - OpenJDK 17
#   - OWASP ZAP (latest stable)
#   - Nessus Essentials
#   - Supplementary tools (nmap, curl, python3, etc.)
#   - Lab user with SSH access
#
# Run as root: sudo bash vm02-zap-nessus-setup.sh
###############################################################################

set -uo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
LAB_USER="${LAB_USER:-${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo "labuser")}}"
[ "$LAB_USER" = "root" ] && LAB_USER="${SUDO_USER:-labuser}"
LAB_HOME=$(getent passwd "$LAB_USER" 2>/dev/null | cut -d: -f6)
[ -z "$LAB_HOME" ] && LAB_HOME="/home/$LAB_USER"
THIS_IP="${THIS_IP:-$(hostname -I | awk '{print $1}')}"
# Directory of this script (used to locate Nessus .deb placed alongside it)
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
VM01_IP="${VM01_IP:-}"
VM02_IP="${VM02_IP:-$THIS_IP}"
VM03_IP="${VM03_IP:-}"
ZAP_API_KEY="lab-api-key-2024"

LOG_FILE="/var/log/vm02-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================================================"
echo " VM-02 SETUP — DAST Attack Node (ZAP + Nessus)"
echo " Started: $(date)"
echo "======================================================================"

# ─── STEP 1: SYSTEM PREP ────────────────────────────────────────────────────
echo ""
echo "[STEP 1/10] System update and base packages..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget unzip git net-tools vim nano htop tree jq \
  software-properties-common apt-transport-https ca-certificates \
  gnupg lsb-release ufw openssh-server \
  python3 python3-pip python3-venv \
  nmap nikto dnsutils whois traceroute \
  firefox xdg-utils

# ─── STEP 2: CREATE LAB USER ────────────────────────────────────────────────
echo ""
echo "[STEP 2/10] Verifying lab user: $LAB_USER..."

if ! id "$LAB_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G sudo "$LAB_USER"
  echo "  Created user $LAB_USER. Set a password with: sudo passwd $LAB_USER"
fi
if [ ! -f "/etc/sudoers.d/$LAB_USER" ]; then
  echo "$LAB_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$LAB_USER"
  chmod 440 "/etc/sudoers.d/$LAB_USER"
fi
echo "  Lab user: $LAB_USER (home: $LAB_HOME)"

# ─── STEP 3: SSH CONFIGURATION ──────────────────────────────────────────────
echo ""
echo "[STEP 3/10] Configuring SSH..."

sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

# ─── STEP 4: INSTALL JAVA 17 ────────────────────────────────────────────────
echo ""
echo "[STEP 4/10] Installing OpenJDK 17..."

if java -version 2>&1 | grep -q 'version "17'; then
  echo "  Java 17 already installed: $(java -version 2>&1 | head -1)"
else
  apt-get install -y -qq openjdk-17-jdk openjdk-17-jre
  echo "  Installed: $(java -version 2>&1 | head -1)"
fi

# ─── STEP 5: INSTALL OWASP ZAP ──────────────────────────────────────────────
echo ""
echo "[STEP 5/10] Installing OWASP ZAP..."

if [ -d /opt/zaproxy ] && [ -f /opt/zaproxy/zap.sh ]; then
  echo "  ZAP already installed at /opt/zaproxy — skipping download."
else
  ZAP_DL_URL="https://github.com/zaproxy/zaproxy/releases/download/v2.16.1/ZAP_2.16.1_Linux.tar.gz"
  cd /tmp
  if [ ! -f "zap-linux.tar.gz" ]; then
    echo "  Downloading OWASP ZAP..."
    wget -q "$ZAP_DL_URL" -O zap-linux.tar.gz || {
      echo "  Direct download failed, trying latest release API..."
      ZAP_DL_URL=$(curl -s https://api.github.com/repos/zaproxy/zaproxy/releases/latest \
        | jq -r '.assets[] | select(.name | contains("Linux") and contains("tar.gz")) | .browser_download_url' \
        | head -1)
      wget -q "$ZAP_DL_URL" -O zap-linux.tar.gz
    }
  else
    echo "  Using cached download: zap-linux.tar.gz"
  fi

  tar -xzf zap-linux.tar.gz -C /opt/
  ZAP_FOUND=$(find /opt -maxdepth 1 -name "ZAP_*" -type d | head -1)
  if [ -z "$ZAP_FOUND" ]; then
    echo "  ERROR: Could not find extracted ZAP directory. Download may have failed."
    echo "  You can retry with: sudo bash vm02-zap-nessus-setup.sh"
  else
    rm -rf /opt/zaproxy
    mv "$ZAP_FOUND" /opt/zaproxy
    echo "  ZAP extracted to /opt/zaproxy"
  fi
fi

# Ensure zap.sh is executable and symlinked
if [ -f /opt/zaproxy/zap.sh ]; then
  chmod +x /opt/zaproxy/zap.sh
  ln -sf /opt/zaproxy/zap.sh /usr/local/bin/zap
  echo "  ZAP installed at /opt/zaproxy"
fi

# ─── STEP 6: CONFIGURE ZAP FOR DAEMON MODE ──────────────────────────────────
echo ""
echo "[STEP 6/10] Configuring ZAP daemon service..."

# Create ZAP data directory
mkdir -p "$LAB_HOME/.ZAP/policies"
chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/.ZAP"

# Create systemd service for ZAP daemon
cat > /etc/systemd/system/zap-daemon.service << EOF
[Unit]
Description=OWASP ZAP Daemon
After=network.target

[Service]
Type=simple
User=$LAB_USER
ExecStart=/opt/zaproxy/zap.sh -daemon -port 8090 -host 0.0.0.0 \
  -config api.key=$ZAP_API_KEY \
  -config api.addrs.addr.name=.* \
  -config api.addrs.addr.regex=true \
  -config api.disablekey=false \
  -config connection.timeoutInSecs=120
Restart=on-failure
RestartSec=15
StandardOutput=append:/var/log/zap-daemon.log
StandardError=append:/var/log/zap-daemon.log

[Install]
WantedBy=multi-user.target
EOF

touch /var/log/zap-daemon.log
chown "$LAB_USER:$LAB_USER" /var/log/zap-daemon.log

systemctl daemon-reload
systemctl enable zap-daemon

echo "  ZAP daemon service configured (port 8090, API key: $ZAP_API_KEY)"

# ─── STEP 6b: ZAP GUI SETUP ──────────────────────────────────────────────────
echo ""
echo "[STEP 6b/10] Setting up ZAP GUI launcher..."

# Install Swing/AWT display libraries needed to run ZAP in GUI mode.
# libasound is named differently on Ubuntu 22 vs 24 — try both.
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq libgtk-3-0 libxtst6 libgl1 xdg-utils 2>/dev/null || true
apt-get install -y -qq libasound2 2>/dev/null || apt-get install -y -qq libasound2t64 2>/dev/null || true

# Locate ZAP icon bundled in the tarball (name varies by release)
ZAP_ICON=$(find /opt/zaproxy -maxdepth 2 -name "*.png" 2>/dev/null | head -1)
[ -z "$ZAP_ICON" ] && ZAP_ICON="/opt/zaproxy/zap.png"

# ── Desktop application launcher (shows in GNOME/KDE app menu) ───────────────
cat > /usr/share/applications/zaproxy.desktop << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=OWASP ZAP
GenericName=Web Security Scanner
Comment=Zed Attack Proxy — interactive web application security testing
Exec=/opt/zaproxy/zap.sh
Icon=${ZAP_ICON}
Terminal=false
Categories=Security;Network;Development;
Keywords=security;proxy;scanner;web;owasp;zap;dast;
StartupNotify=true
StartupWMClass=org-zaproxy-zap-ZAP
EOF
chmod 644 /usr/share/applications/zaproxy.desktop
update-desktop-database /usr/share/applications/ 2>/dev/null || true

echo "  Desktop launcher created: /usr/share/applications/zaproxy.desktop"
echo "  ZAP will appear in your application menu (Security / Network)."
echo "  If using a desktop session, you can also click the app icon to launch it."

# ── STEP 7: INSTALL NESSUS ESSENTIALS ────────────────────────────────────────
echo ""
echo "[STEP 7/10] Installing Nessus Essentials..."

mkdir -p "$LAB_HOME/scripts"

if dpkg -l nessus 2>/dev/null | grep -q '^ii'; then
  # ── Already installed ──────────────────────────────────────────────────────
  echo "  Nessus already installed."
  systemctl enable nessusd 2>/dev/null || true
  systemctl start nessusd 2>/dev/null || true

else
  # ── Not yet installed — look for .deb ─────────────────────────────────────
  # Search in: same dir as this script, then /tmp
  NESSUS_DEB_PATH=""
  for search_dir in "$SCRIPT_DIR" "/tmp" "$LAB_HOME"; do
    found=$(find "$search_dir" -maxdepth 1 -iname "Nessus*.deb" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      NESSUS_DEB_PATH="$found"
      break
    fi
  done

  if [ -n "$NESSUS_DEB_PATH" ]; then
    echo "  Found Nessus .deb: $NESSUS_DEB_PATH"
    echo "  Installing Nessus..."
    dpkg -i "$NESSUS_DEB_PATH" 2>/dev/null || apt-get install -f -y -qq
    systemctl enable nessusd 2>/dev/null || true
    systemctl start nessusd 2>/dev/null || true
    echo "  Nessus installed. Complete first-time setup in the browser."
  else
    # ── .deb not found — inform and create helper ──────────────────────────
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║  ACTION REQUIRED — Nessus .deb not found                       ║"
    echo "  ║                                                                  ║"
    echo "  ║  1. Go to: https://www.tenable.com/downloads/nessus             ║"
    echo "  ║  2. Select: Nessus Essentials → Linux — Ubuntu (amd64)         ║"
    echo "  ║  3. Download the file (name will contain 'Nessus' and end .deb) ║"
    echo "  ║  4. Place the file in the same folder as student-setup.sh       ║"
    echo "  ║     (e.g. ~/SASTandDAST-main/)                                  ║"
    echo "  ║  5. Re-run: sudo bash student-setup.sh  (choose Lab 2 again)   ║"
    echo "  ║                                                                  ║"
    echo "  ║  OR: run ~/scripts/install-nessus.sh after placing the file     ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Create a helper that can be run once the .deb is placed in SCRIPT_DIR
    cat > "$LAB_HOME/scripts/install-nessus.sh" << NSCRIPT
#!/bin/bash
# Place the Nessus .deb (filename containing 'Nessus', ending .deb)
# in the same folder as student-setup.sh, then run this script.
SCRIPT_DIR="${SCRIPT_DIR}"
DEB=\$(find "\$SCRIPT_DIR" /tmp "$LAB_HOME" -maxdepth 1 -iname "Nessus*.deb" 2>/dev/null | head -1)
if [ -z "\$DEB" ]; then
  echo "Nessus .deb not found. Download from: https://www.tenable.com/downloads/nessus"
  echo "Place the file in: \$SCRIPT_DIR"
  exit 1
fi
echo "Installing Nessus from: \$DEB"
sudo dpkg -i "\$DEB" || sudo apt-get install -f -y
sudo systemctl enable nessusd
sudo systemctl start nessusd
echo ""
echo "Nessus installed! Access at: https://\$(hostname -I | awk '{print \$1}'):8834"
echo "First-time setup: select 'Nessus Essentials', enter activation code."
NSCRIPT
    chmod +x "$LAB_HOME/scripts/install-nessus.sh" 2>/dev/null || true
    chown "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts/install-nessus.sh" 2>/dev/null || true
    echo "  Helper script created: ~/scripts/install-nessus.sh"
    echo "  Nessus step skipped — all other Lab 2 components will still install."
  fi
fi

# ─── STEP 8: INSTALL SUPPLEMENTARY TOOLS ─────────────────────────────────────
echo ""
echo "[STEP 8/10] Installing supplementary security tools..."

# Python tools
pip3 install --break-system-packages requests beautifulsoup4 2>/dev/null || \
  pip3 install requests beautifulsoup4 2>/dev/null || true

# Install sqlmap
if [ ! -d /opt/sqlmap ]; then
  git clone --depth 1 https://github.com/sqlmapproject/sqlmap.git /opt/sqlmap 2>/dev/null || echo "  sqlmap clone failed (network?), skipping."
  ln -sf /opt/sqlmap/sqlmap.py /usr/local/bin/sqlmap 2>/dev/null || true
fi

echo "  Supplementary tools installed: nmap, nikto, sqlmap, python3"

# ─── STEP 9: FIREWALL & NETWORK ─────────────────────────────────────────────
echo ""
echo "[STEP 9/10] Configuring firewall..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 8080/tcp comment "ZAP Proxy (alternate)"
ufw allow 8090/tcp comment "ZAP Daemon API"
ufw allow 8834/tcp comment "Nessus Web UI"
ufw --force enable

echo "  Firewall configured: SSH + TCP 8080, 8090, 8834"

# ─── STEP 10: HOSTS FILE & HELPER SCRIPTS ───────────────────────────────────
echo ""
echo "[STEP 10/10] Configuring hosts file and helper scripts..."

add_hosts_entry() {
  local IP="$1"; local ALIASES="$2"
  [ -n "$IP" ] && ! grep -q "$IP" /etc/hosts && echo "$IP   $ALIASES" >> /etc/hosts
}
echo "" >> /etc/hosts
echo "# AppSec Lab Environment" >> /etc/hosts
add_hosts_entry "$VM01_IP" "vm01 sonarqube-server"
add_hosts_entry "$VM02_IP" "vm02 zap-server nessus-server"
add_hosts_entry "$VM03_IP" "vm03 target-server"

# Create helper scripts directory
mkdir -p "$LAB_HOME/scripts"

# Status check script — unquoted heredoc so $VM01_IP/$VM03_IP expand at write-time
cat > "$LAB_HOME/scripts/check-status.sh" << SCRIPT
#!/bin/bash
echo "=== VM-02 Service Status ==="
echo ""
echo "--- OWASP ZAP Daemon ---"
if systemctl is-active zap-daemon &>/dev/null; then
  echo "Status: RUNNING"
  ZAP_VER=\$(curl -sf 'http://localhost:8090/JSON/core/view/version/?apikey=${ZAP_API_KEY}' 2>/dev/null | jq -r '.version' 2>/dev/null || echo "unknown")
  echo "Version: \$ZAP_VER"
  echo "API: http://localhost:8090"
else
  echo "Status: STOPPED"
  echo "Start with: sudo systemctl start zap-daemon"
fi
echo ""
echo "--- Nessus ---"
if systemctl is-active nessusd &>/dev/null; then
  echo "Status: RUNNING"
  echo "Web UI: https://\$(hostname -I | awk '{print \$1}'):8834"
else
  echo "Status: STOPPED (or not installed)"
  echo "Start with: sudo systemctl start nessusd"
fi
echo ""
echo "--- Connectivity to Lab VMs ---"
VM01="${VM01_IP}"
VM03="${VM03_IP}"
if [ -n "\$VM01" ]; then
  ping -c 1 -W 2 "\$VM01" > /dev/null 2>&1 && echo "[OK] SonarQube (\$VM01)" || echo "[FAIL] SonarQube (\$VM01)"
else
  echo "[SKIP] SonarQube VM IP not configured"
fi
if [ -n "\$VM03" ]; then
  ping -c 1 -W 2 "\$VM03" > /dev/null 2>&1 && echo "[OK] Target (\$VM03)" || echo "[FAIL] Target (\$VM03)"
else
  echo "[SKIP] Target VM IP not configured"
fi
echo ""
echo "--- Disk / Memory ---"
df -h / | tail -1 | awk '{print "Disk: " \$3 " / " \$2 " (" \$5 ")"}'
free -h | grep Mem | awk '{print "RAM:  " \$3 " / " \$2}'
SCRIPT

# ZAP scan wrapper script
cat > "$LAB_HOME/scripts/zap-scan.sh" << 'SCRIPT'
#!/bin/bash
# Usage: ./zap-scan.sh <target-url> [scan-type]
# scan-type: passive (default), active, spider
TARGET=${1:?"Usage: $0 <target-url> [passive|active|spider]"}
SCAN_TYPE=${2:-"passive"}
API_KEY="lab-api-key-2024"
ZAP_URL="http://localhost:8090"

echo "=== ZAP Scan: $SCAN_TYPE ==="
echo "Target: $TARGET"
echo ""

case $SCAN_TYPE in
  spider)
    echo "Starting spider..."
    SCAN_ID=$(curl -sf "$ZAP_URL/JSON/spider/action/scan/?apikey=$API_KEY&url=$TARGET&recurse=true" | jq -r '.scan')
    echo "Spider ID: $SCAN_ID"
    while true; do
      PROGRESS=$(curl -sf "$ZAP_URL/JSON/spider/view/status/?apikey=$API_KEY&scanId=$SCAN_ID" | jq -r '.status')
      echo "  Progress: $PROGRESS%"
      [ "$PROGRESS" = "100" ] && break
      sleep 5
    done
    echo "Spider complete!"
    ;;
  active)
    echo "WARNING: Active scan sends attack payloads to the target."
    echo "Ensure you have authorization to scan: $TARGET"
    echo ""
    echo "Starting spider first..."
    SPIDER_ID=$(curl -sf "$ZAP_URL/JSON/spider/action/scan/?apikey=$API_KEY&url=$TARGET&recurse=true" | jq -r '.scan')
    while true; do
      PROGRESS=$(curl -sf "$ZAP_URL/JSON/spider/view/status/?apikey=$API_KEY&scanId=$SPIDER_ID" | jq -r '.status')
      [ "$PROGRESS" = "100" ] && break
      sleep 5
    done
    echo "Spider complete. Starting active scan..."
    SCAN_ID=$(curl -sf "$ZAP_URL/JSON/ascan/action/scan/?apikey=$API_KEY&url=$TARGET&recurse=true" | jq -r '.scan')
    echo "Active Scan ID: $SCAN_ID"
    while true; do
      PROGRESS=$(curl -sf "$ZAP_URL/JSON/ascan/view/status/?apikey=$API_KEY&scanId=$SCAN_ID" | jq -r '.status')
      echo "  Progress: $PROGRESS%"
      [ "$PROGRESS" = "100" ] && break
      sleep 10
    done
    echo "Active scan complete!"
    ;;
  passive|*)
    echo "Accessing URL for passive analysis..."
    curl -sf "$ZAP_URL/JSON/core/action/accessUrl/?apikey=$API_KEY&url=$TARGET" > /dev/null
    sleep 3
    echo "Passive scan queued."
    ;;
esac

echo ""
echo "--- Alerts Summary ---"
curl -sf "$ZAP_URL/JSON/alert/view/alertsSummary/?apikey=$API_KEY&baseurl=$TARGET" | jq '.'
echo ""
echo "Full report: curl -o report.html '$ZAP_URL/OTHER/core/other/htmlreport/?apikey=$API_KEY'"
SCRIPT

# ZAP export root CA script
cat > "$LAB_HOME/scripts/zap-export-ca.sh" << SCRIPT
#!/bin/bash
API_KEY="lab-api-key-2024"
OUTPUT="\${1:-$LAB_HOME/zap-root-ca.cer}"
echo "Exporting ZAP Root CA certificate to \$OUTPUT..."
curl -sf "http://localhost:8090/OTHER/core/other/rootcert/?apikey=\$API_KEY" -o "\$OUTPUT"
if [ -f "\$OUTPUT" ]; then
  echo "Certificate exported: \$OUTPUT"
  echo ""
  echo "To trust in Firefox:"
  echo "  Settings > Privacy & Security > View Certificates > Import > Select \$OUTPUT"
  echo "  Check: 'Trust this CA to identify websites'"
else
  echo "Failed to export. Is ZAP daemon running?"
fi
SCRIPT

# Nessus scan checker script
cat > "$LAB_HOME/scripts/nessus-check.sh" << 'SCRIPT'
#!/bin/bash
echo "=== Nessus Essentials Status ==="
if systemctl is-active nessusd &>/dev/null; then
  echo "Service: RUNNING"
  echo "Web UI:  https://$(hostname -I | awk '{print $1}'):8834"
  echo ""
  echo "If this is first access, you will need to:"
  echo "  1. Accept the self-signed certificate in browser"
  echo "  2. Select 'Nessus Essentials'"
  echo "  3. Enter activation code from https://www.tenable.com/products/nessus/nessus-essentials"
  echo "  4. Create admin user"
  echo "  5. Wait for plugin download (~10-15 min)"
else
  echo "Service: STOPPED"
  echo "Start: sudo systemctl start nessusd"
fi
SCRIPT

# ── ZAP GUI launcher script ───────────────────────────────────────────────────
# Handles display detection (desktop session, X11 forwarding, Wayland).
# Stops the ZAP daemon first so both don't compete for the same data directory.
cat > "$LAB_HOME/scripts/zap-gui.sh" << 'SCRIPT'
#!/bin/bash
###############################################################################
# ZAP GUI Launcher
# Launches OWASP ZAP in full graphical (interactive) mode.
#
# Requirements — ONE of:
#   • Desktop VM    : just run this script while logged into the desktop.
#   • SSH + X11     : connect with "ssh -X user@<ip>", then run this script.
#   • SSH + Windows : use MobaXterm (X11 built-in) or enable X11 in PuTTY.
###############################################################################

ZAP_BIN="/opt/zaproxy/zap.sh"

# ── Preflight ────────────────────────────────────────────────────────────────
if [ ! -f "$ZAP_BIN" ]; then
  echo "[ERROR] ZAP not found at $ZAP_BIN"
  echo "        Run Lab 2 setup first: sudo bash student-setup.sh"
  exit 1
fi

# ── Daemon conflict check ─────────────────────────────────────────────────────
if systemctl is-active zap-daemon &>/dev/null; then
  echo ""
  echo "[WARN] ZAP daemon is currently running (port 8090)."
  echo "       The daemon and GUI share the same data directory (~/.ZAP)."
  echo "       Running both simultaneously can corrupt session data."
  echo ""
  read -r -p "  Stop ZAP daemon and launch GUI? [Y/n]: " ANS
  if [[ "${ANS:-Y}" =~ ^[Nn]$ ]]; then
    echo "Aborted. Daemon left running."
    exit 0
  fi
  echo "  Stopping ZAP daemon..."
  sudo systemctl stop zap-daemon
  echo "  Daemon stopped. It will restart automatically after reboot."
  echo "  To restart manually: sudo systemctl start zap-daemon"
  echo ""
fi

# ── Display detection ─────────────────────────────────────────────────────────
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  # Try the local console display (:0) — works if a desktop session is running
  if xdpyinfo -display :0 &>/dev/null 2>&1; then
    export DISPLAY=:0
    echo "[INFO] Using local display :0"
  else
    echo ""
    echo "[ERROR] No graphical display found."
    echo ""
    echo "  ZAP GUI requires a display. Choose one of:"
    echo ""
    echo "  A) Desktop session (easiest)"
    echo "     Log into the VM desktop, open a terminal, and run:"
    echo "       ~/scripts/zap-gui.sh"
    echo ""
    echo "  B) SSH with X11 forwarding (Linux/macOS host)"
    echo "     Disconnect, then reconnect with:"
    echo "       ssh -X $(whoami)@$(hostname -I | awk '{print $1}')"
    echo "     Then run: ~/scripts/zap-gui.sh"
    echo ""
    echo "  C) SSH from Windows"
    echo "     • MobaXterm: X11 forwarding is built-in — just reconnect and run."
    echo "     • PuTTY: Connection → SSH → X11 → Enable X11 forwarding → tick box."
    echo ""
    echo "  D) Headless / daemon mode (no display needed)"
    echo "     The ZAP daemon is available at: http://$(hostname -I | awk '{print $1}'):8090"
    echo "     API key: lab-api-key-2024"
    echo "     Scripts: ~/scripts/zap-scan.sh  ~/scripts/zap-export-ca.sh"
    echo ""
    exit 1
  fi
fi

# ── Launch ───────────────────────────────────────────────────────────────────
echo ""
echo "[INFO] Launching OWASP ZAP GUI..."
echo "       First launch may take 20-30 seconds."
echo "       ZAP will open with its built-in proxy on port 8080."
echo ""
echo "  When done, use File → Exit in ZAP."
echo "  To restart the daemon afterwards: sudo systemctl start zap-daemon"
echo ""

cd /opt/zaproxy
exec "$ZAP_BIN" "$@"
SCRIPT

chmod +x "$LAB_HOME/scripts/"*.sh 2>/dev/null || true
chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts"

# ─── MOTD / WELCOME MESSAGE ─────────────────────────────────────────────────
cat > /etc/motd << 'EOF'

 ╔══════════════════════════════════════════════════════════════╗
 ║  VM-02: DAST Attack Node — ZAP + Nessus                     ║
 ║  Application Security Testing — SAST & DAST Lab             ║
 ║  Sarath G | www.sarathg.me                                  ║
 ╠══════════════════════════════════════════════════════════════╣
 ║                                                              ║
 ║  ZAP Daemon (headless)                                       ║
 ║    API:     http://<this-ip>:8090                           ║
 ║    API Key: lab-api-key-2024                                 ║
 ║    Start:   sudo systemctl start zap-daemon                 ║
 ║                                                              ║
 ║  ZAP GUI (interactive)                                       ║
 ║    Desktop: click OWASP ZAP in app menu                     ║
 ║    SSH+X11: ssh -X user@<ip>  then  ~/scripts/zap-gui.sh   ║
 ║                                                              ║
 ║  Nessus:   https://<this-ip>:8834                           ║
 ║                                                              ║
 ║  Scripts:  ~/scripts/zap-gui.sh       (GUI mode)           ║
 ║            ~/scripts/zap-scan.sh      (headless scan)       ║
 ║            ~/scripts/zap-export-ca.sh (export CA cert)      ║
 ║            ~/scripts/check-status.sh                        ║
 ║            ~/scripts/nessus-check.sh                        ║
 ║                                                              ║
 ║  Targets:  http://<vm03-ip>/dvwa/                           ║
 ║            http://<vm03-ip>:8080  (VulnShop)                ║
 ║                                                              ║
 ╚══════════════════════════════════════════════════════════════╝

EOF

# ─── START SERVICES ──────────────────────────────────────────────────────────
echo ""
echo "Starting ZAP daemon..."
systemctl start zap-daemon

echo "Waiting for ZAP to initialize..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:8090/JSON/core/view/version/?apikey=$ZAP_API_KEY" &>/dev/null; then
    ZAP_VER=$(curl -sf "http://localhost:8090/JSON/core/view/version/?apikey=$ZAP_API_KEY" | jq -r '.version')
    echo "  ZAP is UP! Version: $ZAP_VER"
    break
  fi
  echo "  [$i/30] Waiting..."
  sleep 5
done

if systemctl is-active nessusd &>/dev/null; then
  echo "Nessus is running."
else
  echo "Nessus: Not started (may need manual installation — see ~/scripts/install-nessus-manual.sh)"
fi

# ─── CLEANUP ─────────────────────────────────────────────────────────────────
echo ""
echo "Cleaning up..."
rm -f /tmp/zap-linux.tar.gz /tmp/nessus.deb
apt-get autoremove -y -qq
apt-get clean

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo " VM-02 SETUP COMPLETE"
echo "======================================================================"
echo ""
echo " ZAP (Headless Daemon):  http://$THIS_IP:8090"
echo "   API key:              $ZAP_API_KEY"
echo "   Control:              sudo systemctl start|stop|status zap-daemon"
echo ""
echo " ZAP (GUI / Interactive):"
echo "   Desktop session:      Click 'OWASP ZAP' in the application menu"
echo "   SSH with X11:         ssh -X $LAB_USER@$THIS_IP"
echo "                         then run: ~/scripts/zap-gui.sh"
echo "   Windows (MobaXterm):  Connect → run: ~/scripts/zap-gui.sh"
echo ""
echo " Nessus Essentials:      https://$THIS_IP:8834"
echo "   (browser-based first-time setup required)"
echo "   Activation code:      https://www.tenable.com/products/nessus/nessus-essentials"
echo ""
echo " Lab User:               $LAB_USER (home: $LAB_HOME)"
echo " Helper Scripts:         $LAB_HOME/scripts/"
echo "   zap-gui.sh            Launch ZAP in GUI/interactive mode"
echo "   zap-scan.sh           Run a headless scan via daemon API"
echo "   zap-export-ca.sh      Export ZAP root CA certificate"
echo "   nessus-check.sh       Nessus service status and first-time setup guide"
echo "   check-status.sh       Overall service health summary"
echo " Log File:               $LOG_FILE"
echo ""
echo " Completed: $(date)"
echo "======================================================================"
