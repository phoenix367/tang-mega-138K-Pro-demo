/*
 * soft_atomic.c -- libatomic stand-in for this board's single-hart "soft-atomic" rule.
 *
 * Code compiled with -march=rv32imfdc (no "a") turns every C11/GCC atomic read-modify-write
 * builtin into a call such as __atomic_fetch_add_4(); on a real libatomic those would be
 * lr/sc loops, which hang this SoC on a DDR cache miss (no coherency manager, see
 * doc/06-key-findings.md).  Here they are plain loads and stores: there is one hart, the
 * kernel and musl already treat atomics the same way, and a preemption between the load
 * and the store is the accepted single-hart caveat of the whole stack.
 *
 * scripts/rootfs/build_ffmpeg.sh builds this into $STAGING/lib/libsoftatomic.a; link it
 * after libav* (-lsoftatomic).  32-bit variants only; 1/2/8-byte ones are added when
 * something needs them.
 */
#include <stdint.h>
#include <stdbool.h>

#define RMW(name, expr)                                                      \
    uint32_t __atomic_##name##_4(volatile void *p, uint32_t v, int mo)       \
    {                                                                        \
        (void)mo;                                                            \
        uint32_t old = *(volatile uint32_t *)p;                              \
        *(volatile uint32_t *)p = (expr);                                    \
        return old;                                                          \
    }

RMW(fetch_add, old + v)
RMW(fetch_sub, old - v)
RMW(fetch_or,  old | v)
RMW(fetch_and, old & v)
RMW(fetch_xor, old ^ v)
RMW(exchange,  v)
#undef RMW

#define ARITH(name, expr)                                                    \
    uint32_t __atomic_##name##_4(volatile void *p, uint32_t v, int mo)       \
    {                                                                        \
        (void)mo;                                                            \
        uint32_t old = *(volatile uint32_t *)p, n = (expr);                  \
        *(volatile uint32_t *)p = n;                                         \
        return n;                                                            \
    }
ARITH(add_fetch, old + v)
ARITH(sub_fetch, old - v)
ARITH(or_fetch,  old | v)
ARITH(and_fetch, old & v)
ARITH(xor_fetch, old ^ v)
#undef ARITH

bool __atomic_compare_exchange_4(volatile void *p, void *expected, uint32_t desired, bool weak, int smo, int fmo)
{
    (void)weak; (void)smo; (void)fmo;
    uint32_t cur = *(volatile uint32_t *)p;
    if (cur == *(uint32_t *)expected) {
        *(volatile uint32_t *)p = desired;
        return true;
    }
    *(uint32_t *)expected = cur;
    return false;
}

uint32_t __atomic_load_4(const volatile void *p, int mo) { (void)mo; return *(const volatile uint32_t *)p; }
void __atomic_store_4(volatile void *p, uint32_t v, int mo) { (void)mo; *(volatile uint32_t *)p = v; }
bool __atomic_test_and_set(volatile void *p, int mo) { (void)mo; uint8_t old = *(volatile uint8_t *)p; *(volatile uint8_t *)p = 1; return old != 0; }
void __atomic_clear(volatile void *p, int mo) { (void)mo; *(volatile uint8_t *)p = 0; }
