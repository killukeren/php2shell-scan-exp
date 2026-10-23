#!/usr/bin/env bash
# Non-destructive fingerprint of a PHP host whose X-Powered-By is stripped.
#
# Answers only what the chain actually needs:
#   1. is PHP handling this vhost (or is it static Apache)?
#   2. is session.upload_progress enabled?
#   3. does a session cookie come back at all?
#   4. does the entry point redirect?
#
# Sends one HEAD, one GET for a random .php, and one small (1 KB) multipart
# POST. No OOM, no large bodies, nothing that changes server state.
#
#   ./probe_target.sh https://host[:port]
set -u

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "usage: $0 http://HOST[:PORT]"
  exit 1
fi

echo "=== target: $TARGET ==="
echo

echo "--- 1. headers"
curl -sI -m 10 "$TARGET/" | grep -Ei '^(server|x-powered-by|set-cookie|content-type)' || echo "(none)"

echo
echo "--- 2. does Apache hand .php to PHP?"
RND="p2sprobe$RANDOM$RANDOM"
BODY=$(curl -s -m 10 "$TARGET/$RND.php")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$TARGET/$RND.php")
echo "  status: $CODE"
echo "  body  : $(echo "$BODY" | head -c 120)"
if echo "$BODY" | grep -qiE 'PHP|Fatal|Warning|Notice|Undefined'; then
  echo "  -> PHP is executing on this vhost"
else
  echo "  -> no PHP signature in the 404 body"
fi

echo
echo "--- 3. session cookie on a plain GET?"
curl -s -i -m 10 "$TARGET/" | grep -i 'set-cookie' || echo "  (no Set-Cookie)"

echo
echo "--- 4. session.upload_progress probe (1 KB, harmless)"
curl -s -i -m 15 -X POST "$TARGET/" \
  -F "PHP_SESSION_UPLOAD_PROGRESS=p2sprobe" \
  -F "f=@/etc/hostname;filename=a.txt" 2>/dev/null \
  | grep -iE '^(HTTP/|set-cookie)' || echo "  (no Set-Cookie -> upload_progress likely Off)"

echo
echo "--- 5. redirect on the entry point"
curl -sI -m 10 "$TARGET/" | grep -i '^location' || echo "  (no redirect)"

echo
echo "--- verdict"
echo "  A target is only worth testing when step 3 or 4 shows a PHPSESSID."
echo "  No session cookie = no PS(id) = nothing for the chain to dangle."
