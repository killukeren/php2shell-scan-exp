#!/usr/bin/env bash
# Entrypoint: wait for the DB, install WordPress if needed, then start Apache.
#
# Installation is idempotent: it only runs when the wp_users table is missing,
# so a container restart does not wipe the site.
#
# Runs as root (Apache's official image starts as root and drops privileges per
# worker), so wp-cli is invoked with `su www-data -s /bin/sh -c` instead of
# sudo, which this image does not ship.
set -eu

DB_HOST="${WORDPRESS_DB_HOST:-db}"
DB_NAME="${WORDPRESS_DB_NAME:-wordpress}"
DB_USER="${WORDPRESS_DB_USER:-wpuser}"
DB_PASS="${WORDPRESS_DB_PASSWORD:-wppass123}"
SITE_URL="${WP_SITE_URL:-http://127.0.0.1:18120}"
ADMIN_USER="${WP_ADMIN_USER:-admin}"
ADMIN_PASS="${WP_ADMIN_PASS:-adminpass123}"
ADMIN_MAIL="${WP_ADMIN_MAIL:-admin@lab.local}"

as_www() {
  su -s /bin/sh www-data -c "cd /var/www/html && $*"
}

echo "[p2s] waiting for database ${DB_HOST} ..."
for i in $(seq 1 90); do
  if mariadb-admin --protocol=tcp -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" ping >/dev/null 2>&1; then
    echo "[p2s] database is up (after ${i}s)"
    break
  fi
  sleep 1
done

installed=0
if mariadb --protocol=tcp -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -N -B \
      -e "SELECT COUNT(*) FROM information_schema.tables
          WHERE table_schema='${DB_NAME}' AND table_name='wp_users';" 2>/dev/null \
      | grep -q '^1$'; then
  installed=1
fi

if [ "$installed" = "0" ]; then
  echo "[p2s] installing WordPress at ${SITE_URL}"
  # Single-quoted heredoc so the arguments survive as one shell word.
  su -s /bin/sh www-data -c "cd /var/www/html && wp core install \
      --url='$SITE_URL' \
      --title='php2shell lab' \
      --admin_user='$ADMIN_USER' \
      --admin_password='$ADMIN_PASS' \
      --admin_email='$ADMIN_MAIL' \
      --skip-email" 2>&1 | sed 's/^/[p2s] /' || true
else
  echo "[p2s] WordPress already installed, skipping"
fi

echo "[p2s] plugins:"
as_www wp plugin list --fields=name,status 2>/dev/null | sed 's/^/[p2s] /' || true

echo "[p2s] starting apache"
exec apache2-foreground
