#include <stdint.h>

#define GPIO_OUT (*(volatile uint32_t *)0x10000000u)
#define UART_TX  (*(volatile uint32_t *)0x10000004u)

volatile uint32_t initialized_word = 0x12345678u;
volatile uint8_t initialized_bytes[7] = {0x80, 0x01, 0x7f, 0xa5, 0x55, 0xfe, 0x33};
volatile uint32_t zero_words[3];
volatile uint8_t zero_bytes[3];
static const char message[] = "RUNTIME OK\r\n";

int main(void)
{
    if (initialized_word != 0x12345678u || initialized_bytes[0] != 0x80u ||
        initialized_bytes[3] != 0xa5u || initialized_bytes[6] != 0x33u) {
        GPIO_OUT = 0xe1u;
        return 1;
    }
    for (unsigned i = 0; i < 3; ++i) {
        if (zero_words[i] != 0 || zero_bytes[i] != 0) {
            GPIO_OUT = 0xe2u;
            return 2;
        }
    }
    // Corrupt writable state so a second reset must restore .data and .bss.
    initialized_word = 0;
    initialized_bytes[0] = 0;
    initialized_bytes[3] = 0;
    initialized_bytes[6] = 0;
    for (unsigned i = 0; i < 3; ++i) {
        zero_words[i] = 0xffffffffu;
        zero_bytes[i] = 0xffu;
    }
    for (const char *p = message; *p; ++p) UART_TX = (uint8_t)*p;
    GPIO_OUT = 0xa5u;
    return 0;
}
