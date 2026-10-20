#if defined(__aarch64__) && defined(KILN_OPTIMIZED) && !defined(KILN_GENERIC)
#include "zng_defines.h"
#include "../zlib-ng/arch/arm/crc32_armv8_pmull_eor3.c"
#endif
