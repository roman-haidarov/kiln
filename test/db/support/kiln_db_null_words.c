#include "kiln_db.h"

#include <assert.h>
#include <stdint.h>

int main(void) {
    assert(kiln_db_null_words(0) == 0);
    assert(kiln_db_null_words(1) == 1);
    assert(kiln_db_null_words(63) == 1);
    assert(kiln_db_null_words(64) == 1);
    assert(kiln_db_null_words(65) == 2);
    assert(kiln_db_null_words(UINT32_MAX) == 67108864u);
    return 0;
}
