/* Minimal ee_printf for the atk_l50 RV32I SoC.
 *
 * EEMBC's barebones/ee_printf.c cannot be used as-is: its number() routine
 * divides by a *runtime* base,
 *
 *     tmp[i++] = dig[((unsigned long) num) % (unsigned) base];
 *     num      = ((unsigned long) num) / (unsigned) base;
 *
 * which makes GCC emit a real div/rem. RV32I has no M extension, -nostdlib
 * links no libgcc, and software/verify_firmware.py rejects M-extension
 * encodings outright, so that file cannot link on this target at all.
 *
 * CoreMark only ever prints with %d, %u, %lu, %s and %04x. This file
 * implements exactly those, and only those, without generating a single
 * multiply or divide instruction. Unsupported conversions are emitted
 * literally instead of silently producing wrong numbers, so a future format
 * change is visible on the UART rather than corrupting a score.
 */
#include "coremark.h"
#include <stdarg.h>

#define OUTPUT_BUF 640

static char out_buf[OUTPUT_BUF];
static ee_u32 out_len;

/* Declared here, implemented in core_portme.c. */
void uart_send_char(char c);

static void out_char(char c)
{
    /* Bounded and, more importantly, *not* flushed eagerly: writing straight to
     * the UART per byte would make the benchmark's own reporting dominate the
     * measurement window on a 1 MBaud link. */
    if (out_len < (ee_u32)OUTPUT_BUF - 1u) {
        out_buf[out_len++] = c;
    }
}

static void out_str(const char *s)
{
    while (*s) out_char(*s++);
}

/* Unsigned decimal with an optional minimum field width padded by zeros.
 * Digits are produced into a small buffer most-significant first and then
 * emitted in the same order.
 *
 * The obvious implementation, value % 10 / value / 10, does NOT work here: the
 * divisor is constant, but strength reduction normally replaces it with a
 * multiply-and-shift, and RV32I has no multiply instruction. GCC therefore
 * emits a call to __umodsi3/__udivsi3 instead -- confirmed by disassembling
 * the object file, which shows `li a1,10` followed by `call __umodsi3`. Those
 * helpers only exist in libgcc, which -nostdlib deliberately excludes, so the
 * link fails. Digit extraction is done by subtract-and-compare on a power-of-
 * ten table instead, exactly as software/perf_report.c already does. */
static void out_udec(ee_u32 value, ee_u32 width, int zero_pad)
{
    static const ee_u32 pow10[10] = {
        1u, 10u, 100u, 1000u, 10000u,
        100000u, 1000000u, 10000000u, 100000000u, 1000000000u
    };
    char tmp[10];
    ee_u32 count = 0;

    if (value == 0u) {
        tmp[count++] = '0';
    } else {
        /* Walk down from the highest power of ten that fits, peeling off one
         * digit per column. Every column is emitted even when its digit is
         * zero, which is what keeps 1000000 from printing as "1". */
        int scale = 9;
        while (scale > 0 && value < pow10[scale]) {
            scale--;
        }
        while (scale >= 0) {
            ee_u32 digit = 0;
            if (scale == 0) {
                /* Units column: whatever is left is the digit itself. */
                digit = value;
            } else {
                while (value >= pow10[scale]) {
                    value -= pow10[scale];
                    digit++;
                }
            }
            tmp[count++] = (char)('0' + (char)digit);
            scale--;
        }
    }

    if (zero_pad) {
        while (count < width) {
            out_char('0');
            width--;
        }
    }
    while (count < width) {
        out_char(' ');
        width--;
    }
    /* Most-significant first, so emit forwards. */
    {
        ee_u32 index;
        for (index = 0u; index < count; index++) {
            out_char(tmp[index]);
        }
    }
}

static void out_sdec(ee_s32 value, ee_u32 width)
{
    if (value < 0) {
        out_char('-');
        /* Negating INT_MIN would overflow, and the result would be printed as
         * its own magnitude either way, so go through unsigned arithmetic. */
        out_udec((ee_u32)0u - (ee_u32)value, width, 0);
    } else {
        out_udec((ee_u32)value, width, 0);
    }
}

static void out_hex(ee_u32 value, ee_u32 width, int zero_pad)
{
    char tmp[8];
    ee_u32 count = 0;

    if (value == 0u) {
        tmp[count++] = '0';
    } else {
        while (value != 0u) {
            ee_u32 nibble = value & 0xFu;
            tmp[count++] = (char)(nibble < 10u ? ('0' + (char)nibble)
                                               : ('a' + (char)(nibble - 10u)));
            value = value >> 4;
        }
    }

    while (count < width) {
        out_char(zero_pad ? '0' : ' ');
        width--;
    }
    while (count > 0u) {
        count--;
        out_char(tmp[count]);
    }
}

int ee_printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);

    out_len = 0;
    while (*fmt) {
        ee_u32 width;
        int zero_pad;
        int long_arg;

        if (*fmt != '%') {
            out_char(*fmt++);
            continue;
        }
        fmt++;

        zero_pad = 0;
        width = 0;
        if (*fmt == '0') {
            zero_pad = 1;
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10u + (ee_u32)(*fmt - '0');
            fmt++;
        }
        long_arg = 0;
        if (*fmt == 'l') {
            long_arg = 1;
            fmt++;
        }

        switch (*fmt) {
        case 'd':
        case 'i':
            out_sdec(long_arg ? (ee_s32)va_arg(args, long) : va_arg(args, int), width);
            break;
        case 'u':
            out_udec(long_arg ? (ee_u32)va_arg(args, unsigned long)
                              : va_arg(args, unsigned int), width, zero_pad);
            break;
        case 'x':
            out_hex(long_arg ? (ee_u32)va_arg(args, unsigned long)
                             : va_arg(args, unsigned int), width, zero_pad);
            break;
        case 's':
            out_str(va_arg(args, const char *));
            break;
        case 'c':
            out_char((char)va_arg(args, int));
            break;
        case '%':
            out_char('%');
            break;
        default:
            /* Emit the conversion literally: a wrong number is worse than an
             * obviously unstyled one. */
            out_char('%');
            if (*fmt) out_char(*fmt);
            break;
        }
        if (*fmt) fmt++;
    }

    va_end(args);

    for (ee_u32 i = 0; i < out_len; i++) {
        uart_send_char(out_buf[i]);
    }
    return (int)out_len;
}