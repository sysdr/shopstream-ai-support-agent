#!/usr/bin/env bash
# Stop SupportDesk (exits 0 even if nothing is running).
ROOT="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$ROOT/supportdesk/.run/app.pid"
if [ -f "$PID_FILE" ]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null && echo "[INFO] SupportDesk stopped." || echo "[INFO] SupportDesk was not running."
  rm -f "$PID_FILE"
else
  echo "[INFO] Nothing to stop."
fi
exit 0
