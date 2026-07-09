#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
#  ChatBantu v2 — Local Development Launcher
#  Real-time: Bantu HTTP + WebSocket Relay
# ════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${PORT:-8080}"
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
  ./dev.sh --port 9000      Use a custom HTTP port
  ./dev.sh --no-browser     Don't auto-open the browser
  ./dev.sh --docker         Run inside Docker
  ./dev.sh --help           Show this help

Architecture:
  Bantu HTTP server  → http://localhost:8080
  WebSocket relay     → ws://localhost:8081
  Embedded TURN       → localhost:3478 (Bantu v1.3.0)

Environment variables:
  PORT      HTTP port (default: 8080)
  WS_PORT   WebSocket relay port (default: 8081)
  DB_PATH   SQLite path (default: ./chatbantu.db)
EOF
      exit 0 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

export PORT
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

# Check for bantu binary
BANTU_BIN="$SCRIPT_DIR/bantu"
if [[ ! -x "$BANTU_BIN" ]]; then
  echo "✗ Bantu binary not found at: $BANTU_BIN"
  echo "  Run: ./dev.sh --build"
  exit 1
fi

# Check for wsrelay binary
WSRELAY_BIN="$SCRIPT_DIR/wsrelay"
if [[ ! -x "$WSRELAY_BIN" ]]; then
  echo "▶ wsrelay not found, building from source…"
  if command -v gcc >/dev/null 2>&1; then
    gcc -O2 -pthread -o "$WSRELAY_BIN" "$SCRIPT_DIR/wsrelay.c" -lsqlite3
    echo "  ✓ wsrelay built"
  else
    echo "✗ gcc not found. Cannot build wsrelay."
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

echo
echo "──────────────────────────────────────────────────────────────────"
echo "  Bantu:    $BANTU_BIN"
echo "  Relay:    $WSRELAY_BIN"
echo "  HTTP:     http://localhost:$PORT"
echo "  WebSocket:ws://localhost:$WS_PORT"
echo "  TURN:     embedded (port 3478)"
echo "  DB:       $DB_PATH"
echo "  Demo:     silivestir / bantu123"
echo "──────────────────────────────────────────────────────────────────"
echo

# Cleanup function
cleanup() {
  echo ""
  echo "▶ Shutting down…"
  kill $WSRELAY_PID 2>/dev/null || true
  wait $WSRELAY_PID 2>/dev/null || true
  echo "  ✓ Stopped"
  exit 0
}
trap cleanup SIGINT SIGTERM

# Start WebSocket relay in background
echo "▶ Starting WebSocket relay on port $WS_PORT…"
"$WSRELAY_BIN" "$WS_PORT" "$DB_PATH" &
WSRELAY_PID=$!
sleep 0.5

# Verify relay started
if ! kill -0 $WSRELAY_PID 2>/dev/null; then
  echo "✗ WebSocket relay failed to start"
  exit 1
fi
echo "  ✓ WebSocket relay running (pid $WSRELAY_PID)"

# Open browser
if [[ "$OPEN_BROWSER" -eq 1 ]]; then
  (sleep 1.5 && {
    URL="http://localhost:$PORT"
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$URL" >/dev/null 2>&1 || true
    elif command -v open >/dev/null 2>&1; then
      open "$URL" >/dev/null 2>&1 || true
    fi
  }) &
fi

echo "▶ Starting Bantu HTTP server on port $PORT…"
echo ""
exec "$BANTU_BIN" run "$SCRIPT_DIR/server.b" &
BANTU_PID=$!
wait $BANTU_PID 2>/dev/null
cleanup