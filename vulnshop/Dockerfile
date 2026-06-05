###############################################################################
# VulnShop — Intentionally Vulnerable Laravel App
# For AppSec / SAST+DAST training purposes only.
# DO NOT deploy on production or public networks.
###############################################################################

FROM php:8.1-apache

LABEL maintainer="Sarath G <www.sarathg.me>"
LABEL description="VulnShop: intentionally vulnerable Laravel e-commerce app for AppSec training"

# ── System dependencies ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip curl \
        libpng-dev libzip-dev libxml2-dev libonig-dev libcurl4-openssl-dev \
        libicu-dev \
    && docker-php-ext-install pdo_mysql zip gd xml mbstring bcmath intl \
    && a2enmod rewrite headers \
    && rm -rf /var/lib/apt/lists/*

# ── Composer ─────────────────────────────────────────────────────────────────
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# ── Create base Laravel 10 scaffold ──────────────────────────────────────────
# This layer is cached as long as the Laravel version doesn't change.
RUN composer config --global audit.block-insecure false && \
COMPOSER_ALLOW_SUPERUSER=1 composer create-project \
        laravel/laravel:10.* /app --no-interaction && \
    && composer clear-cache

WORKDIR /app

# Remove default Laravel migrations — VulnShop has its own schema
RUN rm -f \
    database/migrations/2014_10_12_000000_create_users_table.php \
    database/migrations/2014_10_12_100000_create_password_reset_tokens_table.php \
    database/migrations/2019_08_19_000000_create_failed_jobs_table.php \
    database/migrations/2019_12_14_000001_create_personal_access_tokens_table.php

# ── Copy VulnShop source (overwrites scaffold defaults) ───────────────────────
COPY app/       /app/app/
COPY database/  /app/database/
COPY resources/ /app/resources/
COPY routes/    /app/routes/
COPY .env       /app/.env

# ── Upload directory for insecure file upload vulnerability ───────────────────
RUN mkdir -p /app/public/uploads/avatars \
    && chmod -R 777 /app/public/uploads

# ── Apache virtual host ───────────────────────────────────────────────────────
COPY apache.conf /etc/apache2/sites-available/000-default.conf

# ── Permissions ───────────────────────────────────────────────────────────────
RUN chown -R www-data:www-data /app \
    && chmod -R 755 /app/storage /app/bootstrap/cache

# ── Entrypoint: waits for DB, runs migrations, seeds, then starts Apache ──────
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 80

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2-foreground"]
