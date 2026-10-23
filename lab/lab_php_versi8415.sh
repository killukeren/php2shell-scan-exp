#!/usr/bin/env bash
# PHP 8.4.15 lab - single-worker Apache on 127.0.0.1:8088
#
#   ./lab_php_versi8415.sh up       start
#   ./lab_php_versi8415.sh check    version + required ini values
#   ./lab_php_versi8415.sh session  verify session_start() works
#   ./lab_php_versi8415.sh down     stop
#
# Single worker is forced via lab/apache-prefork.conf: the chain needs the
# dangling session and the reclaim request to land on the same process.
#
# Requires: docker, curl. Run as root (docker socket).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

CT="php8415-lab"
PORT="8088"
IMAGE="php:8.4.15-apache"
OUT="$ROOT/out"

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "run as root: sudo bash $0 $*" >&2
    exit 1
  fi
}

up() {
  need_root
  mkdir -p "$OUT"
  docker rm -f "$CT" >/dev/null 2>&1 || true

  docker run -d --name "$CT" \
    --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    -p "127.0.0.1:$PORT:80" \
    -v "$HERE/www:/var/www/html" \
    -v "$OUT:/out" \
    -v "$HERE/apache-prefork.conf:/etc/apache2/conf-enabled/zz-p2s.conf:ro" \
    "$IMAGE" /bin/sh -c \
    "cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini; \
     chown -R www-data:www-data /out 2>/dev/null || true; \
     exec apache2-foreground" >/dev/null || { echo "docker run failed"; exit 1; }

  for _ in $(seq 1 60); do
    curl -s -m 2 "http://127.0.0.1:$PORT/" | grep -q . && break
    sleep 0.5
  done
  echo "up: http://127.0.0.1:$PORT/  (results -> $OUT)"
}

check() {
  need_root
  echo "-- version"
  docker exec "$CT" php -v | head -1
  echo "-- ini (chain requirements)"
  docker exec "$CT" php -i 2>/dev/null | grep -E \
    '^(memory_limit|post_max_size|max_input_vars|session.upload_progress.enabled|session.upload_progress.cleanup|session.use_strict_mode)'
  echo "-- workers (expect 2: one parent + one child)"
  docker exec "$CT" sh -c 'ps -C apache2 --no-headers | wc -l'
  echo "-- probe"
  curl -s -m 5 "http://127.0.0.1:$PORT/" | head -3
}

session() {
  echo "-- request 1"
  curl -s -i -m 5 "http://127.0.0.1:$PORT/" | grep -Ei 'set-cookie|^sid=|^hits=' | head -3
  echo "-- request 2 with that cookie (hits should increment)"
  ck=$(curl -s -i -m 5 "http://127.0.0.1:$PORT/" | grep -i 'set-cookie' | sed 's/.*PHPSESSID=\([^;]*\).*/\1/')
  if [ -n "${ck:-}" ]; then
    curl -s -m 5 -H "Cookie: PHPSESSID=$ck" "http://127.0.0.1:$PORT/" | head -3
  fi
}

down() {
  need_root
  docker rm -f "$CT" >/dev/null 2>&1
  echo "down"
}

case "${1:-}" in
  up)      up ;;
  check)   check ;;
  session) session ;;
  down)    down ;;
  *)       echo "usage: $0 {up|check|session|down}"; exit 1 ;;
esac
