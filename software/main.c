#include <stdint.h>

#define GPIO_OUT (*(volatile uint32_t *)0x10000000u)
#define UART_TX  (*(volatile uint32_t *)0x10000004u)

static void uart_putc(char ch)
{
    UART_TX = (uint32_t)(uint8_t)ch;
}

int main(void)
{
    static const char message[] = "OK\r\n";
    GPIO_OUT = 0x5au;
    for (const char *p = message; *p; ++p) uart_putc(*p);
    GPIO_OUT = 0xa5u;
    return 0;
}
