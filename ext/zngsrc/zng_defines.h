#ifndef KILN_ZNG_DEFINES_H
#define KILN_ZNG_DEFINES_H
#ifndef NDEBUG
#define NDEBUG 1
#endif
#define ZLIBNG_NATIVE_API 1
#define WITH_ALL_FALLBACKS 1
#define HAVE_VISIBILITY_HIDDEN 1
#if !defined(__APPLE__)
#define HAVE_VISIBILITY_INTERNAL 1
#endif
#define HAVE_ATTRIBUTE_ALIGNED 1
#define HAVE_BUILTIN_ASSUME_ALIGNED 1
#if defined(KILN_OPTIMIZED) && !defined(KILN_GENERIC) && (defined(__x86_64__) || defined(__aarch64__))
#define WITH_OPTIM 1
#endif
#if defined(WITH_OPTIM) && defined(__x86_64__)
#define X86_FEATURES 1
#define HAVE_CPUID_GNU 1
#define X86_HAVE_XSAVE_INTRIN 1
#define X86_SSE2 1
#define X86_SSSE3 1
#define X86_SSE41 1
#define X86_SSE42 1
#define X86_PCLMULQDQ_CRC 1
#define X86_AVX2 1
#endif
#if defined(WITH_OPTIM) && defined(__aarch64__)
#define ARM_FEATURES 1
#define ARM_NEON 1
#define ARM_NEON_HASLD4 1
#define ARM_CRC32 1
#define ARM_CRC32_INTRIN 1
#define ARM_PMULL_EOR3 1
#define HAVE_ARM_ACLE_H 1
#if defined(__linux__)
#define HAVE_SYS_AUXV_H 1
#endif
#endif
#endif
