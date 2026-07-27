#!/bin/bash
# Serves the build control center over the LAN on port 8420.
# Usage: serve-status.sh [start|stop|reload|status]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$ROOT/scripts/nginx.conf"
PID="$ROOT/.nginx/nginx.pid"
PORT=8420

mkdir -p "$ROOT/.nginx/tmp"

case "${1:-start}" in
  start)
    if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
      echo "already running (pid $(cat "$PID"))"
    else
      nginx -c "$CONF"
      echo "started"
    fi
    IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)
    echo "  http://$IP:$PORT   (LAN)"
    echo "  http://localhost:$PORT"
    ;;
  stop)
    [ -f "$PID" ] && nginx -c "$CONF" -s quit && echo "stopped" || echo "not running"
    ;;
  reload)
    nginx -c "$CONF" -s reload && echo "reloaded"
    ;;
  status)
    if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
      echo "running (pid $(cat "$PID")) on port $PORT"
    else
      echo "not running"
    fi
    ;;
  *)
    echo "usage: $0 [start|stop|reload|status]" >&2
    exit 1
    ;;
esac
