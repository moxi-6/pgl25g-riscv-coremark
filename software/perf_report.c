/* Board-side performance counter report.
 *
 * Unlike perf_test.c, which only proves that the MMIO counters can be read,
 * this image prints the actual 64-bit cycle and instruction counts over UART
 * so a real board run produces a human-readable measurement.
 *
 * Decimal output deliberately avoids a division instruction: RV32I has no DIV,
 * -nostdlib links no libgcc, and verify_firmware.py rejects M-extension
 * encodings, so 64-bit division has no implementation available. Decimal
 * digits are produced by repeated subtraction of powers of ten instead.
 */
#include <stdint.h>
#include "perf.h"

#define GPIO_OUT (*(volatile uint32_t *)0x10000000u)
#define UART_TX  (*(volatile uint32_t *)0x10000004u)

#define WORK_ITEMS 2048u
#define WORK_SLOTS 64u

/* Deterministic load/store/branch workload. Uninitialized, so .bss clears it
 * on every reset and repeated runs start from identical state. */
static volatile uint32_t scratch[WORK_SLOTS];

static void uart_putc(char ch)
{
    UART_TX = (uint32_t)(uint8_t)ch;
}

static void uart_puts(const char *text)
{
    while (*text) uart_putc(*text++);
}

static void uart_u64_dec(uint64_t value)
{
    /* Scale a running power of ten up to the leading digit, then peel one
     * digit at a time. This is O(digits) rather than O(value): subtracting a
     * fixed power repeatedly would need up to 10^19 iterations for large
     * inputs, which cannot fit a board run's UART budget. */
    static const uint64_t pow10[20] = {
        1ull, 10ull, 100ull, 1000ull, 10000ull, 100000ull, 1000000ull,
        10000000ull, 100000000ull, 1000000000ull, 10000000000ull,
        100000000000ull, 1000000000000ull, 10000000000000ull,
        100000000000000ull, 1000000000000000ull, 10000000000000000ull,
        100000000000000000ull, 1000000000000000000ull,
        10000000000000000000ull
    };
    int scale = 19;
    while (scale > 0 && value < pow10[scale]) scale = scale - 1;
    for (int index = scale; index >= 0; --index) {
        uint32_t digit = 0;
        while (value >= pow10[index]) {
            value -= pow10[index];
            digit = digit + 1;
        }
        uart_putc((char)('0' + (char)digit));
    }
}

static void uart_u64_hex(uint64_t value)
{
    uart_puts("0x");
    for (int shift = 60; shift >= 0; shift -= 4) {
        uint32_t nibble = (uint32_t)((value >> shift) & 0xfull);
        uart_putc((char)(nibble < 10u ? ('0' + nibble) : ('a' + (nibble - 10u))));
    }
}

static void report(const char *label, uint64_t value)
{
    uart_puts(label);
    uart_puts("=");
    uart_u64_dec(value);
    uart_puts(" hex=");
    uart_u64_hex(value);
    uart_puts("\r\n");
}

int main(void)
{
    uint64_t cycle_start = perf_cycles();
    uint64_t retire_start = perf_instret();

    uint32_t accumulator = 0x12345678u;
    for (uint32_t index = 0; index < WORK_ITEMS; ++index) {
        uint32_t slot = index & (WORK_SLOTS - 1u);
        uint32_t value = scratch[slot] + index;
        value = value ^ (value << 3);
        scratch[slot] = value;
        accumulator = accumulator + value;
    }

    uint64_t cycle_delta = perf_cycles() - cycle_start;
    uint64_t retire_delta = perf_instret() - retire_start;
    uint32_t clock_hz = perf_clock_hz();

    uart_puts("PERF REPORT\r\n");
    report("CLOCK_HZ", (uint64_t)clock_hz);
    report("ACC", (uint64_t)accumulator);
    report("CYCLES", cycle_delta);
    report("INSTRET", retire_delta);
    uart_puts("PERF DONE\r\n");

    /* 0xa5 matches the accepted main.c pattern; 0x0f flags an implausible
     * reading so the board LED state distinguishes the two without a terminal. */
    if (clock_hz == 0u || retire_delta == 0ull || cycle_delta < retire_delta) {
        GPIO_OUT = 0x0fu;
        return 1;
    }
    GPIO_OUT = 0xa5u;
    return 0;
}