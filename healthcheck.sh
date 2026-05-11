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

# ─── ARGUMENT PARSING ────────────────────────────────────────────────────────
MODE="interactive"  # interactive | check | fix | reset
for arg in "$@"; do
  case "$arg" in
    --check)  MODE="check"  ;;
    --fix)    MODE="fix"    ;;
    --reset)  MODE="reset"  ;;
    --help|-h)
      echo "Usage: sudo bash healthcheck.sh [--check|--fix|--reset]"
      echo "  (no flag)  Interactive mode — report then ask before fixing"
      echo "  --check    Report only; no changes made"
      echo "  --fix      Auto-fix all detected issues without prompting"
      echo "  --reset    Full factory reset of all detected lab apps"
      exit 0 ;;
  esac
done

# ─── ROOT CHECK ──────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
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

# ─── CONSTANTS ───────────────────────────────────────────────────────────────
# Lab 1 — SonarQube
SONAR_DB_USER="sonarqube"
SONAR_DB_PASS="S0narDB@2024"
SONAR_DB_NAME="sonarqube"
SONAR_PORT=9000
SONAR_DIR="/opt/sonarqube"
SONAR_SCANNER_DIR="/opt/sonar-scanner"

# Lab 2 — ZAP + Nessus
ZAP_API_KEY="lab-api-key-2024"
ZAP_PORT=8090
ZAP_DIR="/opt/zaproxy"
NESSUS_PORT=8834

# Lab 3 — DVWA + VulnShop
DVWA_DB_USER="dvwa"
DVWA_DB_PASS="dvwa_pass"
DVWA_DB_NAME="dvwa"
DVWA_DIR="/var/www/html/dvwa"

VULNSHOP_DB_USER="vulnshop_user"
VULNSHOP_DB_PASS="vulnshop_pass"
VULNSHOP_DB_NAME="vulnshop"
VULNSHOP_DIR="/var/www/html/vulnshop"
VULNSHOP_PORT=8080

# ─── COUNTERS & FIX QUEUE ────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
declare -a FIX_QUEUE=()   # list of fix function names to run

# ─── OUTPUT HELPERS ──────────────────────────────────────────────────────────
pass() { echo -e "  ${GREEN}${PASS_SYM} PASS${NC}  $1"; ((PASS_COUNT++)); }
fail() {
  local msg="$1"
  local fix_fn="${2:-}"
  echo -e "  ${RED}${FAIL_SYM} FAIL${NC}  $msg"
  ((FAIL_COUNT++))
  [ -n "$fix_fn" ] && FIX_QUEUE+=("$fix_fn")
}
warn() { echo -e "  ${YELLOW}${WARN_SYM} WARN${NC}  $1"; ((WARN_COUNT++)); }
info() { echo -e "  ${CYAN}ℹ INFO${NC}  $1"; }
section() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
}
subsection() {
  echo ""
  echo -e "  ${BOLD}▸ $1${NC}"
}

# ─── LAB DETECTION ───────────────────────────────────────────────────────────
HAS_LAB1=false; HAS_LAB2=false; HAS_LAB3=false
[ -d "$SONAR_DIR" ]   && HAS_LAB1=true
[ -d "$ZAP_DIR" ]     && HAS_LAB2=true
[ -d "$DVWA_DIR" ] || [ -d "$VULNSHOP_DIR" ] && HAS_LAB3=true

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   SASTandDAST Lab — Health Check & Auto-Fix                 ║${NC}"
echo -e "${BOLD}║   Sarath G | www.sarathg.me                                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Mode:    ${BOLD}$MODE${NC}"
echo -e "  User:    ${BOLD}$LAB_USER${NC}  (home: $LAB_HOME)"
echo -e "  IP:      ${BOLD}$THIS_IP${NC}"
echo -e "  Labs:    $(${HAS_LAB1} && echo -n '[Lab1-SonarQube] '; ${HAS_LAB2} && echo -n '[Lab2-ZAP/Nessus] '; ${HAS_LAB3} && echo -n '[Lab3-DVWA/VulnShop]'; echo)"

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
  echo -e "         Service configs will be re-applied."
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
    chown -R sonarqube:sonarqube "$SONAR_DIR"
    systemctl start sonarqube
    echo -e "  ${GREEN}Lab 1 reset complete.${NC}"
  fi

  if $HAS_LAB2; then
    subsection "Resetting Lab 2 — ZAP + Nessus"
    systemctl stop zap-daemon 2>/dev/null || true
    rm -rf "$LAB_HOME/.ZAP"
    mkdir -p "$LAB_HOME/.ZAP/policies"
    chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/.ZAP"
    : > /var/log/zap-daemon.log
    chown "$LAB_USER:$LAB_USER" /var/log/zap-daemon.log
    systemctl start zap-daemon
    echo -e "  ${GREEN}Lab 2 reset complete.${NC}"
  fi

  if $HAS_LAB3; then
    subsection "Resetting Lab 3 — DVWA + VulnShop"
    # DVWA DB reset
    mysql -e "DROP DATABASE IF EXISTS $DVWA_DB_NAME;" 2>/dev/null || true
    mysql -e "CREATE DATABASE $DVWA_DB_NAME;" 2>/dev/null
    mysql -e "CREATE USER IF NOT EXISTS '$DVWA_DB_USER'@'localhost' IDENTIFIED BY '$DVWA_DB_PASS';" 2>/dev/null || true
    mysql -e "GRANT ALL ON $DVWA_DB_NAME.* TO '$DVWA_DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
    # VulnShop DB reset
    mysql -e "DROP DATABASE IF EXISTS $VULNSHOP_DB_NAME;" 2>/dev/null || true
    mysql -e "CREATE DATABASE $VULNSHOP_DB_NAME;" 2>/dev/null
    mysql -e "CREATE USER IF NOT EXISTS '$VULNSHOP_DB_USER'@'localhost' IDENTIFIED BY '$VULNSHOP_DB_PASS';" 2>/dev/null || true
    mysql -e "GRANT ALL ON $VULNSHOP_DB_NAME.* TO '$VULNSHOP_DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
    # VulnShop artisan
    if [ -d "$VULNSHOP_DIR" ]; then
      cd "$VULNSHOP_DIR"
      php artisan migrate:fresh --force --seed 2>/dev/null || true
      php artisan key:generate --force 2>/dev/null || true
      php artisan config:clear 2>/dev/null || true
      php artisan cache:clear 2>/dev/null || true
      chown -R www-data:www-data "$VULNSHOP_DIR"
      chmod -R 755 "$VULNSHOP_DIR/storage" "$VULNSHOP_DIR/bootstrap/cache" 2>/dev/null || true
    fi
    # DVWA permissions
    if [ -d "$DVWA_DIR" ]; then
      chown -R www-data:www-data "$DVWA_DIR"
      chmod -R 755 "$DVWA_DIR"
      chmod 777 "$DVWA_DIR/hackable/uploads/"
      chmod 777 "$DVWA_DIR/config/"
    fi
    # Init DVWA DB
    curl -s -o /dev/null -X POST -d "create_db=Create+%2F+Reset+Database" \
      "http://localhost/dvwa/setup.php" 2>/dev/null || true
    systemctl restart apache2 mariadb 2>/dev/null || true
    echo -e "  ${GREEN}Lab 3 reset complete.${NC}"
  fi

  echo ""
  echo -e "${GREEN}${BOLD}Reset complete. Run healthcheck.sh again to verify.${NC}"
  exit 0
}

[ "$MODE" = "reset" ] && do_reset

###############################################################################
# ══════════════════════════════════════════════════════════════════════════════
# CHECK FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════
###############################################################################

# ─── COMMON: KERNEL PARAMETERS ───────────────────────────────────────────────
fix_kernel_params() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Applying kernel parameters..."
  grep -q 'vm.max_map_count' /etc/sysctl.conf || echo 'vm.max_map_count=524288' >> /etc/sysctl.conf
  grep -q 'fs.file-max' /etc/sysctl.conf      || echo 'fs.file-max=131072'      >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
  echo -e "  ${GREEN}${PASS_SYM}${NC} Kernel parameters applied."
}

check_kernel_params() {
  subsection "Kernel Parameters (SonarQube / Elasticsearch)"
  local cur_map
  cur_map=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
  if [ "$cur_map" -ge 524288 ]; then
    pass "vm.max_map_count = $cur_map (≥ 524288)"
  else
    fail "vm.max_map_count = $cur_map (need ≥ 524288)" "fix_kernel_params"
  fi

  local cur_files
  cur_files=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
  if [ "$cur_files" -ge 131072 ]; then
    pass "fs.file-max = $cur_files (≥ 131072)"
  else
    fail "fs.file-max = $cur_files (need ≥ 131072)" "fix_kernel_params"
  fi

  if grep -q 'vm.max_map_count=524288' /etc/sysctl.conf 2>/dev/null; then
    pass "/etc/sysctl.conf has vm.max_map_count=524288 (persistent)"
  else
    warn "/etc/sysctl.conf missing vm.max_map_count — may revert after reboot"
  fi
}

# ─── COMMON: SYSTEM PACKAGES ─────────────────────────────────────────────────
fix_base_packages() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Installing missing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq curl wget unzip git net-tools jq 2>/dev/null
}

check_base_packages() {
  subsection "Base Packages"
  local pkgs=(curl wget unzip git net-tools jq)
  local missing=()
  for pkg in "${pkgs[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      pass "Package installed: $pkg"
    else
      fail "Package missing: $pkg" ""
      missing+=("$pkg")
    fi
  done
  [ "${#missing[@]}" -gt 0 ] && FIX_QUEUE+=("fix_base_packages")
}

# ─── COMMON: SCRIPTS DIRECTORY ───────────────────────────────────────────────
fix_scripts_dir() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating scripts directory..."
  mkdir -p "$LAB_HOME/scripts"
  chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts"
  chmod 755 "$LAB_HOME/scripts"
}

check_scripts_dir() {
  subsection "Lab Scripts Directory"
  if [ -d "$LAB_HOME/scripts" ]; then
    pass "Scripts directory exists: $LAB_HOME/scripts"
    local owner
    owner=$(stat -c '%U' "$LAB_HOME/scripts" 2>/dev/null)
    if [ "$owner" = "$LAB_USER" ]; then
      pass "Scripts directory owner: $owner"
    else
      fail "Scripts directory owner: $owner (should be $LAB_USER)" "fix_scripts_dir"
    fi
  else
    fail "Scripts directory missing: $LAB_HOME/scripts" "fix_scripts_dir"
  fi
}

###############################################################################
# ─── LAB 1: SONARQUBE ────────────────────────────────────────────────────────
###############################################################################
fix_java17() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Installing OpenJDK 17..."
  apt-get install -y -qq openjdk-17-jdk
}

fix_postgresql_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Starting PostgreSQL..."
  systemctl enable postgresql
  systemctl start postgresql
}

fix_sonar_db() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating/repairing SonarQube database..."
  sudo -u postgres psql -c "CREATE USER $SONAR_DB_USER WITH ENCRYPTED PASSWORD '$SONAR_DB_PASS';" 2>/dev/null || true
  sudo -u postgres psql -c "CREATE DATABASE $SONAR_DB_NAME OWNER $SONAR_DB_USER;" 2>/dev/null || true
  sudo -u postgres psql -c "ALTER USER $SONAR_DB_USER SET search_path TO public;" 2>/dev/null || true
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $SONAR_DB_NAME TO $SONAR_DB_USER;" 2>/dev/null || true
  echo -e "  ${GREEN}${PASS_SYM}${NC} SonarQube database verified."
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
  chown sonarqube:sonarqube "$SONAR_DIR/conf/sonar.properties"
}

fix_sonar_permissions() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing SonarQube directory ownership..."
  chown -R sonarqube:sonarqube "$SONAR_DIR"
}

fix_sonar_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Enabling and starting SonarQube service..."
  systemctl daemon-reload
  systemctl enable sonarqube
  systemctl restart sonarqube
  echo -e "  ${GREEN}${PASS_SYM}${NC} SonarQube service restarted. Allow 2-3 minutes for startup."
}

fix_sonar_limits() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Adding SonarQube system limits..."
  grep -q 'sonarqube.*nofile.*131072' /etc/security/limits.conf 2>/dev/null || cat >> /etc/security/limits.conf << 'EOF'

# SonarQube limits
sonarqube   -   nofile   131072
sonarqube   -   nproc    8192
EOF
}

check_lab1() {
  section "LAB 1 — SonarQube SAST Hub"

  # Java
  subsection "Java 17"
  if dpkg -l openjdk-17-jdk 2>/dev/null | grep -q '^ii'; then
    local jver
    jver=$(java -version 2>&1 | head -1)
    pass "OpenJDK 17 installed: $jver"
  else
    fail "openjdk-17-jdk not installed" "fix_java17"
  fi
  if [ -d /usr/lib/jvm/java-17-openjdk-amd64 ]; then
    pass "JAVA_HOME path exists: /usr/lib/jvm/java-17-openjdk-amd64"
  else
    warn "Expected JAVA_HOME path not found; java may still work"
  fi

  # PostgreSQL
  subsection "PostgreSQL"
  if dpkg -l postgresql 2>/dev/null | grep -q '^ii'; then
    pass "PostgreSQL package installed"
  else
    fail "PostgreSQL not installed" "fix_postgresql_service"
  fi
  if systemctl is-active postgresql &>/dev/null; then
    pass "PostgreSQL service: RUNNING"
  else
    fail "PostgreSQL service: STOPPED" "fix_postgresql_service"
  fi
  if systemctl is-enabled postgresql &>/dev/null; then
    pass "PostgreSQL enabled at boot"
  else
    warn "PostgreSQL not enabled at boot"
  fi

  # SonarQube DB
  subsection "SonarQube Database"
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$SONAR_DB_USER'" 2>/dev/null | grep -q 1; then
    pass "DB user '$SONAR_DB_USER' exists in PostgreSQL"
  else
    fail "DB user '$SONAR_DB_USER' missing from PostgreSQL" "fix_sonar_db"
  fi
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$SONAR_DB_NAME'" 2>/dev/null | grep -q 1; then
    pass "Database '$SONAR_DB_NAME' exists"
  else
    fail "Database '$SONAR_DB_NAME' missing" "fix_sonar_db"
  fi
  if sudo -u postgres psql -d "$SONAR_DB_NAME" -c "SELECT 1" &>/dev/null; then
    pass "DB user can connect to '$SONAR_DB_NAME'"
  else
    fail "DB user cannot connect to '$SONAR_DB_NAME'" "fix_sonar_db"
  fi

  # SonarQube directories
  subsection "SonarQube Directories & Files"
  local dirs=("$SONAR_DIR" "$SONAR_DIR/conf" "$SONAR_DIR/logs" "$SONAR_DIR/data" "$SONAR_DIR/extensions" "$SONAR_DIR/bin/linux-x86-64")
  for d in "${dirs[@]}"; do
    if [ -d "$d" ]; then
      pass "Directory exists: $d"
    else
      fail "Directory missing: $d" "fix_sonar_permissions"
    fi
  done

  local files=("$SONAR_DIR/conf/sonar.properties" "$SONAR_DIR/bin/linux-x86-64/sonar.sh")
  for f in "${files[@]}"; do
    if [ -f "$f" ]; then
      pass "File exists: $f"
    else
      fail "File missing: $f" "fix_sonar_properties"
    fi
  done

  # sonar.properties content
  subsection "sonar.properties Configuration"
  local sprops="$SONAR_DIR/conf/sonar.properties"
  if [ -f "$sprops" ]; then
    if grep -q "sonar.jdbc.username=$SONAR_DB_USER" "$sprops"; then
      pass "sonar.jdbc.username=$SONAR_DB_USER"
    else
      fail "sonar.jdbc.username not set to '$SONAR_DB_USER'" "fix_sonar_properties"
    fi
    if grep -q "sonar.jdbc.url=jdbc:postgresql://localhost:5432/$SONAR_DB_NAME" "$sprops"; then
      pass "sonar.jdbc.url points to localhost:5432/$SONAR_DB_NAME"
    else
      fail "sonar.jdbc.url incorrect in sonar.properties" "fix_sonar_properties"
    fi
    if grep -q "sonar.web.port=$SONAR_PORT" "$sprops"; then
      pass "sonar.web.port=$SONAR_PORT"
    else
      fail "sonar.web.port not set to $SONAR_PORT" "fix_sonar_properties"
    fi
    if grep -q "sonar.web.host=0.0.0.0" "$sprops"; then
      pass "sonar.web.host=0.0.0.0 (listening on all interfaces)"
    else
      warn "sonar.web.host may not be set to 0.0.0.0 — SonarQube may not be network-accessible"
    fi
  fi

  # Ownership
  subsection "File Permissions"
  if [ -d "$SONAR_DIR" ]; then
    local owner
    owner=$(stat -c '%U' "$SONAR_DIR" 2>/dev/null)
    if [ "$owner" = "sonarqube" ]; then
      pass "$SONAR_DIR owned by sonarqube"
    else
      fail "$SONAR_DIR owned by $owner (should be sonarqube)" "fix_sonar_permissions"
    fi
  fi

  # Systemd limits
  subsection "System Limits"
  if grep -q 'sonarqube.*nofile.*131072' /etc/security/limits.conf 2>/dev/null; then
    pass "/etc/security/limits.conf has sonarqube nofile=131072"
  else
    warn "SonarQube limits not in /etc/security/limits.conf"
    FIX_QUEUE+=("fix_sonar_limits")
  fi

  # Systemd service
  subsection "SonarQube Service"
  if [ -f /etc/systemd/system/sonarqube.service ]; then
    pass "sonarqube.service unit file exists"
  else
    fail "sonarqube.service unit file missing" "fix_sonar_service"
  fi
  if systemctl is-enabled sonarqube &>/dev/null; then
    pass "sonarqube.service enabled at boot"
  else
    warn "sonarqube.service not enabled at boot"
  fi
  if systemctl is-active sonarqube &>/dev/null; then
    pass "sonarqube.service: RUNNING"
  else
    fail "sonarqube.service: STOPPED" "fix_sonar_service"
  fi

  # Log files
  subsection "Log Files"
  local logdir="$SONAR_DIR/logs"
  if [ -d "$logdir" ]; then
    pass "Log directory: $logdir"
    for lf in sonar.log es.log web.log ce.log; do
      [ -f "$logdir/$lf" ] && pass "Log file exists: $logdir/$lf" || warn "Log file not yet created: $logdir/$lf (normal if service just started)"
    done
  else
    warn "Log directory not yet created: $logdir"
  fi
  if [ -f /var/log/vm01-setup.log ]; then
    pass "Setup log exists: /var/log/vm01-setup.log"
  else
    warn "Setup log not found: /var/log/vm01-setup.log"
  fi

  # SonarScanner CLI
  subsection "SonarScanner CLI"
  if [ -d "$SONAR_SCANNER_DIR" ]; then
    pass "SonarScanner directory: $SONAR_SCANNER_DIR"
  else
    warn "SonarScanner not found at $SONAR_SCANNER_DIR"
  fi
  if command -v sonar-scanner &>/dev/null; then
    local sv
    sv=$(sonar-scanner --version 2>&1 | grep -i version | head -1 || echo "installed")
    pass "sonar-scanner in PATH: $sv"
  else
    warn "sonar-scanner not in PATH (add /opt/sonar-scanner/bin to PATH or re-login)"
  fi
  if [ -f "$SONAR_SCANNER_DIR/conf/sonar-scanner.properties" ]; then
    pass "sonar-scanner.properties exists"
    if grep -q "sonar.host.url=http://localhost:$SONAR_PORT" "$SONAR_SCANNER_DIR/conf/sonar-scanner.properties" 2>/dev/null; then
      pass "sonar.host.url=http://localhost:$SONAR_PORT"
    else
      warn "sonar.host.url may not point to localhost:$SONAR_PORT"
    fi
  else
    warn "sonar-scanner.properties not found"
  fi

  # API check
  subsection "SonarQube API"
  local status
  status=$(curl -sf --max-time 5 "http://localhost:$SONAR_PORT/api/system/status" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unreachable")
  case "$status" in
    UP)       pass "SonarQube API: UP (http://$THIS_IP:$SONAR_PORT)" ;;
    STARTING) warn "SonarQube API: STARTING — wait 2-3 minutes then re-run" ;;
    *)        fail "SonarQube API: $status — service may be down or still initializing" "" ;;
  esac

  # Helper scripts
  subsection "Helper Scripts"
  for s in check-status.sh scan-project.sh; do
    if [ -f "$LAB_HOME/scripts/$s" ]; then
      pass "Helper script: ~/scripts/$s"
    else
      warn "Helper script missing: ~/scripts/$s (re-run vm01 setup or --fix)"
      FIX_QUEUE+=("fix_lab1_scripts")
    fi
  done
}

fix_lab1_scripts() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Recreating Lab 1 helper scripts..."
  mkdir -p "$LAB_HOME/scripts"

  cat > "$LAB_HOME/scripts/check-status.sh" << 'SCRIPT'
#!/bin/bash
echo "=== VM-01 Service Status ==="
echo ""
echo "--- SonarQube ---"
systemctl is-active sonarqube && echo "Status: RUNNING" || echo "Status: STOPPED"
curl -sf http://localhost:9000/api/system/status 2>/dev/null | jq -r '.status' 2>/dev/null && true || echo "(not responding yet)"
echo ""
echo "--- PostgreSQL ---"
systemctl is-active postgresql && echo "Status: RUNNING" || echo "Status: STOPPED"
echo ""
echo "--- Disk Usage ---"
df -h / | tail -1 | awk '{print "Used: " $3 " / " $2 " (" $5 ")"}'
echo ""
echo "--- Memory ---"
free -h | grep Mem | awk '{print "Used: " $3 " / " $2}'
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
echo ""
echo "Scan complete. View results: http://localhost:9000/dashboard?id=$PROJECT_KEY"
SCRIPT

  chmod +x "$LAB_HOME/scripts/"*.sh 2>/dev/null || true
  chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts"
}

###############################################################################
# ─── LAB 2: ZAP + NESSUS ─────────────────────────────────────────────────────
###############################################################################
fix_zap_dir() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing ZAP data directory..."
  mkdir -p "$LAB_HOME/.ZAP/policies"
  chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/.ZAP"
}

fix_zap_log() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating ZAP log file..."
  touch /var/log/zap-daemon.log
  chown "$LAB_USER:$LAB_USER" /var/log/zap-daemon.log
}

fix_zap_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Rewriting zap-daemon.service..."
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
  systemctl enable zap-daemon
  systemctl restart zap-daemon
  echo -e "  ${GREEN}${PASS_SYM}${NC} ZAP daemon service restarted."
}

fix_zap_symlink() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating zap symlink..."
  chmod +x "$ZAP_DIR/zap.sh"
  ln -sf "$ZAP_DIR/zap.sh" /usr/local/bin/zap
}

check_lab2() {
  section "LAB 2 — OWASP ZAP + Nessus"

  # Java (required for ZAP)
  subsection "Java 17 (ZAP dependency)"
  if command -v java &>/dev/null; then
    local jver
    jver=$(java -version 2>&1 | head -1)
    pass "Java available: $jver"
  else
    fail "Java not found (required for ZAP)" "fix_java17"
  fi

  # ZAP directories and files
  subsection "ZAP Installation"
  if [ -d "$ZAP_DIR" ]; then
    pass "ZAP directory: $ZAP_DIR"
  else
    fail "ZAP directory missing: $ZAP_DIR" ""
  fi
  if [ -f "$ZAP_DIR/zap.sh" ]; then
    pass "ZAP launcher: $ZAP_DIR/zap.sh"
  else
    fail "ZAP launcher missing: $ZAP_DIR/zap.sh" ""
  fi
  if [ -x "$ZAP_DIR/zap.sh" ]; then
    pass "zap.sh is executable"
  else
    fail "zap.sh is not executable" "fix_zap_symlink"
  fi
  if [ -L /usr/local/bin/zap ] || [ -f /usr/local/bin/zap ]; then
    pass "zap command available at /usr/local/bin/zap"
  else
    warn "zap symlink missing from /usr/local/bin"
    FIX_QUEUE+=("fix_zap_symlink")
  fi

  # ZAP data directory
  subsection "ZAP Data Directory"
  if [ -d "$LAB_HOME/.ZAP" ]; then
    pass "ZAP data directory: $LAB_HOME/.ZAP"
    local owner
    owner=$(stat -c '%U' "$LAB_HOME/.ZAP" 2>/dev/null)
    if [ "$owner" = "$LAB_USER" ]; then
      pass ".ZAP owned by $LAB_USER"
    else
      fail ".ZAP owned by $owner (should be $LAB_USER)" "fix_zap_dir"
    fi
  else
    fail "ZAP data directory missing: $LAB_HOME/.ZAP" "fix_zap_dir"
  fi
  if [ -d "$LAB_HOME/.ZAP/policies" ]; then
    pass "ZAP policies directory exists"
  else
    warn "ZAP policies directory missing"
    FIX_QUEUE+=("fix_zap_dir")
  fi

  # ZAP log
  subsection "ZAP Log"
  if [ -f /var/log/zap-daemon.log ]; then
    pass "ZAP log file: /var/log/zap-daemon.log"
    local log_owner
    log_owner=$(stat -c '%U' /var/log/zap-daemon.log 2>/dev/null)
    if [ "$log_owner" = "$LAB_USER" ]; then
      pass "ZAP log owned by $LAB_USER"
    else
      fail "ZAP log owned by $log_owner (should be $LAB_USER)" "fix_zap_log"
    fi
  else
    fail "ZAP log file missing: /var/log/zap-daemon.log" "fix_zap_log"
  fi

  # ZAP systemd service
  subsection "ZAP Daemon Service"
  if [ -f /etc/systemd/system/zap-daemon.service ]; then
    pass "zap-daemon.service unit file exists"
    # Check service config contents
    if grep -q "api.key=$ZAP_API_KEY" /etc/systemd/system/zap-daemon.service 2>/dev/null; then
      pass "ZAP API key configured in service: $ZAP_API_KEY"
    else
      fail "ZAP API key not found in service unit" "fix_zap_service"
    fi
    if grep -q "port 8090" /etc/systemd/system/zap-daemon.service 2>/dev/null; then
      pass "ZAP daemon port: 8090"
    else
      warn "ZAP daemon port may not be 8090 — check service config"
    fi
    if grep -q "User=$LAB_USER" /etc/systemd/system/zap-daemon.service 2>/dev/null; then
      pass "ZAP service runs as $LAB_USER"
    else
      warn "ZAP service user may not match $LAB_USER"
      FIX_QUEUE+=("fix_zap_service")
    fi
  else
    fail "zap-daemon.service unit file missing" "fix_zap_service"
  fi
  if systemctl is-enabled zap-daemon &>/dev/null; then
    pass "zap-daemon enabled at boot"
  else
    warn "zap-daemon not enabled at boot"
  fi
  if systemctl is-active zap-daemon &>/dev/null; then
    pass "zap-daemon.service: RUNNING"
  else
    fail "zap-daemon.service: STOPPED" "fix_zap_service"
  fi

  # ZAP API
  subsection "ZAP API"
  local zap_ver
  zap_ver=$(curl -sf --max-time 5 "http://localhost:$ZAP_PORT/JSON/core/view/version/?apikey=$ZAP_API_KEY" 2>/dev/null | jq -r '.version' 2>/dev/null || echo "unreachable")
  if [ "$zap_ver" != "unreachable" ] && [ -n "$zap_ver" ]; then
    pass "ZAP API responding: version=$zap_ver (http://$THIS_IP:$ZAP_PORT)"
  else
    fail "ZAP API not responding on port $ZAP_PORT" ""
    info "ZAP can take 1-2 minutes to start. Try: sudo systemctl restart zap-daemon"
  fi

  # Python tools
  subsection "Python Tools"
  if command -v python3 &>/dev/null; then
    pass "python3 available: $(python3 --version 2>&1)"
  else
    warn "python3 not found"
  fi
  if command -v pip3 &>/dev/null; then
    pass "pip3 available"
  else
    warn "pip3 not found"
  fi
  for pymod in requests bs4; do
    if python3 -c "import $pymod" 2>/dev/null; then
      pass "Python module available: $pymod"
    else
      warn "Python module missing: $pymod (run: pip3 install requests beautifulsoup4)"
    fi
  done

  # nmap / nikto / sqlmap
  subsection "Security Tools"
  for tool in nmap nikto; do
    if command -v "$tool" &>/dev/null; then
      pass "$tool installed"
    else
      warn "$tool not installed (apt-get install $tool)"
    fi
  done
  if [ -d /opt/sqlmap ] || command -v sqlmap &>/dev/null; then
    pass "sqlmap installed"
  else
    warn "sqlmap not installed"
  fi

  # Nessus
  subsection "Nessus Essentials"
  if dpkg -l nessus 2>/dev/null | grep -q '^ii'; then
    pass "Nessus package installed"
    if systemctl is-active nessusd &>/dev/null; then
      pass "nessusd service: RUNNING"
      info "Nessus Web UI: https://$THIS_IP:$NESSUS_PORT"
    else
      fail "nessusd service: STOPPED" "fix_nessus_service"
    fi
    if systemctl is-enabled nessusd &>/dev/null; then
      pass "nessusd enabled at boot"
    else
      warn "nessusd not enabled at boot"
    fi
  else
    warn "Nessus not installed (may need manual .deb download)"
    if [ -f "$LAB_HOME/scripts/install-nessus-manual.sh" ]; then
      info "Manual install script: ~/scripts/install-nessus-manual.sh"
    fi
  fi

  # Helper scripts
  subsection "Helper Scripts"
  for s in check-status.sh zap-scan.sh zap-export-ca.sh; do
    if [ -f "$LAB_HOME/scripts/$s" ]; then
      pass "Helper script: ~/scripts/$s"
    else
      warn "Helper script missing: ~/scripts/$s"
      FIX_QUEUE+=("fix_lab2_scripts")
    fi
  done

  # Setup log
  subsection "Setup Log"
  if [ -f /var/log/vm02-setup.log ]; then
    pass "Setup log: /var/log/vm02-setup.log"
  else
    warn "Setup log not found: /var/log/vm02-setup.log"
  fi
}

fix_nessus_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Starting Nessus..."
  systemctl enable nessusd 2>/dev/null || true
  systemctl start nessusd 2>/dev/null || true
}

fix_lab2_scripts() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Recreating Lab 2 helper scripts..."
  mkdir -p "$LAB_HOME/scripts"

  cat > "$LAB_HOME/scripts/check-status.sh" << SCRIPT
#!/bin/bash
echo "=== VM-02 Service Status ==="
echo ""
echo "--- OWASP ZAP Daemon ---"
if systemctl is-active zap-daemon &>/dev/null; then
  echo "Status: RUNNING"
  ZAP_VER=\$(curl -sf 'http://localhost:$ZAP_PORT/JSON/core/view/version/?apikey=$ZAP_API_KEY' 2>/dev/null | jq -r '.version' 2>/dev/null || echo "unknown")
  echo "Version: \$ZAP_VER"
  echo "API: http://localhost:$ZAP_PORT"
else
  echo "Status: STOPPED"
  echo "Start with: sudo systemctl start zap-daemon"
fi
echo ""
echo "--- Nessus ---"
if systemctl is-active nessusd &>/dev/null; then
  echo "Status: RUNNING"
  echo "Web UI: https://\$(hostname -I | awk '{print \$1}'):$NESSUS_PORT"
else
  echo "Status: STOPPED (or not installed)"
  echo "Start with: sudo systemctl start nessusd"
fi
echo ""
echo "--- Disk / Memory ---"
df -h / | tail -1 | awk '{print "Disk Used: " \$3 " / " \$2 " (" \$5 ")"}'
free -h | grep Mem | awk '{print "RAM Used: " \$3 " / " \$2}'
SCRIPT

  cat > "$LAB_HOME/scripts/zap-scan.sh" << SCRIPT
#!/bin/bash
TARGET=\${1:?"Usage: \$0 <target-url> [passive|active|spider]"}
SCAN_TYPE=\${2:-passive}
ZAP_API="http://localhost:$ZAP_PORT"
APIKEY="$ZAP_API_KEY"

echo "Starting ZAP \$SCAN_TYPE scan on \$TARGET..."
curl -sf "\$ZAP_API/JSON/core/action/accessUrl/?apikey=\$APIKEY&url=\$TARGET" >/dev/null

case "\$SCAN_TYPE" in
  passive)
    SCAN_ID=\$(curl -sf "\$ZAP_API/JSON/spider/action/scan/?apikey=\$APIKEY&url=\$TARGET" | jq -r '.scan')
    echo "Spider scan ID: \$SCAN_ID"
    while true; do
      P=\$(curl -sf "\$ZAP_API/JSON/spider/view/status/?apikey=\$APIKEY&scanId=\$SCAN_ID" | jq -r '.status')
      echo "  Progress: \$P%"
      [ "\$P" = "100" ] && break
      sleep 5
    done
    ;;
  active)
    SCAN_ID=\$(curl -sf "\$ZAP_API/JSON/ascan/action/scan/?apikey=\$APIKEY&url=\$TARGET&recurse=true" | jq -r '.scan')
    echo "Active scan ID: \$SCAN_ID"
    while true; do
      P=\$(curl -sf "\$ZAP_API/JSON/ascan/view/status/?apikey=\$APIKEY&scanId=\$SCAN_ID" | jq -r '.status')
      echo "  Progress: \$P%"
      [ "\$P" = "100" ] && break
      sleep 10
    done
    ;;
esac

echo ""
echo "Scan complete. Fetching alerts..."
curl -sf "\$ZAP_API/JSON/alert/view/alerts/?apikey=\$APIKEY&baseurl=\$TARGET" | jq '.alerts[] | {risk:.risk, name:.alert, url:.url}' 2>/dev/null || echo "No alerts found or jq not available."
SCRIPT

  cat > "$LAB_HOME/scripts/zap-export-ca.sh" << SCRIPT
#!/bin/bash
OUTPUT="\${1:-$LAB_HOME/zap-root-ca.cer}"
curl -sf "http://localhost:$ZAP_PORT/OTHER/core/other/rootcert/?apikey=$ZAP_API_KEY" -o "\$OUTPUT"
if [ -f "\$OUTPUT" ]; then
  echo "ZAP Root CA exported to: \$OUTPUT"
  echo "Import this into your browser to intercept HTTPS traffic."
else
  echo "Export failed — is ZAP running? (sudo systemctl status zap-daemon)"
fi
SCRIPT

  chmod +x "$LAB_HOME/scripts/"*.sh 2>/dev/null || true
  chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts"
}

###############################################################################
# ─── LAB 3: DVWA + VULNSHOP ──────────────────────────────────────────────────
###############################################################################

# PHP INI detection helper
get_php_ini_apache() {
  find /etc/php -name "php.ini" -path "*/apache2/*" 2>/dev/null | head -1
}
get_php_ini_cli() {
  find /etc/php -name "php.ini" -path "*/cli/*" 2>/dev/null | head -1
}

fix_apache_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Enabling and restarting Apache2..."
  a2enmod rewrite headers 2>/dev/null || true
  systemctl enable apache2
  systemctl restart apache2
}

fix_mariadb_service() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Enabling and starting MariaDB..."
  systemctl enable mariadb
  systemctl start mariadb
}

fix_dvwa_db() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating/repairing DVWA database..."
  mysql -e "CREATE DATABASE IF NOT EXISTS $DVWA_DB_NAME;" 2>/dev/null
  mysql -e "CREATE USER IF NOT EXISTS '$DVWA_DB_USER'@'localhost' IDENTIFIED BY '$DVWA_DB_PASS';" 2>/dev/null || true
  mysql -e "GRANT ALL ON $DVWA_DB_NAME.* TO '$DVWA_DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
  # Initialize DVWA tables via setup.php
  curl -s -o /dev/null -X POST -d "create_db=Create+%2F+Reset+Database" \
    "http://localhost/dvwa/setup.php" 2>/dev/null || true
  echo -e "  ${GREEN}${PASS_SYM}${NC} DVWA database initialized."
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
}

fix_dvwa_permissions() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing DVWA permissions..."
  chown -R www-data:www-data "$DVWA_DIR"
  chmod -R 755 "$DVWA_DIR"
  chmod 777 "$DVWA_DIR/hackable/uploads/" 2>/dev/null || true
  chmod 777 "$DVWA_DIR/config/" 2>/dev/null || true
  chmod 666 "$DVWA_DIR/external/phpids/0.6/lib/IDS/tmp/phpids_log.txt" 2>/dev/null || true
}

fix_php_ini() {
  local ini
  ini=$(get_php_ini_apache)
  if [ -z "$ini" ]; then
    echo -e "  ${YELLOW}${WARN_SYM}${NC} Could not find Apache php.ini"
    return
  fi
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing PHP ini settings in $ini..."
  sed -i 's/^[;[:space:]]*allow_url_include[[:space:]]*=.*/allow_url_include = On/'  "$ini"
  sed -i 's/^[;[:space:]]*allow_url_fopen[[:space:]]*=.*/allow_url_fopen = On/'     "$ini"
  sed -i 's/^[;[:space:]]*display_errors[[:space:]]*=.*/display_errors = On/'       "$ini"
  sed -i 's/^[;[:space:]]*expose_php[[:space:]]*=.*/expose_php = On/'               "$ini"
  sed -i 's/^[;[:space:]]*file_uploads[[:space:]]*=.*/file_uploads = On/'           "$ini"
  systemctl restart apache2 2>/dev/null || true
  echo -e "  ${GREEN}${PASS_SYM}${NC} PHP ini updated and Apache restarted."
}

fix_apache_dvwa_vhost() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Enabling AllowOverride All for /var/www/html..."
  sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf 2>/dev/null || true
  systemctl reload apache2 2>/dev/null || true
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
  grep -q "^Listen $VULNSHOP_PORT" /etc/apache2/ports.conf 2>/dev/null || echo "Listen $VULNSHOP_PORT" >> /etc/apache2/ports.conf
  a2enmod rewrite 2>/dev/null || true
  a2ensite vulnshop.conf 2>/dev/null || true
  apache2ctl configtest 2>/dev/null && systemctl reload apache2 2>/dev/null || systemctl restart apache2 2>/dev/null
  echo -e "  ${GREEN}${PASS_SYM}${NC} VulnShop vhost enabled and Apache reloaded."
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
  chown www-data:www-data "$VULNSHOP_DIR/.env"
}

fix_vulnshop_composer() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Running composer install for VulnShop..."
  cd "$VULNSHOP_DIR"
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --optimize-autoloader 2>/dev/null || true
  chown -R www-data:www-data "$VULNSHOP_DIR/vendor" 2>/dev/null || true
}

fix_vulnshop_db() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Creating/repairing VulnShop database..."
  mysql -e "CREATE DATABASE IF NOT EXISTS $VULNSHOP_DB_NAME;" 2>/dev/null
  mysql -e "CREATE USER IF NOT EXISTS '$VULNSHOP_DB_USER'@'localhost' IDENTIFIED BY '$VULNSHOP_DB_PASS';" 2>/dev/null || true
  mysql -e "GRANT ALL ON $VULNSHOP_DB_NAME.* TO '$VULNSHOP_DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
  cd "$VULNSHOP_DIR"
  git config --global user.email "lab@lab.local" 2>/dev/null || true
  git config --global user.name "Lab Setup" 2>/dev/null || true
  php artisan migrate --force 2>/dev/null || true
  php artisan db:seed --force 2>/dev/null || true
  echo -e "  ${GREEN}${PASS_SYM}${NC} VulnShop database migrated and seeded."
}

fix_vulnshop_storage() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Fixing VulnShop storage permissions..."
  chmod -R 775 "$VULNSHOP_DIR/storage" "$VULNSHOP_DIR/bootstrap/cache" 2>/dev/null || true
  chown -R www-data:www-data "$VULNSHOP_DIR/storage" "$VULNSHOP_DIR/bootstrap/cache" 2>/dev/null || true
  cd "$VULNSHOP_DIR"
  php artisan storage:link 2>/dev/null || true
  php artisan cache:clear 2>/dev/null || true
  php artisan config:clear 2>/dev/null || true
}

check_lab3() {
  section "LAB 3 — Target Apps (DVWA + VulnShop)"

  # Packages
  subsection "Required Packages"
  local pkgs=(apache2 mariadb-server php php-mysql php-gd php-xml php-mbstring php-curl php-zip php-bcmath php-intl)
  for pkg in "${pkgs[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      pass "Package installed: $pkg"
    else
      fail "Package missing: $pkg" ""
    fi
  done
  if [ ! -f /usr/local/bin/composer ]; then
    fail "Composer not installed at /usr/local/bin/composer" "fix_vulnshop_composer"
  else
    pass "Composer installed: $(composer --version 2>&1 | head -1)"
  fi

  # Apache
  subsection "Apache2 Service"
  if systemctl is-active apache2 &>/dev/null; then
    pass "apache2 service: RUNNING"
  else
    fail "apache2 service: STOPPED" "fix_apache_service"
  fi
  if systemctl is-enabled apache2 &>/dev/null; then
    pass "apache2 enabled at boot"
  else
    warn "apache2 not enabled at boot"
  fi
  # mod_rewrite
  if apache2ctl -M 2>/dev/null | grep -q 'rewrite'; then
    pass "mod_rewrite: enabled"
  else
    fail "mod_rewrite: not enabled" "fix_apache_service"
  fi
  # AllowOverride
  if grep -q 'AllowOverride All' /etc/apache2/apache2.conf 2>/dev/null; then
    pass "AllowOverride All set in apache2.conf"
  else
    fail "AllowOverride not set to All in apache2.conf (DVWA/.htaccess won't work)" "fix_apache_dvwa_vhost"
  fi

  # MariaDB
  subsection "MariaDB Service"
  if systemctl is-active mariadb &>/dev/null; then
    pass "mariadb service: RUNNING"
  else
    fail "mariadb service: STOPPED" "fix_mariadb_service"
  fi
  if systemctl is-enabled mariadb &>/dev/null; then
    pass "mariadb enabled at boot"
  else
    warn "mariadb not enabled at boot"
  fi

  # PHP configuration
  subsection "PHP Configuration"
  local php_ini
  php_ini=$(get_php_ini_apache)
  if [ -n "$php_ini" ]; then
    pass "PHP ini (Apache): $php_ini"
    # Check critical settings
    local settings=("allow_url_include" "allow_url_fopen" "display_errors" "file_uploads")
    for setting in "${settings[@]}"; do
      local val
      val=$(grep -E "^[;[:space:]]*${setting}[[:space:]]*=" "$php_ini" 2>/dev/null | tail -1 | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]')
      if echo "$val" | grep -qi "^On$"; then
        pass "PHP: $setting = On"
      elif echo "$val" | grep -qi "^Off$"; then
        fail "PHP: $setting = Off (need On for lab exercises)" "fix_php_ini"
      else
        warn "PHP: $setting = '$val' — may need to be 'On'"
      fi
    done
  else
    warn "Could not find Apache PHP ini (PHP may not be installed)"
  fi
  # PHP version
  if command -v php &>/dev/null; then
    pass "PHP: $(php --version 2>&1 | head -1)"
  else
    fail "php command not found" ""
  fi

  # ── DVWA ──────────────────────────────────────────────────────────────────
  if [ -d "$DVWA_DIR" ]; then
    subsection "DVWA Installation"
    pass "DVWA directory: $DVWA_DIR"

    # Config file
    if [ -f "$DVWA_DIR/config/config.inc.php" ]; then
      pass "DVWA config: $DVWA_DIR/config/config.inc.php"
      if grep -q "db_user.*$DVWA_DB_USER" "$DVWA_DIR/config/config.inc.php" 2>/dev/null; then
        pass "DVWA config: db_user=$DVWA_DB_USER"
      else
        fail "DVWA config: db_user not set to '$DVWA_DB_USER'" "fix_dvwa_config"
      fi
      if grep -q "db_password.*$DVWA_DB_PASS" "$DVWA_DIR/config/config.inc.php" 2>/dev/null; then
        pass "DVWA config: db_password set"
      else
        fail "DVWA config: db_password incorrect" "fix_dvwa_config"
      fi
      if grep -q "db_database.*$DVWA_DB_NAME" "$DVWA_DIR/config/config.inc.php" 2>/dev/null; then
        pass "DVWA config: db_database=$DVWA_DB_NAME"
      else
        fail "DVWA config: db_database not set to '$DVWA_DB_NAME'" "fix_dvwa_config"
      fi
      local sec_level
      sec_level=$(grep "default_security_level" "$DVWA_DIR/config/config.inc.php" 2>/dev/null | grep -oP "'[^']+'" | tail -1 | tr -d "'")
      if [ "$sec_level" = "low" ]; then
        pass "DVWA security level: low (good for labs)"
      else
        warn "DVWA security level: ${sec_level:-unknown} (recommend 'low' for labs)"
      fi
    elif [ -f "$DVWA_DIR/config/config.inc.php.dist" ]; then
      fail "DVWA config not created from .dist template" "fix_dvwa_config"
    else
      fail "DVWA config file missing entirely" "fix_dvwa_config"
    fi

    # Key DVWA files
    subsection "DVWA Files"
    for f in index.php login.php setup.php; do
      [ -f "$DVWA_DIR/$f" ] && pass "DVWA file: $f" || fail "DVWA file missing: $f" ""
    done
    [ -d "$DVWA_DIR/hackable/uploads" ] && pass "DVWA uploads dir exists" || fail "DVWA uploads dir missing" "fix_dvwa_permissions"

    # Permissions
    subsection "DVWA Permissions"
    local downer
    downer=$(stat -c '%U' "$DVWA_DIR" 2>/dev/null)
    if [ "$downer" = "www-data" ]; then
      pass "DVWA owned by www-data"
    else
      fail "DVWA owned by $downer (should be www-data)" "fix_dvwa_permissions"
    fi
    local uploads_perm
    uploads_perm=$(stat -c '%a' "$DVWA_DIR/hackable/uploads" 2>/dev/null)
    if [ "$uploads_perm" = "777" ]; then
      pass "DVWA uploads/ permissions: 777"
    else
      fail "DVWA uploads/ permissions: $uploads_perm (should be 777)" "fix_dvwa_permissions"
    fi
    local config_perm
    config_perm=$(stat -c '%a' "$DVWA_DIR/config" 2>/dev/null)
    if [ "$config_perm" = "777" ]; then
      pass "DVWA config/ permissions: 777"
    else
      fail "DVWA config/ permissions: $config_perm (should be 777)" "fix_dvwa_permissions"
    fi

    # DVWA database
    subsection "DVWA Database"
    if mysql -u "$DVWA_DB_USER" -p"$DVWA_DB_PASS" -e "USE $DVWA_DB_NAME; SELECT 1;" &>/dev/null; then
      pass "DVWA DB connection OK ($DVWA_DB_USER@localhost/$DVWA_DB_NAME)"
    else
      fail "Cannot connect to DVWA DB" "fix_dvwa_db"
    fi
    if mysql -u "$DVWA_DB_USER" -p"$DVWA_DB_PASS" "$DVWA_DB_NAME" -e "SHOW TABLES;" 2>/dev/null | grep -q 'users'; then
      pass "DVWA DB tables exist (initialized)"
    else
      fail "DVWA DB not initialized (tables missing)" "fix_dvwa_db"
    fi

    # DVWA HTTP
    subsection "DVWA HTTP"
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost/dvwa/login.php" 2>/dev/null || echo "0")
    case "$http_code" in
      200) pass "DVWA login page: HTTP $http_code (http://$THIS_IP/dvwa/login.php)" ;;
      302) pass "DVWA redirecting: HTTP $http_code (may be normal)" ;;
      500) fail "DVWA returns HTTP 500 — check PHP config and db credentials" "fix_dvwa_config" ;;
      0)   fail "DVWA not responding — Apache may be down" "fix_apache_service" ;;
      *)   warn "DVWA returned HTTP $http_code (expected 200 or 302)" ;;
    esac
  fi

  # ── VULNSHOP ──────────────────────────────────────────────────────────────
  if [ -d "$VULNSHOP_DIR" ]; then
    subsection "VulnShop Installation"
    pass "VulnShop directory: $VULNSHOP_DIR"

    # Apache vhost
    subsection "VulnShop Virtual Host"
    if [ -f /etc/apache2/sites-available/vulnshop.conf ]; then
      pass "vulnshop.conf vhost file exists"
    else
      fail "vulnshop.conf missing from sites-available" "fix_vulnshop_vhost"
    fi
    if [ -f /etc/apache2/sites-enabled/vulnshop.conf ] || [ -L /etc/apache2/sites-enabled/vulnshop.conf ]; then
      pass "vulnshop.conf is enabled (sites-enabled)"
    else
      fail "vulnshop.conf not enabled (a2ensite vulnshop.conf not run)" "fix_vulnshop_vhost"
    fi
    if grep -q "^Listen $VULNSHOP_PORT" /etc/apache2/ports.conf 2>/dev/null; then
      pass "Apache listening on port $VULNSHOP_PORT"
    else
      fail "Apache not configured to listen on port $VULNSHOP_PORT" "fix_vulnshop_vhost"
    fi
    if [ -f /etc/apache2/sites-available/vulnshop.conf ]; then
      if grep -q "DocumentRoot.*$VULNSHOP_DIR/public" /etc/apache2/sites-available/vulnshop.conf 2>/dev/null; then
        pass "VulnShop DocumentRoot points to $VULNSHOP_DIR/public"
      else
        warn "VulnShop DocumentRoot may not point to $VULNSHOP_DIR/public"
      fi
    fi

    # .env
    subsection "VulnShop .env"
    if [ -f "$VULNSHOP_DIR/.env" ]; then
      pass ".env file exists"
      if grep -q "DB_DATABASE=$VULNSHOP_DB_NAME" "$VULNSHOP_DIR/.env" 2>/dev/null; then
        pass ".env: DB_DATABASE=$VULNSHOP_DB_NAME"
      else
        fail ".env: DB_DATABASE not set to '$VULNSHOP_DB_NAME'" "fix_vulnshop_env"
      fi
      if grep -q "DB_USERNAME=$VULNSHOP_DB_USER" "$VULNSHOP_DIR/.env" 2>/dev/null; then
        pass ".env: DB_USERNAME=$VULNSHOP_DB_USER"
      else
        fail ".env: DB_USERNAME not set to '$VULNSHOP_DB_USER'" "fix_vulnshop_env"
      fi
      # Check APP_KEY is not empty
      local app_key
      app_key=$(grep "^APP_KEY=" "$VULNSHOP_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
      if [ -n "$app_key" ] && [ "$app_key" != "=" ]; then
        pass ".env: APP_KEY is set"
      else
        fail ".env: APP_KEY is empty (artisan key:generate needed)" "fix_vulnshop_env"
      fi
      if grep -q "APP_URL=http://localhost:$VULNSHOP_PORT" "$VULNSHOP_DIR/.env" 2>/dev/null; then
        pass ".env: APP_URL=http://localhost:$VULNSHOP_PORT"
      else
        warn ".env: APP_URL may not match port $VULNSHOP_PORT"
      fi
    else
      fail ".env file missing" "fix_vulnshop_env"
    fi

    # vendor/
    subsection "VulnShop Composer Dependencies"
    if [ -d "$VULNSHOP_DIR/vendor" ]; then
      pass "vendor/ directory exists"
    else
      fail "vendor/ directory missing (composer install not run)" "fix_vulnshop_composer"
    fi
    if [ -f "$VULNSHOP_DIR/vendor/autoload.php" ]; then
      pass "vendor/autoload.php exists"
    else
      fail "vendor/autoload.php missing" "fix_vulnshop_composer"
    fi

    # Storage permissions
    subsection "VulnShop Storage Permissions"
    for sd in storage storage/logs storage/framework storage/framework/cache storage/framework/sessions storage/framework/views bootstrap/cache; do
      if [ -d "$VULNSHOP_DIR/$sd" ]; then
        local sperm
        sperm=$(stat -c '%a' "$VULNSHOP_DIR/$sd" 2>/dev/null)
        if [ "$sperm" = "775" ] || [ "$sperm" = "777" ]; then
          pass "VulnShop $sd: permissions $sperm"
        else
          fail "VulnShop $sd: permissions $sperm (need 775 or 777)" "fix_vulnshop_storage"
        fi
      else
        fail "VulnShop $sd: directory missing" "fix_vulnshop_storage"
      fi
    done
    local vs_owner
    vs_owner=$(stat -c '%U' "$VULNSHOP_DIR/storage" 2>/dev/null)
    if [ "$vs_owner" = "www-data" ]; then
      pass "VulnShop storage owned by www-data"
    else
      fail "VulnShop storage owned by $vs_owner (should be www-data)" "fix_vulnshop_storage"
    fi

    # VulnShop database
    subsection "VulnShop Database"
    if mysql -u "$VULNSHOP_DB_USER" -p"$VULNSHOP_DB_PASS" -e "USE $VULNSHOP_DB_NAME; SELECT 1;" &>/dev/null; then
      pass "VulnShop DB connection OK ($VULNSHOP_DB_USER@localhost/$VULNSHOP_DB_NAME)"
    else
      fail "Cannot connect to VulnShop DB" "fix_vulnshop_db"
    fi
    for tbl in users products orders; do
      if mysql -u "$VULNSHOP_DB_USER" -p"$VULNSHOP_DB_PASS" "$VULNSHOP_DB_NAME" -e "DESCRIBE $tbl;" &>/dev/null; then
        pass "VulnShop DB: table '$tbl' exists"
      else
        fail "VulnShop DB: table '$tbl' missing (migrations not run)" "fix_vulnshop_db"
      fi
    done

    # VulnShop HTTP
    subsection "VulnShop HTTP"
    local vs_code
    vs_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:$VULNSHOP_PORT" 2>/dev/null || echo "0")
    case "$vs_code" in
      200|301|302) pass "VulnShop HTTP: $vs_code (http://$THIS_IP:$VULNSHOP_PORT)" ;;
      403) fail "VulnShop HTTP: 403 Forbidden — check DocumentRoot and permissions" "fix_vulnshop_storage" ;;
      404) fail "VulnShop HTTP: 404 — vhost may not point to /public" "fix_vulnshop_vhost" ;;
      500) fail "VulnShop HTTP: 500 — check .env, storage permissions, composer" "fix_vulnshop_storage" ;;
      0)   fail "VulnShop not responding — Apache may be down or port $VULNSHOP_PORT not open" "fix_vulnshop_vhost" ;;
      *)   warn "VulnShop returned HTTP $vs_code" ;;
    esac

    # VulnShop log
    subsection "VulnShop Log"
    local vs_log="$VULNSHOP_DIR/storage/logs/laravel.log"
    if [ -f "$vs_log" ]; then
      pass "VulnShop log: $vs_log"
      # Check for recent errors
      local err_count
      err_count=$(grep -c "\[ERROR\]\|\[CRITICAL\]\|PHP Fatal" "$vs_log" 2>/dev/null || echo "0")
      if [ "$err_count" -gt 0 ]; then
        warn "VulnShop log has $err_count error(s) — check $vs_log"
        tail -3 "$vs_log" | while IFS= read -r line; do info "  $line"; done
      else
        pass "VulnShop log: no critical errors"
      fi
    else
      warn "VulnShop log not yet created: $vs_log"
    fi
  fi

  # Setup log
  subsection "Setup Log"
  if [ -f /var/log/vm03-setup.log ]; then
    pass "Setup log: /var/log/vm03-setup.log"
  else
    warn "Setup log not found: /var/log/vm03-setup.log"
  fi

  # Helper scripts
  subsection "Helper Scripts"
  for s in check-status.sh reset-dvwa-db.sh; do
    if [ -f "$LAB_HOME/scripts/$s" ]; then
      pass "Helper script: ~/scripts/$s"
    else
      warn "Helper script missing: ~/scripts/$s"
      FIX_QUEUE+=("fix_lab3_scripts")
    fi
  done
}

fix_lab3_scripts() {
  echo -e "  ${CYAN}${FIX_SYM}${NC} Recreating Lab 3 helper scripts..."
  mkdir -p "$LAB_HOME/scripts"

  cat > "$LAB_HOME/scripts/check-status.sh" << SCRIPT
#!/bin/bash
echo "=== VM-03 Service Status ==="
echo ""
echo "--- Apache2 ---"
systemctl is-active apache2 && echo "Status: RUNNING" || echo "Status: STOPPED"
echo ""
echo "--- MariaDB ---"
systemctl is-active mariadb && echo "Status: RUNNING" || echo "Status: STOPPED"
echo ""
echo "--- DVWA ---"
CODE=\$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 http://localhost/dvwa/login.php 2>/dev/null || echo "0")
echo "HTTP: \$CODE  —  http://\$(hostname -I | awk '{print \$1}')/dvwa/login.php"
echo ""
echo "--- VulnShop ---"
CODE=\$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:$VULNSHOP_PORT 2>/dev/null || echo "0")
echo "HTTP: \$CODE  —  http://\$(hostname -I | awk '{print \$1}'):$VULNSHOP_PORT"
echo ""
echo "--- Disk / Memory ---"
df -h / | tail -1 | awk '{print "Disk Used: " \$3 " / " \$2 " (" \$5 ")"}'
free -h | grep Mem | awk '{print "RAM Used: " \$3 " / " \$2}'
SCRIPT

  cat > "$LAB_HOME/scripts/reset-dvwa-db.sh" << SCRIPT
#!/bin/bash
echo "Resetting DVWA database..."
mysql -e "DROP DATABASE IF EXISTS $DVWA_DB_NAME; CREATE DATABASE $DVWA_DB_NAME;"
mysql -e "GRANT ALL ON $DVWA_DB_NAME.* TO '$DVWA_DB_USER'@'localhost' IDENTIFIED BY '$DVWA_DB_PASS'; FLUSH PRIVILEGES;"
curl -s -o /dev/null -X POST -d "create_db=Create+%2F+Reset+Database" http://localhost/dvwa/setup.php
echo "Done. Visit http://\$(hostname -I | awk '{print \$1}')/dvwa/setup.php to verify."
SCRIPT

  cat > "$LAB_HOME/scripts/reset-vulnshop.sh" << SCRIPT
#!/bin/bash
echo "Resetting VulnShop database..."
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
# ─── FIREWALL CHECKS ─────────────────────────────────────────────────────────
###############################################################################
check_firewall() {
  section "FIREWALL (UFW)"
  if ! command -v ufw &>/dev/null; then
    warn "ufw not installed"
    return
  fi
  local ufw_status
  ufw_status=$(ufw status 2>/dev/null | head -1)
  if echo "$ufw_status" | grep -qi "active"; then
    pass "UFW: active"
  else
    warn "UFW: inactive (lab ports not enforced)"
  fi

  local needed_ports=()
  $HAS_LAB1 && needed_ports+=(9000)
  $HAS_LAB2 && needed_ports+=(8090 8834)
  $HAS_LAB3 && needed_ports+=(80 8080)

  for port in "${needed_ports[@]}"; do
    if ufw status 2>/dev/null | grep -qE "^${port}"; then
      pass "UFW: port $port allowed"
    else
      warn "UFW: port $port not explicitly listed (may be blocked)"
    fi
  done
  if ufw status 2>/dev/null | grep -qiE "^22|^OpenSSH"; then
    pass "UFW: SSH (port 22) allowed"
  else
    warn "UFW: SSH may not be explicitly allowed"
  fi
}

###############################################################################
# ─── RUN ALL CHECKS ──────────────────────────────────────────────────────────
###############################################################################
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

# De-duplicate FIX_QUEUE
declare -a UNIQUE_FIXES=()
declare -A SEEN_FIXES=()
for fn in "${FIX_QUEUE[@]:-}"; do
  if [ -n "$fn" ] && [ -z "${SEEN_FIXES[$fn]:-}" ]; then
    UNIQUE_FIXES+=("$fn")
    SEEN_FIXES[$fn]=1
  fi
done

###############################################################################
# ─── FIX EXECUTION ───────────────────────────────────────────────────────────
###############################################################################
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}All critical checks passed! Your lab environment looks healthy.${NC}"
  echo ""
  if $HAS_LAB1; then
    echo -e "  SonarQube:  http://$THIS_IP:$SONAR_PORT  (admin / admin)"
  fi
  if $HAS_LAB2; then
    echo -e "  ZAP API:    http://$THIS_IP:$ZAP_PORT   (key: $ZAP_API_KEY)"
    echo -e "  Nessus:     https://$THIS_IP:$NESSUS_PORT"
  fi
  if $HAS_LAB3; then
    echo -e "  DVWA:       http://$THIS_IP/dvwa/        (admin / password)"
    echo -e "  VulnShop:   http://$THIS_IP:$VULNSHOP_PORT  (admin@vulnshop.local / admin123)"
  fi
  echo ""
  exit 0
fi

if [ "${#UNIQUE_FIXES[@]}" -eq 0 ]; then
  echo -e "${YELLOW}Some warnings detected but no auto-fixable issues found.${NC}"
  exit 0
fi

echo -e "${BOLD}Auto-fixable issues found: ${#UNIQUE_FIXES[@]} fix routine(s) queued.${NC}"
echo ""

case "$MODE" in
  check)
    echo -e "${YELLOW}Running in --check mode. No changes made.${NC}"
    echo -e "Re-run with ${BOLD}--fix${NC} to apply fixes automatically."
    exit 1
    ;;
  fix)
    echo -e "${CYAN}${BOLD}Auto-fix mode: applying all fixes...${NC}"
    echo ""
    for fn in "${UNIQUE_FIXES[@]}"; do
      if declare -f "$fn" > /dev/null 2>&1; then
        $fn
      else
        echo -e "  ${YELLOW}${WARN_SYM}${NC} Unknown fix function: $fn"
      fi
    done
    ;;
  interactive)
    echo -e "${BOLD}Would you like to apply all auto-fixes now?${NC}"
    read -r -p "Apply fixes? [y/N]: " APPLY
    if [[ "$APPLY" =~ ^[Yy]$ ]]; then
      echo ""
      for fn in "${UNIQUE_FIXES[@]}"; do
        if declare -f "$fn" > /dev/null 2>&1; then
          $fn
        else
          echo -e "  ${YELLOW}${WARN_SYM}${NC} Unknown fix function: $fn"
        fi
      done
    else
      echo "No fixes applied."
      exit 1
    fi
    ;;
esac

echo ""
echo -e "${GREEN}${BOLD}Fixes applied. Re-running health check to verify...${NC}"
echo ""
sleep 2

# Quick re-check of services
RECHECK_FAILS=0
check_svc() {
  local svc="$1"; local label="$2"
  if systemctl is-active "$svc" &>/dev/null; then
    echo -e "  ${GREEN}${PASS_SYM}${NC} $label: RUNNING"
  else
    echo -e "  ${RED}${FAIL_SYM}${NC} $label: STOPPED — manual intervention may be needed"
    ((RECHECK_FAILS++))
  fi
}

$HAS_LAB1 && check_svc postgresql "PostgreSQL"
$HAS_LAB1 && check_svc sonarqube  "SonarQube"
$HAS_LAB2 && check_svc zap-daemon "ZAP Daemon"
$HAS_LAB3 && check_svc mariadb    "MariaDB"
$HAS_LAB3 && check_svc apache2    "Apache2"

echo ""
if [ "$RECHECK_FAILS" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}All services running. Run healthcheck.sh again for full verification.${NC}"
else
  echo -e "${YELLOW}${BOLD}$RECHECK_FAILS service(s) still not running. Run 'sudo bash healthcheck.sh --fix' again.${NC}"
fi
echo ""
