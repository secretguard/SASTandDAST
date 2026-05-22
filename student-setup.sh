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
#   2. Sets vm.max_map_count for SonarQube / Elasticsearch
#   3. Creates .env from .env.example (asks for Nessus activation code)
#   4. Runs `docker compose up -d --build`
#   5. Prints access URLs
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
# STEP 2 — Kernel tuning (SonarQube / Elasticsearch requirement)
###############################################################################
step "2/4" "Kernel parameters"

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
# STEP 3 — Environment file
###############################################################################
step "3/4" "Configuration"

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
    warn "Nessus activation code not set. Complete activation in the browser after setup."
  fi
else
  ok ".env already exists — skipping creation."
fi

###############################################################################
# STEP 4 — Launch containers
###############################################################################
step "4/4" "Starting lab containers"
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

# ── Wait briefly then show container status ───────────────────────────────────
echo ""
echo "  Waiting for services to initialise (15s)..."
sleep 15

echo ""
docker compose ps

THIS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║     Lab Setup Complete!                                     ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Service          URL                              Credentials${NC}"
echo    "  ─────────────────────────────────────────────────────────────────────"
echo -e "  SonarQube        http://$THIS_IP:9000            admin / admin"
echo -e "  ZAP API          http://$THIS_IP:8090            key: lab-api-key-2024"
echo -e "  Nessus           https://$THIS_IP:8834           setup in browser"
echo -e "  DVWA             http://$THIS_IP:8888            admin / password"
echo -e "  VulnShop         http://$THIS_IP:4040            admin@vulnshop.local / admin123"
echo ""
echo -e "  ${YELLOW}NOTE:${NC} SonarQube takes 2-3 min to fully start. Refresh if you see 503."
echo -e "  ${YELLOW}NOTE:${NC} VulnShop builds its image on first run — may take 3-5 min."
echo ""
echo -e "  Verify all services:  ${BOLD}sudo bash healthcheck.sh${NC}"
echo -e "  View logs:            ${BOLD}docker compose logs -f <service>${NC}"
echo -e "  Stop everything:      ${BOLD}docker compose down${NC}"
echo -e "  Reset a service:      ${BOLD}docker compose restart <service>${NC}"
echo ""
