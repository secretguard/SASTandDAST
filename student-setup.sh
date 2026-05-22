#!/bin/bash
###############################################################################
# SASTandDAST Lab — Student Setup (Docker Edition)
# Author: Sarath G | www.sarathg.me
#
# Usage:  sudo bash student-setup.sh   ← as a regular user via sudo
#         bash student-setup.sh        ← when already logged in as root
#
# What this does:
#   1. Installs Docker + Docker Compose (if not present)
#   2. Installs ZAP GUI (zaproxy) via apt or snap
#   3. Sets vm.max_map_count for SonarQube / Elasticsearch
#   4. Creates .env from .env.example (asks for Nessus activation code)
#   5. Runs `docker compose up -d --build`
#   6. Runs healthcheck --fix to verify and auto-recover any failing containers
###############################################################################

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

step()  { echo -e "\n${BOLD}${BLUE}[$1]${NC} $2"; }
ok()    { echo -e "  ${GREEN}✓${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
abort() { echo -e "\n${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     SAST & DAST Lab — Student Setup                         ║${NC}"
echo -e "${BOLD}║     Sarath G | www.sarathg.me                               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Root check ────────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && abort "Run with sudo: sudo bash student-setup.sh  (or as root directly)"

# ── Detect operator identity ──────────────────────────────────────────────────
# Three cases:
#   a) sudo bash student-setup.sh  → SUDO_USER is the real user
#   b) su -; bash student-setup.sh → SUDO_USER is empty, we are root directly
#   c) already logged in as root   → same as (b)
LAB_USER="${SUDO_USER:-}"
if [[ -z "$LAB_USER" || "$LAB_USER" = "root" ]]; then
  # Running directly as root — no non-root user in context
  LAB_USER="root"
  LAB_HOME="/root"
  RUNNING_AS_ROOT_DIRECTLY=true
else
  RUNNING_AS_ROOT_DIRECTLY=false
  LAB_HOME=$(getent passwd "$LAB_USER" 2>/dev/null | cut -d: -f6)
  [[ -z "$LAB_HOME" ]] && LAB_HOME="/home/$LAB_USER"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok "Operator: $LAB_USER  (home: $LAB_HOME)"

# ── OS check ─────────────────────────────────────────────────────────────────
if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu/Debian. Your OS may not be supported."
  read -r -p "  Continue anyway? [y/N]: " CONT
  [[ "$CONT" =~ ^[Yy]$ ]] || exit 0
fi

###############################################################################
# STEP 1 — Install Docker
###############################################################################
step "1/4" "Docker"

install_docker() {
  echo "  Installing Docker CE..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  ok "Docker installed: $(docker --version)"
}

if command -v docker &>/dev/null && docker info &>/dev/null; then
  ok "Docker already installed: $(docker --version)"
else
  install_docker
fi

if ! docker compose version &>/dev/null; then
  abort "docker compose not available. Ensure docker-compose-plugin is installed."
fi
ok "Docker Compose: $(docker compose version --short)"

# Add lab user to docker group so they can run docker without sudo after re-login
# (Skipped for root — root already has unrestricted access)
if [[ "$RUNNING_AS_ROOT_DIRECTLY" = false ]] && ! id -nG "$LAB_USER" | grep -qw docker; then
  usermod -aG docker "$LAB_USER"
  warn "User $LAB_USER added to 'docker' group. Log out and back in to use docker without sudo."
fi

###############################################################################
# STEP 2 — ZAP GUI (zaproxy desktop application)
###############################################################################
step "2/5" "ZAP GUI"

install_zap_gui() {
  # Try apt first (works on Kali Linux and Debian-based distros with zaproxy in repos)
  if apt-get install -y -qq zaproxy 2>/dev/null; then
    ok "ZAP GUI installed via apt: $(zaproxy --version 2>/dev/null | head -1 || echo 'zaproxy')"
    return 0
  fi

  # Fall back to snap
  if command -v snap &>/dev/null; then
    echo "  apt install failed — trying snap..."
    if snap install zaproxy --classic 2>/dev/null; then
      ok "ZAP GUI installed via snap"
      return 0
    fi
  fi

  warn "Could not install ZAP GUI automatically."
  warn "Download manually from: https://www.zaproxy.org/download/"
  warn "(The ZAP daemon for API scanning is still available via Docker on port 8090)"
  return 1
}

if command -v zaproxy &>/dev/null; then
  ok "ZAP GUI already installed: $(zaproxy --version 2>/dev/null | head -1 || echo 'zaproxy')"
else
  install_zap_gui
fi

###############################################################################
# STEP 3 — Kernel tuning (SonarQube / Elasticsearch requirement)
###############################################################################
step "3/5" "Kernel parameters"

CURRENT_MAP=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if [[ "$CURRENT_MAP" -lt 524288 ]]; then
  sysctl -w vm.max_map_count=524288 >/dev/null
  grep -q 'vm.max_map_count=524288' /etc/sysctl.conf 2>/dev/null \
    || echo 'vm.max_map_count=524288' >> /etc/sysctl.conf
  ok "vm.max_map_count set to 524288 (persisted to /etc/sysctl.conf)"
else
  ok "vm.max_map_count=$CURRENT_MAP (already sufficient)"
fi

###############################################################################
# STEP 4 — Environment file
###############################################################################
step "4/5" "Configuration"

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  ok "Created .env from .env.example"

  echo ""
  echo "  Nessus requires a free activation code from:"
  echo "  https://www.tenable.com/products/nessus/nessus-essentials"
  echo ""
  read -r -p "  Enter your Nessus activation code (or press Enter to skip): " NESSUS_CODE
  if [[ -n "$NESSUS_CODE" ]]; then
    sed -i "s/^NESSUS_ACTIVATION_CODE=.*/NESSUS_ACTIVATION_CODE=$NESSUS_CODE/" "$SCRIPT_DIR/.env"
    ok "Nessus activation code saved."
  else
    warn "Nessus activation code skipped."
    warn "Nessus will start as an UNREGISTERED server."
    warn "To activate it after setup:"
    warn "  1. Open https://<YOUR-IP>:8834  →  log in with admin / admin123"
    warn "  2. Click the gear icon (top-right) → Settings → Overview"
    warn "  3. Enter your free activation code from tenable.com/products/nessus/nessus-essentials"
    warn "  4. Wait 15-30 min for plugin download to complete"
  fi
else
  ok ".env already exists — skipping creation."
fi

###############################################################################
# STEP 5 — Launch containers
###############################################################################
step "5/5" "Starting lab containers"
echo ""
echo "  This downloads ~2 GB of Docker images on first run."
echo "  SonarQube image alone is ~600 MB. Please be patient."
echo ""

cd "$SCRIPT_DIR"
if [[ "$RUNNING_AS_ROOT_DIRECTLY" = true ]]; then
  docker compose up -d --build
else
  sudo -u "$LAB_USER" docker compose up -d --build
fi

# ── Give containers a moment to register before the health check ──────────────
echo ""
echo "  Waiting 20s for containers to initialise before health check..."
sleep 20

###############################################################################
# STEP 6 — Health check (auto-fix any failing containers)
###############################################################################
echo ""
echo -e "${BOLD}${BLUE}[6/6]${NC} Health check"
echo ""
bash "$SCRIPT_DIR/healthcheck.sh" --fix
