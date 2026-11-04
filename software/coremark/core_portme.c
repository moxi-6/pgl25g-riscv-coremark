/* CoreMark platform glue for the atk_l50 RV32I SoC.
 *
 * Replaces barebones/core_portme.c, which is written against a hosted C
 * environment: it needs time.h for timing, and it leaves two #error
 * placeholders (barebones_clock and portable_init) that must be filled in by
 * whoever ports CoreMark. This file fills them using the board's own MMIO.
 */
#include "coremark.h"
#include "perf.h"

#define GPIO_OUT (*(volatile ee_u32 *)0x10000000u)
#define UART_TX  (*(volatile ee_u32 *)0x10000004u)

/* Seed selection. PERFORMANCE_RUN and VALIDATION_RUN are chosen by
 * core_portme.h from TOTAL_DATA_SIZE; core_main.c copies these into the
 * benchmark results. Only seed4 (iterations) is ours to choose, and it is the
 * one that controls the run length. */
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* The board's 64-bit free-running cycle counter is the timebase. It is the
 * only clock available: there is no RTC and no time.h. */
CORETIMETYPE barebones_clock(void)
{
    return (CORETIMETYPE)perf_cycles();
}

#define GETMYTIME(_t) (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini) ((fin) - (ini))
#define TIMER_RES_DIVIDER 1
#define SAMPLE_TIME_IMPLEMENTATION 1

#ifndef BOARD_CLOCK_HZ
#error "BOARD_CLOCK_HZ must be defined by the build (see coremark.mak)."
#endif

/* Only consumed if a port falls back to the reference time_in_secs; ours does
 * not, but leaving a runtime division in a macro that might be picked up later
 * would reintroduce the div problem described below. */
#define EE_TICKS_PER_SEC (BOARD_CLOCK_HZ / TIMER_RES_DIVIDER)

static CORETIMETYPE start_time_val, stop_time_val;

// Keep timer boundaries identifiable in disassembly even for LTO builds.
// This is port instrumentation; the benchmark algorithms remain unchanged.
__attribute__((noinline, noclone, externally_visible)) void start_time(void)
{
    GETMYTIME(&start_time_val);
}

__attribute__((noinline, noclone, externally_visible)) void stop_time(void)
{
    GETMYTIME(&stop_time_val);
}

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
}

/* Integer-only conversion: HAS_FLOAT is 0, so secs_ret is an integer and the
 * result must truncate. A truncated 0 makes core_main.c report
 * "ERROR! Must execute for at least 10 secs" even on a valid run.
 *
 * No division appears here on purpose, in either width. BOARD_CLOCK_HZ is a
 * compile-time constant and ticks is 64 bit, but GCC cannot strength-reduce a
 * 64-bit division on a target with no multiply instruction, so even the
 * "constant" form becomes a call to __udivdi3 -- and -nostdlib links no
 * libgcc. Whole seconds are counted by repeated subtraction instead, which is
 * O(seconds) with a tiny constant: a benchmark run is tens of seconds, so the
 * loop body executes a few dozen times at most and never inside the timed
 * region. */
secs_ret time_in_secs(CORE_TICKS ticks)
{
    const CORE_TICKS ticks_per_second = (CORE_TICKS)BOARD_CLOCK_HZ;
    secs_ret seconds = 0;

    while (ticks >= ticks_per_second) {
        ticks -= ticks_per_second;
        seconds++;
    }
    return seconds;
}

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    /* No initialization is needed: start.S has already brought up .data/.bss
     * and the stack, and the UART is usable as soon as the SoC leaves reset.
     * argc/argv are unused because MAIN_HAS_NOARGC is 1. */
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

/* CoreMark calls this once, after it has printed the whole report and the
 * validation verdict, so it is the natural place to drive the board's
 * pass/fail LED flag. Doing it here rather than in a wrapper around main()
 * avoids having to rename core_main.c's main() to make room for one.
 *
 * p->portable_id is left alone: core_main.c sets the flag before calling and
 * nothing reads it afterwards. */
void portable_fini(core_portable *p)
{
    (void)p;
    GPIO_OUT = 0xa5u;
}

/* ee_printf's output hook. The UART is write-only and self-throttling at the
 * SoC level (uart_valid is gated by uart_ready), so no polling is required. */
void uart_send_char(char c)
{
    UART_TX = (ee_u32)(ee_u8)c;
}
