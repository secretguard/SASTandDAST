#!/bin/bash
###############################################################################
# SASTandDAST Lab — Student Setup Entry Point
#
# Run on your VM as:
#   sudo bash student-setup.sh
#
# This script detects your system's user, IP, and network interface
# automatically, then lets you choose which lab(s) to install.
###############################################################################

set -euo pipefail

# ─── COLOUR OUTPUT ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     SAST & DAST Lab — Student Setup                         ║${NC}"
echo -e "${BOLD}║     Sarath G | www.sarathg.me                               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── PRE-FLIGHT CHECKS ───────────────────────────────────────────────────────
preflight_check() {
  # Must run with sudo
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Please run with sudo:"
    echo "        sudo bash student-setup.sh"
    exit 1
  fi

  # Detect the real user (not root)
  LAB_USER="${SUDO_USER:-${USER:-}}"
  if [ -z "$LAB_USER" ] || [ "$LAB_USER" = "root" ]; then
    echo -e "${YELLOW}[PROMPT]${NC} Could not auto-detect your username."
    read -r -p "         Enter your username (not root): " LAB_USER
    if [ -z "$LAB_USER" ] || [ "$LAB_USER" = "root" ]; then
      echo -e "${RED}[ERROR]${NC} A non-root username is required."
      exit 1
    fi
  fi

  # Resolve home directory
  LAB_HOME=$(getent passwd "$LAB_USER" 2>/dev/null | cut -d: -f6)
  [ -z "$LAB_HOME" ] && LAB_HOME="/home/$LAB_USER"

  # OS check
  if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    echo -e "${YELLOW}[WARN]${NC} This script targets Ubuntu/Debian. Your OS may not be supported."
    read -r -p "       Continue anyway? [y/N]: " CONT
    [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
  fi

  # Auto-detect network interface — try common names, fall back to default route
  LAB_IFACE=""
  for IFACE in ens160 ens33 eth0 enp3s0 enp0s3 ens3 ens4 ens18 enp1s0; do
    if ip link show "$IFACE" &>/dev/null; then
      LAB_IFACE="$IFACE"
      break
    fi
  done
  if [ -z "$LAB_IFACE" ]; then
    LAB_IFACE=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
  fi

  # Detect THIS_IP
  THIS_IP=""
  if [ -n "$LAB_IFACE" ]; then
    THIS_IP=$(ip -4 addr show "$LAB_IFACE" 2>/dev/null \
      | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
  fi
  [ -z "$THIS_IP" ] && THIS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

  if [ -z "$THIS_IP" ]; then
    echo -e "${YELLOW}[WARN]${NC} Could not detect your IP address."
    read -r -p "       Enter this VM's IP address: " THIS_IP
  fi

  # Disk check (20 GB = 20971520 KB)
  FREE_KB=$(df / --output=avail 2>/dev/null | tail -1)
  if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 20971520 ]; then
    echo -e "${YELLOW}[WARN]${NC} Less than 20 GB free disk space on /."
    echo "       SonarQube (Lab 1) requires ~15 GB. Labs 2 and 3 need ~10 GB each."
    read -r -p "       Continue anyway? [y/N]: " CONT
    [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
  fi

  # RAM check — warn for SonarQube
  RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
  if [ -n "$RAM_MB" ] && [ "$RAM_MB" -lt 4096 ]; then
    echo -e "${YELLOW}[WARN]${NC} Less than 4 GB RAM detected (${RAM_MB} MB)."
    echo "       Lab 1 (SonarQube) requires at least 4 GB RAM and may fail."
    echo "       Labs 2 and 3 should work fine."
  fi

  echo ""
  echo -e "${GREEN}[OK]${NC} Pre-flight complete."
  echo -e "     User:      ${BOLD}$LAB_USER${NC} (home: $LAB_HOME)"
  echo -e "     Interface: ${BOLD}$LAB_IFACE${NC}"
  echo -e "     IP:        ${BOLD}$THIS_IP${NC}"
  echo ""
}

# ─── MENU ────────────────────────────────────────────────────────────────────
show_menu() {
  echo -e "${BOLD}Which lab do you want to install on this VM?${NC}"
  echo ""
  echo "  1) Lab 1 — SonarQube SAST Hub"
  echo "     Installs: Java 17, PostgreSQL, SonarQube, SonarScanner"
  echo "     Requirements: 8+ GB RAM recommended, 50+ GB disk"
  echo ""
  echo "  2) Lab 2 — OWASP ZAP + Nessus (DAST Node)"
  echo "     Installs: Java 17, OWASP ZAP daemon, Nessus, nmap, sqlmap"
  echo "     Requirements: 4+ GB RAM, 30+ GB disk"
  echo ""
  echo "  3) Lab 3 — Target Apps (DVWA + VulnShop)"
  echo "     Installs: Apache, PHP 8.1, MariaDB, DVWA, VulnShop"
  echo "     Requirements: 4+ GB RAM, 20+ GB disk"
  echo ""
  echo "  4) All three labs on this single machine"
  echo "     Installs everything above (for single-VM setups)"
  echo "     Requirements: 8+ GB RAM, 80+ GB disk"
  echo ""
  while true; do
    read -r -p "Enter choice [1-4]: " LAB_CHOICE
    case "$LAB_CHOICE" in
      1|2|3|4) break ;;
      *) echo "  Please enter 1, 2, 3, or 4." ;;
    esac
  done
}

# ─── PEER IP PROMPTS ─────────────────────────────────────────────────────────
prompt_peer_ips() {
  VM01_IP=""
  VM02_IP=""
  VM03_IP=""

  # For "all on one machine", all IPs point to this machine
  if [ "$LAB_CHOICE" = "4" ]; then
    VM01_IP="$THIS_IP"
    VM02_IP="$THIS_IP"
    VM03_IP="$THIS_IP"
    return
  fi

  # Set this VM's own IP for its lab role
  case "$LAB_CHOICE" in
    1) VM01_IP="$THIS_IP" ;;
    2) VM02_IP="$THIS_IP" ;;
    3) VM03_IP="$THIS_IP" ;;
  esac

  echo ""
  echo -e "${BLUE}[OPTIONAL]${NC} If you have other lab VMs, enter their IPs to add"
  echo "           /etc/hosts entries so the VMs can reach each other by name."
  echo "           Press Enter to skip if you only have one VM."
  echo ""

  if [ "$LAB_CHOICE" != "1" ]; then
    read -r -p "  Lab 1 (SonarQube) VM IP [Enter to skip]: " VM01_IP
  fi
  if [ "$LAB_CHOICE" != "2" ]; then
    read -r -p "  Lab 2 (ZAP/Nessus) VM IP [Enter to skip]: " VM02_IP
  fi
  if [ "$LAB_CHOICE" != "3" ]; then
    read -r -p "  Lab 3 (Target apps) VM IP [Enter to skip]: " VM03_IP
  fi
}

# ─── CONFIRMATION ────────────────────────────────────────────────────────────
show_confirmation() {
  local LAB_NAME
  case "$LAB_CHOICE" in
    1) LAB_NAME="Lab 1 — SonarQube SAST Hub" ;;
    2) LAB_NAME="Lab 2 — OWASP ZAP + Nessus" ;;
    3) LAB_NAME="Lab 3 — Target Apps (DVWA + VulnShop)" ;;
    4) LAB_NAME="All three labs (single-machine mode)" ;;
  esac

  echo ""
  echo -e "${BOLD}════════════════════ SETUP SUMMARY ════════════════════${NC}"
  echo "  Installing:  $LAB_NAME"
  echo "  User:        $LAB_USER"
  echo "  Home:        $LAB_HOME"
  echo "  This IP:     $THIS_IP"
  echo "  VM01 IP:     ${VM01_IP:-'(not set)'}"
  echo "  VM02 IP:     ${VM02_IP:-'(not set)'}"
  echo "  VM03 IP:     ${VM03_IP:-'(not set)'}"
  echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
  echo ""

  read -r -p "Proceed with installation? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
}

# ─── RUN ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

preflight_check
show_menu
prompt_peer_ips
show_confirmation

# Export all variables so child scripts inherit them
export LAB_USER LAB_HOME THIS_IP LAB_IFACE VM01_IP VM02_IP VM03_IP

echo ""
echo -e "${BOLD}Starting installation...${NC}"
echo ""

case "$LAB_CHOICE" in
  1)
    bash "$SCRIPT_DIR/vm01-sonarqube-setup.sh"
    ;;
  2)
    bash "$SCRIPT_DIR/vm02-zap-nessus-setup.sh"
    ;;
  3)
    bash "$SCRIPT_DIR/vm03-target-setup.sh"
    ;;
  4)
    echo -e "${BOLD}[1/3] Installing Lab 1 — SonarQube...${NC}"
    bash "$SCRIPT_DIR/vm01-sonarqube-setup.sh"
    echo ""
    echo -e "${BOLD}[2/3] Installing Lab 2 — ZAP + Nessus...${NC}"
    bash "$SCRIPT_DIR/vm02-zap-nessus-setup.sh"
    echo ""
    echo -e "${BOLD}[3/3] Installing Lab 3 — Target Apps...${NC}"
    bash "$SCRIPT_DIR/vm03-target-setup.sh"
    ;;
esac

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║     Installation complete! Run ~/scripts/check-status.sh    ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
