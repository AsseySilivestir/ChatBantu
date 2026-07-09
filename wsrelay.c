{#include <stddef.h>}
Written wsrelay.c
” Standalone WebSocket Relay Server for ChatBantu
 *
 * Compiles: gcc -O2 -pthread -o wsrelay wsrelay.c -ldl -lsqlite3
 * Runs:     ./wsrelay 8081 /path/to/chatbantu.db
 *
 * Protocol:
 *   - WebSocket on /ws?token=<auth_token>
 *   - HTTP POST  /send  { to: userId, from: userId, type: "...", data: {...} }
 *   - HTTP GET   /online  -> { online: [{id, username}, ...] }
 *   - HTTP POST  /broadcast  { type: "...", data: {...} } -> all connected
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <sqlite3.h>

#define MAX_CLIENTS 1024
#define WS_BUF_SIZE 65536
#define SHA1_DIGEST_LENGTH 20

typedef struct {
    int fd;
    int userId;
    char username[128];
    char token[512];
    int alive;
    time_t connectedAt;
} WsClient;

static WsClient clients[MAX_CLIENTS];
static pthread_mutex_t clients_mutex = PTHREAD_MUTEX_INITIALIZER;
static sqlite3 *auth_db = NULL;
static int relay_port = 8081;

static const uint32_t sha1_k[64] = {
    0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999,
    0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999,
    0x5A827999, 0x5A827999, 0x5A827999, 0x5A827999, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1,
    0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1,
    0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1, 0x6ED9EBA1,
    0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC,
    0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC,
    0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0x8F1BBCDC, 0xCA62C1D6, 0xCA62C1D6, 0xCA62C1D6, 0xCA62C1D6
};


static uint32_t sha1_rotl(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

static void sha1(const unsigned char *msg, size_t len, unsigned char out[SHA1_DIGEST_LENGTH]) {
    uint32_t h0=0x67452301, h1=0xEFCDAB89, h2=0x98BADCFE, h3=0x10325476, h4=0xC3D2E1F0;
    size_t newlen = len + 1 + 8;
    while (newlen % 64 != 0) newlen++;
    unsigned char *buf = calloc(newlen, 1);
    memcpy(buf, msg, len);
    buf[len] = 0x80;
    uint64_t bitlen = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++) buf[newlen - 1 - i] = (bitlen >> (i * 8)) & 0xFF;
    for (size_t chunk = 0; chunk < newlen; chunk += 64) {
        uint32_t w[80];
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)buf[chunk+i*4]<<24)|((uint32_t)buf[chunk+i*4+1]<<16)|
                    ((uint32_t)buf[chunk+i*4+2]<<8)|((uint32_t)buf[chunk+i*4+3]);
        for (int i = 16; i < 80; i++)
            w[i] = sha1_rotl(w[i-3]^w[i-8]^w[i-14]^w[i-16], 1);
        uint32_t a=h0, b=h1, c=h2, d=h3, e=h4;
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20)      { f = (b&c)|((~b)&d); k = sha1_k[0]; }
            else if (i < 40) { f = b^c^d;            k = sha1_k[20]; }
            else if (i < 60) { f = (b&c)|(b&d)|(c&d); k = sha1_k[40]; }
            else              { f = b^c^d;            k = sha1_k[60]; }
            uint32_t temp = sha1_rotl(a,5) + f + e + k + w[i];
            e = d; d = c; c = sha1_rotl(b,30); b = a; a = temp;
        }
        h0 += a; h1 += b; h2 += c; h3 += d; h4 += e;
    }
    free(buf);
    uint32_t h[5] = {h0, h1, h2, h3, h4};
    for (int i = 0; i < 5; i++) {
        out[i*4]   = (h[i] >> 24) & 0xFF;
        out[i*4+1] = (h[i] >> 16) & 0xFF;
        out[i*4+2] = (h[i] >> 8)  & 0xFF;
        out[i*4+3] = h[i] & 0xFF;
    }
}

static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void base64_encode(const unsigned char *in, size_t len, char *out) {
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t n = (uint32_t)in[i] << 16;
        if (i+1 < len) n |= (uint32_t)in[i+1] << 8;
        if (i+2 < len) n |= (uint32_t)in[i+2];
        out[o++] = b64[(n >> 18) & 0x3F];
        out[o++] = b64[(n >> 12) & 0x3F];
        out[o++] = (i+1 < len) ? b64[(n >> 6) & 0x3F] : '=';
        out[o++] = (i+2 < len) ? b64[n & 0x3F] : '=';
    }
    out[o] = '\0';
}

static void ws_compute_accept(const char *key, char *out) {
    const char *magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    size_t keylen = strlen(key);
    size_t magiclen = strlen(magic);
    size_t combolen = keylen + magiclen;
    unsigned char *combined = malloc(combolen);
    memcpy(combined, key, keylen);
    memcpy(combined + keylen, magic, magiclen);
    unsigned char digest[SHA1_DIGEST_LENGTH];
    sha1(combined, combolen, digest);
    free(combined);
    base64_encode(digest, SHA1_DIGEST_LENGTH, out);
}

static int ws_send(int fd, const char *msg, size_t len) {
    unsigned char buf[WS_BUF_SIZE];
    size_t pos = 0;
    buf[pos++] = 0x81;
    if (len < 126) {
        buf[pos++] = (unsigned char)len;
    } else if (len < 65536) {
        buf[pos++] = 126;
        buf[pos++] = (len >> 8) & 0xFF;
        buf[pos++] = len & 0xFF;
    } else {
        buf[pos++] = 127;
        for (int i = 7; i >= 0; i--) buf[pos++] = (len >> (i*8)) & 0xFF;
    }
    memcpy(buf + pos, msg, len);
    pos += len;
    return send(fd, buf, pos, MSG_NOSIGNAL) > 0 ? 0 : -1;
}

static int ws_send_json(int fd, const char *json) {
    return ws_send(fd, json, strlen(json));
}

static ssize_t ws_recv(int fd, char *payload, size_t maxpayload, uint8_t *opcode) {
    unsigned char hdr[2];
    ssize_t n = recv(fd, hdr, 2, 0);
    if (n <= 0) return -1;
    *opcode = hdr[0] & 0x0F;
    int masked = (hdr[1] & 0x80) != 0;
    uint64_t payload_len = hdr[1] & 0x7F;
    size_t hdr_len = 2;
    if (payload_len == 126) {
        unsigned char ext[2]; if (recv(fd, ext, 2, 0) != 2) return -1;
        payload_len = ((uint64_t)ext[0] << 8) | ext[1]; hdr_len = 4;
    } else if (payload_len == 127) {
        unsigned char ext[8]; if (recv(fd, ext, 8, 0) != 8) return -1;
        payload_len = 0;
        for (int i = 0; i < 8; i++) payload_len = (payload_len << 8) | ext[i];
        hdr_len = 10;
    }
    unsigned char mask[4] = {0};
    if (masked) { if (recv(fd, mask, 4, 0) != 4) return -1; hdr_len += 4; }
    if (payload_len > maxpayload) payload_len = maxpayload;
    n = recv(fd, (unsigned char*)payload, payload_len, 0);
    if (n <= 0) return -1;
    if (masked) { for (ssize_t i = 0; i < n; i++) payload[i] ^= mask[i % 4]; }
    payload[n] = '\0';
    return n;
}

static int find_client_slot(void) {
    for (int i = 0; i < MAX_CLIENTS; i++) if (!clients[i].alive) return i;
    return -1;
}

static void broadcast_online_status(void) {
    char msg[8192] = "{\"type\":\"presence\",\"online\":[";
    size_t pos = strlen(msg);
    int first = 1;
    pthread_mutex_lock(&clients_mutex);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].alive && clients[i].userId > 0) {
            if (!first) msg[pos++] = ',';
            pos += (size_t)snprintf(msg + pos, sizeof(msg) - pos,
                "{\"id\":%d,\"name\":\"%s\"}", clients[i].userId, clients[i].username);
            first = 0;
        }
    }
    pthread_mutex_unlock(&clients_mutex);
    pos += (size_t)snprintf(msg + pos, sizeof(msg) - pos, "]}");
    pthread_mutex_lock(&clients_mutex);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].alive) ws_send_json(clients[i].fd, msg);
    }
    pthread_mutex_unlock(&clients_mutex);
}

static int send_to_user(int userId, const char *json) {
    pthread_mutex_lock(&clients_mutex);
    int sent = 0;
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].alive && clients[i].userId == userId) {
            ws_send_json(clients[i].fd, json);
            sent = 1; break;
        }
    }
    pthread_mutex_unlock(&clients_mutex);
    return sent;
}

static int broadcast_all(const char *json) {
    pthread_mutex_lock(&clients_mutex);
    int sent = 0;
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].alive) { ws_send_json(clients[i].fd, json); sent++; }
    }
    pthread_mutex_unlock(&clients_mutex);
    return sent;
}

static int auth_verify_token(const char *token, int *out_userId, char *out_username, size_t name_max) {
    if (!auth_db || !token || !*token) return 0;
    sqlite3_stmt *stmt;
    const char *sql = "SELECT id, username FROM users WHERE token = ? LIMIT 1";
    if (sqlite3_prepare_v2(auth_db, sql, -1, &stmt, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_text(stmt, 1, token, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        *out_userId = sqlite3_column_int(stmt, 0);
        const char *name = (const char *)sqlite3_column_text(stmt, 1);
        if (name) { strncpy(out_username, name, name_max - 1); out_username[name_max - 1] = '\0'; }
        sqlite3_finalize(stmt); return 1;
    }
    sqlite3_finalize(stmt); return 0;
}

static void http_send(int fd, int code, const char *status, const char *ctype, const char *body) {
    char resp[65536];
    int n = (int)snprintf(resp, sizeof(resp),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type\r\n"
        "\r\n%s", code, status, ctype, body ? strlen(body) : 0, body ? body : "");
    send(fd, resp, n, MSG_NOSIGNAL);
}

static int json_get_int(const char *json, const char *key) {
    char search[256], buf[64]; buf[0] = '\0';
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return 0;
    p += strlen(search);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    if (*p != '"') return 0;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i < sizeof(buf) - 1) { if (*p == '\\' && *(p+1)) p++; buf[i++] = *p++; }
    buf[i] = '\0';
    return atoi(buf);
}

static int handle_http_api(int fd, const char *method, const char *path, const char *body) {
    if (strcmp(method, "OPTIONS") == 0) { http_send(fd, 204, "No Content", "text/plain", NULL); return 1; }
    if (strcmp(method, "GET") == 0 && strcmp(path, "/online") == 0) {
        char resp[8192] = "{\"online\":[";
        size_t pos = strlen(resp); int first = 1;
        pthread_mutex_lock(&clients_mutex);
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (clients[i].alive && clients[i].userId > 0) {
                if (!first) resp[pos++] = ',';
                pos += (size_t)snprintf(resp + pos, sizeof(resp) - pos,
                    "{\"id\":%d,\"username\":\"%s\"}", clients[i].userId, clients[i].username);
                first = 0;
            }
        }
        pthread_mutex_unlock(&clients_mutex);
        pos += (size_t)snprintf(resp + pos, sizeof(resp) - pos, "]}");
        http_send(fd, 200, "OK", "application/json", resp); return 1;
    }
    if (strcmp(method, "POST") == 0 && strcmp(path, "/send") == 0) {
        int toUserId = json_get_int(body, "to");
        if (toUserId > 0) {
            char typeBuf[64]; typeBuf[0] = '\0';
            const char *type = "message";
            const char *typeStr = strstr(body, "\"type\"");
            if (typeStr) {
                typeStr += 7;
                const char *val = typeStr;
                while (*val && (*val == ' ' || *val == ':')) val++;
                if (*val == '"') {
                    val++; size_t di = 0;
                    while (*val && *val != '"' && di < sizeof(typeBuf) - 1) {
                        if (*val == '\\' && *(val+1)) val++;
                        typeBuf[di++] = *val++;
                    }
                    typeBuf[di] = '\0';
                    if (di > 0) type = typeBuf;
                }
            }
            char dataBuf[65536]; dataBuf[0] = '\0';
            const char *dataField = strstr(body, "\"data\"");
            if (dataField) {
                dataField += 6;
                while (*dataField && (*dataField == ' ' || *dataField == ':')) dataField++;
                if (*dataField == '"') {
                    dataField++; size_t di = 0;
                    while (*dataField && *dataField != '"' && di < sizeof(dataBuf) - 1) {
                        if (*dataField == '\\' && *(dataField+1)) dataField++;
                        dataBuf[di++] = *dataField++;
                    }
                    dataBuf[di] = '\0';
                }
            }
            int fromId = json_get_int(body, "from");
            char msg[65536];
            snprintf(msg, sizeof(msg),
                "{\"type\":\"%s\",\"from\":%d,\"fromName\":\"%s\",\"data\":%s}",
                type, fromId > 0 ? fromId : 0, "", dataBuf);
            /* Append the rest of the original JSON after "from" for forwarded fields */
            const char *fromStr = strstr(body, "\"from\"");
            if (fromStr) {
                fromStr += 6;
                while (*fromStr && (*fromStr == ' ' || *fromStr == ':')) fromStr++;
                if (*fromStr == '"') {
                    fromStr++;
                    const char *restStart = fromStr;
                    /* Find where the value ends: skip the JSON string value */
                    int depth = 1;
                    while (*restStart && depth > 0) {
                        if (*restStart == '\\') { restStart++; continue; }
                        if (*restStart == '"') depth--;
                        restStart++;
                    }
                    /* Append from=... and everything after it */
                    size_t curLen = strlen(msg);
                    snprintf(msg + curLen, sizeof(msg) - curLen,
                        ",\"from\":%d", fromId > 0 ? fromId : 0);
                    if (restStart) {
                        snprintf(msg + strlen(msg), sizeof(msg) - strlen(msg),
                            ",\"fromName\":\"\""); 
                        /* We just send the type, to, from, fromName, and data â€” 
                           the relay doesn't need the original from value again */
                    }
                }
            }
            int sent = send_to_user(toUserId, msg);
            char resp[256];
            snprintf(resp, sizeof(resp), "{\"sent\":%d}", sent);
            http_send(fd, 200, "OK", "application/json", resp);
        } else {
            http_send(fd, 400, "Bad Request", "application/json", "{\"error\":\"missing to\"}");
        }
        return 1;
    }
    if (strcmp(method, "POST") == 0 && strcmp(path, "/broadcast") == 0) {
        char typeBuf[64]; typeBuf[0] = '\0';
        const char *type = "message";
        const char *typeStr = strstr(body, "\"type\"");
        if (typeStr) {
            typeStr += 7;
            const char *val = typeStr;
            while (*val && (*val == ' ' || *val == ':')) val++;
            if (*val == '"') {
                val++; size_t di = 0;
                while (*val && *val != '"' && di < sizeof(typeBuf) - 1) {
                    if (*val == '\\' && *(val+1)) val++;
                    typeBuf[di++] = *val++;
                }
                typeBuf[di] = '\0';
                if (di > 0) type = typeBuf;
            }
        }
        char dataBuf[65536]; dataBuf[0] = '\0';
        const char *dataField = strstr(body, "\"data\"");
        if (dataField) {
            dataField += 6;
            while (*dataField && (*dataField == ' ' || *dataField == ':')) dataField++;
            if (*dataField == '"') {
                dataField++; size_t di = 0;
                while (*dataField && *dataField != '"' && di < sizeof(dataBuf) - 1) {
                    if (*dataField == '\\' && *(dataField+1)) dataField++;
                    dataBuf[di++] = *dataField++;
                }
                dataBuf[di] = '\0';
            }
        }
        char msg[65536];
        snprintf(msg, sizeof(msg), "{\"type\":\"%s\",\"data\":%s}", type, dataBuf);
        int sent = broadcast_all(msg);
        char resp[256];
        snprintf(resp, sizeof(resp), "{\"sent\":%d}", sent);
        http_send(fd, 200, "OK", "application/json", resp);
        return 1;
    }
    return 0;
}

static int parse_http_request(const char *buf, ssize_t len, char *method, size_t meth_max, char *path, size_t path_max, char *headers, size_t hdr_max, char *body, size_t body_max) {
    method[0] = path[0] = headers[0] = body[0] = '\0';
    if (len <= 0) return -1;
    const char *p = buf;
    int i = 0;
    while (*p && *p != ' ' && *p != '\r' && *p != '\n' && i < (int)meth_max - 1) method[i++] = *p++;
    method[i] = '\0';
    if (*p == ' ') p++;
    i = 0;
    while (*p && *p != ' ' && *p != '\r' && *p != '?' && i < (int)path_max - 1) path[i++] = *p++;
    path[i] = '\0';
    const char *hdr_end = strstr(buf, "\r\n\r\n");
    if (hdr_end) {
        const char *hs = strstr(buf, "\r\n");
        if (hs && hdr_end > hs) {
            size_t hlen = (size_t)(hdr_end - hs);
            if (hlen > hdr_max - 1) hlen = hdr_max - 1;
            memcpy(headers, hs, hlen); headers[hlen] = '\0';
        }
        const char *bs = hdr_end + 4;
        size_t blen = len - (bs - buf);
        if (blen > body_max - 1) blen = body_max - 1;
        memcpy(body, bs, blen); body[blen] = '\0';
    }
    return (strstr(headers, "Upgrade: websocket") != NULL || strstr(headers, "upgrade: websocket") != NULL) ? 1 : 0;
}

static const char *get_query_param(const char *query, const char *key, char *out, size_t max) {
    char search[256]; snprintf(search, sizeof(search), "%s=", key);
    const char *p = strstr(query, search);
    if (!p) return NULL;
    p += strlen(search);
    size_t i = 0;
    while (*p && *p != '&' && *p != ' ' && i < max - 1) out[i++] = *p++;
    out[i] = '\0';
    char *s = out, *d = out;
    while (*s) {
        if (*s == '%' && s[1] && s[2]) { char hex[3] = { s[1], s[2], 0 }; *d++ = (char)strtol(hex, NULL, 16); s += 3; }
        else if (*s == '+') { *d++ = ' '; s++; }
        else { *d++ = *s++; }
    }
    *d = '\0';
    return out;
}

static void *ws_client_handler(void *arg) {
    int slot = *(int *)arg;
    int fd = clients[slot].fd;
    char payload[WS_BUF_SIZE];
    uint8_t opcode;
    printf("  [WS] Client connected: slot=%d fd=%d user=%s (id=%d)\n", slot, fd, clients[slot].username, clients[slot].userId);
    char welcome[512];
    snprintf(welcome, sizeof(welcome), "{\"type\":\"connected\",\"userId\":%d,\"username\":\"%s\"}", clients[slot].userId, clients[slot].username);
    ws_send_json(fd, welcome);
    broadcast_online_status();
    while (clients[slot].alive) {
        ssize_t n = ws_recv(fd, payload, sizeof(payload) - 1, &opcode);
        if (n <= 0) break;
        if (opcode == 0x8) break;
        if (opcode == 0x9) { unsigned char pong[2] = {0x8A, 0x00}; send(fd, pong, 2, MSG_NOSIGNAL); continue; }
        if (opcode != 0x1) continue;
        int toId = json_get_int(payload, "to");
        if (toId > 0) {
            char relay[65536];
            const char *brace = strchr(payload, '{');
            if (brace && brace[1]) {
                snprintf(relay, sizeof(relay), "{\"from\":%d,\"fromName\":\"%s\",%s",
                    clients[slot].userId, clients[slot].username, brace + 1);
            } else {
                snprintf(relay, sizeof(relay), "{\"from\":%d,\"fromName\":\"%s\",\"data\":%s}",
                    clients[slot].userId, clients[slot].username, payload);
            }
            send_to_user(toId, relay);
        }
    }
    printf("  [WS] Client disconnected: slot=%d user=%s (id=%d)\n", slot, clients[slot].username, clients[slot].userId);
    clients[slot].alive = 0;
    close(fd);
    broadcast_online_status();
    return NULL;
}

static volatile int running = 1;
static void sig_handler(int sig) { (void)sig; running = 0; }

int main(int argc, char *argv[]) {
    if (argc < 3) { printf("Usage: %s <port> <database_path>\n", argv[0]); return 1; }
    relay_port = atoi(argv[1]);
    const char *dbpath = argv[2];
    if (sqlite3_open(dbpath, &auth_db) != SQLITE_OK) {
        fprintf(stderr, "  [WS] Failed to open database: %s\n", sqlite3_errmsg(auth_db)); return 1;
    }
    printf("  [WS] Database opened: %s\n", dbpath);
    signal(SIGINT, sig_handler); signal(SIGTERM, sig_handler);
    int servSock = socket(AF_INET, SOCK_STREAM, 0);
    if (servSock < 0) { perror("socket"); return 1; }
    int opt = 1; setsockopt(servSock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = INADDR_ANY; addr.sin_port = htons(relay_port);
    if (bind(servSock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); fprintf(stderr, "  [WS] Failed to bind port %d\n", relay_port); return 1;
    }
    listen(servSock, 128);
    printf("  [WS] WebSocket relay listening on port %d\n  [WS] Ready for connections\n\n", relay_port);
    while (running) {
        struct sockaddr_in clientAddr; socklen_t clientLen = sizeof(clientAddr);
        int clientSock = accept(servSock, (struct sockaddr *)&clientAddr, &clientLen);
        if (clientSock < 0) { if (running) perror("accept"); continue; }
        char buf[16384]; ssize_t n = recv(clientSock, buf, sizeof(buf) - 1, 0);
        if (n <= 0) { close(clientSock); continue; }
        buf[n] = '\0';
        char method[16] = "", path[1024] = "", headers[8192] = "", body[8192] = "";
        int is_ws = parse_http_request(buf, n, method, sizeof(method), path, sizeof(path), headers, sizeof(headers), body, sizeof(body));
        if (is_ws) {
            char wsKey[256] = "";
            const char *keyLine = strstr(headers, "sec-websocket-key:");
            if (!keyLine) keyLine = strstr(headers, "Sec-WebSocket-Key:");
            if (keyLine) {
                keyLine += strlen("sec-websocket-key:");
                while (*keyLine == ' ') keyLine++;
                size_t ki = 0;
                while (*keyLine && *keyLine != '\r' && *keyLine != '\n' && ki < sizeof(wsKey) - 1) wsKey[ki++] = *keyLine++;
                wsKey[ki] = '\0';
            }
            char token[512] = "";
            const char *qmark = strchr(path, '?');
            if (qmark) get_query_param(qmark + 1, "token", token, sizeof(token));
            int userId = 0; char username[128] = "";
            if (!auth_verify_token(token, &userId, username, sizeof(username))) {
                http_send(clientSock, 401, "Unauthorized", "application/json", "{\"error\":\"invalid token\"}");
                close(clientSock); continue;
            }
            char acceptKey[128];
            ws_compute_accept(wsKey, acceptKey);
            char resp[1024];
            int rlen = (int)snprintf(resp, sizeof(resp),
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                "Sec-WebSocket-Accept: %s\r\n\r\n", acceptKey);
            send(clientSock, resp, rlen, MSG_NOSIGNAL);
            pthread_mutex_lock(&clients_mutex);
            int slot = find_client_slot();
            if (slot < 0) { pthread_mutex_unlock(&clients_mutex); close(clientSock); continue; }
            clients[slot].fd = clientSock; clients[slot].userId = userId;
            strncpy(clients[slot].username, username, sizeof(clients[slot].username) - 1);
            strncpy(clients[slot].token, token, sizeof(clients[slot].token) - 1);
            clients[slot].alive = 1; clients[slot].connectedAt = time(NULL);
            int slotCopy = slot;
            pthread_mutex_unlock(&clients_mutex);
            pthread_t tid;
            pthread_create(&tid, NULL, ws_client_handler, &slotCopy);
            pthread_detach(tid);
        } else {
            handle_http_api(clientSock, method, path, body);
            close(clientSock);
        }
    }
    printf("\n  [WS] Shutting down...\n");
    pthread_mutex_lock(&clients_mutex);
    for (int i = 0; i < MAX_CLIENTS; i++) { if (clients[i].alive) { clients[i].alive = 0; close(clients[i].fd); } }
    pthread_mutex_unlock(&clients_mutex);
    close(servSock);
    if (auth_db) sqlite3_close(auth_db);
    return 0;
}
