#!/bin/bash
###############################################################################
# VM-01: SAST Central Hub — SonarQube Server
# Master Kit Setup Script
# OS: Ubuntu 22.04 LTS | CPU: 8 vCPU | RAM: 16 GB | Disk: 150 GB SSD
#
# This script installs and configures:
#   - OpenJDK 17
#   - PostgreSQL 14
#   - SonarQube Community Edition (LTS)
#   - SonarScanner CLI
#   - Lab user with SSH access
#
# Run as root: sudo bash vm01-sonarqube-setup.sh
###############################################################################

set -uo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
LAB_USER="${LAB_USER:-${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo "labuser")}}"
[ "$LAB_USER" = "root" ] && LAB_USER="${SUDO_USER:-labuser}"
LAB_HOME=$(getent passwd "$LAB_USER" 2>/dev/null | cut -d: -f6)
[ -z "$LAB_HOME" ] && LAB_HOME="/home/$LAB_USER"
THIS_IP="${THIS_IP:-$(hostname -I | awk '{print $1}')}"
VM01_IP="${VM01_IP:-$THIS_IP}"
VM02_IP="${VM02_IP:-}"
VM03_IP="${VM03_IP:-}"
SONAR_DB_USER="sonarqube"
SONAR_DB_PASS="S0narDB@2024"
SONAR_DB_NAME="sonarqube"
SONARQUBE_VERSION="10.7.0.96327"  # LTS as of 2025
SONARSCANNER_VERSION="6.2.1.4610"

LOG_FILE="/var/log/vm01-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================================================"
echo " VM-01 SETUP — SonarQube SAST Central Hub"
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
  gnupg lsb-release ufw openssh-server

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

# ─── STEP 4: KERNEL TUNING (required by SonarQube / Elasticsearch) ────────
echo ""
echo "[STEP 4/10] Kernel tuning for SonarQube (Elasticsearch requirements)..."

grep -q 'vm.max_map_count=524288' /etc/sysctl.conf 2>/dev/null || cat >> /etc/sysctl.conf << 'EOF'

# SonarQube / Elasticsearch requirements
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl -p 2>/dev/null || true

grep -q 'sonarqube.*nofile.*131072' /etc/security/limits.conf 2>/dev/null || cat >> /etc/security/limits.conf << 'EOF'

# SonarQube limits
sonarqube   -   nofile   131072
sonarqube   -   nproc    8192
EOF

# ─── STEP 5: INSTALL JAVA 17 ────────────────────────────────────────────────
echo ""
echo "[STEP 5/10] Installing OpenJDK 17..."

if java -version 2>&1 | grep -q 'version "17'; then
  echo "  Java 17 already installed: $(java -version 2>&1 | head -1)"
else
  apt-get install -y -qq openjdk-17-jdk
  echo "  Installed: $(java -version 2>&1 | head -1)"
fi
echo "  JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"

# ─── STEP 6: INSTALL & CONFIGURE POSTGRESQL ─────────────────────────────────
echo ""
echo "[STEP 6/10] Installing and configuring PostgreSQL..."

if dpkg -l postgresql 2>/dev/null | grep -q '^ii'; then
  echo "  PostgreSQL already installed."
else
  apt-get install -y -qq postgresql postgresql-contrib
fi
systemctl enable postgresql
systemctl start postgresql
# Wait briefly for PostgreSQL to fully start
sleep 2

# Create SonarQube database and user (safe if already exists)
sudo -u postgres psql -c "CREATE USER $SONAR_DB_USER WITH ENCRYPTED PASSWORD '$SONAR_DB_PASS';" 2>/dev/null || echo "  DB user already exists."
sudo -u postgres psql -c "CREATE DATABASE $SONAR_DB_NAME OWNER $SONAR_DB_USER;" 2>/dev/null || echo "  Database already exists."
sudo -u postgres psql -c "ALTER USER $SONAR_DB_USER SET search_path TO public;" 2>/dev/null || true
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $SONAR_DB_NAME TO $SONAR_DB_USER;" 2>/dev/null || true

echo "  PostgreSQL configured with database: $SONAR_DB_NAME"

# ─── STEP 7: INSTALL SONARQUBE ───────────────────────────────────────────────
echo ""
echo "[STEP 7/10] Installing SonarQube Community Edition v${SONARQUBE_VERSION}..."

# Create sonarqube system user
if ! id "sonarqube" &>/dev/null; then
  useradd -r -s /bin/false -d /opt/sonarqube sonarqube
fi

# Download and extract only if not already installed at this version
if [ -d /opt/sonarqube ] && [ -f /opt/sonarqube/bin/linux-x86-64/sonar.sh ]; then
  echo "  SonarQube already installed at /opt/sonarqube — reconfiguring only."
else
  cd /tmp
  if [ ! -f "sonarqube-${SONARQUBE_VERSION}.zip" ]; then
    echo "  Downloading SonarQube v${SONARQUBE_VERSION}..."
    wget -q "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SONARQUBE_VERSION}.zip"
  else
    echo "  Using cached download: sonarqube-${SONARQUBE_VERSION}.zip"
  fi
  unzip -qo "sonarqube-${SONARQUBE_VERSION}.zip" -d /opt/
  rm -rf /opt/sonarqube
  mv "/opt/sonarqube-${SONARQUBE_VERSION}" /opt/sonarqube
fi

# Configure SonarQube
cat > /opt/sonarqube/conf/sonar.properties << EOF
# Database
sonar.jdbc.username=$SONAR_DB_USER
sonar.jdbc.password=$SONAR_DB_PASS
sonar.jdbc.url=jdbc:postgresql://localhost:5432/$SONAR_DB_NAME

# Web Server
sonar.web.host=0.0.0.0
sonar.web.port=9000
sonar.web.context=

# Elasticsearch
sonar.search.javaOpts=-Xmx2g -Xms2g
sonar.search.host=127.0.0.1

# Logging
sonar.log.level=INFO
sonar.path.logs=/opt/sonarqube/logs
EOF

# Set ownership
chown -R sonarqube:sonarqube /opt/sonarqube

# Create systemd service
cat > /etc/systemd/system/sonarqube.service << 'EOF'
[Unit]
Description=SonarQube
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=forking
User=sonarqube
Group=sonarqube
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
LimitNOFILE=131072
LimitNPROC=8192
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sonarqube

echo "  SonarQube installed at /opt/sonarqube"

# ─── STEP 8: INSTALL SONARSCANNER CLI ────────────────────────────────────────
echo ""
echo "[STEP 8/10] Installing SonarScanner CLI v${SONARSCANNER_VERSION}..."

if [ -d /opt/sonar-scanner ] && [ -f /opt/sonar-scanner/bin/sonar-scanner ]; then
  echo "  SonarScanner already installed at /opt/sonar-scanner — skipping download."
else
  cd /tmp
  if [ ! -f "sonar-scanner-cli-${SONARSCANNER_VERSION}-linux-x64.zip" ]; then
    echo "  Downloading SonarScanner CLI v${SONARSCANNER_VERSION}..."
    wget -q "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONARSCANNER_VERSION}-linux-x64.zip"
  else
    echo "  Using cached download."
  fi
  unzip -qo "sonar-scanner-cli-${SONARSCANNER_VERSION}-linux-x64.zip" -d /opt/
  rm -rf /opt/sonar-scanner
  mv "/opt/sonar-scanner-${SONARSCANNER_VERSION}-linux-x64" /opt/sonar-scanner
fi

# Add to PATH globally
cat > /etc/profile.d/sonar-scanner.sh << 'EOF'
export PATH=$PATH:/opt/sonar-scanner/bin
export SONAR_SCANNER_HOME=/opt/sonar-scanner
EOF

# Configure scanner defaults
cat > /opt/sonar-scanner/conf/sonar-scanner.properties << EOF
sonar.host.url=http://localhost:9000
sonar.sourceEncoding=UTF-8
EOF

chmod +x /opt/sonar-scanner/bin/sonar-scanner
ln -sf /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner

echo "  SonarScanner installed: $(sonar-scanner --version 2>&1 | head -1 || echo 'installed')"

# ─── STEP 9: FIREWALL & NETWORK ─────────────────────────────────────────────
echo ""
echo "[STEP 9/10] Configuring firewall..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 9000/tcp comment "SonarQube Web UI"
ufw --force enable

echo "  Firewall configured: SSH + TCP 9000"

# ─── STEP 10: HOSTS FILE & STATIC IP NOTES ──────────────────────────────────
echo ""
echo "[STEP 10/10] Configuring hosts file and lab aliases..."

add_hosts_entry() {
  local IP="$1"; local ALIASES="$2"
  [ -n "$IP" ] && ! grep -q "$IP" /etc/hosts && echo "$IP   $ALIASES" >> /etc/hosts
}
echo "" >> /etc/hosts
echo "# AppSec Lab Environment" >> /etc/hosts
add_hosts_entry "$VM01_IP" "vm01 sonarqube-server"
add_hosts_entry "$VM02_IP" "vm02 zap-server nessus-server"
add_hosts_entry "$VM03_IP" "vm03 target-server"

# ─── CREATE LAB HELPER SCRIPTS ──────────────────────────────────────────────
mkdir -p "$LAB_HOME/scripts"

# Quick status check script
cat > "$LAB_HOME/scripts/check-status.sh" << 'SCRIPT'
#!/bin/bash
echo "=== VM-01 Service Status ==="
echo ""
echo "--- SonarQube ---"
systemctl is-active sonarqube && echo "Status: RUNNING" || echo "Status: STOPPED"
curl -sf http://localhost:9000/api/system/status 2>/dev/null | jq -r '.status' 2>/dev/null && true || echo "(not responding yet — may still be starting)"
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

# Scan helper script
cat > "$LAB_HOME/scripts/scan-project.sh" << 'SCRIPT'
#!/bin/bash
# Usage: ./scan-project.sh <project-key> <source-dir> [token]
PROJECT_KEY=${1:?"Usage: $0 <project-key> <source-dir> [token]"}
SOURCE_DIR=${2:?"Usage: $0 <project-key> <source-dir> [token]"}
TOKEN=${3:-""}

if [ -z "$TOKEN" ]; then
  echo "No token provided. Generate one at http://localhost:9000 > My Account > Security > Generate Token"
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

# ─── MOTD / WELCOME MESSAGE ─────────────────────────────────────────────────
cat > /etc/motd << 'EOF'

 ╔══════════════════════════════════════════════════════════════╗
 ║  VM-01: SAST Central Hub — SonarQube Server                 ║
 ║  Application Security Testing — SAST & DAST Lab             ║
 ║  Sarath G | www.sarathg.me                                  ║
 ╠══════════════════════════════════════════════════════════════╣
 ║                                                              ║
 ║  SonarQube:     http://<this-ip>:9000                       ║
 ║  Default Login: admin / admin (change on first use)         ║
 ║  SonarScanner:  sonar-scanner --version                     ║
 ║                                                              ║
 ║  Helper scripts:  ~/scripts/check-status.sh                 ║
 ║                   ~/scripts/scan-project.sh                 ║
 ║                                                              ║
 ╚══════════════════════════════════════════════════════════════╝

EOF

# ─── START SERVICES ──────────────────────────────────────────────────────────
echo ""
echo "Starting SonarQube..."
systemctl start sonarqube

echo ""
echo "Waiting for SonarQube to initialize (this can take 2-3 minutes)..."
for i in $(seq 1 60); do
  STATUS=$(curl -sf http://localhost:9000/api/system/status 2>/dev/null | jq -r '.status' 2>/dev/null || echo "STARTING")
  if [ "$STATUS" = "UP" ]; then
    echo "  SonarQube is UP and ready!"
    break
  fi
  echo "  [$i/60] Status: $STATUS — waiting..."
  sleep 5
done

# ─── CLEANUP ─────────────────────────────────────────────────────────────────
echo ""
echo "Cleaning up..."
rm -f /tmp/sonarqube-*.zip /tmp/sonar-scanner-*.zip
apt-get autoremove -y -qq
apt-get clean

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo " VM-01 SETUP COMPLETE"
echo "======================================================================"
echo ""
echo " SonarQube Web UI:    http://$THIS_IP:9000"
echo " Default Credentials: admin / admin"
echo " SonarScanner CLI:    sonar-scanner --version"
echo " Lab User:            $LAB_USER (home: $LAB_HOME)"
echo " Helper Scripts:      $LAB_HOME/scripts/"
echo " Log File:            $LOG_FILE"
echo ""
echo " IMPORTANT: Change the admin password on first login!"
echo ""
echo " Completed: $(date)"
echo "======================================================================"
