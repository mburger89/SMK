// 32-bit __atomic_* helpers for the SAMD21 (Cortex-M0+, armv6m).
//
// armv6-M has no LDREX/STREX, so LLVM lowers Embedded Swift's refcounting
// and once-init atomics to libatomic helper calls instead of inline
// instructions — the exact undefined-symbol set observed at this port's
// first link (__atomic_load_4/store_4/fetch_add_4/fetch_sub_4/
// compare_exchange_4). The RP2040 build (same armv6m core) gets these from
// pico-sdk; this bare-metal port provides them itself.
//
// Single-core chip, no RTOS: a PRIMASK disable/restore critical section is
// a complete implementation (the only concurrency is interrupts). Memory
// order arguments are irrelevant under that model and ignored.

#include <stdint.h>
#include <stdbool.h>

static inline uint32_t irq_save(void) {
    uint32_t primask;
    __asm__ volatile("mrs %0, PRIMASK" : "=r"(primask));
    __asm__ volatile("cpsid i" ::: "memory");
    return primask;
}

static inline void irq_restore(uint32_t primask) {
    __asm__ volatile("msr PRIMASK, %0" :: "r"(primask) : "memory");
}

uint32_t __atomic_load_4(const volatile void *ptr, int memorder) {
    (void)memorder;
    uint32_t s = irq_save();
    uint32_t v = *(const volatile uint32_t *)ptr;
    irq_restore(s);
    return v;
}

void __atomic_store_4(volatile void *ptr, uint32_t val, int memorder) {
    (void)memorder;
    uint32_t s = irq_save();
    *(volatile uint32_t *)ptr = val;
    irq_restore(s);
}

uint32_t __atomic_fetch_add_4(volatile void *ptr, uint32_t val, int memorder) {
    (void)memorder;
    uint32_t s = irq_save();
    uint32_t old = *(volatile uint32_t *)ptr;
    *(volatile uint32_t *)ptr = old + val;
    irq_restore(s);
    return old;
}

uint32_t __atomic_fetch_sub_4(volatile void *ptr, uint32_t val, int memorder) {
    (void)memorder;
    uint32_t s = irq_save();
    uint32_t old = *(volatile uint32_t *)ptr;
    *(volatile uint32_t *)ptr = old - val;
    irq_restore(s);
    return old;
}

bool __atomic_compare_exchange_4(volatile void *ptr, void *expected,
                                 uint32_t desired, bool weak,
                                 int success_memorder, int failure_memorder) {
    (void)weak; (void)success_memorder; (void)failure_memorder;
    uint32_t s = irq_save();
    uint32_t old = *(volatile uint32_t *)ptr;
    bool matched = (old == *(uint32_t *)expected);
    if (matched) {
        *(volatile uint32_t *)ptr = desired;
    } else {
        *(uint32_t *)expected = old;
    }
    irq_restore(s);
    return matched;
}
