#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kiln_tls.h"

__thread int sp_ffi_bin_len;

#define TLS_TSAN_THREADS 16
#define TLS_TSAN_ROUNDS  128

#ifndef __has_feature
#define __has_feature(feature) 0
#endif
#if __has_feature(thread_sanitizer) || defined(__SANITIZE_THREAD__)
#define TLS_TEST_KIND "TLS TSan"
#else
#define TLS_TEST_KIND "TLS native"
#endif

static pthread_mutex_t tls_tsan_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t tls_tsan_cond = PTHREAD_COND_INITIALIZER;
static int tls_tsan_ready;
static int tls_tsan_go;
static int tls_tsan_lifecycle_ready;
static int tls_tsan_lifecycle_go;
static char tls_tsan_alpn[257];
static const char *tls_tsan_cert;
static const char *tls_tsan_key;

static void *tls_tsan_worker(void *argument) {
    (void)argument;
    pthread_mutex_lock(&tls_tsan_lock);
    tls_tsan_ready++;
    pthread_cond_broadcast(&tls_tsan_cond);
    while (!tls_tsan_go) {
        pthread_cond_wait(&tls_tsan_cond, &tls_tsan_lock);
    }
    pthread_mutex_unlock(&tls_tsan_lock);
    int failed = 0;
    for (int i = 0; i < TLS_TSAN_ROUNDS; i++) {
        long context = kiln_tls_context_new("", "", "", 0, "", "", 0x0303, tls_tsan_alpn);
        if (context >= 0 || !kiln_tls_error_text()[0]) {
            if (context >= 0)
                kiln_tls_context_free(context);
            failed = 1;
            break;
        }
    }
    if (tls_tsan_cert) {
        pthread_mutex_lock(&tls_tsan_lock);
        tls_tsan_lifecycle_ready++;
        pthread_cond_broadcast(&tls_tsan_cond);
        while (!tls_tsan_lifecycle_go) {
            pthread_cond_wait(&tls_tsan_cond, &tls_tsan_lock);
        }
        pthread_mutex_unlock(&tls_tsan_lock);
        for (int i = 0; !failed && i < 12; i++) {
            long context = kiln_tls_context_new(
                tls_tsan_cert, tls_tsan_key, "", 0, "", "", 0x0303, "http/1.1");
            if (context < 0) {
                failed = 1;
                break;
            }
            kiln_tls_conn *conn = kiln_tls_conn_new(context);
            if (!conn) {
                kiln_tls_context_free(context);
                failed = 1;
                break;
            }
            kiln_tls_conn_free(conn);
            if (kiln_tls_context_free(context) != 0) {
                failed = 1;
                break;
            }
        }
    }
    return (void *)(intptr_t)failed;
}

int main(int argc, char **argv) {
    if (argc != 1 && argc != 3)
        return 2;
    if (argc == 3) {
        tls_tsan_cert = argv[1];
        tls_tsan_key = argv[2];
    }

    void *crypto = NULL;
    const char *crypto_path = getenv("KILN_LIBCRYPTO");
    if (crypto_path && *crypto_path) {
        crypto = dlopen(crypto_path, RTLD_NOW | RTLD_LOCAL);
        if (!crypto) {
            fprintf(stderr, "TLS test cannot load libcrypto: %s\n", dlerror());
            return 1;
        }
    }
    memset(tls_tsan_alpn, 'a', sizeof tls_tsan_alpn - 1);
    tls_tsan_alpn[sizeof tls_tsan_alpn - 1] = '\0';
    if (!kiln_tls_available()) {
        fprintf(stderr, "TLS native test requires OpenSSL: %s\n", kiln_tls_error_text());
        return 1;
    }
    pthread_t threads[TLS_TSAN_THREADS];
    for (intptr_t i = 0; i < TLS_TSAN_THREADS; i++) {
        if (pthread_create(&threads[i], NULL, tls_tsan_worker, NULL) != 0) {
            return 1;
        }
    }
    pthread_mutex_lock(&tls_tsan_lock);
    while (tls_tsan_ready != TLS_TSAN_THREADS) {
        pthread_cond_wait(&tls_tsan_cond, &tls_tsan_lock);
    }
    tls_tsan_go = 1;
    pthread_cond_broadcast(&tls_tsan_cond);
    if (tls_tsan_cert) {
        while (tls_tsan_lifecycle_ready != TLS_TSAN_THREADS) {
            pthread_cond_wait(&tls_tsan_cond, &tls_tsan_lock);
        }
        tls_tsan_lifecycle_go = 1;
        pthread_cond_broadcast(&tls_tsan_cond);
    }
    pthread_mutex_unlock(&tls_tsan_lock);
    int failed = 0;
    for (int i = 0; i < TLS_TSAN_THREADS; i++) {
        void *result = NULL;
        if (pthread_join(threads[i], &result) != 0 || result) {
            failed = 1;
        }
    }
    if (crypto)
        dlclose(crypto);
    if (failed) {
        return 1;
    }
    printf("%s: %s\n", TLS_TEST_KIND,
        tls_tsan_cert ? "concurrent TLS context lifecycles passed"
                      : "concurrent failed context initialization passed");
    return 0;
}
