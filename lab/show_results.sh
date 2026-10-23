#!/usr/bin/env bash
# Show saved results: one folder per target.
#
#   ./show_results.sh              # all targets
#   ./show_results.sh 10.0.0.5_80  # one target
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
RESULTS="$ROOT/out/results"

if [ ! -d "$RESULTS" ]; then
  echo "no results yet ($RESULTS)"
  exit 0
fi

if [ $# -gt 0 ]; then
  set -- "$RESULTS/$1"
fi

for t in "${@:-$RESULTS/*/}"; do
  [ -d "$t" ] || continue
  echo "--- $(basename "$t")"
  for f in cmd.txt output.txt meta.json; do
    if [ -f "$t/$f" ]; then
      echo "  [$f]"
      sed 's/^/    /' "$t/$f"
    fi
  done
  echo
done
