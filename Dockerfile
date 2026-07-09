# ════════════════════════════════════════════════════════════════════
#  ChatBantu v2 — Multi-stage Dockerfile for Render
#  Real-time: WebSocket relay + embedded TURN (Bantu v1.3.0)
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
    && file /build/compiler/build/bantu \
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
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy binaries
COPY --from=builder /build/bantu /usr/local/bin/bantu
COPY --from=builder /build/wsrelay /usr/local/bin/wsrelay
RUN chmod +x /usr/local/bin/bantu /usr/local/bin/wsrelay

# Copy application
COPY server.b /app/server.b
COPY public/  /app/public/

RUN mkdir -p /data && chmod 777 /data

ENV PORT=8080
EXPOSE 8080 8081

RUN echo "=== Pre-flight ===" \
    && ldd /usr/local/bin/bantu \
    && ldd /usr/local/bin/wsrelay \
    && /usr/local/bin/bantu --version

# Start both Bantu HTTP server AND WebSocket relay
COPY dev.sh /app/dev.sh
RUN chmod +x /app/dev.sh
CMD ["/app/dev.sh"]