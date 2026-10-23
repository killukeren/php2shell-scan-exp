#!/usr/bin/env bash
# Does CVE-2026-109618/619 affect WordPress?
#
# The chain needs a live PHP session (PS(id)) that an OOM during request
# startup can leave dangling. WordPress core does not use PHP sessions - it
# has its own cookie auth - so core alone should have no PHPSESSID at all.
#
# This script proves it in two passes:
#
#   pass A  plugins off  -> expect NO PHPSESSID  -> chain cannot start
#   pass B  session plugin on -> expect PHPSESSID -> chain may start
#
#   ./test_wordpress.sh
#
# Requires the stack from docker-compose.yml (port 18120).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"
URL="http://127.0.0.1:18120"
WP="docker exec -u www-data p2s-wp wp"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m[+]\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m[-]\033[0m %s\n' "$*"; }
inf() { printf '  \033[2m[*]\033[0m %s\n' "$*"; }

wait_up() {
  for _ in $(seq 1 90); do
    if curl -s -m 2 -o /dev/null "$URL/"; then return 0; fi
    sleep 1
  done
  return 1
}

session_cookie() {
  # Returns the Set-Cookie header containing PHPSESSID, or empty.
  curl -s -i -m 10 "$URL/" | grep -i 'set-cookie:.*PHPSESSID' | head -1
}

upload_progress_cookie() {
  # The real precondition: PHP writes progress into the session during parsing.
  curl -s -i -m 15 -X POST "$URL/" \
    -F "PHP_SESSION_UPLOAD_PROGRESS=p2sprobe" \
    -F "f=@/etc/hostname;filename=a.txt" 2>/dev/null \
    | grep -i 'set-cookie:.*PHPSESSID' | head -1
}

say "waiting for $URL"
if ! wait_up; then
  bad "site did not come up"
  exit 1
fi
ok "site is up"

say "does WP core use PHP sessions?"
inf "grep for session_start() in WordPress core:"
COUNT=$($WP eval 'echo 0;' >/dev/null 2>&1; \
        docker exec p2s-wp sh -c \
        "grep -rl 'session_start' /var/www/html/wp-includes /var/www/html/wp-admin 2>/dev/null | wc -l")
inf "core files calling session_start(): $COUNT"

say "PASS A - control, session plugin OFF"
$WP plugin deactivate p2s-session-on  >/dev/null 2>&1 || true
$WP plugin activate   p2s-session-off >/dev/null 2>&1 || true
$WP plugin list --fields=name,status 2>/dev/null | sed 's/^/    /'

CK=$(session_cookie)
if [ -n "$CK" ]; then
  bad "PHPSESSID present without a session plugin: $CK"
  A_PRECOND=1
else
  ok "no PHPSESSID - WP core does not start a session"
  A_PRECOND=0
fi

CK=$(upload_progress_cookie)
if [ -n "$CK" ]; then
  bad "upload_progress produced a session: $CK"
  A_VECTOR=1
else
  ok "upload_progress produced no session - attack vector absent"
  A_VECTOR=0
fi

say "PASS B - session plugin ON"
$WP plugin deactivate p2s-session-off >/dev/null 2>&1 || true
$WP plugin activate   p2s-session-on  >/dev/null 2>&1 || true
$WP plugin list --fields=name,status 2>/dev/null | sed 's/^/    /'

CK=$(session_cookie)
if [ -n "$CK" ]; then
  ok "PHPSESSID present: $CK"
  B_PRECOND=1
else
  bad "still no PHPSESSID - plugin did not take effect"
  B_PRECOND=0
fi

CK=$(upload_progress_cookie)
if [ -n "$CK" ]; then
  ok "upload_progress writes into a session: $CK"
  B_VECTOR=1
else
  bad "upload_progress produced no session"
  B_VECTOR=0
fi

say "VERDICT"
if [ "$A_PRECOND" = "0" ] && [ "$A_VECTOR" = "0" ]; then
  ok "WordPress core is NOT affected: no PHP session, nothing to dangle"
else
  bad "WordPress core exposes a session - investigate"
fi

if [ "$B_PRECOND" = "1" ] && [ "$B_VECTOR" = "1" ]; then
  ok "WordPress WITH a session plugin IS in the affected configuration"
  inf "run the chain against it:"
  inf "  python3 exploit.py -t $URL/index.php --cmd 'id' --save /tmp/p2s --force"
else
  bad "session plugin did not enable the precondition"
fi

say "run the chain? (only meaningful for pass B)"
echo "  python3 $ROOT/exploit.py -t $URL/index.php \\"
echo "      --cmd 'id' --save /tmp/p2s_out --force"
