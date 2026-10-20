#if defined(__x86_64__) && defined(KILN_OPTIMIZED) && !defined(KILN_GENERIC)
#include "zng_defines.h"
#include "../zlib-ng/arch/x86/compare256_avx2.c"
#endif
