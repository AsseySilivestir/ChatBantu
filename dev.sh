#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
#  ChatBantu v2 — Local Development Launcher
#  Real-time: Bantu HTTP + WebSocket Relay (via nginx proxy)
#
#  Architecture (same as Docker/Render):
#    nginx on $PORT (default 8080) — the ONLY port browsers need
#      /ws/*  → wsrelay (port 8081, internal)
#      /*     → Bantu HTTP (port 9080, internal)
#
#  If nginx is not installed, falls back to direct mode:
#    Bantu on $PORT, wsrelay on 8081 (WebSocket won't work
#    because /ws hits Bantu, not wsrelay — install nginx!)
# ════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${PORT:-8080}"
BANTU_INTERNAL_PORT=9080
WS_PORT="${WS_PORT:-8081}"
DB_PATH="${DB_PATH:-./chatbantu.db}"
OPEN_BROWSER=1
REBUILD=0
RESET_DB=0
USE_DOCKER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)         REBUILD=1; shift ;;
    --reset-db)      RESET_DB=1; shift ;;
    --port)          PORT="$2"; shift 2 ;;
    --no-browser)    OPEN_BROWSER=0; shift ;;
    --docker)        USE_DOCKER=1; shift ;;
    --help|-h)
      cat <<'EOF'
ChatBantu v2 — Real-Time Social Network

Usage:
  ./dev.sh                  Run the app (default)
  ./dev.sh --build          Rebuild Bantu + wsrelay from source
  ./dev.sh --reset-db       Wipe chatbantu.db before starting
  ./dev.sh --port 9000      Use a custom external port
  ./dev.sh --no-browser     Don't auto-open the browser
  ./dev.sh --docker         Run inside Docker (uses Dockerfile)
  ./dev.sh --help           Show this help

Architecture (with nginx):
  nginx (external)   → http://localhost:8080
  Bantu HTTP (int.)  → http://localhost:9080
  WebSocket relay    → ws://localhost:8081 (routed via nginx /ws)
  Embedded TURN      → localhost:3478 (Bantu v1.3.0)

Requirements for real-time:
  - nginx (for /ws → wsrelay proxy). Falls back to API-only without it.

Environment variables:
  PORT      External port (default: 8080)
  WS_PORT   WebSocket relay port (default: 8081)
  DB_PATH   SQLite path (default: ./chatbantu.db)
EOF
      exit 0 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

export DB_PATH

if [[ "$USE_DOCKER" -eq 1 ]]; then
  echo "▶ Starting ChatBantu in Docker (port $PORT)…"
  if ! command -v docker >/dev/null 2>&1; then
    echo "✗ docker not found." >&2; exit 1
  fi
  PORT="$PORT" docker compose -f docker-compose.dev.yml up --build
  exit 0
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ChatBantu v2 — Real-Time Social Network                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

# Check for bantu binary — prefer local dir, fall back to PATH (Docker)
BANTU_BIN=""
if [[ -x "$SCRIPT_DIR/bantu" ]]; then
  BANTU_BIN="$SCRIPT_DIR/bantu"
elif BANTU_BIN="$(command -v bantu 2>/dev/null)" && [[ -n "$BANTU_BIN" ]]; then
  true  # found on PATH (e.g. /usr/local/bin/bantu in Docker)
fi
if [[ -z "$BANTU_BIN" || ! -x "$BANTU_BIN" ]]; then
  echo "✗ Bantu binary not found (tried: $SCRIPT_DIR/bantu, PATH)"
  echo "  Run: ./dev.sh --build"
  exit 1
fi

# Check for wsrelay binary — prefer local dir, fall back to PATH (Docker)
WSRELAY_BIN=""
if [[ -x "$SCRIPT_DIR/wsrelay" ]]; then
  WSRELAY_BIN="$SCRIPT_DIR/wsrelay"
elif WSRELAY_BIN="$(command -v wsrelay 2>/dev/null)" && [[ -n "$WSRELAY_BIN" ]]; then
  true  # found on PATH
else
  # Try to build from source if gcc is available
  if [[ -f "$SCRIPT_DIR/wsrelay.c" ]] && command -v gcc >/dev/null 2>&1; then
    echo "▶ wsrelay not found, building from source…"
    gcc -O2 -pthread -o "$SCRIPT_DIR/wsrelay" "$SCRIPT_DIR/wsrelay.c" -lsqlite3
    WSRELAY_BIN="$SCRIPT_DIR/wsrelay"
    echo "  ✓ wsrelay built"
  else
    echo "✗ wsrelay binary not found (tried: $SCRIPT_DIR/wsrelay, PATH)"
    echo "  gcc not available for source build either."
    exit 1
  fi
fi

# Check shared libraries
echo "▶ Checking shared libraries…"
ldd "$BANTU_BIN" 2>/dev/null | grep -E "not found" && {
  echo "✗ Missing shared libraries."
  exit 1
} || echo "  ✓ All shared libraries available"

# Optional: rebuild
if [[ "$REBUILD" -eq 1 ]]; then
  echo "▶ Rebuilding Bantu from source…"
  cd "$SCRIPT_DIR/bantu-src/compiler"
  if [[ ! -x ./build.sh ]]; then chmod +x ./build.sh; fi
  ./build.sh
  cp -f ./build/bantu "$SCRIPT_DIR/bantu"
  chmod +x "$SCRIPT_DIR/bantu"
  cd "$SCRIPT_DIR"
  echo "  ✓ Bantu rebuilt"

  echo "▶ Rebuilding wsrelay…"
  gcc -O2 -pthread -o "$WSRELAY_BIN" "$SCRIPT_DIR/wsrelay.c" -lsqlite3
  echo "  ✓ wsrelay rebuilt"
fi

# Optional: reset DB
if [[ "$RESET_DB" -eq 1 ]]; then
  echo "▶ Resetting database…"
  rm -f "$SCRIPT_DIR/chatbantu.db" "$SCRIPT_DIR/chatbantu.db-wal" "$SCRIPT_DIR/chatbantu.db-shm"
  echo "  ✓ Database deleted"
fi

# ── Check for nginx ──────────────────────────────────────────────
HAS_NGINX=0
NGINX_BIN=""
if NGINX_BIN="$(command -v nginx 2>/dev/null)" && [[ -n "$NGINX_BIN" ]]; then
  HAS_NGINX=1
fi

if [[ "$HAS_NGINX" -eq 0 ]]; then
  echo "⚠  nginx not found — running in direct mode."
  echo "   Real-time features (online status, live messages, notifications)"
  echo "   will NOT work. Install nginx for full real-time support:"
  echo "   sudo apt install nginx  OR  brew install nginx"
  echo ""
  DIRECT_MODE=1
else
  DIRECT_MODE=0
fi

echo
echo "──────────────────────────────────────────────────────────────────"
echo "  Bantu:    $BANTU_BIN"
echo "  Relay:    $WSRELAY_BIN"
if [[ "$DIRECT_MODE" -eq 0 ]]; then
  echo "  Mode:     nginx proxy (real-time ENABLED)"
  echo "  External: http://localhost:$PORT"
  echo "  Bantu:    http://localhost:$BANTU_INTERNAL_PORT (internal)"
  echo "  WS Relay: ws://localhost:$WS_PORT (proxied via /ws)"
else
  echo "  Mode:     DIRECT (real-time DISABLED — install nginx)"
  echo "  HTTP:     http://localhost:$PORT"
  echo "  WS Relay: ws://localhost:$WS_PORT (NOT proxied)"
fi
echo "  TURN:     embedded (port 3478, local dev only)"
echo "  DB:       $DB_PATH"
echo "  Demo:     silivestir / bantu123"
echo "──────────────────────────────────────────────────────────────────"
echo

# ── PIDs for cleanup ─────────────────────────────────────────────
WSRELAY_PID=""
BANTU_PID=""
NGINX_PID=""

cleanup() {
  echo ""
  echo "▶ Shutting down…"
  [[ -n "$NGINX_PID" ]] && { nginx -s stop 2>/dev/null || kill "$NGINX_PID" 2>/dev/null; } || true
  [[ -n "$BANTU_PID" ]]  && kill "$BANTU_PID" 2>/dev/null || true
  [[ -n "$WSRELAY_PID" ]] && kill "$WSRELAY_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  # Remove temp nginx config
  rm -f "$SCRIPT_DIR/.dev-nginx.conf"
  echo "  ✓ Stopped"
  exit 0
}
trap cleanup SIGINT SIGTERM

# ── Start WebSocket relay on 8081 (internal) ─────────────────────
echo "▶ Starting WebSocket relay on 127.0.0.1:$WS_PORT…"
"$WSRELAY_BIN" "$WS_PORT" "$DB_PATH" &
WSRELAY_PID=$!
sleep 0.3
if ! kill -0 "$WSRELAY_PID" 2>/dev/null; then
  echo "✗ WebSocket relay failed to start"; exit 1
fi
echo "  ✓ wsrelay running (pid $WSRELAY_PID)"

# ── Determine Bantu port ─────────────────────────────────────────
if [[ "$DIRECT_MODE" -eq 1 ]]; then
  BANTU_LISTEN_PORT="$PORT"
else
  BANTU_LISTEN_PORT="$BANTU_INTERNAL_PORT"
fi

# ── Start Bantu HTTP (internal port 9080 if nginx, else $PORT) ──
echo "▶ Starting Bantu HTTP on 127.0.0.1:$BANTU_LISTEN_PORT…"
PORT="$BANTU_LISTEN_PORT" "$BANTU_BIN" run "$SCRIPT_DIR/server.b" &
BANTU_PID=$!
sleep 0.5
if ! kill -0 "$BANTU_PID" 2>/dev/null; then
  echo "✗ Bantu HTTP failed to start"; exit 1
fi
echo "  ✓ Bantu running (pid $BANTU_PID)"

# ── Start nginx proxy (if available) ─────────────────────────────
if [[ "$DIRECT_MODE" -eq 0 ]]; then
  echo "▶ Generating nginx config for port $PORT…"
  cat > "$SCRIPT_DIR/.dev-nginx.conf" <<NGINX
worker_processes 1;
daemon on;
error_log /dev/stderr warn;
pid $SCRIPT_DIR/.dev-nginx.pid;

events {
    worker_connections 256;
}

http {
    access_log /dev/stdout combined;

    upstream bantu_http {
        server 127.0.0.1:$BANTU_INTERNAL_PORT;
    }
    upstream ws_relay {
        server 127.0.0.1:$WS_PORT;
    }

    server {
        listen $PORT;
        server_name localhost;

        location /ws {
            proxy_pass http://ws_relay;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 86400s;
            proxy_send_timeout 86400s;
        }

        location / {
            proxy_pass http://bantu_http;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }
}
NGINX

  echo "▶ Starting nginx on port $PORT…"
  nginx -c "$SCRIPT_DIR/.dev-nginx.conf"
  NGINX_PID=$(cat "$SCRIPT_DIR/.dev-nginx.pid" 2>/dev/null || echo "")
  echo "  ✓ nginx running (pid ${NGINX_PID:-unknown})"
fi

# ── Open browser ─────────────────────────────────────────────────
if [[ "$OPEN_BROWSER" -eq 1 ]]; then
  (sleep 1 && {
    URL="http://localhost:$PORT"
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$URL" >/dev/null 2>&1 || true
    elif command -v open >/dev/null 2>&1; then
      open "$URL" >/dev/null 2>&1 || true
    fi
  }) &
fi

echo ""
if [[ "$DIRECT_MODE" -eq 0 ]]; then
  echo "  ✅ ALL REAL-TIME FEATURES ENABLED via nginx proxy"
else
  echo "  ⚠️  Running without nginx — real-time features disabled"
  echo "     Install nginx for online status, live messages & notifications"
fi
echo "  Open http://localhost:$PORT"
echo ""

# Wait for background processes
wait $BANTU_PID 2>/dev/null
cleanup