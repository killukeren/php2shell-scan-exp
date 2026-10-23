#!/usr/bin/env bash
# WordPress lab without docker-compose (this host has none).
#
#   ./lab_wordpress.sh up       build if needed, start db + wordpress
#   ./lab_wordpress.sh status   container state + plugin list
#   ./lab_wordpress.sh seed     install WordPress if the DB is empty
#   ./lab_wordpress.sh down     stop and remove containers (keeps the volume)
#   ./lab_wordpress.sh nuke     also remove the DB volume
#
# Run as root.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"

NET="p2s-wp-net"
DB="p2s-wp-db"
WP="p2s-wp"
IMG="p2s-wordpress:lab"
PORT="18120"
VOL="p2s-wp-db-vol"
OUT="$HERE/out"

need_root() {
  [ "$(id -u)" = "0" ] || { echo "run as root: sudo bash $0 $*" >&2; exit 1; }
}

wait_db() {
  echo "[lab] waiting for mariadb ..."
  for i in $(seq 1 90); do
    if docker exec "$DB" mariadb-admin --protocol=tcp -h127.0.0.1 \
         -uwpuser -pwppass123 ping >/dev/null 2>&1; then
      echo "[lab] db ready (${i}s)"
      return 0
    fi
    sleep 1
  done
  echo "[lab] db did not come up"
  return 1
}

build() {
  need_root
  if docker image inspect "$IMG" >/dev/null 2>&1; then
    echo "[lab] image $IMG already built (delete it to rebuild)"
    return 0
  fi
  echo "[lab] building $IMG"
  docker build -t "$IMG" "$HERE" || return 1
}

up() {
  need_root
  mkdir -p "$OUT"
  build || exit 1

  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
  docker volume inspect "$VOL" >/dev/null 2>&1 || docker volume create "$VOL" >/dev/null

  docker rm -f "$WP" "$DB" >/dev/null 2>&1 || true

  echo "[lab] starting db"
  docker run -d --name "$DB" --network "$NET" \
    -e MARIADB_DATABASE=wordpress \
    -e MARIADB_USER=wpuser \
    -e MARIADB_PASSWORD=wppass123 \
    -e MARIADB_ROOT_PASSWORD=rootpass123 \
    -v "$VOL:/var/lib/mysql" \
    mariadb:11 >/dev/null || exit 1

  wait_db || exit 1

  echo "[lab] starting wordpress on 127.0.0.1:$PORT"
  docker run -d --name "$WP" --network "$NET" \
    -p "127.0.0.1:$PORT:80" \
    -e WORDPRESS_DB_HOST="$DB" \
    -e WORDPRESS_DB_NAME=wordpress \
    -e WORDPRESS_DB_USER=wpuser \
    -e WORDPRESS_DB_PASSWORD=wppass123 \
    -e WP_SITE_URL="http://127.0.0.1:$PORT" \
    -v "$OUT:/out" \
    "$IMG" >/dev/null || exit 1

  echo "[lab] waiting for the site"
  for _ in $(seq 1 120); do
    if curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/"; then
      echo "[lab] up: http://127.0.0.1:$PORT/"
      return 0
    fi
    sleep 1
  done
  echo "[lab] site did not come up; check: docker logs $WP"
  return 1
}

status() {
  need_root
  docker ps -a --filter "name=p2s-wp" --format '{{.Names}}  {{.Status}}  {{.Image}}'
  echo
  if docker exec "$WP" true 2>/dev/null; then
    echo "-- php"
    docker exec "$WP" php -v | head -1
    echo "-- chain ini values"
    docker exec "$WP" php -i 2>/dev/null | grep -E \
      '^(memory_limit|post_max_size|max_input_vars|session.upload_progress.enabled|session.upload_progress.cleanup)'
    echo "-- workers"
    docker exec "$WP" sh -c 'ps -C apache2 --no-headers | wc -l'
    echo "-- plugins"
    docker exec -u www-data "$WP" wp plugin list --fields=name,status 2>/dev/null
  fi
}

seed() {
  need_root
  docker exec -u www-data "$WP" wp core is-installed 2>/dev/null && {
    echo "[lab] already installed"
    return 0
  }
  docker exec -u www-data "$WP" wp core install \
    --url="http://127.0.0.1:$PORT" \
    --title="php2shell WP lab" \
    --admin_user=admin \
    --admin_password=adminpass123 \
    --admin_email=admin@lab.local \
    --skip-email
}

down() {
  need_root
  docker rm -f "$WP" "$DB" >/dev/null 2>&1 || true
  echo "[lab] stopped"
}

nuke() {
  need_root
  down
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  echo "[lab] volume and network removed"
}

case "${1:-}" in
  up)     up ;;
  build)  build ;;
  status) status ;;
  seed)   seed ;;
  down)   down ;;
  nuke)   nuke ;;
  *)      echo "usage: $0 {up|build|status|seed|down|nuke}"; exit 1 ;;
esac
