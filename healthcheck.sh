#!/bin/bash
###############################################################################
# SASTandDAST Lab — Health Check (Docker Edition)
# Author: Sarath G | www.sarathg.me
#
# Usage:
#   bash healthcheck.sh          # check all containers
#   bash healthcheck.sh --fix    # restart unhealthy containers
#   bash healthcheck.sh --logs   # show recent logs for failing containers
###############################################################################

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

PASS_SYM="✓"; FAIL_SYM="✗"; WARN_SYM="⚠"
PASS_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0
FAILED_CONTAINERS=()

pass()    { echo -e "  ${GREEN}${PASS_SYM} PASS${NC}  $1"; ((PASS_COUNT++)); }
fail()    { echo -e "  ${RED}${FAIL_SYM} FAIL${NC}  $1"; ((FAIL_COUNT++)); FAILED_CONTAINERS+=("${2:-}"); }
warn()    { echo -e "  ${YELLOW}${WARN_SYM} WARN${NC}  $1"; ((WARN_COUNT++)); }
info()    { echo -e "  ${BLUE}ℹ${NC}  $1"; }
section() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
MODE="check"
for arg in "${@:-}"; do
  case "$arg" in
    --fix)  MODE="fix"  ;;
    --logs) MODE="logs" ;;
    --help|-h)
      echo "Usage: bash healthcheck.sh [--fix|--logs]"
      echo "  (no flag)  Check container and service health"
      echo "  --fix      Restart unhealthy containers"
      echo "  --logs     Show recent logs for failing containers"
      exit 0 ;;
  esac
done

THIS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   SASTandDAST Lab — Health Check                            ║${NC}"
echo -e "${BOLD}║   Sarath G | www.sarathg.me                                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Mode:  ${BOLD}$MODE${NC}   IP: ${BOLD}$THIS_IP${NC}"

###############################################################################
# Docker check
###############################################################################
section "DOCKER"

if ! command -v docker &>/dev/null; then
  echo -e "  ${RED}${FAIL_SYM} FAIL${NC}  Docker not installed — run: sudo bash student-setup.sh"
  exit 1
fi
pass "Docker installed: $(docker --version | cut -d' ' -f3 | tr -d ',')"

if ! docker info &>/dev/null; then
  echo -e "  ${RED}${FAIL_SYM} FAIL${NC}  Docker daemon not running"
  echo "  Fix: sudo systemctl start docker"
  exit 1
fi
pass "Docker daemon: running"

if ! docker compose version &>/dev/null; then
  fail "docker compose plugin not available" ""
else
  pass "Docker Compose: $(docker compose version --short)"
fi

# ── Check compose project is up ───────────────────────────────────────────────
cd "$SCRIPT_DIR"
RUNNING=$(docker compose ps --services --filter status=running 2>/dev/null | wc -l)
TOTAL=$(docker compose ps --services 2>/dev/null | wc -l)
if [[ "$TOTAL" -eq 0 ]]; then
  warn "No containers found. Run: docker compose up -d"
else
  info "$RUNNING / $TOTAL services running"
fi

###############################################################################
# check_container <name> <url> <grep_pattern> <friendly_url>
###############################################################################
check_container() {
  local name="$1"
  local url="${2:-}"
  local pattern="${3:-}"
  local friendly="${4:-$url}"

  local status
  status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "not_found")
  local health
  health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo "unknown")

  if [[ "$status" = "not_found" ]]; then
    fail "Container $name: not found" "$name"
    return
  fi

  if [[ "$status" != "running" ]]; then
    fail "Container $name: $status" "$name"
    return
  fi

  if [[ "$health" = "unhealthy" ]]; then
    warn "Container $name: running but UNHEALTHY"
    FAILED_CONTAINERS+=("$name")
  else
    pass "Container $name: $status${health:+ ($health)}"
  fi

  if [[ -z "$url" ]]; then return; fi

  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 8 "$url" 2>/dev/null || echo "0")
  if [[ "$code" = "0" ]]; then
    warn "$name HTTP: not responding yet (may still be starting)"
  elif [[ -n "$pattern" ]]; then
    local body
    body=$(curl -sk --max-time 8 "$url" 2>/dev/null || echo "")
    if echo "$body" | grep -qi "$pattern"; then
      pass "$name HTTP $code — $friendly"
    else
      warn "$name HTTP $code — content check failed (still starting?)"
    fi
  else
    if [[ "$code" =~ ^[23] ]]; then
      pass "$name HTTP $code — $friendly"
    else
      warn "$name HTTP $code — $friendly"
    fi
  fi
}

###############################################################################
# Lab checks
###############################################################################
section "LAB 1 — SonarQube (SAST)"
check_container "sonar-db"  "" "" ""
check_container "sonarqube" \
  "http://localhost:9000/api/system/status" \
  '"status":"UP"' \
  "http://$THIS_IP:9000"

sq_status=$(curl -sf --max-time 8 "http://localhost:9000/api/system/status" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null \
  || echo "unreachable")
case "$sq_status" in
  UP)       pass "SonarQube API: UP" ;;
  STARTING) warn "SonarQube: still starting — wait 2-3 min and re-run this check" ;;
  *)        warn "SonarQube API: $sq_status" ;;
esac

section "LAB 2 — ZAP + Nessus (DAST)"
check_container "zap" \
  "http://localhost:8090/JSON/core/view/version/?apikey=lab-api-key-2024" \
  "version" \
  "http://$THIS_IP:8090"

check_container "nessus" "" "" ""
nessus_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 8 "https://localhost:8834" 2>/dev/null || echo "0")
if [[ "$nessus_code" =~ ^[23] ]] || [[ "$nessus_code" = "302" ]]; then
  pass "Nessus HTTPS $nessus_code — https://$THIS_IP:8834"
elif [[ "$nessus_code" = "0" ]]; then
  warn "Nessus: not responding yet (plugin download can take 15-30 min on first run)"
else
  warn "Nessus HTTP $nessus_code"
fi

section "LAB 3 — DVWA + VulnShop (Targets)"
check_container "dvwa-db"     "" "" ""
check_container "dvwa" \
  "http://localhost:8888/dvwa/login.php" \
  "Login" \
  "http://$THIS_IP:8888/dvwa/"
check_container "vulnshop-db" "" "" ""
check_container "vulnshop" \
  "http://localhost:4040" \
  "VulnShop" \
  "http://$THIS_IP:4040"

section "KERNEL"
cur_map=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
[[ "$cur_map" -ge 524288 ]] \
  && pass "vm.max_map_count=$cur_map (SonarQube OK)" \
  || warn "vm.max_map_count=$cur_map — should be ≥524288. Run: sudo bash student-setup.sh"

###############################################################################
# Summary
###############################################################################
section "SUMMARY"
echo ""
echo -e "  ${GREEN}${PASS_SYM} PASS${NC}  $PASS_COUNT"
echo -e "  ${RED}${FAIL_SYM} FAIL${NC}  $FAIL_COUNT"
echo -e "  ${YELLOW}${WARN_SYM} WARN${NC}  $WARN_COUNT"
echo ""

if [[ "$FAIL_COUNT" -eq 0 && "$WARN_COUNT" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All services healthy!${NC}"
  echo ""
  echo -e "  SonarQube:  http://$THIS_IP:9000           admin / admin"
  echo -e "  ZAP API:    http://$THIS_IP:8090           key: lab-api-key-2024"
  echo -e "  Nessus:     https://$THIS_IP:8834"
  echo -e "  DVWA:       http://$THIS_IP:8888/dvwa/     admin / password"
  echo -e "  VulnShop:   http://$THIS_IP:4040           admin@vulnshop.local / admin123"
elif [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}Some containers need attention.${NC}"
  echo ""
  case "$MODE" in
    fix)
      echo -e "  ${BOLD}Restarting failing containers...${NC}"
      for c in "${FAILED_CONTAINERS[@]}"; do
        [[ -z "$c" ]] && continue
        echo "  Restarting: $c"
        docker compose restart "$c" 2>/dev/null || true
      done
      echo ""
      echo "  Waiting 15s then re-checking..."
      sleep 15
      exec bash "${BASH_SOURCE[0]}"
      ;;
    logs)
      for c in "${FAILED_CONTAINERS[@]}"; do
        [[ -z "$c" ]] && continue
        echo -e "\n  ${BOLD}=== Logs: $c (last 30 lines) ===${NC}"
        docker compose logs --tail=30 "$c" 2>/dev/null || true
      done
      ;;
    *)
      echo "  Quick fixes:"
      echo "  • Restart a service:      docker compose restart <name>"
      echo "  • Auto-restart failing:   bash healthcheck.sh --fix"
      echo "  • View logs:              bash healthcheck.sh --logs"
      echo "  • Full restart:           docker compose down && docker compose up -d"
      echo "  • Rebuild VulnShop:       docker compose up -d --build vulnshop"
      ;;
  esac
fi
echo ""
