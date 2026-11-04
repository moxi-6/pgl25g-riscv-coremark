/* CoreMark porting layer for the atk_l50 RV32I SoC.
 *
 * This is our port, not EEMBC's barebones one: the board is RV32I/ILP32 with
 * no libc, no libgcc and an MMIO cycle counter instead of time.h, so every
 * assumption barebones makes about hosted C has to be replaced here.
 *
 * Two settings are load-bearing and are explained where they are defined:
 *   HAS_FLOAT 0   - avoids the soft-float library; RV32I has no FPU and
 *                   -nostdlib links no libgcc, so any float would not link.
 *   MEM_STATIC    - keeps the algorithm data block out of the 1 KiB stack.
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include "board_coremark_config.h"

/* No hosted headers are available: see software/README.md for the toolchain
 * flags. HAS_TIME_H/USE_CLOCK only matter to the reference ports' timing code,
 * which we replace wholesale in core_portme.c. */
#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0

/* Reported verbatim in the CoreMark output so a score can be reproduced. */
#ifndef COMPILER_VERSION
#define COMPILER_VERSION "GCC" __VERSION__
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS FLAGS_STR
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef unsigned char ee_u8;
typedef unsigned int ee_u32;
typedef ee_u32 ee_ptr_int;
typedef ee_u32 ee_size_t;

#define NULL ((void *)0)
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

/* The board counter is 64 bit. A 32-bit CORE_TICKS would wrap after ~86 s at
 * 50 MHz, which is close enough to the >=10 s run requirement to be a real
 * scoring hazard, so keep the full width. CoreMark only ever subtracts two
 * readings, so the unsigned wrap-around arithmetic stays correct regardless. */
typedef unsigned long long CORETIMETYPE;
typedef unsigned long long CORE_TICKS;

/* Seeds come from the volatile variables in core_portme.c: there are no
 * command line arguments on this target. */
#define SEED_METHOD SEED_VOLATILE

/* MEM_STATIC rather than MEM_STACK: the algorithm data block is 2000 bytes and
 * only 1 KiB of the 8 KiB RAM is reserved for the stack, so core_main.c's
 * stack_memblock[] array cannot be used. MEM_STATIC also lets the linker prove
 * the layout, since .bss and _stack_bottom are both known at link time. */
#define MEM_METHOD MEM_STATIC

#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

/* Selecting the run profile by TOTAL_DATA_SIZE is EEMBC's own convention
 * (core_portme.h in the reference port does the same). It matters because
 * core_main.c derives seedcrc from size = TOTAL_DATA_SIZE/3 and only
 * validates the CRC results when that lands on a published (seed, size) pair.
 * 2000 is the 2K variant of both the performance and the validation run. */
#ifndef TOTAL_DATA_SIZE
#define TOTAL_DATA_SIZE 2000
#endif

/* Profile selection, following EEMBC's own convention in the reference
 * barebones/core_portme.h. core_main.c derives seedcrc from size =
 * TOTAL_DATA_SIZE/3 and only validates the CRC results when that lands on a
 * published (seed, size) pair, so this choice is not cosmetic: with
 * TOTAL_DATA_SIZE 2000 the size is 666 per algorithm, which matches the "2K"
 * variant of both the performance run (seedcrc 0xe9f5) and the validation run
 * (seedcrc 0x18f2). 2000 selects PERFORMANCE_RUN here, exactly as upstream;
 * the seeds that go with it are set in core_portme.c. Defining VALIDATION_RUN
 * instead is a supported change (the same 666-byte size matches 0x18f2), which
 * is what the correctness check uses. */
#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */