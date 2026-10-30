#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>

#ifdef SP_THREADS
extern __thread int sp_ffi_bin_len;
#else
extern int sp_ffi_bin_len;
#endif

#define KSOCK_MAX_INHERITED 64

static long ksock_errno(void) {
    return errno ? -(long)errno : -1;
}

static int ksock_cloexec(int fd, int on) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0)
        return -1;
    flags = on ? flags | FD_CLOEXEC : flags & ~FD_CLOEXEC;
    return fcntl(fd, F_SETFD, flags);
}

static int ksock_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0)
        return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void ksock_nosigpipe(int fd) {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#else
    (void)fd;
#endif
}

static int ksock_socket(int family, int type) {
    int fd = socket(family, type, 0);
    if (fd < 0)
        return -1;
    if (ksock_cloexec(fd, 1) < 0 || ksock_nonblock(fd) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    ksock_nosigpipe(fd);
    return fd;
}

static long ksock_finish_listen(int fd, long backlog) {
    if (listen(fd, (int)backlog) < 0) {
        long rc = ksock_errno();
        close(fd);
        return rc;
    }
    return fd;
}

long kiln_sock_tcp(const char *host, long port, long backlog, long reuse_port) {
    struct addrinfo hints;
    struct addrinfo *found = NULL;
    char service[16];
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE | AI_NUMERICSERV;
    if (port < 0 || port > 65535 || backlog < 1)
        return -EINVAL;
    snprintf(service, sizeof service, "%ld", port);
    int rc = getaddrinfo(*host ? host : NULL, service, &hints, &found);
    if (rc != 0)
        return -EADDRNOTAVAIL;
    long result = -EADDRNOTAVAIL;
    for (struct addrinfo *at = found; at; at = at->ai_next) {
        int fd = ksock_socket(at->ai_family, at->ai_socktype);
        if (fd < 0) {
            result = ksock_errno();
            continue;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
#ifdef SO_REUSEPORT
        if (reuse_port)
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
#else
        if (reuse_port) {
            close(fd);
            result = -ENOTSUP;
            continue;
        }
#endif
        if (at->ai_family == AF_INET6)
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one);
        if (bind(fd, at->ai_addr, at->ai_addrlen) < 0) {
            result = ksock_errno();
            close(fd);
            continue;
        }
        result = ksock_finish_listen(fd, backlog);
        break;
    }
    freeaddrinfo(found);
    return result;
}

static long ksock_stale(const char *path) {
    struct stat st;
    if (lstat(path, &st) < 0)
        return errno == ENOENT ? 0 : ksock_errno();
    if (!S_ISSOCK(st.st_mode))
        return -EADDRINUSE;
    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe < 0)
        return ksock_errno();
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, strlen(path));
    int connected = connect(probe, (struct sockaddr *)&addr, sizeof addr) == 0;
    int probe_errno = errno;
    close(probe);
    if (connected || probe_errno != ECONNREFUSED) {
        return connected ? -EADDRINUSE : -(long)probe_errno;
    }
    struct stat current;
    if (lstat(path, &current) < 0 || !S_ISSOCK(current.st_mode) || current.st_dev != st.st_dev ||
        current.st_ino != st.st_ino) {
        return -EADDRINUSE;
    }
    return unlink(path) < 0 ? ksock_errno() : 0;
}

long kiln_sock_unix(const char *path, long backlog, long mode) {
    struct sockaddr_un addr;
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof addr.sun_path || backlog < 1)
        return -ENAMETOOLONG;
    long stale = ksock_stale(path);
    if (stale < 0)
        return stale;
    int fd = ksock_socket(AF_UNIX, SOCK_STREAM);
    if (fd < 0)
        return ksock_errno();
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, len);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        long rc = ksock_errno();
        close(fd);
        return rc;
    }
    if (mode >= 0 && chmod(path, (mode_t)mode) < 0) {
        long rc = ksock_errno();
        close(fd);
        unlink(path);
        return rc;
    }
    return ksock_finish_listen(fd, backlog);
}

long kiln_sock_kind(long fd) {
    struct sockaddr_storage addr;
    memset(&addr, 0, sizeof addr);
    socklen_t len = sizeof addr;
    if (getsockname((int)fd, (struct sockaddr *)&addr, &len) < 0)
        return ksock_errno();
#ifdef SO_ACCEPTCONN
    int accepting = 0;
    socklen_t flag_len = sizeof accepting;
    if (getsockopt((int)fd, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &flag_len) == 0 && !accepting)
        return -EINVAL;
#endif
    if (addr.ss_family == AF_UNIX)
        return 2;
    return addr.ss_family == AF_INET || addr.ss_family == AF_INET6 ? 1 : -EAFNOSUPPORT;
}

long kiln_sock_adopt(long fd) {
    long kind = kiln_sock_kind(fd);
    if (kind < 0)
        return kind;
    if (ksock_cloexec((int)fd, 1) < 0 || ksock_nonblock((int)fd) < 0)
        return ksock_errno();
    ksock_nosigpipe((int)fd);
    return kind;
}

long kiln_sock_nosigpipe(long fd) {
    ksock_nosigpipe((int)fd);
    return 0;
}

long kiln_sock_ignore_sigpipe(void) {
    struct sigaction current;
    if (sigaction(SIGPIPE, NULL, &current) < 0)
        return ksock_errno();
    if (current.sa_handler != SIG_DFL || (current.sa_flags & SA_SIGINFO))
        return 0;
    struct sigaction ignore;
    memset(&ignore, 0, sizeof ignore);
    ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    return sigaction(SIGPIPE, &ignore, NULL) < 0 ? ksock_errno() : 1;
}

long kiln_sock_port(long fd) {
    struct sockaddr_storage addr;
    memset(&addr, 0, sizeof addr);
    socklen_t len = sizeof addr;
    if (getsockname((int)fd, (struct sockaddr *)&addr, &len) < 0)
        return ksock_errno();
    if (addr.ss_family == AF_INET6)
        return ntohs(((struct sockaddr_in6 *)&addr)->sin6_port);
    if (addr.ss_family == AF_INET)
        return ntohs(((struct sockaddr_in *)&addr)->sin_port);
    return 0;
}

long kiln_sock_accept(long fd, long nodelay) {
    int client;
#ifdef __linux__
    client = accept4((int)fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
#else
    client = accept((int)fd, NULL, NULL);
    if (client >= 0 && (ksock_cloexec(client, 1) < 0 || ksock_nonblock(client) < 0)) {
        close(client);
        return -EBADF;
    }
#endif
    if (client < 0)
        return errno == EAGAIN || errno == EWOULDBLOCK ? -EAGAIN : ksock_errno();
    if (nodelay) {
        int one = 1;
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    }
    ksock_nosigpipe(client);
    return client;
}

long kiln_sock_shutdown(long fd, long how) {
    int mode = SHUT_RDWR;
    if (how == 0)
        mode = SHUT_RD;
    else if (how == 1)
        mode = SHUT_WR;
    return shutdown((int)fd, mode) < 0 ? ksock_errno() : 0;
}

long kiln_sock_close(long fd) {
    return close((int)fd) < 0 ? ksock_errno() : 0;
}

long kiln_sock_path_id(const char *path, int64_t *out) {
    struct stat st;
    if (lstat(path, &st) < 0)
        return ksock_errno();
    if (!S_ISSOCK(st.st_mode))
        return -EINVAL;
    out[0] = (int64_t)st.st_dev;
    out[1] = (int64_t)st.st_ino;
    return 0;
}

long kiln_sock_unlink_owned(const char *path, long device, long inode) {
    struct stat st;
    if (lstat(path, &st) < 0)
        return errno == ENOENT ? 0 : ksock_errno();
    if (!S_ISSOCK(st.st_mode) || (int64_t)st.st_dev != device || (int64_t)st.st_ino != inode)
        return 0;
    return unlink(path) < 0 ? ksock_errno() : 0;
}

long kiln_sock_unlink(const char *path) {
    struct stat st;
    if (lstat(path, &st) < 0 || !S_ISSOCK(st.st_mode))
        return 0;
    return unlink(path) < 0 ? ksock_errno() : 0;
}

long kiln_sock_inherited(void) {
    const char *pid = getenv("LISTEN_PID");
    const char *count = getenv("LISTEN_FDS");
    if (!pid || !count)
        return 0;
    char *end = NULL;
    long owner = strtol(pid, &end, 10);
    if (*end || owner != (long)getpid())
        return 0;
    long n = strtol(count, &end, 10);
    if (*end || n < 0 || n > KSOCK_MAX_INHERITED)
        return 0;
    return n;
}

const char *kiln_sock_errno_text(long code) {
    const char *text = strerror((int)(code < 0 ? -code : code));
    sp_ffi_bin_len = (int)strlen(text);
    return text;
}

long kiln_sock_dup(long fd) {
    int copy;
    do {
        copy = fcntl((int)fd, F_DUPFD_CLOEXEC, 0);
    } while (copy < 0 && errno == EINTR);
    return copy < 0 ? -errno : copy;
}
