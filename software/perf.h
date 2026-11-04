#ifndef FPGA_PERF_H
#define FPGA_PERF_H
#include <stdint.h>

/* Board-specific read-only MMIO, not architectural RISC-V CSR registers. */
static inline uint64_t perf_read64(uintptr_t low_addr)
{
    volatile const uint32_t *reg = (volatile const uint32_t *)low_addr;
    uint32_t hi, lo, check;
    do {
        hi = reg[1];
        lo = reg[0];
        check = reg[1];
    } while (hi != check);
    return ((uint64_t)hi << 32) | lo;
}

static inline uint64_t perf_cycles(void) { return perf_read64(0x10000010u); }
static inline uint64_t perf_instret(void) { return perf_read64(0x10000018u); }
static inline uint32_t perf_clock_hz(void)
{
    return *(volatile const uint32_t *)0x10000020u;
}
#endif
