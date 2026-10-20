// Standalone native SSL_write state-machine regression test.
// clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
//   test/tls_write_retry_native.c -ldl -pthread -o /tmp/kiln-tls-write-test && \
//   /tmp/kiln-tls-write-test
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

// Include the implementation to replace its private dlopen table with test doubles.
int sp_ffi_bin_len;
#include "../ext/kiln_tls.c"

static const char *last_ptr;
static int last_len;
static int next_error;
static int writes;
static int clears;
static int errors;
static int scripted[8];
static int scripted_len;
static int scripted_pos;

static int fake_write(SSL *ssl, const void *ptr, int len) {
    (void)ssl;
    assert(len > 0 && len <= 16384);
    writes++;
    if (scripted_pos < scripted_len && scripted[scripted_pos] != 0) {
        next_error = scripted[scripted_pos++];
        last_ptr = ptr;
        last_len = len;
        return -1;
    }
    scripted_pos++;
    if (last_ptr) {
        assert(ptr == last_ptr);
        assert(len == last_len);
        last_ptr = NULL;
    }
    return len;
}

static int fake_get_error(const SSL *ssl, int result) {
    (void)ssl;
    assert(result < 1);
    errors++;
    return next_error;
}

static void fake_clear(void) {
    clears++;
}

static void reset(void) {
    last_ptr = NULL;
    last_len = 0;
    next_error = 0;
    writes = 0;
    clears = 0;
    errors = 0;
    scripted_pos = 0;
    scripted_len = 0;
}

int main(void) {
    ktls.write = fake_write;
    ktls.get_error = fake_get_error;
    ktls.err_clear = fake_clear;
    kiln_tls_conn conn = {0};
    char payload[20000] = {0};
    size_t consumed = 99;

    reset();
    scripted[0] = KTLS_ERROR_WANT_READ;
    scripted[1] = 0;
    scripted_len = 2;
    assert(kiln_tls_write(&conn, payload, 10, &consumed) == KILN_TLS_WANT_READ);
    assert(consumed == 0 && errors == 1 && clears == 0);
    assert(kiln_tls_write(&conn, payload, 10, &consumed) == KILN_TLS_DONE);
    assert(consumed == 10 && writes == 2);

    reset();
    scripted[0] = 0;  // First 16KiB chunk consumed.
    scripted[1] = KTLS_ERROR_WANT_WRITE;
    scripted[2] = 0;
    scripted_len = 3;
    assert(kiln_tls_write(&conn, payload, sizeof(payload), &consumed) == KILN_TLS_WANT_WRITE);
    assert(consumed == 16384 && errors == 1 && clears == 0);
    assert(kiln_tls_write(&conn, payload + consumed, sizeof(payload) - consumed, &consumed) ==
           KILN_TLS_DONE);
    assert(consumed == sizeof(payload) - 16384 && writes == 3);

    reset();
    scripted[0] = KTLS_ERROR_ZERO_RETURN;
    scripted_len = 1;
    assert(kiln_tls_write(&conn, payload, 10, &consumed) == KILN_TLS_CLOSED);
    assert(consumed == 0 && errors == 1 && clears == 1);

    reset();
    scripted[0] = 1; // Unknown fatal condition.
    scripted_len = 1;
    assert(kiln_tls_write(&conn, payload, 10, &consumed) == KILN_TLS_FAIL);
    assert(consumed == 0 && errors == 1 && clears == 1);

    puts("tls_write retry arguments and error classification: ok");
    return 0;
}
