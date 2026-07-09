# ChatBantu v2 — Real-Time Social Network

A full-featured social network built entirely with [Bantu](https://github.com/AsseySilivestir/Bantu) v1.3.0, the Sua web framework, and SQLite. No Node.js, no Python, no external databases.

**v2 rewrite: WebSocket real-time everything. Zero polling.**

## What's New in v2

| Feature | v1 (Polling) | v2 (Real-Time) |
|---------|-------------|----------------|
| Chat | HTTP poll every 1.5s | WebSocket — instant |
| Video/Voice calls | HTTP poll for SDP/ICE | WebSocket — instant |
| Presence | Heartbeat every 30s | WebSocket connections |
| Call signaling | 6 REST endpoints + SQLite | WebSocket relay |
| ICE/STUN | Google public STUN only | Embedded TURN (port 3478) |
| Incoming calls | No UI (manual URL) | Full-screen call overlay |

## Architecture

```
Browser (JS)                    Server
┌─────────────┐    WebSocket    ┌──────────────┐
│  chat.html  │ ◄────────────► │  wsrelay      │ (port 8081)
│  feed.html  │                 │  (C, pthread) │
│  call.html  │    HTTP/REST    ├──────────────┤
│             │ ◄────────────► │  Bantu server │ (port 8080)
└─────────────┘                 │  server.b     │
                                │  + SQLite     │
                                ├──────────────┤
                                │  Embedded     │
                                │  TURN server  │ (port 3478)
                                └──────────────┘
```

- **Bantu HTTP server** (`server.b`): REST API, static files, message persistence
- **wsrelay** (`wsrelay.c`): WebSocket relay — authenticates users, routes messages peer-to-peer
- **Embedded TURN** (Bantu v1.3.0): NAT traversal for WebRTC, no external STUN/TURN needed

## Quick Start

### Local (Linux)

```bash
# 1. Clone
git clone https://github.com/AsseySilivestir/ChatBantu.git
cd ChatBantu

# 2. Build wsrelay
gcc -O2 -pthread -o wsrelay wsrelay.c -lsqlite3

# 3. Build Bantu (if not using pre-built binary)
cd bantu-src/compiler && chmod +x build.sh && ./build.sh
cp build/bantu ../../bantu && cd ../..

# 4. Run both servers
./dev.sh
# Or: make run
```

Opens at **http://localhost:8080** — login with `silivestir / bantu123`.

### Docker

```bash
docker compose -f docker-compose.dev.yml up --build
```

### Deploy (Render)

The Dockerfile builds both `bantu` and `wsrelay` from source, then runs them together. Push to GitHub and connect to Render.

## Features

- **Real-time chat** — messages delivered instantly via WebSocket
- **Video & voice calls** — WebRTC with embedded TURN relay
- **Social feed** — posts, likes, comments
- **People discovery** — follow/unfollow, online presence
- **Notifications** — likes, comments, follows, messages, calls
- **Incoming call UI** — full-screen overlay with accept/decline
- **Zero polling** — all real-time data flows through WebSocket

## Tech Stack

- **Language**: Bantu (tree-walking interpreter, C++17)
- **Framework**: Sua (Bantu's web framework)
- **Database**: SQLite (WAL mode)
- **Real-time**: Custom C WebSocket relay (`wsrelay.c`)
- **WebRTC**: Browser native + embedded TURN (Bantu v1.3.0)
- **Frontend**: Vanilla JS, no frameworks

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | HTTP server port |
| `WS_PORT` | `8081` | WebSocket relay port |
| `DB_PATH` | `./chatbantu.db` | SQLite database path |