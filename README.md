# AppSec SAST & DAST Lab

> **Author:** Sarath G — [www.sarathg.me](https://www.sarathg.me)

---

## Quick Start

```bash
git clone https://github.com/secretguard/SASTandDAST.git
cd SASTandDAST
sudo bash student-setup.sh
```

The script installs Docker (if needed), tunes the kernel for SonarQube, and starts all containers.
First run downloads ~2 GB of images and builds VulnShop — allow 5–10 minutes.

---

## Day-to-Day Usage

| Action | Command |
|--------|---------|
| Start lab | `docker compose up -d` |
| Stop lab | `docker compose down` |
| Check health | `bash healthcheck.sh` |
| Full reset (deletes all data) | `docker compose down -v && docker compose up -d` |

```bash
# Start everything
docker compose up -d

# Stop everything (data is preserved in Docker volumes)
docker compose down

# Start or stop a single service
docker compose up -d sonarqube
docker compose stop sonarqube

# Restart a single service
docker compose restart sonarqube

# View live logs for a service
docker compose logs -f vulnshop

# Check health of all services
bash healthcheck.sh

# Full reset — wipes all data and starts fresh
docker compose down -v && docker compose up -d
```

> **Note:** Data (SonarQube projects, scan results, DVWA state) persists across start/stop cycles.
> Only `docker compose down -v` (the `-v` flag) deletes volumes and resets everything to a clean state.

---

## Requirements

| Item | Minimum |
|------|---------|
| OS | Ubuntu 22.04 LTS (or any Debian-based distro) |
| RAM | 6 GB (8 GB recommended — SonarQube needs ~3 GB) |
| Disk | 20 GB free |
| Run as | Your own user via `sudo` — not directly as root |
| Internet | Required on first run to pull images |

---

## Access URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| SonarQube (SAST) | `http://localhost:9000` | `admin` / `admin` |
| OWASP ZAP API | `http://localhost:8090` or search for `zaproxy` in apps or in CLI | API key: `lab-api-key-2024` |
| Nessus | `https://localhost:8834` | Setup in browser (If login is asked enter `admin` / `admin123`) |
| DVWA | `http://localhost:8888/dvwa/` | `admin` / `password` |
| VulnShop | `http://localhost:4040` | `admin@vulnshop.local` / `admin123` |

---

## First-Time Steps After Setup

### SonarQube
1. Open `http://<YOUR-IP>:9000` — may take 2–3 min to fully start
2. Login: `admin` / `admin` — change password when prompted
3. To scan a project: `docker compose run --rm sonar-scanner`

### Nessus
1. Open `https://<YOUR-IP>:8834` and accept the self-signed certificate
2. Log in with `admin` / `admin123`
3. If you skipped the activation code during setup, Nessus starts as an **unregistered server** — activate it as follows:
   - Click the **gear icon** (top-right) → **Settings** → **Overview**
   - Enter your free activation code in the **Activation Code** field
   - Get a free code from [tenable.com/products/nessus/nessus-essentials](https://www.tenable.com/products/nessus/nessus-essentials) — they email it instantly
4. Wait **15–30 min** for plugin download to complete (progress bar shown on dashboard)

### DVWA
- Navigate to `http://<YOUR-IP>:8888/dvwa/` — the database is set up automatically
- Login: `admin` / `password`

### VulnShop
- Navigate to `http://<YOUR-IP>:4040` — the database is migrated and seeded automatically
- Login: `admin@vulnshop.local` / `admin123`

---

## Container Management

```bash
# Check all service status
bash healthcheck.sh

# View logs for a specific service
docker compose logs -f sonarqube
docker compose logs -f vulnshop

# Restart a single service
docker compose restart sonarqube

# Auto-restart failing containers
bash healthcheck.sh --fix

# Stop everything
docker compose down

# Stop and delete all data (full reset)
docker compose down -v

# Rebuild VulnShop after source changes
docker compose up -d --build vulnshop
```

---

## Scanning with SonarScanner

Run a scan against any directory from your host machine:

```bash
docker run --rm \
  --network sastanddast-main_default \
  -v "$(pwd):/usr/src" \
  sonarsource/sonar-scanner-cli \
  -Dsonar.projectKey=my-project \
  -Dsonar.sources=/usr/src \
  -Dsonar.host.url=http://sonarqube:9000 \
  -Dsonar.token=<your-token>
```

Generate a token at: SonarQube → My Account → Security → Generate Token

---

## Architecture

```
docker compose up -d
        │
        ├─ sonar-db      (PostgreSQL 15)
        ├─ sonarqube     (SonarQube Community) ── :9000
        ├─ zap           (OWASP ZAP daemon)    ── :8090
        ├─ nessus        (Nessus Essentials)   ── :8834
        ├─ dvwa-db       (MariaDB 10)
        ├─ dvwa          (DVWA)                ── :8888
        ├─ vulnshop-db   (MariaDB 10)
        └─ vulnshop      (Laravel app)         ── :4040
```

---

## VulnShop — Intentional Vulnerabilities

| # | Vulnerability | Location | OWASP | CWE |
|---|---------------|----------|-------|-----|
| 1 | SQL Injection | `GET /products/search?q=` | A03:2021 | CWE-89 |
| 2 | Stored XSS | Product reviews (`{!! $review->comment !!}`) | A03:2021 | CWE-79 |
| 3 | IDOR | `GET /order/{id}` — no ownership check | A01:2021 | CWE-639 |
| 4 | CSRF | `POST /change-password` — excluded from CSRF middleware | A01:2021 | CWE-352 |
| 5 | Weak Crypto (MD5) | `User::setPasswordAttribute()` | A02:2021 | CWE-328 |
| 6 | Hardcoded Credentials | `.env` committed to git | A07:2021 | CWE-798 |
| 7 | Debug Mode | `APP_DEBUG=true` in production | A05:2021 | CWE-215 |
| 8 | Insecure File Upload | `POST /profile/upload-avatar` — no type check | A04:2021 | CWE-434 |
| 9 | No Rate Limiting | `POST /login` | A07:2021 | CWE-307 |
| 10 | Info Disclosure | `GET /debug-info`, footer version string, `ServerSignature On` | A05:2021 | CWE-200 |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| SonarQube shows 503 | Wait 2–3 min — Elasticsearch takes time to start |
| SonarQube keeps restarting | Check `vm.max_map_count`: `sysctl vm.max_map_count` — should be ≥ 524288. Run `sudo bash student-setup.sh` to fix. |
| VulnShop not loading | `docker compose logs vulnshop` — usually waiting for DB on first start |
| DVWA login fails | `docker compose restart dvwa` — the DB may not have been ready |
| Nessus 503 / blank | Normal during plugin download — check `docker compose logs nessus` |
| Port already in use | Edit `.env` to change port numbers, then `docker compose up -d` |
| Want fresh data | `docker compose down -v && docker compose up -d` (deletes all volumes) |

---

## Credential Reference

| Service | Username | Password |
|---------|----------|----------|
| SonarQube | `admin` | `admin` (change on first login) |
| DVWA | `admin` | `password` |
| VulnShop admin | `admin@vulnshop.local` | `admin123` |
| VulnShop user 1 | `alice@example.com` | `password123` |
| VulnShop user 2 | `bob@example.com` | `password123` |
| ZAP API key | — | `lab-api-key-2024` |
