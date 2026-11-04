#include <stdint.h>
#include "perf.h"

#define GPIO_OUT (*(volatile uint32_t *)0x10000000u)
#define UART_TX (*(volatile uint32_t *)0x10000004u)

/* Volatile work retains a known loop with loads, stores and branches. */
static volatile uint32_t checksum;
volatile uint64_t measured_cycles;
volatile uint64_t measured_instret;

int main(void)
{
    uint64_t cycle_start = perf_cycles();
    uint64_t retire_start = perf_instret();
    for (uint32_t i = 1; i <= 32; ++i) checksum += i;
    measured_instret = perf_instret() - retire_start;
    measured_cycles = perf_cycles() - cycle_start;
    if (checksum != 528 || measured_instret == 0 ||
        measured_cycles < measured_instret || perf_clock_hz() == 0) {
        GPIO_OUT = 0x0fu;
        return 1;
    }
    static const char message[] = "PERF OK\r\n";
    for (const char *p = message; *p; ++p) UART_TX = (uint32_t)(uint8_t)*p;
    GPIO_OUT = 0xa5u;
    return 0;
}
