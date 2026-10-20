#if defined(__aarch64__) && defined(KILN_OPTIMIZED) && !defined(KILN_GENERIC)
#include "zng_defines.h"
#include "../zlib-ng/arch/arm/compare256_neon.c"
#endif
