#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
#  ChatBantu v2 — Docker/Render Entrypoint
#  Single-port architecture: nginx on $PORT multiplexes all traffic.
#    /ws/*  → wsrelay (port 8081, internal only)
#    /*     → Bantu HTTP (port 8080, internal only)
# ════════════════════════════════════════════════════════════════════
set -euo pipefail

PORT="${PORT:-10000}"
DB_PATH="${DB_PATH:-/data/chatbantu.db}"
BANTU_PORT=8080
RELAY_PORT=8081

echo "═══════════════════════════════════════════════════════════════"
echo "  ChatBantu v2 — Starting (single-port mode)"
echo "  External port:  $PORT (nginx)"
echo "  Bantu HTTP:     127.0.0.1:$BANTU_PORT (internal)"
echo "  WS Relay:       127.0.0.1:$RELAY_PORT (internal)"
echo "  Database:       $DB_PATH"
echo "═══════════════════════════════════════════════════════════════"

# ── Pre-flight checks ──────────────────────────────────────────────
echo "▶ Pre-flight library check…"
ldd /usr/local/bin/bantu 2>/dev/null | grep -E "not found" && {
  echo "✗ Missing shared libraries for bantu"; exit 1;
}
ldd /usr/local/bin/wsrelay 2>/dev/null | grep -E "not found" && {
  echo "✗ Missing shared libraries for wsrelay"; exit 1;
}
echo "  ✓ All libraries OK"

# ── Patch nginx.conf to listen on $PORT ───────────────────────────
echo "▶ Configuring nginx on port $PORT…"
sed -i "s/listen [0-9]*/listen ${PORT}/" /etc/nginx/nginx.conf
echo "  ✓ nginx configured"

# ── Start WebSocket relay on 8081 (internal) ─────────────────────
echo "▶ Starting WebSocket relay on 127.0.0.1:$RELAY_PORT…"
/usr/local/bin/wsrelay "$RELAY_PORT" "$DB_PATH" &
WSRELAY_PID=$!
sleep 0.3
if ! kill -0 "$WSRELAY_PID" 2>/dev/null; then
  echo "✗ WebSocket relay failed to start"; exit 1;
fi
echo "  ✓ wsrelay running (pid $WSRELAY_PID)"

# ── Start Bantu HTTP on 8080 (internal) ───────────────────────────
echo "▶ Starting Bantu HTTP on 127.0.0.1:$BANTU_PORT…"
PORT="$BANTU_PORT" DB_PATH="$DB_PATH" /usr/local/bin/bantu run /app/server.b &
BANTU_PID=$!
sleep 0.5
if ! kill -0 "$BANTU_PID" 2>/dev/null; then
  echo "✗ Bantu HTTP failed to start"; exit 1;
fi
echo "  ✓ Bantu running (pid $BANTU_PID)"

# ── Start nginx on $PORT (the ONLY external port) ────────────────
echo "▶ Starting nginx on port $PORT (external)…"
nginx
echo "  ✓ nginx running"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ChatBantu v2 is LIVE"
echo "  All traffic enters via port $PORT (nginx)"
echo "  /ws/*  → real-time WebSocket relay"
echo "  /*     → Bantu HTTP API + static files"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ── Wait for any process to exit, then clean up ───────────────────
wait -n $WSRELAY_PID $BANTU_PID 2>/dev/null || true
echo "▶ A process exited — shutting down…"
kill "$WSRELAY_PID" 2>/dev/null || true
kill "$BANTU_PID" 2>/dev/null || true
wait 2>/dev/null || true
echo "  ✓ Stopped"