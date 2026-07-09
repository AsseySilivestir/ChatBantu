# ════════════════════════════════════════════════════════════════════
#  ChatBantu v2 — Makefile (Real-Time: HTTP + WebSocket Relay)
# ════════════════════════════════════════════════════════════════════

PORT     ?= 8080
WS_PORT  ?= 8081
DB_PATH  ?= ./chatbantu.db
BANTU    := ./bantu
WSRELAY  := ./wsrelay
LOG_FILE := /tmp/chatbantu.log
PID_FILE := /tmp/chatbantu.pid
WS_PID   := /tmp/chatbantu-ws.pid

.PHONY: help run bg stop logs docker build build-relay reset-db test clean

help: ## Show this help
	@echo "ChatBantu v2 — real-time social network"
	@echo
	@echo "  make run         Start HTTP + WebSocket relay (foreground)"
	@echo "  make bg          Start in background"
	@echo "  make stop        Stop background servers"
	@echo "  make build       Rebuild bantu binary"
	@echo "  make build-relay Rebuild wsrelay binary"
	@echo "  make test        Smoke test health + login"
	@echo "  make reset-db    Wipe database"
	@echo "  make clean       Remove all artifacts"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

run: ## Start ChatBantu (HTTP + WS relay) in foreground
	@echo "Starting wsrelay on port $(WS_PORT)…"
	@$(WSRELAY) $(WS_PORT) $(DB_PATH) & echo $$! > $(WS_PID)
	@sleep 0.5
	@echo "Starting Bantu HTTP on port $(PORT)…"
	@PORT=$(PORT) DB_PATH=$(DB_PATH) $(BANTU) run server.b; \
	  kill $$(cat $(WS_PID)) 2>/dev/null; rm -f $(WS_PID)

bg: ## Start ChatBantu in the background
	@echo "Starting on port $(PORT) + WS port $(WS_PORT)…"
	@$(WSRELAY) $(WS_PORT) $(DB_PATH) > /dev/null 2>&1 & echo $$! > $(WS_PID)
	@PORT=$(PORT) DB_PATH=$(DB_PATH) nohup $(BANTU) run server.b > $(LOG_FILE) 2>&1 & \
	  echo $$! > $(PID_FILE)
	@sleep 1 && curl -fsS "http://localhost:$(PORT)/api/health" && echo ""
	@echo "Running. HTTP PID=$$(cat $(PID_FILE)), WS PID=$$(cat $(WS_PID))"

stop: ## Stop background servers
	@if [ -f $(PID_FILE) ]; then \
	  kill $$(cat $(PID_FILE)) 2>/dev/null || true; rm -f $(PID_FILE); fi
	@if [ -f $(WS_PID) ]; then \
	  kill $$(cat $(WS_PID)) 2>/dev/null || true; rm -f $(WS_PID); fi
	@echo "Stopped"

logs: ## Tail server logs
	@tail -f $(LOG_FILE)

docker: ## Start in Docker
	PORT=$(PORT) docker compose -f docker-compose.dev.yml up --build

build: ## Rebuild bantu binary from source
	cd bantu-src/compiler && ./build.sh
	cp -f bantu-src/compiler/build/bantu ./bantu
	chmod +x ./bantu
	@echo "Bantu rebuilt"

build-relay: ## Rebuild wsrelay from source
	gcc -O2 -pthread -o $(WSRELAY) wsrelay.c -lsqlite3
	@echo "wsrelay rebuilt"

reset-db: ## Wipe database
	rm -f chatbantu.db chatbantu.db-wal chatbantu.db-shm
	@echo "Database reset"

test: ## Smoke test: health + login
	@echo "Health check..."
	@curl -fsS "http://localhost:$(PORT)/api/health" | head -c 300; echo ""
	@echo "Login as silivestir..."
	@curl -fsS -X POST "http://localhost:$(PORT)/api/auth/login" \
	  -H "Content-Type: application/json" \
	  -d '{"username":"silivestir","password":"bantu123"}' | head -c 300; echo ""

clean: ## Remove all artifacts
	rm -f chatbantu.db chatbantu.db-wal chatbantu.db-shm $(LOG_FILE) $(PID_FILE) $(WS_PID)
	rm -rf bantu-src/compiler/build
	rm -f $(WSRELAY)
	@echo "Cleaned"