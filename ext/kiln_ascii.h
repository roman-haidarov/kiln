#ifndef KILN_ASCII_H
#define KILN_ASCII_H

#include <stddef.h>

static inline int kiln_ascii_case_equal(const char *a, const char *b, size_t len) {
    for (size_t i = 0; i < len; i++) {
        unsigned char x = (unsigned char)a[i];
        unsigned char y = (unsigned char)b[i];
        if (x >= 'A' && x <= 'Z') {
            x += 'a' - 'A';
        }
        if (y >= 'A' && y <= 'Z') {
            y += 'a' - 'A';
        }
        if (x != y) {
            return 0;
        }
    }
    return 1;
}

#endif
