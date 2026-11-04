/* ATK-L50 reflex game: the CPU lights one LED0-3 at a random moment and the
 * player must press the matching KEY0-3 as fast as possible. The UART reports
 * the reaction time per round plus the match summary.
 *
 * This is the competition's "real application" demo. It uses only the parts of
 * the SoC that already exist: GPIO output for the LEDs, the read-only KEY
 * register added next to it, the UART transmitter and the free-running cycle
 * counter. No new peripheral block was needed.
 *
 * RV32I has neither multiply nor divide, and this project links -nostdlib, so
 * the helper symbols GCC emits for `*`, `/` and `%` are provided at the bottom
 * of this file instead of coming from libgcc.
 */
#include <stdint.h>

#define GPIO_OUT  (*(volatile uint32_t *)0x10000000u)
#define UART_DATA (*(volatile uint32_t *)0x10000004u)
#define KEY_IN    (*(volatile uint32_t *)0x10000008u)
#define CYCLE_LO  (*(volatile uint32_t *)0x10000010u)

/* Optional display registers are ignored by a legacy SoC with LCD_ENABLE=0.
 * GPIO LEDs remain the timing cue: LCD snapshots can lag by up to one frame. */
#define LCD_STATUS (*(volatile uint32_t *)0x10000030u)
#define LCD_TIME   (*(volatile uint32_t *)0x10000034u)
#define LCD_SCORE  (*(volatile uint32_t *)0x10000038u)
#define LCD_BEST   (*(volatile uint32_t *)0x1000003cu)
static uint32_t bcd4(uint32_t value)
{
    uint32_t out = 0u;
    if (value > 9999u) value = 9999u;
    for (uint32_t shift = 0; shift < 16u; shift += 4u) {
        uint32_t quotient = value / 10u;
        out |= (value - quotient * 10u) << shift;
        value = quotient;
    }
    return out;
}
static void lcd_publish(uint32_t state, uint32_t target, uint32_t round,
                        uint32_t hits, uint32_t elapsed, uint32_t best)
{
    LCD_TIME = bcd4(elapsed);
    LCD_SCORE = (bcd4(hits) << 16) | bcd4(round);
    LCD_BEST = best == 0xffffffffu ? 0u : bcd4(best);
    LCD_STATUS = state | (target << 8); /* Commit last; other words are staging. */
}

#define CLOCK_HZ     50000000u
#define MS_CYCLES    (CLOCK_HZ / 1000u)
#define KEY_MASK     0xFu
/* The simulation build shrinks a match to two short rounds: at 50 MHz of
 * modelled time a real 3 s timeout would need 150 M simulated cycles, which
 * Icarus cannot chew through in reasonable time. The logic exercised is
 * identical, only the round count and hold times change. */
#ifdef GAME_FAST_SIM
#define ROUNDS        2u
#define HOLD_TIMEOUT  120u
#define QUIET_FIRST   5u
#define QUIET_SPAN    5u
#define RESULT_HOLD   5u
#else
#define ROUNDS        10u
#define HOLD_TIMEOUT  3000u
#define QUIET_FIRST   600u
#define QUIET_SPAN    1400u
#define RESULT_HOLD   500u
#endif

static void uart_putc(char ch)
{
    while ((UART_DATA & 1u) == 0u) {
    }
    UART_DATA = (uint32_t)(uint8_t)ch;
}

static void uart_puts(const char *text)
{
    while (*text != 0) {
        uart_putc(*text);
        text++;
    }
}

static void uart_putu(uint32_t value)
{
    char digits[10];
    uint32_t count = 0;

    if (value == 0u) {
        uart_putc('0');
        return;
    }
    while (value != 0u) {
        uint32_t quotient = value / 10u;
        digits[count] = (char)('0' + (uint8_t)(value - quotient * 10u));
        count++;
        value = quotient;
    }
    while (count != 0u) {
        count--;
        uart_putc(digits[count]);
    }
}

static void uart_puthex(uint32_t value)
{
    static const char digits[] = "0123456789ABCDEF";
    int shift;

    uart_puts("0x");
    for (shift = 28; shift >= 0; shift -= 4) {
        uart_putc(digits[(value >> (uint32_t)shift) & 0xFu]);
    }
}

static void delay_cycles(uint32_t cycles)
{
    uint32_t start = CYCLE_LO;

    while ((uint32_t)(CYCLE_LO - start) < cycles) {
    }
}

static void delay_ms(uint32_t milliseconds)
{
    while (milliseconds != 0u) {
        delay_cycles(MS_CYCLES);
        milliseconds--;
    }
}

static uint32_t keys_raw(void)
{
    return KEY_IN & KEY_MASK;
}

/* Held keys bounce for a few milliseconds; require the same electrical state
 * on consecutive 1 ms samples before believing it. */
static uint32_t keys_settled(void)
{
    uint32_t previous = keys_raw();
    uint32_t stable = 0u;

    while (stable < 3u) {
        delay_ms(1u);
        uint32_t current = keys_raw();
        if (current == previous) {
            stable++;
        } else {
            previous = current;
            stable = 0u;
        }
    }
    return previous;
}

static void wait_all_released(void)
{
    uint32_t started = CYCLE_LO;

    while ((uint32_t)(CYCLE_LO - started) < 2000u * MS_CYCLES) {
        if (keys_settled() == KEY_MASK) {
            return;
        }
    }
}

static uint32_t rng_state = 0x2545f491u;

static uint32_t rng_next(void)
{
    uint32_t value = rng_state;

    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    rng_state = value;
    return value;
}

/* Wait until exactly one key is held. Returns 0..3, or -1 on timeout. A state
 * with two keys down is skipped rather than reported as a result.
 *
 * keys_settled() returns the raw active-low nibble, so "exactly one key down"
 * means exactly one ZERO bit. The pressed mask below flips the polarity first
 * and only then tests for a single set bit; testing the raw value instead would
 * accept 0b1011 (KEY2 down) only when it also had exactly one low bit, which
 * never happens for a real key press. */
static int wait_single_key(uint32_t timeout_ms)
{
    uint32_t started = CYCLE_LO;
    uint32_t timeout_cycles = timeout_ms * MS_CYCLES;

    while ((uint32_t)(CYCLE_LO - started) < timeout_cycles) {
        uint32_t pressed = (~keys_settled()) & KEY_MASK;
        if (pressed != 0u && (pressed & (pressed - 1u)) == 0u) {
            for (int index = 0; index < 4; index++) {
                if ((pressed & (1u << (uint32_t)index)) != 0u) {
                    return index;
                }
            }
        }
    }
    return -1;
}

static void report_round(uint32_t round, uint32_t target, int key,
                         uint32_t elapsed_ms, int ok)
{
    uart_puts("R");
    uart_putu(round);
    uart_puts(": LED");
    uart_putu(target);
    uart_puts(" -> ");
    if (ok == 1) {
        uart_puts("OK ");
        uart_putu(elapsed_ms);
        uart_puts(" ms");
    } else if (ok == -1) {
        uart_puts("WRONG KEY");
        if (key >= 0) {
            uart_puts(" (KEY");
            uart_putu((uint32_t)key);
            uart_puts(")");
        }
    } else {
        uart_puts("TIMEOUT");
    }
    uart_puts("\r\n");
}

int main(void)
{
    lcd_publish(0u, 0u, 0u, 0u, 0u, 0xffffffffu);
    uart_puts("\r\n\r\n=== ATK-L50 RISC-V reflex game ===\r\n");
    uart_puts("KEY register reads ");
    uart_puthex(keys_raw());
    uart_puts(" at boot (0xF = all keys released, low nibble = KEY0..KEY3 active-low).\r\n");
    uart_puts("One LED lights at a random moment: press the matching KEY fast.\r\n");
    uart_putu(ROUNDS);
    uart_puts(" rounds per match; press any key to start the next match.\r\n");

    for (;;) {
        uint32_t total_ms = 0u;
        uint32_t best_ms = 0xFFFFFFFFu;
        uint32_t hits = 0u;

        uart_puts("\r\n-- new match --\r\n");
        wait_all_released();

        for (uint32_t round = 1u; round <= ROUNDS; round++) {
            uint32_t target = (rng_next() >> 8) & 3u;
            uint32_t quiet_ms = QUIET_FIRST + (rng_next() % QUIET_SPAN);
            int key;
            uint32_t elapsed_ms;
            int ok;

            GPIO_OUT = 0u;
            lcd_publish(1u, target, round, hits, 0u, best_ms);
            delay_ms(quiet_ms);
            lcd_publish(2u, target, round, hits, 0u, best_ms);
            GPIO_OUT = 1u << target;

            uint32_t started = CYCLE_LO;
            key = wait_single_key(HOLD_TIMEOUT);
            uint32_t cycles = CYCLE_LO - started;
            elapsed_ms = cycles / MS_CYCLES;
            GPIO_OUT = 0u;

            if (key < 0) {
                ok = 0;
            } else if ((uint32_t)key == target) {
                ok = 1;
                hits++;
                total_ms += elapsed_ms;
                if (elapsed_ms < best_ms) {
                    best_ms = elapsed_ms;
                }
            } else {
                ok = -1;
            }
            lcd_publish(ok == 1 ? 3u : (ok == -1 ? 4u : 5u), target, round,
                        hits, elapsed_ms, best_ms);
            report_round(round, target, key, elapsed_ms, ok);
            delay_ms(RESULT_HOLD); /* Keep the result visible for multiple LCD frames. */
            wait_all_released();
        }

        lcd_publish(6u, 0u, ROUNDS, hits, hits ? total_ms / hits : 0u, best_ms);
        uart_puts("Match: ");
        uart_putu(hits);
        uart_puts("/");
        uart_putu(ROUNDS);
        uart_puts(" hit");
        if (hits != 0u) {
            uart_puts(", avg ");
            uart_putu(total_ms / hits);
            uart_puts(" ms, best ");
            uart_putu(best_ms);
            uart_puts(" ms");
        }
        uart_puts("\r\nPress any key for another match.\r\n");
        wait_all_released();
        while (keys_settled() == KEY_MASK) {
            delay_ms(10u);
        }
    }
    return 0;
}

/* Software integer arithmetic: RV32I has no M extension and this project links
 * without libgcc, so GCC's own calls to these psABI symbols must be satisfied
 * here. Only shifts, adds, subtracts and compares are used. */

uint32_t __mulsi3(uint32_t a, uint32_t b)
{
    uint32_t result = 0u;

    while (b != 0u) {
        if ((b & 1u) != 0u) {
            result += a;
        }
        a <<= 1;
        b >>= 1;
    }
    return result;
}

static void udivmod(uint32_t numerator, uint32_t denominator,
                    uint32_t *quotient, uint32_t *remainder)
{
    uint32_t quotient_value = 0u;
    uint32_t remainder_value = 0u;

    if (denominator == 0u) {
        *quotient = 0xFFFFFFFFu;
        *remainder = numerator;
        return;
    }
    for (int bit = 31; bit >= 0; bit--) {
        remainder_value = (remainder_value << 1) | ((numerator >> (uint32_t)bit) & 1u);
        if (remainder_value >= denominator) {
            remainder_value -= denominator;
            quotient_value |= 1u << (uint32_t)bit;
        }
    }
    *quotient = quotient_value;
    *remainder = remainder_value;
}

uint32_t __udivsi3(uint32_t a, uint32_t b)
{
    uint32_t quotient;
    uint32_t remainder;

    udivmod(a, b, &quotient, &remainder);
    return quotient;
}

uint32_t __umodsi3(uint32_t a, uint32_t b)
{
    uint32_t quotient;
    uint32_t remainder;

    udivmod(a, b, &quotient, &remainder);
    return remainder;
}
