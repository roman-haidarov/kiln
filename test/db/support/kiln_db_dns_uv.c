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
    assert(kiln_db_configure(&limits) == KILN_DB_OK);
    id = kiln_db_resolver_submit("127.0.0.1", 9, &fd, addr, sizeof addr, &done);
    assert(id == 0 && fd == -1 && done == 1 && strcmp(addr, "127.0.0.1") == 0);
    id = kiln_db_resolver_submit("localhost", 9, &fd, addr, sizeof addr, &done);
    assert(id > 0 && fd >= 0 && done == 0);
    waiting.fd = fd;
    waiting.events = POLLIN;
    rc = poll(&waiting, 1, 5000);
    assert(rc == 1 && (waiting.revents & POLLIN));
    assert(kiln_db_resolver_take(id, addr, sizeof addr) == KILN_DB_OK);
    assert(strchr(addr, ':') || strchr(addr, '.'));
    assert(kiln_db_resolver_take(id, addr, sizeof addr) == KILN_DB_ERR);
    for (rc = 0; rc < 64; rc++) {
        int tries = 0;
        do {
            id = kiln_db_resolver_submit("localhost", 9, &fd, addr, sizeof addr, &done);
            if (id <= 0) {
                poll(NULL, 0, 5);
            }
        } while (id <= 0 && ++tries < 1000);
        assert(id > 0);
        assert(kiln_db_resolver_cancel(id) == KILN_DB_OK);
    }
    id = -1;
    for (rc = 0; rc < 1000 && id <= 0; rc++) {
        id = kiln_db_resolver_submit("localhost", 9, &fd, addr, sizeof addr, &done);
        if (id <= 0) {
            poll(NULL, 0, 5);
        }
    }
    assert(id > 0);
    waiting.fd = fd;
    waiting.events = POLLIN;
    assert(poll(&waiting, 1, 5000) == 1);
    assert(kiln_db_resolver_take(id, addr, sizeof addr) == KILN_DB_OK);
    puts("ok libuv dns cancel");
    puts("ok libuv dns");
    return 0;
}
