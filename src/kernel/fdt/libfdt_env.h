/* Freestanding libfdt environment header.
 * Overrides the standard libfdt_env.h to work without libc.
 * Provide minimal definitions and implementations needed by libfdt.
 */

#ifndef LIBFDT_ENV_H
#define LIBFDT_ENV_H

/* Fixed-width integer types */
typedef signed char int8_t;
typedef unsigned char uint8_t;
typedef signed short int16_t;
typedef unsigned short uint16_t;
typedef signed int int32_t;
typedef unsigned int uint32_t;
typedef signed long long int64_t;
typedef unsigned long long uint64_t;
typedef unsigned long size_t;
typedef unsigned long uintptr_t;

/* FDT big-endian types (used in libfdt for type safety) */
typedef uint16_t fdt16_t;
typedef uint32_t fdt32_t;
typedef uint64_t fdt64_t;

/* Limits */
#define INT_MAX 2147483647
#define INT32_MAX 2147483647
#define UINT32_MAX 4294967295U
#define UINT64_MAX 18446744073709551615ULL

/* Boolean */
typedef _Bool bool;
#define true 1
#define false 0

/* NULL */
#define NULL ((void *)0)

/* Memory functions - use compiler builtins */
#define memcpy __builtin_memcpy
#define memset __builtin_memset
#define memmove __builtin_memmove
#define memcmp __builtin_memcmp
#define memchr __builtin_memchr

/* String functions - use compiler builtins */
#define strlen __builtin_strlen
#define strncmp __builtin_strncmp
#define strchr __builtin_strchr

/* Functions not available as builtins - implemented in c_compat.zig */
extern size_t strnlen(const char *s, size_t maxlen);
extern char *strrchr(const char *s, int c);
extern unsigned long strtoul(const char *s, char **endp, int base);

/* Byte order conversion - big-endian DTB on little-endian host */
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define fdt16_to_cpu(x) __builtin_bswap16(x)
#define cpu_to_fdt16(x) __builtin_bswap16(x)
#define fdt32_to_cpu(x) __builtin_bswap32(x)
#define cpu_to_fdt32(x) __builtin_bswap32(x)
#define fdt64_to_cpu(x) __builtin_bswap64(x)
#define cpu_to_fdt64(x) __builtin_bswap64(x)
#else
#define fdt16_to_cpu(x) (x)
#define cpu_to_fdt16(x) (x)
#define fdt32_to_cpu(x) (x)
#define cpu_to_fdt32(x) (x)
#define fdt64_to_cpu(x) (x)
#define cpu_to_fdt64(x) (x)
#endif

#endif /* LIBFDT_ENV_H */
