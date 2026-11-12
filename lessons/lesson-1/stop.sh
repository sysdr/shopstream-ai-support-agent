#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT/supportdesk"
PID_FILE="$PROJECT_DIR/.run/app.pid"

echo "[INFO] Stopping ShopStream SupportDesk background services..."

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        echo "[INFO] Process $PID stopped."
    else
        echo "[INFO] Process $PID was not running."
    fi
    rm -f "$PID_FILE"
else
    echo "[INFO] No running PID file found."
fi

# Clean up log and run artifacts if present
rm -rf "$PROJECT_DIR/.run/*.log" 2>/dev/null || true

echo "[INFO] Cleanup complete."