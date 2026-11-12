#!/usr/bin/env bash
# Runs every lesson end to end: start.sh (tests, server, verify, demo), verify.sh again, stop.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PASS=0
for n in 1 2 3 4 5 6 7; do
  d="$ROOT/lessons/lesson-$n"
  [ -f "$d/start.sh" ] || continue
  echo "=== Lesson $n ==="
  (cd "$d" && bash start.sh > "/tmp/supportdesk-lesson-$n.log" 2>&1 && bash verify.sh | tail -1 && bash stop.sh >/dev/null) \
    || { echo "FAIL lesson $n (log: /tmp/supportdesk-lesson-$n.log)"; (cd "$d" && bash stop.sh >/dev/null 2>&1 || true); exit 1; }
  PASS=$((PASS+1))
done
echo "Final code unit tests:"
(cd "$ROOT" && python3 -m unittest discover -s tests 2>&1 | tail -3)
echo "All $PASS lessons passed."
