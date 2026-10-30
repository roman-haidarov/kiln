#include "kiln_db.h"
#include <assert.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef SP_THREADS
__thread int sp_ffi_bin_len;
#else
int sp_ffi_bin_len;
#endif

int main(void) {
    kiln_db_limits limits = {65536, 1024, 4096, 67108864, 8, 64, 16, 5000};
    char addr[64];
    struct pollfd waiting;
    int fd = -1;
    int done = 0;
    int id;
    int rc;
    uint64_t request = UINT64_MAX;
    uint64_t previous;
    assert(kiln_db_configure(&limits) == KILN_DB_OK);
    id = kiln_db_resolver_submit("127.0.0.1", 9, &fd, addr, sizeof addr, &done, &request);
    assert(id == 0 && request == 0 && fd == -1 && done == 1 && strcmp(addr, "127.0.0.1") == 0);
    assert(kiln_db_resolver_submit("localhost", 9, &fd, addr, sizeof addr, &done, NULL) ==
           -KILN_DB_CONFIG);
    id = kiln_db_resolver_submit("localhost", 9, &fd, addr, sizeof addr, &done, &request);
    assert(id > 0 && fd >= 0 && done == 0);
    assert((uint32_t)request == (uint32_t)id && (request >> 32) != 0);
    waiting.fd = fd;
    waiting.events = POLLIN;
    rc = poll(&waiting, 1, 5000);
    assert(rc == 1 && (waiting.revents & POLLIN));
    assert(kiln_db_resolver_take(request, addr, sizeof addr) == KILN_DB_OK);
    assert(strchr(addr, ':') || strchr(addr, '.'));
    assert(kiln_db_resolver_take(request, addr, sizeof addr) == KILN_DB_ERR);
    previous = request;
    id = kiln_db_resolver_submit("localhost", 9, &fd, addr, sizeof addr, &done, &request);
    assert(id > 0 && (uint32_t)request == (uint32_t)previous);
    assert((request >> 32) != (previous >> 32));
    assert(kiln_db_resolver_cancel(previous) == KILN_DB_STALE);
    waiting.fd = fd;
    waiting.revents = 0;
    assert(poll(&waiting, 1, 5000) == 1 && (waiting.revents & POLLIN));
    assert(kiln_db_resolver_take(previous, addr, sizeof addr) == KILN_DB_STALE);
    assert(kiln_db_resolver_cancel(previous) == KILN_DB_STALE);
    assert(kiln_db_resolver_take(request, addr, sizeof addr) == KILN_DB_OK);
    puts("ok public dns stale generation");
    {
        int64_t error = 0;
        int64_t out[8] = {0};
        int64_t owned[3] = {0};
        uint64_t handle = kiln_db_conn_create(KILN_DB_KIND_PG, 1, 1, &error);
        assert(handle && error == KILN_DB_OK);
        assert(kiln_db_conn_dns_submit(handle, 1, 1, "localhost", 9, owned, 3) == KILN_DB_OK);
        assert((uint32_t)owned[0] == (uint32_t)request);
        assert(kiln_db_resolver_cancel(request) == KILN_DB_STALE);
        assert(kiln_db_resolver_cancel((uint64_t)owned[0]) == KILN_DB_OWNERSHIP);
        assert(kiln_db_resolver_cancel((uint32_t)owned[0]) == KILN_DB_STALE);
        waiting.fd = (int)owned[1];
        waiting.revents = 0;
        assert(poll(&waiting, 1, 5000) == 1 && (waiting.revents & POLLIN));
        assert(kiln_db_conn_dns_take(handle, 1, 1, (uint64_t)owned[0], &error, 1)[0]);
        assert(error == KILN_DB_OK);
        assert(kiln_db_step(handle, 1, 1, KILN_DB_OP_CLOSE, 0, 0, out, 8) == KILN_DB_OK);
    }
    puts("ok public dns generation before ownership");
    for (rc = 0; rc < 64; rc++) {
        int tries = 0;
        do {
            id = kiln_db_resolver_submit("localhost", 9, &fd, addr, sizeof addr, &done, &request);
            if (id <= 0) {
                poll(NULL, 0, 5);
            }
        } while (id <= 0 && ++tries < 1000);
        assert(id > 0);
        assert(kiln_db_resolver_cancel(request) == KILN_DB_OK);
    }
    id = -1;
    for (rc = 0; rc < 1000 && id <= 0; rc++) {
        id = kiln_db_resolver_submit("localhost", 9, &fd, addr, sizeof addr, &done, &request);
        if (id <= 0) {
            poll(NULL, 0, 5);
        }
    }
    assert(id > 0);
    waiting.fd = fd;
    waiting.events = POLLIN;
    assert(poll(&waiting, 1, 5000) == 1);
    assert(kiln_db_resolver_take(request, addr, sizeof addr) == KILN_DB_OK);
    for (rc = 0; rc < 64; rc++) {
        int tries = 0;
        int64_t error = 0;
        int64_t out[8] = {0};
        int64_t request[3] = {0};
        uint64_t handle = kiln_db_conn_create(KILN_DB_KIND_PG, 1, 1, &error);
        assert(handle && error == KILN_DB_OK);
        do {
            error = kiln_db_conn_dns_submit(handle, 1, 1, "localhost", 9, request, 3);
            if (error == KILN_DB_CAPACITY) {
                poll(NULL, 0, 5);
            }
        } while (error == KILN_DB_CAPACITY && ++tries < 1000);
        assert(error == KILN_DB_OK);
        assert(kiln_db_resolver_cancel((uint64_t)request[0]) == KILN_DB_OWNERSHIP);
        assert(kiln_db_step(handle, 1, 1, KILN_DB_OP_CLOSE, 0, 0, out, 8) == KILN_DB_OK);
        kiln_db_resolver_cancel_conn(handle);
        kiln_db_conn_dns_take(handle, 1, 1, (uint64_t)request[0], &error, 1);
        assert(error == KILN_DB_STALE);
    }
    puts("ok connection dns lifetime");
    puts("ok libuv dns cancel");
    puts("ok libuv dns");
    return 0;
}
