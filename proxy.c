/*
 * proxy.c - Tiny TCP proxy for ChatBantu
 *
 * Routes traffic on a single public port:
 *   WebSocket (Upgrade header)  --> wsrelay (internal port)
 *   All other HTTP              --> Bantu   (internal port)
 *
 * Build:  gcc -O2 -o proxy proxy.c
 * Usage:  ./proxy <public_port> <bantu_port> <wsrelay_port>
 * Example: ./proxy 8080 9080 9081
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define BUF_SIZE 65536
#define PEEK_SIZE 4096

static volatile int running = 1;

static void sig_handler(int sig) { (void)sig; running = 0; }

static int connect_backend(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Copy data from src to dst until EOF or error. */
static void copy_loop(int src, int dst) {
    char buf[BUF_SIZE];
    ssize_t n;
    while (running) {
        n = recv(src, buf, sizeof(buf), 0);
        if (n <= 0) break;
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = send(dst, buf + off, (size_t)(n - off), MSG_NOSIGNAL);
            if (w <= 0) return;
            off += w;
        }
    }
}

int main(int argc, char *argv[]) {
    int public_port = 8080;
    int bantu_port  = 9080;
    int relay_port  = 9081;

    if (argc >= 2) public_port = atoi(argv[1]);
    if (argc >= 3) bantu_port  = atoi(argv[2]);
    if (argc >= 4) relay_port  = atoi(argv[3]);

    const char *port_env = getenv("PORT");
    if (port_env && argc < 2) public_port = atoi(port_env);

    signal(SIGINT,  sig_handler);
    signal(SIGTERM, sig_handler);
    signal(SIGCHLD, SIG_IGN);

    int servSock = socket(AF_INET, SOCK_STREAM, 0);
    if (servSock < 0) { perror("socket"); return 1; }
    int opt = 1;
    setsockopt(servSock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons((uint16_t)public_port);

    if (bind(servSock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        fprintf(stderr, "  [PROXY] Failed to bind port %d\n", public_port);
        return 1;
    }
    listen(servSock, 128);

    printf("  [PROXY] Listening on 0.0.0.0:%d\n", public_port);
    printf("  [PROXY]   HTTP      -> 127.0.0.1:%d (Bantu)\n", bantu_port);
    printf("  [PROXY]   WebSocket -> 127.0.0.1:%d (wsrelay)\n\n", relay_port);

    while (running) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int clientSock = accept(servSock, (struct sockaddr *)&clientAddr, &clientLen);
        if (clientSock < 0) {
            if (running) perror("accept");
            continue;
        }

        /* Peek at the request to decide routing */
        char peek[PEEK_SIZE];
        ssize_t n = recv(clientSock, peek, sizeof(peek) - 1, MSG_PEEK);
        if (n <= 0) { close(clientSock); continue; }
        peek[n] = '\0';

        int is_ws = (strstr(peek, "Upgrade: websocket") != NULL ||
                     strstr(peek, "upgrade: websocket") != NULL);
        int target_port = is_ws ? relay_port : bantu_port;

        int backendSock = connect_backend(target_port);
        if (backendSock < 0) { close(clientSock); continue; }

        /* Drain the peeked bytes and forward them to the backend.
           recv with MSG_DONTWAIT after PEEK: data is still in buffer.
           We just need to send the peeked data to backend, then the
           kernel buffers will be in sync. */
        {
            ssize_t off = 0;
            while (off < n) {
                ssize_t w = send(backendSock, peek + off, (size_t)(n - off), MSG_NOSIGNAL);
                if (w <= 0) { close(clientSock); close(backendSock); goto next; }
                off += w;
            }
            /* Now consume the peeked bytes from client socket */
            char drain[PEEK_SIZE];
            ssize_t drain_n;
            while ((drain_n = recv(clientSock, drain, sizeof(drain), MSG_DONTWAIT)) > 0) {
                ssize_t d = 0;
                while (d < drain_n) {
                    ssize_t w = send(backendSock, drain + d, (size_t)(drain_n - d), MSG_NOSIGNAL);
                    if (w <= 0) break;
                    d += w;
                }
                if (d < drain_n) break;
            }
        }

        /* Fork two children for bidirectional proxy */
        pid_t pid1 = fork();
        if (pid1 == 0) {
            close(servSock);
            copy_loop(clientSock, backendSock);
            shutdown(clientSock, SHUT_WR);
            shutdown(backendSock, SHUT_RD);
            _exit(0);
        }

        pid_t pid2 = fork();
        if (pid2 == 0) {
            close(servSock);
            copy_loop(backendSock, clientSock);
            shutdown(backendSock, SHUT_WR);
            shutdown(clientSock, SHUT_RD);
            _exit(0);
        }

        /* Parent: close both fds (children have copies), continue */
        close(clientSock);
        close(backendSock);
        next:;
    }

    printf("\n  [PROXY] Shutting down...\n");
    close(servSock);
    return 0;
}