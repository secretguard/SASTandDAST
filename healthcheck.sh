#!/bin/bash
###############################################################################
# SASTandDAST Lab — Comprehensive Health Check & Auto-Fix
# Author: Sarath G | www.sarathg.me
#
# Usage:
#   sudo bash healthcheck.sh            # interactive (ask before fixing)
#   sudo bash healthcheck.sh --check    # report only, no fixes
#   sudo bash healthcheck.sh --fix      # auto-fix all detected issues
#   sudo bash healthcheck.sh --reset    # full reset of all detected labs
###############################################################################

set -uo pipefail

# ─── COLOUR OUTPUT ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_SYM="✓"
FAIL_SYM="✗"
WARN_SYM="⚠"
FIX_SYM="⚙"
INFO_SYM="ℹ"

# ─── ARGUMENT PARSING ────────────────────────────────────────────────────────
MODE="interactive"
for arg in "${@:-}"; do
  case "$arg" in
    --check)   MODE="check"   ;;
    --fix)     MODE="fix"     ;;
    --reset)   MODE="reset"   ;;
    --recheck) MODE="recheck" ;;   # internal: post-fix full re-run
    --help|-h)
      echo "Usage: sudo bash healthcheck.sh [--check|--fix|--reset]"
      echo "  (no flag)  Interactive — report then ask before fixing"
      echo "  --check    Report only; no changes made"
      echo "  --fix      Auto-fix all detected issues"
      echo "  --reset    Full factory reset of all detected lab apps"
      exit 0 ;;
  esac
done

# ─── ROOT CHECK ──────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} Please run with sudo: sudo bash healthcheck.sh"
  exit 1
fi

# ─── USER DETECTION ──────────────────────────────────────────────────────────
LAB_USER="${SUDO_USER:-${USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo "")}}"
[ -z "$LAB_USER" ] || [ "$LAB_USER" = "root" ] && LAB_USER="${SUDO_USER:-}"
if [ -z "$LAB_USER" ] || [ "$LAB_USER" = "root" ]; then
  read -r -p "Enter the lab username (not root): " LAB_USER
fi
LAB_HOME=$(getent passwd "$LAB_USER" 2>/dev/null | cut -d: -f6)
[ -z "$LAB_HOME" ] && LAB_HOME="/home/$LAB_USER"
THIS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ─── CONSTANTS ───────────────────────────────────────────────────────────────
SONAR_DB_USER="sonarqube"; SONAR_DB_PASS="S0narDB@2024"; SONAR_DB_NAME="sonarqube"
SONAR_PORT=9000;  SONAR_DIR="/opt/sonarqube";  SONAR_SCANNER_DIR="/opt/sonar-scanner"

ZAP_API_KEY="lab-api-key-2024"; ZAP_PORT=8090; ZAP_DIR="/opt/zaproxy"; NESSUS_PORT=8834

DVWA_DB_USER="dvwa"; DVWA_DB_PASS="dvwa_pass"; DVWA_DB_NAME="dvwa"
DVWA_DIR="/var/www/html/dvwa"

VULNSHOP_DB_USER="vulnshop_user"; VULNSHOP_DB_PASS="vulnshop_pass"
VULNSHOP_DB_NAME="vulnshop";      VULNSHOP_DIR="/var/www/html/vulnshop"
VULNSHOP_PORT=8080

# ─── COUNTERS & FIX QUEUE ────────────────────────────────────────────────────
PASS_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0
# Use a plain string list to track queued fixes (dedup at add-time)
FIX_QUEUE=""

queue_fix() {
  local fn="$1"
  # Only add if not already in queue
  case " $FIX_QUEUE " in
    *" $fn "*) ;;               # already queued
    *) FIX_QUEUE="$FIX_QUEUE $fn" ;;
  esac
}

# ─── OUTPUT HELPERS ──────────────────────────────────────────────────────────
pass() { echo -e "  ${GREEN}${PASS_SYM} PASS${NC}  $1"; ((PASS_COUNT++)); }
fail() {
  echo -e "  ${RED}${FAIL_SYM} FAIL${NC}  $1"
  ((FAIL_COUNT++))
  [ -n "${2:-}" ] && queue_fix "$2"
}
warn() { echo -e "  ${YELLOW}${WARN_SYM} WARN${NC}  $1"; ((WARN_COUNT++)); }
info() { echo -e "  ${CYAN}${INFO_SYM} INFO${NC}  $1"; }
section() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
}
subsection() { echo ""; echo -e "  ${BOLD}▸ $1${NC}"; }

# ─── LAB DETECTION ───────────────────────────────────────────────────────────
HAS_LAB1=false; HAS_LAB2=false; HAS_LAB3=false
[ -d "$SONAR_DIR" ]   && HAS_LAB1=true
[ -d "$ZAP_DIR" ]     && HAS_LAB2=true
{ [ -d "$DVWA_DIR" ] || [ -d "$VULNSHOP_DIR" ]; } && HAS_LAB3=true

# ─── BANNER ──────────────────────────────────────────────────────────────────
if [ "$MODE" != "recheck" ]; then
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║   SASTandDAST Lab — Health Check & Auto-Fix                 ║${NC}"
  echo -e "${BOLD}║   Sarath G | www.sarathg.me                                 ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Mode:    ${BOLD}$MODE${NC}"
  echo -e "  User:    ${BOLD}$LAB_USER${NC}  (home: $LAB_HOME)"
  echo -e "  IP:      ${BOLD}$THIS_IP${NC}"
  echo -n "  Labs:    "
  $HAS_LAB1 && echo -n "[Lab1-SonarQube] "
  $HAS_LAB2 && echo -n "[Lab2-ZAP/Nessus] "
  $HAS_LAB3 && echo -n "[Lab3-DVWA/VulnShop]"
  echo ""
else
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  POST-FIX VERIFICATION${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
fi

if ! $HAS_LAB1 && ! $HAS_LAB2 && ! $HAS_LAB3; then
  echo ""
  warn "No lab installations detected. Run student-setup.sh first."
  exit 0
fi

###############################################################################
# ─── FULL RESET MODE ─────────────────────────────────────────────────────────
###############################################################################
do_reset() {
  echo ""
  echo -e "${RED}${BOLD}WARNING: This will reset ALL lab applications to a clean state.${NC}"
  echo -e "         Databases will be dropped and recreated."
  read -r -p "Type 'RESET' to confirm: " CONF
  [ "$CONF" != "RESET" ] && echo "Aborted." && return

  section "FACTORY RESET"

  if $HAS_LAB1; then
    subsection "Resetting Lab 1 — SonarQube"
    systemctl stop sonarqube 2>/dev/null || true
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS $SONAR_DB_NAME;" 2>/dev/null || true
    sudo -u postgres psql -c "DROP USER IF EXISTS $SONAR_DB_USER;" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE USER $SONAR_DB_USER WITH ENCRYPTED PASSWORD '$SONAR_DB_PASS';" 2>/dev/null
    sudo -u postgres psql -c "CREATE DATABASE $SONAR_DB_NAME OWNER $SONAR_DB_USER;" 2>/dev/null
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $SONAR_DB_NAME TO $SONAR_DB_USER;" 2>/dev/null
    chown -R sonarqube:sonarqube "$SONAR_DIR" 2>/dev/null || true
    systemctl start sonarqube
    echo -e "  ${GREEN}Lab 1 reset complete.${NC}"
  fi

  if $HAS_LAB2; then
    subsection "Resetting Lab 2 — ZAP"
    systemctl stop zap-daemon 2>/dev/null || true
    rm -rf "$LAB_HOME/.ZAP" 2>/dev/null || true
    mkdir -p "$LAB_HOME/.ZAP/policies"
    chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/.ZAP"
    : > /var/log/zap-daemon.log 2>/dev/null || true
    chown "$LAB_USER:$LAB_USER" /var/log/zap-daemon.log 2>/dev/null || true
    systemctl start zap-daemon
    echo -e "  ${GREEN}Lab 2 reset complete.${NC}"
  fi

  if $HAS_LAB3; then
    subsection "Resetting Lab 3 — DVWA + VulnShop"
    mysql -e "DROP DATABASE IF EXISTS $DVWA_DB_NAME; CREATE DATABASE $DVWA_DB_NAME;" 2>/dev/null || true
    mysql -e "CREATE USER IF NOT EXISTS '$DVWA_DB_USER'@'localhost' IDENTIFIED BY '$DVWA_DB_PASS';" 2>/dev/null || true
    mysql -e "GRANT ALL ON $DVWA_DB_NAME.* TO '$DVWA_DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true

    mysql -e "DROP DATABASE IF EXISTS $VULNSHOP_DB_NAME; CREATE DATABASE $VULNSHOP_DB_NAME;" 2>/dev/null || true
    mysql -e "CREATE USER IF NOT EXISTS '$VULNSHOP_DB_USER'@'localhost' IDENTIFIED BY '$VULNSHOP_DB_PASS';" 2>/dev/null || true
    mysql -e "GRANT ALL ON $VULNSHOP_DB_NAME.* TO '$VULNSHOP_DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true

    if [ -d "$VULNSHOP_DIR" ]; then
      cd "$VULNSHOP_DIR"
      php artisan migrate:fresh --force --seed 2>/dev/null || true
      php artisan key:generate --force 2>/dev/null || true
      php artisan config:clear 2>/dev/null || true
      php artisan cache:clear 2>/dev/null || true
      chown -R www-data:www-data "$VULNSHOP_DIR" 2>/dev/null || true
      chmod -R 775 "$VULNSHOP_DIR/storage" "$VULNSHOP_DIR/bootstrap/cache" 2>/dev/null || true
    fi
    if [ -d "$DVWA_DIR" ]; then
      chown -R www-data:www-data "$DVWA_DIR"
      chmod -R 755 "$DVWA_DIR"
      chmod 777 "$DVWA_DIR/hackable/uploads/" "$DVWA_DIR/config/"
    fi
    curl -s -o /dev/null -X POST -d "create_db=Create+%2F+Reset+Database" \
      "http://localhost/dvwa/setup.php" 2>/dev/null || true
    systemctl restart apache2 mariadb 2>/dev/null || true
    echo -e "  ${GREEN}Lab 3 reset complete.${NC}"
  fi

  echo ""
  echo -e "${GREEN}${BOLD}Reset complete. Re-running health check to verify...${NC}"
  sleep 2
  exec bash "${BASH_SOURCE[0]}" --check
}

[ "$MODE" = "reset" ] && do_reset

###############################################################################
# ══════════════════════════════════════════════════════════════════════════════
# FIX FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════
###############################################################################

fix_kernel_params() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Applying kernel parameters..."
  grep -q 'vm.max_map_count=524288' /etc/sysctl.conf 2>/dev/null || echo 'vm.max_map_count=524288' >> /etc/sysctl.conf
  grep -q 'fs.file-max=131072' /etc/sysctl.conf 2>/dev/null      || echo 'fs.file-max=131072'      >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
}

fix_base_packages() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Installing missing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq curl wget unzip git net-tools jq 2>/dev/null || true
}

fix_scripts_dir() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating scripts directory: $LAB_HOME/scripts"
  mkdir -p "$LAB_HOME/scripts"
  chown "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts"
  chmod 755 "$LAB_HOME/scripts"
}

# ── Lab 1 fixes ───────────────────────────────────────────────────────────────
fix_java17() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Installing OpenJDK 17..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq openjdk-17-jdk 2>/dev/null || true
}

fix_postgresql_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Starting PostgreSQL..."
  systemctl enable postgresql 2>/dev/null || true
  systemctl start  postgresql 2>/dev/null || true
  sleep 2
}

fix_sonar_db() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating/repairing SonarQube database..."
  sudo -u postgres psql -c "CREATE USER $SONAR_DB_USER WITH ENCRYPTED PASSWORD '$SONAR_DB_PASS';" 2>/dev/null || true
  sudo -u postgres psql -c "CREATE DATABASE $SONAR_DB_NAME OWNER $SONAR_DB_USER;" 2>/dev/null || true
  sudo -u postgres psql -c "ALTER USER $SONAR_DB_USER SET search_path TO public;" 2>/dev/null || true
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $SONAR_DB_NAME TO $SONAR_DB_USER;" 2>/dev/null || true
}

fix_sonar_properties() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Rewriting sonar.properties..."
  cat > "$SONAR_DIR/conf/sonar.properties" << EOF
# Database
sonar.jdbc.username=$SONAR_DB_USER
sonar.jdbc.password=$SONAR_DB_PASS
sonar.jdbc.url=jdbc:postgresql://localhost:5432/$SONAR_DB_NAME

# Web Server
sonar.web.host=0.0.0.0
sonar.web.port=$SONAR_PORT
sonar.web.context=

# Elasticsearch
sonar.search.javaOpts=-Xmx2g -Xms2g
sonar.search.host=127.0.0.1

# Logging
sonar.log.level=INFO
sonar.path.logs=$SONAR_DIR/logs
EOF
  chown sonarqube:sonarqube "$SONAR_DIR/conf/sonar.properties" 2>/dev/null || true
}

fix_sonar_permissions() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing SonarQube directory ownership..."
  chown -R sonarqube:sonarqube "$SONAR_DIR" 2>/dev/null || true
}

fix_sonar_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Enabling and restarting SonarQube..."
  systemctl daemon-reload
  systemctl enable sonarqube 2>/dev/null || true
  systemctl restart sonarqube 2>/dev/null || true
}

fix_sonar_limits() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Adding SonarQube system limits..."
  grep -q 'sonarqube.*nofile.*131072' /etc/security/limits.conf 2>/dev/null || cat >> /etc/security/limits.conf << 'EOF'
sonarqube   -   nofile   131072
sonarqube   -   nproc    8192
EOF
}

fix_lab1_scripts() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Recreating Lab 1 helper scripts..."
  fix_scripts_dir
  cat > "$LAB_HOME/scripts/check-status.sh" << 'SCRIPT'
#!/bin/bash
echo "=== Lab 1 — SonarQube Status ==="
echo ""
echo "--- SonarQube ---"
systemctl is-active sonarqube && echo "Status: RUNNING" || echo "Status: STOPPED"
STATUS=$(curl -sf --max-time 5 http://localhost:9000/api/system/status 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unreachable")
echo "API status: $STATUS"
echo ""
echo "--- PostgreSQL ---"
systemctl is-active postgresql && echo "Status: RUNNING" || echo "Status: STOPPED"
echo ""
df -h / | tail -1 | awk '{print "Disk: " $3 " / " $2 " (" $5 ")"}'
free -h | grep Mem | awk '{print "RAM:  " $3 " / " $2}'
SCRIPT
  cat > "$LAB_HOME/scripts/scan-project.sh" << 'SCRIPT'
#!/bin/bash
PROJECT_KEY=${1:?"Usage: $0 <project-key> <source-dir> [token]"}
SOURCE_DIR=${2:?"Usage: $0 <project-key> <source-dir> [token]"}
TOKEN=${3:-""}
if [ -z "$TOKEN" ]; then
  echo "No token provided. Generate at http://localhost:9000 > My Account > Security > Generate Token"
  exit 1
fi
echo "Scanning $SOURCE_DIR as project $PROJECT_KEY..."
cd "$SOURCE_DIR"
sonar-scanner \
  -Dsonar.projectKey="$PROJECT_KEY" \
  -Dsonar.sources=. \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.token="$TOKEN" \
  -Dsonar.sourceEncoding=UTF-8
echo "Scan complete. View: http://localhost:9000/dashboard?id=$PROJECT_KEY"
SCRIPT
  chmod +x "$LAB_HOME/scripts/"*.sh 2>/dev/null || true
  chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts"
}

# ── Lab 2 fixes ───────────────────────────────────────────────────────────────
fix_zap_dir() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating ZAP data directory..."
  mkdir -p "$LAB_HOME/.ZAP/policies"
  chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/.ZAP"
}

fix_zap_log() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating ZAP log file..."
  touch /var/log/zap-daemon.log
  chown "$LAB_USER:$LAB_USER" /var/log/zap-daemon.log
}

fix_zap_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Rewriting and restarting zap-daemon.service..."
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
  systemctl daemon-reload
  systemctl enable zap-daemon 2>/dev/null || true
  fix_zap_log
  systemctl restart zap-daemon 2>/dev/null || true
}

fix_zap_symlink() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing ZAP symlink..."
  chmod +x "$ZAP_DIR/zap.sh" 2>/dev/null || true
  ln -sf "$ZAP_DIR/zap.sh" /usr/local/bin/zap
}

fix_zap_gui_deps() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Installing ZAP GUI display libraries..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq libgtk-3-0 libxtst6 libgl1 xdg-utils 2>/dev/null || true
  apt-get install -y -qq libasound2 2>/dev/null || apt-get install -y -qq libasound2t64 2>/dev/null || true
}

fix_zap_desktop() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating ZAP desktop launcher..."
  local icon; icon=$(find /opt/zaproxy -maxdepth 2 -name "*.png" 2>/dev/null | head -1)
  [ -z "$icon" ] && icon="/opt/zaproxy/zap.png"
  cat > /usr/share/applications/zaproxy.desktop << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=OWASP ZAP
GenericName=Web Security Scanner
Comment=Zed Attack Proxy — interactive web application security testing
Exec=/opt/zaproxy/zap.sh
Icon=${icon}
Terminal=false
Categories=Security;Network;Development;
Keywords=security;proxy;scanner;web;owasp;zap;dast;
StartupNotify=true
StartupWMClass=org-zaproxy-zap-ZAP
EOF
  chmod 644 /usr/share/applications/zaproxy.desktop
  update-desktop-database /usr/share/applications/ 2>/dev/null || true
}

fix_nessus_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Starting Nessus..."
  systemctl enable nessusd 2>/dev/null || true
  systemctl start  nessusd 2>/dev/null || true
}

fix_lab2_scripts() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Recreating Lab 2 helper scripts..."
  fix_scripts_dir

  # ── check-status.sh ──────────────────────────────────────────────────────
  cat > "$LAB_HOME/scripts/check-status.sh" << SCRIPT
#!/bin/bash
echo "=== Lab 2 — ZAP + Nessus Status ==="
echo ""
echo "--- ZAP Daemon (headless) ---"
if systemctl is-active zap-daemon &>/dev/null; then
  echo "Status: RUNNING"
  ZAP_VER=\$(curl -sf --max-time 5 'http://localhost:$ZAP_PORT/JSON/core/view/version/?apikey=$ZAP_API_KEY' 2>/dev/null | jq -r '.version' 2>/dev/null || echo "starting...")
  echo "Version: \$ZAP_VER  |  API: http://localhost:$ZAP_PORT  |  Key: $ZAP_API_KEY"
else
  echo "Status: STOPPED — run: sudo systemctl start zap-daemon"
fi
echo ""
echo "--- ZAP GUI ---"
echo "Desktop session: click 'OWASP ZAP' in application menu"
echo "SSH + X11:       ssh -X $LAB_USER@\$(hostname -I | awk '{print \$1}')  then: ~/scripts/zap-gui.sh"
echo ""
echo "--- Nessus ---"
systemctl is-active nessusd &>/dev/null && \
  echo "Status: RUNNING  |  https://\$(hostname -I | awk '{print \$1}'):$NESSUS_PORT" || \
  echo "Status: STOPPED (or not installed)"
echo ""
df -h / | tail -1 | awk '{print "Disk: " \$3 " / " \$2 " (" \$5 ")"}'
free -h | grep Mem | awk '{print "RAM:  " \$3 " / " \$2}'
SCRIPT

  # ── zap-scan.sh ──────────────────────────────────────────────────────────
  cat > "$LAB_HOME/scripts/zap-scan.sh" << 'SCRIPT'
#!/bin/bash
TARGET=${1:?"Usage: $0 <target-url> [passive|active|spider]"}
SCAN_TYPE=${2:-passive}
ZAP_URL="http://localhost:8090"
APIKEY="lab-api-key-2024"
echo "=== ZAP $SCAN_TYPE scan: $TARGET ==="
curl -sf "$ZAP_URL/JSON/core/action/accessUrl/?apikey=$APIKEY&url=$TARGET" >/dev/null
case "$SCAN_TYPE" in
  spider|passive)
    SCAN_ID=$(curl -sf "$ZAP_URL/JSON/spider/action/scan/?apikey=$APIKEY&url=$TARGET&recurse=true" | jq -r '.scan')
    echo "Spider ID: $SCAN_ID"
    while true; do
      P=$(curl -sf "$ZAP_URL/JSON/spider/view/status/?apikey=$APIKEY&scanId=$SCAN_ID" | jq -r '.status')
      echo "  Progress: $P%"; [ "$P" = "100" ] && break; sleep 5
    done ;;
  active)
    echo "WARNING: Active scan sends attack payloads. Ensure you have authorization."
    SCAN_ID=$(curl -sf "$ZAP_URL/JSON/ascan/action/scan/?apikey=$APIKEY&url=$TARGET&recurse=true" | jq -r '.scan')
    echo "Active Scan ID: $SCAN_ID"
    while true; do
      P=$(curl -sf "$ZAP_URL/JSON/ascan/view/status/?apikey=$APIKEY&scanId=$SCAN_ID" | jq -r '.status')
      echo "  Progress: $P%"; [ "$P" = "100" ] && break; sleep 10
    done ;;
esac
echo ""
echo "--- Alerts ---"
curl -sf "$ZAP_URL/JSON/alert/view/alertsSummary/?apikey=$APIKEY&baseurl=$TARGET" | jq '.' 2>/dev/null || echo "No alerts or jq missing."
SCRIPT

  # ── zap-export-ca.sh ─────────────────────────────────────────────────────
  cat > "$LAB_HOME/scripts/zap-export-ca.sh" << SCRIPT
#!/bin/bash
OUTPUT="\${1:-$LAB_HOME/zap-root-ca.cer}"
curl -sf "http://localhost:$ZAP_PORT/OTHER/core/other/rootcert/?apikey=$ZAP_API_KEY" -o "\$OUTPUT"
if [ -f "\$OUTPUT" ]; then
  echo "CA certificate exported to: \$OUTPUT"
  echo ""
  echo "Import into Firefox:"
  echo "  Settings > Privacy & Security > View Certificates > Import"
  echo "  Tick: Trust this CA to identify websites"
else
  echo "Export failed — is ZAP daemon running? (sudo systemctl status zap-daemon)"
fi
SCRIPT

  # ── zap-gui.sh ───────────────────────────────────────────────────────────
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

if [ ! -f "$ZAP_BIN" ]; then
  echo "[ERROR] ZAP not found at $ZAP_BIN"
  echo "        Run Lab 2 setup first: sudo bash student-setup.sh"
  exit 1
fi

# ── Daemon conflict check ─────────────────────────────────────────────────────
if systemctl is-active zap-daemon &>/dev/null; then
  echo ""
  echo "[WARN] ZAP daemon is currently running (port 8090)."
  echo "       The daemon and GUI share ~/.ZAP — running both can corrupt session data."
  echo ""
  read -r -p "  Stop daemon and launch GUI? [Y/n]: " ANS
  if [[ "${ANS:-Y}" =~ ^[Nn]$ ]]; then
    echo "Aborted. Daemon left running."
    exit 0
  fi
  echo "  Stopping ZAP daemon..."
  sudo systemctl stop zap-daemon
  echo "  Daemon stopped. To restart: sudo systemctl start zap-daemon"
  echo ""
fi

# ── Display detection ─────────────────────────────────────────────────────────
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  if xdpyinfo -display :0 &>/dev/null 2>&1; then
    export DISPLAY=:0
    echo "[INFO] Using local display :0"
  else
    echo ""
    echo "[ERROR] No graphical display found."
    echo ""
    echo "  Choose one of the following:"
    echo ""
    echo "  A) Desktop session (easiest)"
    echo "     Log into the VM desktop, open a terminal, and run:"
    echo "       ~/scripts/zap-gui.sh"
    echo ""
    echo "  B) SSH with X11 forwarding (Linux / macOS host)"
    echo "     Reconnect with:  ssh -X $(whoami)@$(hostname -I | awk '{print $1}')"
    echo "     Then run:        ~/scripts/zap-gui.sh"
    echo ""
    echo "  C) SSH from Windows"
    echo "     MobaXterm: X11 forwarding is built-in — reconnect and run the script."
    echo "     PuTTY:     Connection → SSH → X11 → Enable X11 forwarding → reconnect."
    echo ""
    echo "  D) Stay headless — use the ZAP daemon instead:"
    echo "     sudo systemctl start zap-daemon"
    echo "     ~/scripts/zap-scan.sh <target-url> [passive|active|spider]"
    echo ""
    exit 1
  fi
fi

# ── Launch ───────────────────────────────────────────────────────────────────
echo "[INFO] Launching OWASP ZAP GUI..."
echo "       First launch may take 20-30 seconds to load."
echo "       ZAP proxy will listen on port 8080 (browser proxy settings)."
echo ""
echo "  When done: File → Exit in ZAP."
echo "  Restart daemon afterwards: sudo systemctl start zap-daemon"
echo ""
cd /opt/zaproxy
exec "$ZAP_BIN" "$@"
SCRIPT

  # ── nessus-check.sh ──────────────────────────────────────────────────────
  cat > "$LAB_HOME/scripts/nessus-check.sh" << 'SCRIPT'
#!/bin/bash
echo "=== Nessus Essentials Status ==="
if systemctl is-active nessusd &>/dev/null; then
  echo "Service: RUNNING"
  echo "Web UI:  https://$(hostname -I | awk '{print $1}'):8834"
  echo ""
  echo "First-time setup steps:"
  echo "  1. Accept the self-signed certificate in your browser"
  echo "  2. Select 'Nessus Essentials'"
  echo "  3. Enter your activation code (free from tenable.com)"
  echo "  4. Create an admin username and password"
  echo "  5. Wait for plugin download (~10-15 minutes)"
else
  echo "Service: STOPPED (or Nessus not installed)"
  echo ""
  echo "To start:   sudo systemctl start nessusd"
  echo "To install: place Nessus*.deb in the lab folder and re-run student-setup.sh"
  echo "Download:   https://www.tenable.com/downloads/nessus"
fi
SCRIPT

  chmod +x "$LAB_HOME/scripts/"*.sh 2>/dev/null || true
  chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts"

  # Also ensure the desktop launcher exists
  fix_zap_desktop
}

# ── Lab 3 fixes ───────────────────────────────────────────────────────────────
fix_apache_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Restarting Apache2..."
  a2enmod rewrite headers 2>/dev/null || true
  systemctl enable apache2 2>/dev/null || true
  systemctl restart apache2 2>/dev/null || true
}

fix_mariadb_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Starting MariaDB..."
  systemctl enable mariadb 2>/dev/null || true
  systemctl start  mariadb 2>/dev/null || true
}

fix_php_ini() {
  local ini
  ini=$(find /etc/php -name "php.ini" -path "*/apache2/*" 2>/dev/null | head -1)
  [ -z "$ini" ] && echo -e "  ${YELLOW}${WARN_SYM}${NC} Apache php.ini not found" && return
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing PHP ini: $ini"
  sed -i 's/^[;[:space:]]*allow_url_include[[:space:]]*=.*/allow_url_include = On/'  "$ini"
  sed -i 's/^[;[:space:]]*allow_url_fopen[[:space:]]*=.*/allow_url_fopen = On/'     "$ini"
  sed -i 's/^[;[:space:]]*display_errors[[:space:]]*=.*/display_errors = On/'       "$ini"
  sed -i 's/^[;[:space:]]*display_startup_errors[[:space:]]*=.*/display_startup_errors = On/' "$ini"
  sed -i 's/^[;[:space:]]*expose_php[[:space:]]*=.*/expose_php = On/'               "$ini"
  sed -i 's/^[;[:space:]]*file_uploads[[:space:]]*=.*/file_uploads = On/'           "$ini"
  systemctl restart apache2 2>/dev/null || true
}

fix_apache_allowoverride() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Setting AllowOverride All in apache2.conf..."
  grep -q 'AllowOverride All' /etc/apache2/apache2.conf 2>/dev/null || \
    sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf 2>/dev/null || true
  systemctl reload apache2 2>/dev/null || true
}

fix_dvwa_db() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating/initializing DVWA database..."
  mysql -e "CREATE DATABASE IF NOT EXISTS $DVWA_DB_NAME;" 2>/dev/null || true
  mysql -e "CREATE USER IF NOT EXISTS '$DVWA_DB_USER'@'localhost' IDENTIFIED BY '$DVWA_DB_PASS';" 2>/dev/null || true
  mysql -e "GRANT ALL ON $DVWA_DB_NAME.* TO '$DVWA_DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
  sleep 1
  curl -s -o /dev/null -X POST -d "create_db=Create+%2F+Reset+Database" \
    "http://localhost/dvwa/setup.php" 2>/dev/null || true
}

fix_dvwa_config() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Repairing DVWA config.inc.php..."
  if [ ! -f "$DVWA_DIR/config/config.inc.php" ] && [ -f "$DVWA_DIR/config/config.inc.php.dist" ]; then
    cp "$DVWA_DIR/config/config.inc.php.dist" "$DVWA_DIR/config/config.inc.php"
  fi
  if [ -f "$DVWA_DIR/config/config.inc.php" ]; then
    sed -i "s/\$_DVWA\[ 'db_user' \] *= *'.*'/\$_DVWA[ 'db_user' ] = '$DVWA_DB_USER'/" "$DVWA_DIR/config/config.inc.php"
    sed -i "s/\$_DVWA\[ 'db_password' \] *= *'.*'/\$_DVWA[ 'db_password' ] = '$DVWA_DB_PASS'/" "$DVWA_DIR/config/config.inc.php"
    sed -i "s/\$_DVWA\[ 'db_database' \] *= *'.*'/\$_DVWA[ 'db_database' ] = '$DVWA_DB_NAME'/" "$DVWA_DIR/config/config.inc.php"
    sed -i "s/\$_DVWA\[ 'default_security_level' \] *= *'.*'/\$_DVWA[ 'default_security_level' ] = 'low'/" "$DVWA_DIR/config/config.inc.php"
  fi
  # Also fix PHP ini and restart apache so config change takes effect
  fix_php_ini
}

fix_dvwa_permissions() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing DVWA permissions..."
  chown -R www-data:www-data "$DVWA_DIR" 2>/dev/null || true
  chmod -R 755 "$DVWA_DIR" 2>/dev/null || true
  chmod 777 "$DVWA_DIR/hackable/uploads/" 2>/dev/null || true
  chmod 777 "$DVWA_DIR/config/" 2>/dev/null || true
  chmod 666 "$DVWA_DIR/external/phpids/0.6/lib/IDS/tmp/phpids_log.txt" 2>/dev/null || true
  systemctl restart apache2 2>/dev/null || true
}

fix_vulnshop_vhost() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Rewriting VulnShop virtual host..."
  cat > /etc/apache2/sites-available/vulnshop.conf << EOF
<VirtualHost *:$VULNSHOP_PORT>
    ServerName localhost
    DocumentRoot $VULNSHOP_DIR/public
    <Directory $VULNSHOP_DIR/public>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/vulnshop_error.log
    CustomLog \${APACHE_LOG_DIR}/vulnshop_access.log combined
</VirtualHost>
EOF
  # Remove any duplicate Listen lines, then add exactly one (prevents "multiple Listeners" error)
  sed -i "/^[[:space:]]*Listen[[:space:]]\+${VULNSHOP_PORT}/d" /etc/apache2/ports.conf 2>/dev/null || true
  echo "Listen $VULNSHOP_PORT" >> /etc/apache2/ports.conf
  a2enmod rewrite 2>/dev/null || true
  a2ensite vulnshop.conf 2>/dev/null || true
  apache2ctl configtest 2>/dev/null && systemctl reload apache2 2>/dev/null || \
    systemctl restart apache2 2>/dev/null || true
}

fix_vulnshop_env() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing VulnShop .env..."
  cat > "$VULNSHOP_DIR/.env" << EOF
APP_NAME=VulnShop
APP_ENV=production
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost:$VULNSHOP_PORT

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=$VULNSHOP_DB_NAME
DB_USERNAME=$VULNSHOP_DB_USER
DB_PASSWORD=$VULNSHOP_DB_PASS

ADMIN_EMAIL=admin@vulnshop.local
ADMIN_PASSWORD=admin123

SESSION_DRIVER=file
SESSION_LIFETIME=120
EOF
  cd "$VULNSHOP_DIR"
  php artisan key:generate --force 2>/dev/null || true
  php artisan config:clear 2>/dev/null || true
  chown www-data:www-data "$VULNSHOP_DIR/.env" 2>/dev/null || true
}

fix_vulnshop_composer() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Running composer install..."
  cd "$VULNSHOP_DIR"
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --optimize-autoloader 2>/dev/null || true
  chown -R www-data:www-data "$VULNSHOP_DIR/vendor" 2>/dev/null || true
}

fix_vulnshop_db() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating/migrating VulnShop database..."
  mysql -e "CREATE DATABASE IF NOT EXISTS $VULNSHOP_DB_NAME;" 2>/dev/null || true
  mysql -e "CREATE USER IF NOT EXISTS '$VULNSHOP_DB_USER'@'localhost' IDENTIFIED BY '$VULNSHOP_DB_PASS';" 2>/dev/null || true
  mysql -e "GRANT ALL ON $VULNSHOP_DB_NAME.* TO '$VULNSHOP_DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
  cd "$VULNSHOP_DIR"
  git config --global user.email "lab@lab.local" 2>/dev/null || true
  git config --global user.name "Lab Setup" 2>/dev/null || true
  php artisan migrate --force 2>/dev/null || true
  php artisan db:seed --force 2>/dev/null || true
}

fix_vulnshop_storage() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing VulnShop storage permissions..."
  chmod -R 775 "$VULNSHOP_DIR/storage" "$VULNSHOP_DIR/bootstrap/cache" 2>/dev/null || true
  chown -R www-data:www-data "$VULNSHOP_DIR/storage" "$VULNSHOP_DIR/bootstrap/cache" 2>/dev/null || true
  cd "$VULNSHOP_DIR"
  php artisan storage:link 2>/dev/null || true
  php artisan cache:clear 2>/dev/null || true
  php artisan config:clear 2>/dev/null || true
  systemctl restart apache2 2>/dev/null || true
}

fix_lab3_scripts() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Recreating Lab 3 helper scripts..."
  fix_scripts_dir
  cat > "$LAB_HOME/scripts/check-status.sh" << SCRIPT
#!/bin/bash
echo "=== Lab 3 — Target Apps Status ==="
echo ""
echo "--- Apache2 ---"
systemctl is-active apache2 && echo "Status: RUNNING" || echo "Status: STOPPED"
echo ""
echo "--- MariaDB ---"
systemctl is-active mariadb && echo "Status: RUNNING" || echo "Status: STOPPED"
echo ""
echo "--- DVWA ---"
CODE=\$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 http://localhost/dvwa/login.php 2>/dev/null || echo "0")
echo "HTTP \$CODE  —  http://\$(hostname -I | awk '{print \$1}')/dvwa/"
echo ""
echo "--- VulnShop ---"
CODE=\$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:$VULNSHOP_PORT 2>/dev/null || echo "0")
echo "HTTP \$CODE  —  http://\$(hostname -I | awk '{print \$1}'):$VULNSHOP_PORT"
echo ""
df -h / | tail -1 | awk '{print "Disk: " \$3 " / " \$2 " (" \$5 ")"}'
free -h | grep Mem | awk '{print "RAM:  " \$3 " / " \$2}'
SCRIPT
  cat > "$LAB_HOME/scripts/reset-dvwa-db.sh" << SCRIPT
#!/bin/bash
echo "Resetting DVWA database..."
mysql -e "DROP DATABASE IF EXISTS $DVWA_DB_NAME; CREATE DATABASE $DVWA_DB_NAME;" 2>/dev/null
mysql -e "GRANT ALL ON $DVWA_DB_NAME.* TO '$DVWA_DB_USER'@'localhost' IDENTIFIED BY '$DVWA_DB_PASS'; FLUSH PRIVILEGES;" 2>/dev/null
sleep 1
curl -s -o /dev/null -X POST -d "create_db=Create+%2F+Reset+Database" http://localhost/dvwa/setup.php
echo "Done. Visit http://\$(hostname -I | awk '{print \$1}')/dvwa/setup.php to verify."
SCRIPT
  cat > "$LAB_HOME/scripts/reset-vulnshop.sh" << SCRIPT
#!/bin/bash
cd $VULNSHOP_DIR
php artisan migrate:fresh --force --seed
php artisan config:clear
php artisan cache:clear
chown -R www-data:www-data storage bootstrap/cache
echo "Done. Visit http://\$(hostname -I | awk '{print \$1}'):$VULNSHOP_PORT"
SCRIPT
  chmod +x "$LAB_HOME/scripts/"*.sh 2>/dev/null || true
  chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts"
}

###############################################################################
# ══════════════════════════════════════════════════════════════════════════════
# CHECK FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════
###############################################################################

check_base_packages() {
  subsection "Base Packages"
  local missing=false
  for pkg in curl wget unzip git net-tools jq; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      pass "Package installed: $pkg"
    else
      fail "Package missing: $pkg" "fix_base_packages"
      missing=true
    fi
  done
}

check_scripts_dir() {
  subsection "Lab Scripts Directory"
  if [ -d "$LAB_HOME/scripts" ]; then
    pass "Scripts directory: $LAB_HOME/scripts"
    local owner; owner=$(stat -c '%U' "$LAB_HOME/scripts" 2>/dev/null)
    [ "$owner" = "$LAB_USER" ] && pass "Scripts dir owner: $owner" || \
      fail "Scripts dir owner: $owner (should be $LAB_USER)" "fix_scripts_dir"
  else
    fail "Scripts directory missing: $LAB_HOME/scripts" "fix_scripts_dir"
  fi
}

check_kernel_params() {
  subsection "Kernel Parameters"
  local cur_map; cur_map=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
  [ "$cur_map" -ge 524288 ] && pass "vm.max_map_count=$cur_map (OK)" || \
    fail "vm.max_map_count=$cur_map (need ≥524288)" "fix_kernel_params"
  local cur_files; cur_files=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
  [ "$cur_files" -ge 131072 ] && pass "fs.file-max=$cur_files (OK)" || \
    fail "fs.file-max=$cur_files (need ≥131072)" "fix_kernel_params"
  grep -q 'vm.max_map_count=524288' /etc/sysctl.conf 2>/dev/null && \
    pass "/etc/sysctl.conf: vm.max_map_count persisted" || \
    warn "/etc/sysctl.conf missing vm.max_map_count — may revert after reboot"
}

check_lab1() {
  section "LAB 1 — SonarQube"

  subsection "Java 17"
  if java -version 2>&1 | grep -q 'version "17'; then
    pass "Java 17 installed: $(java -version 2>&1 | head -1)"
  else
    fail "Java 17 not installed" "fix_java17"
  fi

  subsection "PostgreSQL"
  dpkg -l postgresql 2>/dev/null | grep -q '^ii' && pass "postgresql package installed" || \
    fail "postgresql not installed" "fix_postgresql_service"
  systemctl is-active postgresql &>/dev/null && pass "postgresql: RUNNING" || \
    fail "postgresql: STOPPED" "fix_postgresql_service"
  systemctl is-enabled postgresql &>/dev/null && pass "postgresql: enabled at boot" || \
    warn "postgresql: not enabled at boot"

  subsection "SonarQube DB"
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$SONAR_DB_USER'" 2>/dev/null | grep -q 1; then
    pass "DB user '$SONAR_DB_USER' exists"
  else
    fail "DB user '$SONAR_DB_USER' missing" "fix_sonar_db"
  fi
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$SONAR_DB_NAME'" 2>/dev/null | grep -q 1; then
    pass "Database '$SONAR_DB_NAME' exists"
  else
    fail "Database '$SONAR_DB_NAME' missing" "fix_sonar_db"
  fi
  sudo -u postgres psql -d "$SONAR_DB_NAME" -c "SELECT 1" &>/dev/null && \
    pass "DB connection OK" || fail "Cannot connect to DB" "fix_sonar_db"

  subsection "SonarQube Installation"
  for d in "$SONAR_DIR" "$SONAR_DIR/conf" "$SONAR_DIR/logs" "$SONAR_DIR/bin/linux-x86-64"; do
    [ -d "$d" ] && pass "Dir: $d" || fail "Dir missing: $d" "fix_sonar_permissions"
  done
  [ -f "$SONAR_DIR/conf/sonar.properties" ] && pass "sonar.properties exists" || \
    fail "sonar.properties missing" "fix_sonar_properties"
  [ -f "$SONAR_DIR/bin/linux-x86-64/sonar.sh" ] && pass "sonar.sh exists" || \
    fail "sonar.sh missing" "fix_sonar_permissions"

  subsection "sonar.properties Content"
  local sp="$SONAR_DIR/conf/sonar.properties"
  if [ -f "$sp" ]; then
    grep -q "sonar.jdbc.username=$SONAR_DB_USER" "$sp" && pass "jdbc.username=$SONAR_DB_USER" || \
      fail "jdbc.username wrong in sonar.properties" "fix_sonar_properties"
    grep -q "jdbc:postgresql://localhost:5432/$SONAR_DB_NAME" "$sp" && pass "jdbc.url correct" || \
      fail "jdbc.url incorrect" "fix_sonar_properties"
    grep -q "sonar.web.port=$SONAR_PORT" "$sp" && pass "web.port=$SONAR_PORT" || \
      fail "web.port not set to $SONAR_PORT" "fix_sonar_properties"
    grep -q "sonar.web.host=0.0.0.0" "$sp" && pass "web.host=0.0.0.0" || \
      warn "web.host may not be 0.0.0.0 — SonarQube may not be reachable from network"
  fi

  subsection "Permissions & Limits"
  [ -d "$SONAR_DIR" ] && {
    local o; o=$(stat -c '%U' "$SONAR_DIR" 2>/dev/null)
    [ "$o" = "sonarqube" ] && pass "$SONAR_DIR owned by sonarqube" || \
      fail "$SONAR_DIR owned by $o (need sonarqube)" "fix_sonar_permissions"
  }
  grep -q 'sonarqube.*nofile.*131072' /etc/security/limits.conf 2>/dev/null && \
    pass "limits.conf: sonarqube nofile=131072" || \
    warn "limits.conf missing SonarQube entries" && queue_fix "fix_sonar_limits"

  subsection "SonarQube Service"
  [ -f /etc/systemd/system/sonarqube.service ] && pass "sonarqube.service unit exists" || \
    fail "sonarqube.service unit missing" "fix_sonar_service"
  systemctl is-enabled sonarqube &>/dev/null && pass "sonarqube: enabled at boot" || \
    warn "sonarqube: not enabled at boot"
  systemctl is-active sonarqube &>/dev/null && pass "sonarqube: RUNNING" || \
    fail "sonarqube: STOPPED" "fix_sonar_service"

  subsection "Log Files"
  [ -f /var/log/vm01-setup.log ] && pass "Setup log: /var/log/vm01-setup.log" || \
    warn "Setup log not found: /var/log/vm01-setup.log"
  for lf in sonar.log es.log web.log ce.log; do
    [ -f "$SONAR_DIR/logs/$lf" ] && pass "Log: $SONAR_DIR/logs/$lf" || \
      warn "Log not yet created: $lf (normal if service just started)"
  done

  subsection "SonarScanner CLI"
  [ -d "$SONAR_SCANNER_DIR" ] && pass "SonarScanner dir: $SONAR_SCANNER_DIR" || \
    warn "SonarScanner not found at $SONAR_SCANNER_DIR"
  command -v sonar-scanner &>/dev/null && pass "sonar-scanner in PATH" || \
    warn "sonar-scanner not in PATH (re-login or source /etc/profile.d/sonar-scanner.sh)"
  [ -f "$SONAR_SCANNER_DIR/conf/sonar-scanner.properties" ] && {
    pass "sonar-scanner.properties exists"
    grep -q "sonar.host.url=http://localhost:$SONAR_PORT" \
      "$SONAR_SCANNER_DIR/conf/sonar-scanner.properties" 2>/dev/null && \
      pass "sonar.host.url=http://localhost:$SONAR_PORT" || \
      warn "sonar.host.url may not point to localhost:$SONAR_PORT"
  } || warn "sonar-scanner.properties not found"

  subsection "SonarQube API"
  local api_status
  api_status=$(curl -sf --max-time 5 "http://localhost:$SONAR_PORT/api/system/status" \
    2>/dev/null | jq -r '.status' 2>/dev/null || echo "unreachable")
  case "$api_status" in
    UP)       pass "SonarQube API: UP — http://$THIS_IP:$SONAR_PORT" ;;
    STARTING) warn "SonarQube API: STARTING — wait 2-3 min then re-run" ;;
    *)        fail "SonarQube API: $api_status" "" ;;
  esac

  subsection "Helper Scripts"
  for s in check-status.sh scan-project.sh; do
    [ -f "$LAB_HOME/scripts/$s" ] && pass "~/scripts/$s" || \
      fail "~/scripts/$s missing" "fix_lab1_scripts"
  done
}

check_lab2() {
  section "LAB 2 — OWASP ZAP + Nessus"

  subsection "Java"
  command -v java &>/dev/null && pass "Java: $(java -version 2>&1 | head -1)" || \
    fail "Java not found (required for ZAP)" "fix_java17"

  subsection "ZAP Installation"
  [ -d "$ZAP_DIR" ] && pass "ZAP dir: $ZAP_DIR" || fail "ZAP dir missing: $ZAP_DIR" ""
  [ -f "$ZAP_DIR/zap.sh" ] && pass "zap.sh exists" || fail "zap.sh missing" ""
  [ -x "$ZAP_DIR/zap.sh" ] && pass "zap.sh is executable" || \
    fail "zap.sh not executable" "fix_zap_symlink"
  { [ -L /usr/local/bin/zap ] || [ -f /usr/local/bin/zap ]; } && \
    pass "/usr/local/bin/zap symlink exists" || \
    warn "/usr/local/bin/zap missing" && queue_fix "fix_zap_symlink"

  subsection "ZAP Data Directory"
  [ -d "$LAB_HOME/.ZAP" ] && pass ".ZAP data dir: $LAB_HOME/.ZAP" || \
    fail ".ZAP data dir missing" "fix_zap_dir"
  [ -d "$LAB_HOME/.ZAP/policies" ] && pass ".ZAP/policies exists" || \
    fail ".ZAP/policies missing" "fix_zap_dir"
  if [ -d "$LAB_HOME/.ZAP" ]; then
    local o; o=$(stat -c '%U' "$LAB_HOME/.ZAP" 2>/dev/null)
    [ "$o" = "$LAB_USER" ] && pass ".ZAP owned by $LAB_USER" || \
      fail ".ZAP owned by $o (need $LAB_USER)" "fix_zap_dir"
  fi

  subsection "ZAP Log"
  [ -f /var/log/zap-daemon.log ] && pass "ZAP log: /var/log/zap-daemon.log" || \
    fail "ZAP log missing" "fix_zap_log"

  subsection "ZAP Service"
  [ -f /etc/systemd/system/zap-daemon.service ] && pass "zap-daemon.service exists" || \
    fail "zap-daemon.service missing" "fix_zap_service"
  if [ -f /etc/systemd/system/zap-daemon.service ]; then
    grep -q "api.key=$ZAP_API_KEY" /etc/systemd/system/zap-daemon.service 2>/dev/null && \
      pass "ZAP service: API key configured" || \
      fail "ZAP service: API key not set to '$ZAP_API_KEY'" "fix_zap_service"
    grep -q "User=$LAB_USER" /etc/systemd/system/zap-daemon.service 2>/dev/null && \
      pass "ZAP service: User=$LAB_USER" || \
      warn "ZAP service: User mismatch — expected $LAB_USER" && queue_fix "fix_zap_service"
  fi
  systemctl is-enabled zap-daemon &>/dev/null && pass "zap-daemon: enabled at boot" || \
    warn "zap-daemon: not enabled at boot"
  systemctl is-active zap-daemon &>/dev/null && pass "zap-daemon: RUNNING" || \
    fail "zap-daemon: STOPPED" "fix_zap_service"

  subsection "ZAP API"
  local zap_ver
  zap_ver=$(curl -sf --max-time 5 \
    "http://localhost:$ZAP_PORT/JSON/core/view/version/?apikey=$ZAP_API_KEY" \
    2>/dev/null | jq -r '.version' 2>/dev/null || echo "unreachable")
  if [ "$zap_ver" != "unreachable" ] && [ -n "$zap_ver" ]; then
    pass "ZAP API responding: v$zap_ver — http://$THIS_IP:$ZAP_PORT"
  else
    fail "ZAP API not responding on port $ZAP_PORT" ""
    info "ZAP takes 1-2 min to start. Check: sudo systemctl status zap-daemon"
  fi

  subsection "ZAP GUI"
  # Check display libraries required to run ZAP in graphical mode
  for lib in libgtk-3-0 libxtst6 libgl1; do
    dpkg -l "$lib" 2>/dev/null | grep -q '^ii' && pass "GUI lib: $lib" || \
      fail "GUI lib missing: $lib" "fix_zap_gui_deps"
  done
  # libasound differs by Ubuntu version — accept either
  if dpkg -l libasound2 2>/dev/null | grep -q '^ii' || \
     dpkg -l libasound2t64 2>/dev/null | grep -q '^ii'; then
    pass "GUI lib: libasound2 (or libasound2t64)"
  else
    fail "GUI lib missing: libasound2 / libasound2t64" "fix_zap_gui_deps"
  fi
  # Desktop launcher (.desktop file for the app menu)
  if [ -f /usr/share/applications/zaproxy.desktop ]; then
    pass "Desktop launcher: /usr/share/applications/zaproxy.desktop"
    grep -q "Exec=/opt/zaproxy/zap.sh" /usr/share/applications/zaproxy.desktop 2>/dev/null && \
      pass "Desktop launcher Exec points to /opt/zaproxy/zap.sh" || \
      warn "Desktop launcher Exec line may be incorrect"
    grep -q "Categories=.*Security" /usr/share/applications/zaproxy.desktop 2>/dev/null && \
      pass "Desktop launcher Categories include Security" || \
      warn "Desktop launcher Categories may be missing Security"
  else
    fail "Desktop launcher missing: /usr/share/applications/zaproxy.desktop" "fix_zap_desktop"
  fi
  # zap-gui.sh helper script
  if [ -f "$LAB_HOME/scripts/zap-gui.sh" ]; then
    pass "~/scripts/zap-gui.sh exists"
    [ -x "$LAB_HOME/scripts/zap-gui.sh" ] && pass "zap-gui.sh is executable" || \
      fail "zap-gui.sh not executable" "fix_lab2_scripts"
  else
    fail "~/scripts/zap-gui.sh missing" "fix_lab2_scripts"
  fi
  # Informational: display availability
  if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    info "Display detected (${DISPLAY:-$WAYLAND_DISPLAY}) — ZAP GUI can launch now"
  else
    info "No display in this session — use 'ssh -X' or desktop login for ZAP GUI"
  fi

  subsection "Python Tools"
  command -v python3 &>/dev/null && pass "python3: $(python3 --version 2>&1)" || warn "python3 not found"
  for m in requests bs4; do
    python3 -c "import $m" 2>/dev/null && pass "Python: $m" || \
      warn "Python module missing: $m  (pip3 install requests beautifulsoup4)"
  done

  subsection "Security Tools"
  command -v nmap &>/dev/null && pass "nmap installed" || warn "nmap not installed"
  command -v nikto &>/dev/null && pass "nikto installed" || warn "nikto not installed"
  { [ -d /opt/sqlmap ] || command -v sqlmap &>/dev/null; } && pass "sqlmap installed" || \
    warn "sqlmap not installed"

  subsection "Nessus"
  if dpkg -l nessus 2>/dev/null | grep -q '^ii'; then
    pass "Nessus package installed"
    systemctl is-active nessusd &>/dev/null && pass "nessusd: RUNNING" || \
      fail "nessusd: STOPPED" "fix_nessus_service"
    systemctl is-enabled nessusd &>/dev/null && pass "nessusd: enabled at boot" || \
      warn "nessusd: not enabled at boot"
  else
    # Check if .deb is available
    local deb_path; deb_path=$(find "$SCRIPT_DIR" /tmp "$LAB_HOME" -maxdepth 1 -iname "Nessus*.deb" 2>/dev/null | head -1)
    if [ -n "$deb_path" ]; then
      fail "Nessus .deb found ($deb_path) but not installed" "fix_nessus_service"
    else
      warn "Nessus not installed — download from https://www.tenable.com/downloads/nessus"
      warn "Place Nessus*.deb in: $SCRIPT_DIR  then re-run student-setup.sh or healthcheck --fix"
    fi
  fi

  subsection "Helper Scripts"
  for s in check-status.sh zap-scan.sh zap-export-ca.sh zap-gui.sh nessus-check.sh; do
    [ -f "$LAB_HOME/scripts/$s" ] && pass "~/scripts/$s" || \
      fail "~/scripts/$s missing" "fix_lab2_scripts"
  done
}

get_php_ini_apache() { find /etc/php -name "php.ini" -path "*/apache2/*" 2>/dev/null | head -1; }

check_lab3() {
  section "LAB 3 — DVWA + VulnShop"

  subsection "Packages"
  for pkg in apache2 mariadb-server php php-mysql php-gd php-xml php-mbstring \
             php-curl php-zip php-bcmath php-intl; do
    dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' && pass "Package: $pkg" || \
      fail "Package missing: $pkg" "fix_apache_service"
  done
  [ -f /usr/local/bin/composer ] && pass "Composer: $(composer --version 2>&1 | head -1)" || \
    fail "Composer missing" "fix_vulnshop_composer"

  subsection "Apache2"
  systemctl is-active apache2 &>/dev/null && pass "apache2: RUNNING" || \
    fail "apache2: STOPPED" "fix_apache_service"
  systemctl is-enabled apache2 &>/dev/null && pass "apache2: enabled at boot" || \
    warn "apache2: not enabled at boot"
  apache2ctl -M 2>/dev/null | grep -q 'rewrite' && pass "mod_rewrite: enabled" || \
    fail "mod_rewrite: not enabled" "fix_apache_service"
  grep -q 'AllowOverride All' /etc/apache2/apache2.conf 2>/dev/null && \
    pass "AllowOverride All in apache2.conf" || \
    fail "AllowOverride not All (DVWA .htaccess won't work)" "fix_apache_allowoverride"

  subsection "MariaDB"
  systemctl is-active mariadb &>/dev/null && pass "mariadb: RUNNING" || \
    fail "mariadb: STOPPED" "fix_mariadb_service"
  systemctl is-enabled mariadb &>/dev/null && pass "mariadb: enabled at boot" || \
    warn "mariadb: not enabled at boot"

  subsection "PHP Configuration"
  local php_ini; php_ini=$(get_php_ini_apache)
  if [ -n "$php_ini" ]; then
    pass "PHP ini (Apache): $php_ini"
    for setting in allow_url_include allow_url_fopen display_errors file_uploads; do
      local val
      val=$(grep -E "^[;[:space:]]*${setting}[[:space:]]*=" "$php_ini" 2>/dev/null | tail -1 \
            | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]')
      echo "$val" | grep -qi "^On$" && pass "PHP: $setting=On" || \
        fail "PHP: $setting=$val (need On for lab exercises)" "fix_php_ini"
    done
  else
    warn "Apache php.ini not found (PHP may not be installed)"
  fi

  # ── DVWA ─────────────────────────────────────────────────────────────────
  if [ -d "$DVWA_DIR" ]; then
    subsection "DVWA Config"
    if [ -f "$DVWA_DIR/config/config.inc.php" ]; then
      pass "config.inc.php exists"
      grep -q "db_user.*$DVWA_DB_USER" "$DVWA_DIR/config/config.inc.php" 2>/dev/null && \
        pass "DVWA: db_user=$DVWA_DB_USER" || \
        fail "DVWA: db_user not '$DVWA_DB_USER'" "fix_dvwa_config"
      grep -q "db_password.*$DVWA_DB_PASS" "$DVWA_DIR/config/config.inc.php" 2>/dev/null && \
        pass "DVWA: db_password set" || fail "DVWA: db_password wrong" "fix_dvwa_config"
      grep -q "db_database.*$DVWA_DB_NAME" "$DVWA_DIR/config/config.inc.php" 2>/dev/null && \
        pass "DVWA: db_database=$DVWA_DB_NAME" || \
        fail "DVWA: db_database not '$DVWA_DB_NAME'" "fix_dvwa_config"
      local sl; sl=$(grep "default_security_level" "$DVWA_DIR/config/config.inc.php" 2>/dev/null \
        | grep -oP "'[^']+'" | tail -1 | tr -d "'")
      [ "$sl" = "low" ] && pass "DVWA: security_level=low" || \
        warn "DVWA: security_level=${sl:-unknown} (recommend 'low')"
    elif [ -f "$DVWA_DIR/config/config.inc.php.dist" ]; then
      fail "config.inc.php not created from .dist" "fix_dvwa_config"
    else
      fail "DVWA config missing entirely" "fix_dvwa_config"
    fi

    subsection "DVWA Files & Permissions"
    for f in index.php login.php setup.php; do
      [ -f "$DVWA_DIR/$f" ] && pass "DVWA: $f" || fail "DVWA: $f missing" ""
    done
    local downer; downer=$(stat -c '%U' "$DVWA_DIR" 2>/dev/null)
    [ "$downer" = "www-data" ] && pass "DVWA owned by www-data" || \
      fail "DVWA owned by $downer (need www-data)" "fix_dvwa_permissions"
    local up; up=$(stat -c '%a' "$DVWA_DIR/hackable/uploads" 2>/dev/null)
    [ "$up" = "777" ] && pass "DVWA uploads: 777" || \
      fail "DVWA uploads: $up (need 777)" "fix_dvwa_permissions"
    local cp_; cp_=$(stat -c '%a' "$DVWA_DIR/config" 2>/dev/null)
    [ "$cp_" = "777" ] && pass "DVWA config/: 777" || \
      fail "DVWA config/: $cp_ (need 777)" "fix_dvwa_permissions"

    subsection "DVWA Database"
    mysql -u "$DVWA_DB_USER" -p"$DVWA_DB_PASS" -e "USE $DVWA_DB_NAME; SELECT 1;" &>/dev/null && \
      pass "DVWA DB connection OK" || fail "Cannot connect to DVWA DB" "fix_dvwa_db"
    mysql -u "$DVWA_DB_USER" -p"$DVWA_DB_PASS" "$DVWA_DB_NAME" \
      -e "SHOW TABLES;" 2>/dev/null | grep -q 'users' && \
      pass "DVWA DB: tables initialized" || fail "DVWA DB: tables missing (not initialized)" "fix_dvwa_db"

    subsection "DVWA HTTP"
    local hc; hc=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
      "http://localhost/dvwa/login.php" 2>/dev/null || echo "0")
    case "$hc" in
      200|302) pass "DVWA HTTP: $hc — http://$THIS_IP/dvwa/login.php" ;;
      500)     fail "DVWA HTTP: 500 — PHP config or DB issue" "fix_dvwa_config" ;;
      0)       fail "DVWA: not responding (Apache down?)" "fix_apache_service" ;;
      *)       warn "DVWA HTTP: $hc" ;;
    esac
  fi

  # ── VulnShop ─────────────────────────────────────────────────────────────
  if [ -d "$VULNSHOP_DIR" ]; then
    subsection "VulnShop VHost"
    [ -f /etc/apache2/sites-available/vulnshop.conf ] && pass "vulnshop.conf exists in sites-available" || \
      fail "vulnshop.conf missing from sites-available" "fix_vulnshop_vhost"
    { [ -f /etc/apache2/sites-enabled/vulnshop.conf ] || \
      [ -L /etc/apache2/sites-enabled/vulnshop.conf ]; } && \
      pass "vulnshop.conf enabled" || fail "vulnshop.conf not enabled" "fix_vulnshop_vhost"
    # Detect stale "Listen 8080" inside vulnshop.conf (old setup pattern) and fix it
    if [ -f /etc/apache2/sites-available/vulnshop.conf ] && \
       grep -q "^[[:space:]]*Listen[[:space:]]\+$VULNSHOP_PORT" /etc/apache2/sites-available/vulnshop.conf 2>/dev/null; then
      fail "Listen $VULNSHOP_PORT inside vulnshop.conf (must be in ports.conf only)" "fix_vulnshop_vhost"
    fi
    grep -q "^[[:space:]]*Listen[[:space:]]\+$VULNSHOP_PORT" /etc/apache2/ports.conf 2>/dev/null && \
      pass "Apache: Listen $VULNSHOP_PORT in ports.conf" || \
      fail "Apache not listening on $VULNSHOP_PORT" "fix_vulnshop_vhost"
    [ -f /etc/apache2/sites-available/vulnshop.conf ] && \
      grep -q "DocumentRoot.*$VULNSHOP_DIR/public" \
        /etc/apache2/sites-available/vulnshop.conf 2>/dev/null && \
      pass "DocumentRoot → $VULNSHOP_DIR/public" || \
      warn "DocumentRoot may not point to /public"

    subsection "VulnShop .env"
    if [ -f "$VULNSHOP_DIR/.env" ]; then
      pass ".env exists"
      grep -q "DB_DATABASE=$VULNSHOP_DB_NAME" "$VULNSHOP_DIR/.env" 2>/dev/null && \
        pass ".env: DB_DATABASE=$VULNSHOP_DB_NAME" || \
        fail ".env: DB_DATABASE wrong" "fix_vulnshop_env"
      grep -q "DB_USERNAME=$VULNSHOP_DB_USER" "$VULNSHOP_DIR/.env" 2>/dev/null && \
        pass ".env: DB_USERNAME=$VULNSHOP_DB_USER" || \
        fail ".env: DB_USERNAME wrong" "fix_vulnshop_env"
      local ak; ak=$(grep "^APP_KEY=" "$VULNSHOP_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
      [ -n "$ak" ] && pass ".env: APP_KEY is set" || \
        fail ".env: APP_KEY empty" "fix_vulnshop_env"
    else
      fail ".env missing" "fix_vulnshop_env"
    fi

    subsection "VulnShop Composer & Storage"
    [ -f "$VULNSHOP_DIR/vendor/autoload.php" ] && pass "vendor/autoload.php exists" || \
      fail "vendor/ missing (composer install needed)" "fix_vulnshop_composer"
    for sd in storage storage/logs storage/framework/cache storage/framework/sessions \
               storage/framework/views bootstrap/cache; do
      if [ -d "$VULNSHOP_DIR/$sd" ]; then
        local sp_; sp_=$(stat -c '%a' "$VULNSHOP_DIR/$sd" 2>/dev/null)
        { [ "$sp_" = "775" ] || [ "$sp_" = "777" ]; } && pass "VulnShop $sd: $sp_" || \
          fail "VulnShop $sd: $sp_ (need 775+)" "fix_vulnshop_storage"
      else
        fail "VulnShop $sd: missing" "fix_vulnshop_storage"
      fi
    done
    local vso; vso=$(stat -c '%U' "$VULNSHOP_DIR/storage" 2>/dev/null)
    [ "$vso" = "www-data" ] && pass "storage owned by www-data" || \
      fail "storage owned by $vso (need www-data)" "fix_vulnshop_storage"

    subsection "VulnShop Database"
    mysql -u "$VULNSHOP_DB_USER" -p"$VULNSHOP_DB_PASS" \
      -e "USE $VULNSHOP_DB_NAME; SELECT 1;" &>/dev/null && \
      pass "VulnShop DB connection OK" || fail "Cannot connect to VulnShop DB" "fix_vulnshop_db"
    for tbl in users products orders; do
      mysql -u "$VULNSHOP_DB_USER" -p"$VULNSHOP_DB_PASS" "$VULNSHOP_DB_NAME" \
        -e "DESCRIBE $tbl;" &>/dev/null && \
        pass "VulnShop DB: table '$tbl' exists" || \
        fail "VulnShop DB: table '$tbl' missing" "fix_vulnshop_db"
    done

    subsection "VulnShop HTTP"
    local vc; vc=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
      "http://localhost:$VULNSHOP_PORT" 2>/dev/null || echo "0")
    case "$vc" in
      200|301|302) pass "VulnShop HTTP: $vc — http://$THIS_IP:$VULNSHOP_PORT" ;;
      403) fail "VulnShop HTTP: 403 (permissions or DocumentRoot issue)" "fix_vulnshop_storage" ;;
      404) fail "VulnShop HTTP: 404 (vhost may not point to /public)" "fix_vulnshop_vhost" ;;
      500) fail "VulnShop HTTP: 500 (.env, storage or composer issue)" "fix_vulnshop_storage" ;;
      0)   fail "VulnShop not responding (Apache down or port $VULNSHOP_PORT not listening)" "fix_vulnshop_vhost" ;;
      *)   warn "VulnShop HTTP: $vc" ;;
    esac

    subsection "VulnShop Log"
    local vlog="$VULNSHOP_DIR/storage/logs/laravel.log"
    if [ -f "$vlog" ]; then
      pass "laravel.log exists"
      local errs; errs=$(grep -c "\[ERROR\]\|\[CRITICAL\]\|PHP Fatal\|PHP Parse" "$vlog" 2>/dev/null || echo 0)
      [ "$errs" -gt 0 ] && warn "laravel.log has $errs error(s) — check $vlog" || \
        pass "laravel.log: no critical errors"
    else
      warn "laravel.log not yet created"
    fi
  fi

  subsection "Setup Log"
  [ -f /var/log/vm03-setup.log ] && pass "Setup log: /var/log/vm03-setup.log" || \
    warn "Setup log not found: /var/log/vm03-setup.log"

  subsection "Helper Scripts"
  for s in check-status.sh reset-dvwa-db.sh reset-vulnshop.sh; do
    [ -f "$LAB_HOME/scripts/$s" ] && pass "~/scripts/$s" || \
      fail "~/scripts/$s missing" "fix_lab3_scripts"
  done
}

check_firewall() {
  section "FIREWALL"
  if ! command -v ufw &>/dev/null; then warn "ufw not installed"; return; fi
  ufw status 2>/dev/null | grep -qi "active" && pass "UFW: active" || warn "UFW: inactive"
  local ports=()
  $HAS_LAB1 && ports+=(9000)
  $HAS_LAB2 && ports+=(8090 8834)
  $HAS_LAB3 && ports+=(80 8080)
  for p in "${ports[@]}"; do
    ufw status 2>/dev/null | grep -qE "^${p}" && pass "UFW: port $p allowed" || \
      warn "UFW: port $p not explicitly listed"
  done
  ufw status 2>/dev/null | grep -qiE "^22|^OpenSSH|^ssh" && pass "UFW: SSH allowed" || \
    warn "UFW: SSH may not be explicitly allowed"
}

###############################################################################
# ─── RUN ALL CHECKS ──────────────────────────────────────────────────────────
###############################################################################
section "SYSTEM"
check_base_packages
check_scripts_dir
$HAS_LAB1 && check_kernel_params
$HAS_LAB1 && check_lab1
$HAS_LAB2 && check_lab2
$HAS_LAB3 && check_lab3
check_firewall

###############################################################################
# ─── SUMMARY ─────────────────────────────────────────────────────────────────
###############################################################################
section "SUMMARY"
echo ""
echo -e "  ${GREEN}${PASS_SYM} PASS${NC}  $PASS_COUNT"
echo -e "  ${RED}${FAIL_SYM} FAIL${NC}  $FAIL_COUNT"
echo -e "  ${YELLOW}${WARN_SYM} WARN${NC}  $WARN_COUNT"
echo ""

# ─── Post-fix re-check mode just shows results and exits ─────────────────────
if [ "$MODE" = "recheck" ]; then
  if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All issues resolved!${NC}"
  else
    echo -e "${YELLOW}${BOLD}$FAIL_COUNT issue(s) remain after auto-fix.${NC}"
    echo "You may need to:"
    echo "  • Re-run: sudo bash healthcheck.sh --fix"
    echo "  • Check logs: /var/log/vm01-setup.log  /var/log/vm02-setup.log  /var/log/vm03-setup.log"
    echo "  • For persistent failures: sudo bash healthcheck.sh --reset"
  fi
  echo ""
  if $HAS_LAB1; then echo -e "  SonarQube:  http://$THIS_IP:$SONAR_PORT  (admin / admin)"; fi
  if $HAS_LAB2; then echo -e "  ZAP API:    http://$THIS_IP:$ZAP_PORT   (key: $ZAP_API_KEY)"; fi
  if $HAS_LAB2; then echo -e "  Nessus:     https://$THIS_IP:$NESSUS_PORT"; fi
  if $HAS_LAB3; then echo -e "  DVWA:       http://$THIS_IP/dvwa/        (admin / password)"; fi
  if $HAS_LAB3; then echo -e "  VulnShop:   http://$THIS_IP:$VULNSHOP_PORT  (admin@vulnshop.local / admin123)"; fi
  echo ""
  exit $([ "$FAIL_COUNT" -eq 0 ] && echo 0 || echo 1)
fi

###############################################################################
# ─── FIX EXECUTION ───────────────────────────────────────────────────────────
###############################################################################
# Trim leading space from FIX_QUEUE string
FIX_QUEUE="${FIX_QUEUE# }"

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}All critical checks passed! Your lab environment is healthy.${NC}"
  echo ""
  $HAS_LAB1 && echo -e "  SonarQube:  http://$THIS_IP:$SONAR_PORT  (admin / admin)"
  $HAS_LAB2 && echo -e "  ZAP API:    http://$THIS_IP:$ZAP_PORT   (key: $ZAP_API_KEY)"
  $HAS_LAB2 && echo -e "  Nessus:     https://$THIS_IP:$NESSUS_PORT"
  $HAS_LAB3 && echo -e "  DVWA:       http://$THIS_IP/dvwa/        (admin / password)"
  $HAS_LAB3 && echo -e "  VulnShop:   http://$THIS_IP:$VULNSHOP_PORT  (admin@vulnshop.local / admin123)"
  echo ""
  exit 0
fi

if [ -z "$FIX_QUEUE" ]; then
  echo -e "${YELLOW}Some WARNings detected but no auto-fixable failures.${NC}"
  exit 0
fi

echo -e "${BOLD}Auto-fixable issues queued.${NC}"
echo ""

run_all_fixes() {
  echo -e "${CYAN}${BOLD}Applying fixes...${NC}"
  echo ""
  for fn in $FIX_QUEUE; do
    if declare -f "$fn" > /dev/null 2>&1; then
      $fn
    else
      echo -e "  ${YELLOW}${WARN_SYM}${NC} Unknown fix: $fn"
    fi
  done
  echo ""
  echo -e "${GREEN}${BOLD}Fixes applied. Running full verification...${NC}"
  echo ""
  sleep 2
  # Full re-check in --recheck mode (shows post-fix results cleanly)
  exec bash "${BASH_SOURCE[0]}" --recheck
}

case "$MODE" in
  check)
    echo -e "${YELLOW}Running in --check mode. No changes made.${NC}"
    echo -e "Re-run with ${BOLD}--fix${NC} to apply all fixes automatically."
    exit 1
    ;;
  fix)
    run_all_fixes
    ;;
  interactive)
    echo -e "${BOLD}Found $FAIL_COUNT failure(s). Apply all auto-fixes now?${NC}"
    read -r -p "Fix all? [y/N]: " APPLY
    if [[ "$APPLY" =~ ^[Yy]$ ]]; then
      run_all_fixes
    else
      echo "No fixes applied."
      echo "Re-run with --fix to apply automatically, or --reset for a full factory reset."
      exit 1
    fi
    ;;
esac
