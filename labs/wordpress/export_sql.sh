#!/usr/bin/env bash
# Export the installed WordPress database into sql/wordpress-seed.sql
#
# Why export instead of hand-writing SQL: WordPress has 12 core tables with
# indexes and foreign-key-ish relationships, plus serialised option values
# that must stay byte-exact. A hand-written schema drifts from the real thing
# and breaks plugins in ways that look like lab bugs.
#
# Run once after the first boot:
#   ./export_sql.sh
#
# Afterwards the seed is mounted into mariadb's docker-entrypoint-initdb.d,
# so a fresh volume comes up already installed.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WP="p2s-wp"
DB="p2s-wp-db"
SEED="$HERE/sql/wordpress-seed.sql"

mkdir -p "$HERE/sql"

echo "[sql] checking install state"
if ! docker exec -u www-data "$WP" wp core is-installed >/dev/null 2>&1; then
  echo "[sql] WordPress is not installed yet; run ./lab_wordpress.sh up first"
  exit 1
fi

echo "[sql] exporting"
# --default-character-set keeps the dump loadable by mariadb's init hook
docker exec -u www-data "$WP" wp db export /tmp/wp-seed.sql \
    --default-character-set=utf8mb4 --skip-plugins --skip-themes
docker cp "$WP:/tmp/wp-seed.sql" "$SEED"
docker exec -u www-data "$WP" rm -f /tmp/wp-seed.sql

# The dump contains absolute URLs for the container's own host:port. Nothing to
# rewrite for a local lab, but record the site URL so a reader knows.
URL=$(docker exec -u www-data "$WP" wp option get siteurl 2>/dev/null || echo unknown)

SIZE=$(stat -c %s "$SEED")
TABLES=$(grep -c '^CREATE TABLE' "$SEED" || true)

cat > "$HERE/sql/README.md" <<EOF
# Seed SQL

\`wordpress-seed.sql\` is a \`wp db export\` of the lab install, produced by
\`export_sql.sh\`. It is not hand-written: WordPress serialises option values,
and a hand-rolled schema drifts in ways that look like exploit bugs.

| | |
|---|---|
| site url | ${URL} |
| size | ${SIZE} bytes |
| tables | ${TABLES} |

## How it is used

\`lab_wordpress.sh\` does **not** mount this by default - the entrypoint runs
\`wp core install\` on first boot, which is idempotent and always matches the
image's WordPress version.

To start from the seed instead (faster, pinned content), mount it into
mariadb's init hook on a fresh volume:

\`\`\`bash
docker run -d --name p2s-wp-db --network p2s-wp-net \\
  -e MARIADB_DATABASE=wordpress -e MARIADB_USER=wpuser \\
  -e MARIADB_PASSWORD=wppass123 -e MARIADB_ROOT_PASSWORD=rootpass123 \\
  -v p2s-wp-db-vol:/var/lib/mysql \\
  -v "\$PWD/sql:/docker-entrypoint-initdb.d:ro" \\
  mariadb:11
\`\`\`

mariadb only runs \`/docker-entrypoint-initdb.d/*.sql\` when the data directory
is empty, so this applies to a fresh volume only.
EOF

echo "[sql] wrote $SEED (${SIZE} bytes, ${TABLES} tables)"
echo "[sql] wrote $HERE/sql/README.md"
