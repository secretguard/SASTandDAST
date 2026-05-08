# AppSec SAST & DAST Lab — Setup Guide

> **Author:** Sarath G — [www.sarathg.me](https://www.sarathg.me)

---

## Quick Start

Clone the repo onto your VM and run the setup script:

```bash
git clone https://github.com/secretguard/SASTandDAST.git
cd SASTandDAST
sudo bash student-setup.sh
```

The script auto-detects your username, IP address, and network interface. It then shows a menu — pick the lab(s) you want to install.

---

## Lab Options

| # | Lab | Installs | Min RAM | Min Disk |
|---|-----|----------|---------|----------|
| 1 | SonarQube SAST Hub | Java 17, PostgreSQL, SonarQube, SonarScanner | 8 GB | 50 GB |
| 2 | OWASP ZAP + Nessus | Java 17, ZAP daemon, Nessus, nmap, sqlmap | 4 GB | 30 GB |
| 3 | Target Apps (DVWA + VulnShop) | Apache, PHP 8.1, MariaDB, DVWA, VulnShop | 4 GB | 20 GB |
| 4 | All three on one machine | Everything above | 8 GB | 80 GB |

> **Option 4 (single-VM mode):** All three labs can run on one machine. All ports are distinct (9000, 8090, 8834, 80, 8080) — no conflicts.

---

## Requirements

- **OS:** Ubuntu 22.04 LTS (or any Debian-based distro)
- **Run as:** Your own user account via `sudo` — not directly as root
- **Internet:** Required during setup to download packages

---

## Access URLs

The setup script prints your IP at the end. Replace `<YOUR-IP>` below with it.

| Lab | Service | URL |
|-----|---------|-----|
| 1 | SonarQube | `http://<YOUR-IP>:9000` |
| 2 | OWASP ZAP API | `http://<YOUR-IP>:8090` |
| 2 | Nessus | `https://<YOUR-IP>:8834` |
| 3 | DVWA | `http://<YOUR-IP>/dvwa/` |
| 3 | VulnShop | `http://<YOUR-IP>:8080` |

---

## First-Time Steps After Setup

### SonarQube (Lab 1)
1. Open `http://<YOUR-IP>:9000`
2. Login: `admin` / `admin` — change the password when prompted
3. Administration → Marketplace → verify PHP plugin is installed

### Nessus (Lab 2)
1. Open `https://<YOUR-IP>:8834` — accept the self-signed certificate
2. Select **Nessus Essentials**
3. Enter your free activation code from [tenable.com/products/nessus/nessus-essentials](https://www.tenable.com/products/nessus/nessus-essentials)
4. Create an admin account and wait for plugin download (~15–30 min)

### DVWA (Lab 3)
1. Open `http://<YOUR-IP>/dvwa/setup.php`
2. Click **Create / Reset Database**
3. Login: `admin` / `password`

---

## Lab Application Credentials

These are **intentional** credentials built into the vulnerable apps — do not change them.

| Service | Username | Password |
|---------|----------|----------|
| SonarQube | `admin` | `admin` (change on first login) |
| DVWA | `admin` | `password` |
| VulnShop admin | `admin@vulnshop.local` | `admin123` |
| VulnShop user 1 | `alice@example.com` | `password123` |
| VulnShop user 2 | `bob@example.com` | `password123` |
| ZAP API key | — | `lab-api-key-2024` |

---

## Helper Scripts

After setup, scripts are available in `~/scripts/`:

```bash
~/scripts/check-status.sh        # Check all services on this VM
~/scripts/scan-project.sh        # Run SonarScanner (Lab 1)
~/scripts/zap-scan.sh <url>      # Run a ZAP scan (Lab 2)
~/scripts/zap-export-ca.sh       # Export ZAP root CA cert (Lab 2)
~/scripts/nessus-check.sh        # Nessus status and setup guide (Lab 2)
~/scripts/reset-dvwa-db.sh       # Reset DVWA database (Lab 3)
~/scripts/reset-vulnshop.sh      # Reset VulnShop database (Lab 3)
```

---

## Architecture

Three roles — run each on a separate VM, or all on one machine (option 4):

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│  VM / Machine 1          VM / Machine 2                  │
│  ─────────────           ─────────────                   │
│  SonarQube :9000         ZAP Daemon  :8090               │
│  SonarScanner CLI        Nessus      :8834               │
│  PostgreSQL              nmap, nikto, sqlmap             │
│                                                          │
│              VM / Machine 3                              │
│              ─────────────                               │
│              DVWA      :80                               │
│              VulnShop  :8080                             │
│              MySQL     :3306                             │
│              Apache + PHP                                │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

---

## VulnShop — Intentional Vulnerabilities

| # | Vulnerability | Location | OWASP | CWE |
|---|---------------|----------|-------|-----|
| 1 | SQL Injection | `/products/search?q=` | A03:2021 | CWE-89 |
| 2 | Stored XSS | Product reviews | A03:2021 | CWE-79 |
| 3 | IDOR | `/order/{id}` | A01:2021 | CWE-639 |
| 4 | CSRF Bypass | `/change-password` | A01:2021 | CWE-352 |
| 5 | Weak Crypto (MD5) | Password hashing | A02:2021 | CWE-328 |
| 6 | Hardcoded Credentials | `.env` in git | A07:2021 | CWE-798 |
| 7 | Debug Mode | `APP_DEBUG=true` | A05:2021 | CWE-215 |
| 8 | Insecure File Upload | `/profile/upload-avatar` | A04:2021 | CWE-434 |
| 9 | No Rate Limiting | `/login` | A07:2021 | CWE-307 |
| 10 | Information Disclosure | `/debug-info`, footer, PHP headers | A05:2021 | CWE-200 |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| SonarQube won't start | `tail -50 /opt/sonarqube/logs/sonar.log` — usually low memory or `vm.max_map_count` |
| ZAP not responding | `sudo systemctl status zap-daemon` and `tail /var/log/zap-daemon.log` |
| DVWA setup check fails | `sudo chmod 777 /var/www/html/dvwa/hackable/uploads/ /var/www/html/dvwa/config/` |
| VulnShop 500 error | `tail /var/www/html/vulnshop/storage/logs/laravel.log` |
| Nessus plugins stuck | `sudo systemctl restart nessusd` — may take longer on slow connections |
| Port blocked | `sudo ufw status` — verify the required port is allowed |
| MySQL refused | `sudo systemctl status mariadb` |

---

## File Locations

| Item | Path |
|------|------|
| SonarQube | `/opt/sonarqube/` |
| SonarQube config | `/opt/sonarqube/conf/sonar.properties` |
| SonarScanner | `/opt/sonar-scanner/` |
| OWASP ZAP | `/opt/zaproxy/` |
| ZAP daemon log | `/var/log/zap-daemon.log` |
| DVWA | `/var/www/html/dvwa/` |
| VulnShop | `/var/www/html/vulnshop/` |
| VulnShop logs | `/var/www/html/vulnshop/storage/logs/` |
| Setup logs | `/var/log/vm0{1,2,3}-setup.log` |
| Helper scripts | `~/scripts/` |
