/* A dependency-only reproducer: no Kiln or Spinel code is linked. */
#include <openssl/ssl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

#define REPRO_THREADS 16
#define REPRO_ROUNDS  32

static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cond = PTHREAD_COND_INITIALIZER;
static int ready;
static int start;

static void *openssl_worker(void *arg) {
    (void)arg;
    pthread_mutex_lock(&gate_lock);
    ready++;
    pthread_cond_broadcast(&gate_cond);
    while (!start)
        pthread_cond_wait(&gate_cond, &gate_lock);
    pthread_mutex_unlock(&gate_lock);
    for (int i = 0; i < REPRO_ROUNDS; i++) {
        SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
        if (!ctx)
            return (void *)(intptr_t)1;
        SSL_CTX_free(ctx);
    }
    return NULL;
}

int main(void) {
    pthread_t threads[REPRO_THREADS];
    int created = 0;
    int failed = 0;
    for (; created < REPRO_THREADS; created++) {
        if (pthread_create(&threads[created], NULL, openssl_worker, NULL) != 0) {
            failed = 1;
            break;
        }
    }
    pthread_mutex_lock(&gate_lock);
    while (ready < created)
        pthread_cond_wait(&gate_cond, &gate_lock);
    start = 1;
    pthread_cond_broadcast(&gate_cond);
    pthread_mutex_unlock(&gate_lock);
    for (int i = 0; i < created; i++) {
        void *result = NULL;
        if (pthread_join(threads[i], &result) != 0 || result)
            failed = 1;
    }
    if (failed)
        return 1;
    printf("OpenSSL-only: %s, concurrent SSL_CTX lifecycle passed\n", OpenSSL_version(0));
    return 0;
}
