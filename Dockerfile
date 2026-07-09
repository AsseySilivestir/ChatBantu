# ════════════════════════════════════════════════════════════════════
#  ChatBantu v2 — Multi-stage Dockerfile for Render
#  Real-time: WebSocket relay + embedded TURN (Bantu v1.3.0)
#
#  ARCHITECTURE (single-port for Render):
#    Render exposes only $PORT (10000). All traffic enters through
#    nginx on that port, which multiplexes:
#      /ws/*  → wsrelay (port 8081, internal only)
#      /*     → Bantu HTTP (port 8080, internal only)
# ════════════════════════════════════════════════════════════════════

# ─── Stage 1: Builder ──────────────────────────────────────────────
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        g++ \
        gcc \
        make \
        binutils \
        file \
        libsqlite3-dev \
        libcurl4-openssl-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build Bantu interpreter
COPY bantu-src/compiler/ /build/compiler/
RUN cd /build/compiler \
    && chmod +x build.sh \
    && ./build.sh

RUN test -f /build/compiler/build/bantu \
    && cp /build/compiler/build/bantu /build/bantu \
    && chmod +x /build/bantu

# Build wsrelay (WebSocket relay server)
COPY wsrelay.c /build/wsrelay.c
RUN gcc -O2 -pthread -o /build/wsrelay /build/wsrelay.c -lsqlite3 \
    && chmod +x /build/wsrelay

# ─── Stage 2: Runtime ──────────────────────────────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Africa/Dar_es_Salaam

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libsqlite3-0 \
        ca-certificates \
        sqlite3 \
        libcurl4 \
        nginx \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy binaries
COPY --from=builder /build/bantu /usr/local/bin/bantu
COPY --from=builder /build/wsrelay /usr/local/bin/wsrelay
RUN chmod +x /usr/local/bin/bantu /usr/local/bin/wsrelay

# Copy application
COPY server.b /app/server.b
COPY public/  /app/public/

# Copy nginx config — overwrites default
COPY nginx.conf /etc/nginx/nginx.conf

# Copy and prepare entrypoint
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

# Remove default nginx site config (we use /etc/nginx/nginx.conf directly)
RUN rm -f /etc/nginx/sites-enabled/default

RUN mkdir -p /data && chmod 777 /data

# Render sets PORT=10000 — nginx will listen on this port
ENV PORT=10000
ENV PATH="/usr/local/bin:${PATH}"

# Expose only the nginx port — the single port Render forwards to
EXPOSE ${PORT}

# Entrypoint: starts wsrelay + bantu internally, then nginx on $PORT
CMD ["/app/docker-entrypoint.sh"]