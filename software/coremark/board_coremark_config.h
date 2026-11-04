/* Board-level build constants for the CoreMark image.
 *
 * Kept in a header rather than passed on the command line so that the exact
 * values a score was produced with are visible in the source tree, and so the
 * Python verifier can hash this file as one of the firmware inputs.
 */
#ifndef BOARD_COREMARK_CONFIG_H
#define BOARD_COREMARK_CONFIG_H

/* Mirrors CLOCK_HZ in rtl/top/atk_l50_top.sv (50 MHz input divided by two).
 * It must be a
 * compile-time constant: it is used as a divisor, and a runtime divisor would
 * emit a div instruction that RV32I cannot execute. If the SoC clock is ever
 * changed, this must change with it or every reported time will be wrong. */
#define BOARD_CLOCK_HZ 25000000u

/* CoreMark iterations. core_main.c copies this into the benchmark, and it is
 * the only knob that controls run length.
 *
 * 0 means "let CoreMark choose": core_main.c then grows the iteration count by
 * tens until one iteration-set has taken at least a second, and scales that to
 * a run of about ten seconds. That is EEMBC's own mechanism for meeting the
 * >=10 s run-and-report rule, and it adapts by itself if the clock or the
 * compiler flags change, so the board image uses it.
 *
 * A nonzero value pins the run to that many iterations, which is what the
 * simulation needs. Actual score must use the measured ticks and iterations
 * at the configured hardware frequency; calibration is not a score. */
#ifndef ITERATIONS
#define ITERATIONS 0
#endif

/* The compiler flags string CoreMark prints in its report. EEMBC's own port
 * expects the build system to define FLAGS_STR on the command line, but the
 * project Makefile has a single fixed CFLAGS for every image and is not going
 * to grow a per-app -D. Defining it here keeps the reported flags accurate
 * without touching the shared build recipe, and keeps it visible in a file the
 * verifier already hashes. It must be kept in step with CFLAGS in
 * software/Makefile; it is report text only and affects no computation. */
#ifndef FLAGS_STR
#ifdef __riscv_zmmul
#define FLAGS_STR "-O2 -march=rv32i_zmmul -mabi=ilp32 -mno-relax -msmall-data-limit=0 -ffreestanding -fno-builtin"
#else
#define FLAGS_STR "-O2 -march=rv32i -mabi=ilp32 -mno-relax -msmall-data-limit=0 -ffreestanding -fno-builtin"
#endif
#endif

#endif /* BOARD_COREMARK_CONFIG_H */
