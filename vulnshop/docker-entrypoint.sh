#!/bin/bash
###############################################################################
# VulnShop Docker Entrypoint
# Waits for MariaDB, runs migrations, seeds (once), then starts Apache.
###############################################################################
set -e

log() { echo "[VulnShop] $*"; }

log "Container starting..."

# ── Wait for MariaDB ──────────────────────────────────────────────────────────
log "Waiting for database at ${DB_HOST:-vulnshop-db}..."
until php -r "
    new PDO(
        'mysql:host=' . getenv('DB_HOST') . ';dbname=' . getenv('DB_DATABASE'),
        getenv('DB_USERNAME'),
        getenv('DB_PASSWORD'),
        [PDO::ATTR_TIMEOUT => 3]
    );
" 2>/dev/null; do
    log "  DB not ready — retrying in 3s..."
    sleep 3
done
log "Database ready."

cd /app

# ── Generate app key if missing ───────────────────────────────────────────────
if ! grep -qP '^APP_KEY=base64:.{20,}' .env 2>/dev/null; then
    php artisan key:generate --force --no-interaction
    log "App key generated."
fi

# ── Run migrations (idempotent) ───────────────────────────────────────────────
log "Running migrations..."
php artisan migrate --force --no-interaction 2>&1 | grep -v "^$" || true

# ── Seed only once (check for existing users) ────────────────────────────────
USER_COUNT=$(php -r "
    try {
        \$pdo = new PDO(
            'mysql:host=' . getenv('DB_HOST') . ';dbname=' . getenv('DB_DATABASE'),
            getenv('DB_USERNAME'),
            getenv('DB_PASSWORD')
        );
        echo \$pdo->query('SELECT COUNT(*) FROM users')->fetchColumn();
    } catch (Exception \$e) { echo 0; }
" 2>/dev/null || echo "0")

if [[ "$USER_COUNT" = "0" ]]; then
    log "Seeding database..."
    php artisan db:seed --force --no-interaction
    log "Database seeded."
else
    log "Database already has $USER_COUNT users — skipping seed."
fi

# ── Fix permissions (safety net for volume mounts) ────────────────────────────
chown -R www-data:www-data /app/storage /app/bootstrap/cache 2>/dev/null || true
chmod -R 775 /app/storage /app/bootstrap/cache 2>/dev/null || true

# ── Clear config cache so runtime env vars take effect ───────────────────────
php artisan config:clear --no-interaction 2>/dev/null || true

log "Setup complete. Starting Apache..."
exec "$@"
