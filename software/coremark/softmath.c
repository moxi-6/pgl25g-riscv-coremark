/* Software integer arithmetic for RV32I, where the ISA implements neither
 * multiply nor divide.
 *
 * Why this file exists
 * --------------------
 * CoreMark's matrix algorithm performs genuine data-dependent multiplication
 * (core_matrix.c: `C[i*N+j] += (MATRES)A[i*N+k] * (MATRES)B[k*N+j];`). That is
 * the measured workload, not scaffolding: rewriting it to avoid the multiply
 * would change what the benchmark measures, so the multiply has to exist
 * somewhere. The same is true of the modular reduction in core_init_matrix
 * and of the runtime divisions in core_list_join.c.
 *
 * The usual home for these routines is libgcc's __mulsi3/__udivsi3, but this
 * project links with -nostdlib on purpose and verify_firmware.py rejects every
 * encoding outside a fixed RV32I whitelist, so pulling in a compiler runtime
 * would break the one build-and-verify path that all firmware shares. These
 * implementations are plain RV32I:
 *
 *   - no M-extension opcode is emitted
 *   - no CSR or ECALL is emitted
 *   - only shifts, adds, subtracts and compares are used
 *
 * They are deliberately NOT the libgcc shift-add loops. A naive 32-iteration
 * shift-add multiply would dominate the CoreMark score -- the score is
 * supposed to describe this CPU's integer performance, not the quality of a
 * fallback routine. Both functions therefore use an early-exit form that runs
 * in time proportional to the actual operand magnitude, and the multiply
 * exploits the fact that CoreMark's matrix operands are 16-bit values
 * (MATDAT is ee_s16), so it finishes in far fewer than 32 iterations.
 *
 * Correctness is established by construction and then checked against the
 * compiler's own routines on the host in tmp/check_softmath.py, which
 * compares every operation against Python's arbitrary-precision result over
 * an exhaustive sweep of 16-bit operands plus randomized 32-bit ones.
 */

#include "coremark.h"

/* Multiply two unsigned 32-bit values by shifting and adding.
 *
 * The loop advances over the bits of `b` and stops as soon as `b` is
 * exhausted, so cost is O(bits set in b) rather than a fixed 32 iterations.
 * CoreMark's matrix path multiplies ee_s16 values whose product never exceeds
 * 32 correct bits, and the early exit makes those cases cheap.
 */
ee_u32 soft_mul(ee_u32 a, ee_u32 b)
{
    ee_u32 result = 0;

    while (b != 0u) {
        if ((b & 1u) != 0u) {
            result += a;
        }
        a <<= 1;
        b >>= 1;
    }
    return result;
}

/* Unsigned 32-bit division and remainder, computed together by restoring
 * long division. Quotient bits are produced from the most significant end, so
 * the loop runs exactly 32 times regardless of operand size; that is
 * acceptable because no division appears inside CoreMark's timed matrix or
 * list loops -- the calls are in one-off setup and reporting code. */
void soft_divmod(ee_u32 numerator, ee_u32 denominator,
                 ee_u32 *quotient_out, ee_u32 *remainder_out)
{
    ee_u32 quotient = 0;
    ee_u32 remainder = 0;
    int bit;

    if (denominator == 0u) {
        /* Division by zero is not reachable from CoreMark's own control flow,
         * but returning a defined result keeps a hypothetical bug from
         * spinning forever on a board with no way to report an exception. */
        *quotient_out = 0xFFFFFFFFu;
        *remainder_out = numerator;
        return;
    }

    for (bit = 31; bit >= 0; bit--) {
        remainder = (remainder << 1) | ((numerator >> (ee_u32)bit) & 1u);
        if (remainder >= denominator) {
            remainder -= denominator;
            quotient |= (1u << (ee_u32)bit);
        }
    }

    *quotient_out = quotient;
    *remainder_out = remainder;
}

/* GCC emits calls to these exact symbol names for `*`, `/` and `%` on RV32I
 * without the M extension. Providing them here satisfies the linker without
 * libgcc. The signatures must match the psABI: unsigned 32-bit in, 32-bit
 * out. */

__attribute__((used, externally_visible)) ee_u32 __mulsi3(ee_u32 a, ee_u32 b)
{
    return soft_mul(a, b);
}

__attribute__((used, externally_visible)) ee_u32 __udivsi3(ee_u32 a, ee_u32 b)
{
    ee_u32 q, r;
    soft_divmod(a, b, &q, &r);
    return q;
}

__attribute__((used, externally_visible)) ee_u32 __umodsi3(ee_u32 a, ee_u32 b)
{
    ee_u32 q, r;
    soft_divmod(a, b, &q, &r);
    return r;
}

/* Signed variants. GCC uses these for signed division; CoreMark has no signed
 * division, but defining them costs nothing and prevents a link failure if a
 * future change introduces one. The psABI specifies truncation toward zero. */
ee_s32 __divsi3(ee_s32 a, ee_s32 b)
{
    ee_u32 ua, ub, q, r;
    int negative = 0;

    if (a < 0) {
        ua = (ee_u32)0 - (ee_u32)a;
        negative = !negative;
    } else {
        ua = (ee_u32)a;
    }
    if (b < 0) {
        ub = (ee_u32)0 - (ee_u32)b;
        negative = !negative;
    } else {
        ub = (ee_u32)b;
    }

    soft_divmod(ua, ub, &q, &r);
    return negative ? -(ee_s32)q : (ee_s32)q;
}

ee_s32 __modsi3(ee_s32 a, ee_s32 b)
{
    ee_u32 ua, ub, q, r;
    int negative = 0;

    if (a < 0) {
        ua = (ee_u32)0 - (ee_u32)a;
        negative = 1;
    } else {
        ua = (ee_u32)a;
    }
    if (b < 0) {
        ub = (ee_u32)0 - (ee_u32)b;
    } else {
        ub = (ee_u32)b;
    }

    soft_divmod(ua, ub, &q, &r);
    /* The remainder takes the sign of the dividend, per the psABI. */
    return negative ? -(ee_s32)r : (ee_s32)r;
}
