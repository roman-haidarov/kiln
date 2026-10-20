#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef SP_THREADS
extern __thread int sp_ffi_bin_len;
#else
extern int sp_ffi_bin_len;
#endif

#define KWS_GUID     "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
#define KWS_GUID_LEN 36
#define KWS_KEY_MAX  128
#define KWS_ACCEPT   28

typedef struct {
    uint32_t h[5];
    uint64_t bytes;
    unsigned char block[64];
    size_t fill;
} kws_sha1;

static __thread char *kws_out;
static __thread size_t kws_cap;

static uint32_t kws_rol(uint32_t v, int n) {
    return (v << n) | (v >> (32 - n));
}

static void kws_compress(kws_sha1 *s, const unsigned char *p) {
    uint32_t w[80];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[(size_t)i * 4] << 24) | ((uint32_t)p[(size_t)i * 4 + 1] << 16) |
               ((uint32_t)p[(size_t)i * 4 + 2] << 8) | (uint32_t)p[(size_t)i * 4 + 3];
    for (int i = 16; i < 80; i++)
        w[i] = kws_rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint32_t a = s->h[0];
    uint32_t b = s->h[1];
    uint32_t c = s->h[2];
    uint32_t d = s->h[3];
    uint32_t e = s->h[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f;
        uint32_t k;
        if (i < 20) {
            f = (b & c) | (~b & d);
            k = 0x5A827999U;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1U;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDCU;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6U;
        }
        uint32_t t = kws_rol(a, 5) + f + e + k + w[i];
        e = d;
        d = c;
        c = kws_rol(b, 30);
        b = a;
        a = t;
    }
    s->h[0] += a;
    s->h[1] += b;
    s->h[2] += c;
    s->h[3] += d;
    s->h[4] += e;
}

static void kws_update(kws_sha1 *s, const unsigned char *data, size_t len) {
    s->bytes += len;
    while (len > 0) {
        size_t take = 64 - s->fill;
        if (take > len)
            take = len;
        memcpy(s->block + s->fill, data, take);
        s->fill += take;
        data += take;
        len -= take;
        if (s->fill == 64) {
            kws_compress(s, s->block);
            s->fill = 0;
        }
    }
}

static void kws_digest(kws_sha1 *s, unsigned char out[20]) {
    uint64_t bits = s->bytes * 8;
    unsigned char pad = 0x80;
    kws_update(s, &pad, 1);
    unsigned char zero = 0;
    while (s->fill != 56)
        kws_update(s, &zero, 1);
    unsigned char length[8];
    for (int i = 0; i < 8; i++)
        length[i] = (unsigned char)(bits >> (56 - 8 * i));
    kws_update(s, length, 8);
    for (int i = 0; i < 5; i++) {
        size_t at = (size_t)i * 4;
        out[at] = (unsigned char)(s->h[i] >> 24);
        out[at + 1] = (unsigned char)(s->h[i] >> 16);
        out[at + 2] = (unsigned char)(s->h[i] >> 8);
        out[at + 3] = (unsigned char)s->h[i];
    }
}

static void kws_base64(const unsigned char *in, size_t len, char *out) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < len)
            v |= (uint32_t)in[i + 1] << 8;
        if (i + 2 < len)
            v |= in[i + 2];
        out[o++] = table[(v >> 18) & 63];
        out[o++] = table[(v >> 12) & 63];
        out[o++] = (char)(i + 1 < len ? table[(v >> 6) & 63] : '=');
        out[o++] = (char)(i + 2 < len ? table[v & 63] : '=');
    }
    out[o] = '\0';
}

const char *kiln_ws_accept(const char *key, long len) {
    static __thread char accept[KWS_ACCEPT + 1];
    unsigned char digest[20];
    kws_sha1 s = {{0x67452301U, 0xEFCDAB89U, 0x98BADCFEU, 0x10325476U, 0xC3D2E1F0U}, 0, {0}, 0};
    if (len < 0 || len > KWS_KEY_MAX) {
        sp_ffi_bin_len = 0;
        return "";
    }
    kws_update(&s, (const unsigned char *)key, (size_t)len);
    kws_update(&s, (const unsigned char *)KWS_GUID, KWS_GUID_LEN);
    kws_digest(&s, digest);
    kws_base64(digest, sizeof digest, accept);
    sp_ffi_bin_len = KWS_ACCEPT;
    return accept;
}

const char *kiln_ws_mask(const char *data, long len, long key) {
    if (len <= 0) {
        sp_ffi_bin_len = 0;
        return "";
    }
    if ((size_t)len > kws_cap) {
        char *grown = realloc(kws_out, (size_t)len);
        if (!grown) {
            sp_ffi_bin_len = 0;
            return "";
        }
        kws_out = grown;
        kws_cap = (size_t)len;
    }
    const unsigned char mask[4] = {(unsigned char)(key >> 24), (unsigned char)(key >> 16),
        (unsigned char)(key >> 8), (unsigned char)key};
    uint32_t word;
    memcpy(&word, mask, 4);
    uint64_t wide = ((uint64_t)word << 32) | word;
    long i = 0;
    for (; i + 8 <= len; i += 8) {
        uint64_t chunk;
        memcpy(&chunk, data + i, 8);
        chunk ^= wide;
        memcpy(kws_out + i, &chunk, 8);
    }
    for (; i < len; i++)
        kws_out[i] = (char)(data[i] ^ mask[i & 3]);
    sp_ffi_bin_len = (int)len;
    return kws_out;
}
