#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: idle_conns PORT COUNT SECONDS\n");
        return 2;
    }
    int port = atoi(argv[1]);
    int count = atoi(argv[2]);
    int seconds = atoi(argv[3]);
    const char req[] = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    int *fds = calloc((size_t)count, sizeof(int));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = htonl(0x7f000001);
    for (int i = 0; i < count; i++) {
        fds[i] = socket(AF_INET, SOCK_STREAM, 0);
        if (fds[i] < 0 || connect(fds[i], (struct sockaddr *)&addr, sizeof addr) != 0) {
            perror("connect");
            return 1;
        }
        if (write(fds[i], req, sizeof req - 1) != (ssize_t)(sizeof req - 1)) {
            perror("write");
            return 1;
        }
    }
    char buf[4096];
    for (int i = 0; i < count; i++) {
        size_t got = 0;
        while (got == 0 || memmem(buf, got, "\r\n\r\n", 4) == NULL) {
            ssize_t n = read(fds[i], buf + got, sizeof buf - got);
            if (n <= 0) {
                perror("read");
                return 1;
            }
            got += (size_t)n;
            if (got == sizeof buf) {
                break;
            }
        }
    }
    printf("ready %d\n", count);
    fflush(stdout);
    sleep((unsigned)seconds);
    return 0;
}
