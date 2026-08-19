// Opaque no-op called from inside every hardware-polling busy-wait loop in
// ports/samd21/ClockInit.swift — the same deleted-poll-loop defense as
// ports/stm32f4/platform/cortex_m_intrinsics.c (see that file and
// CLAUDE.md's register-polling note for the full story: Swift's `.pointee`
// is not a volatile access, so an empty-bodied status-poll loop looks
// loop-invariant to LLVM and gets deleted outright). A call to an external
// C function the optimizer cannot see through forces the load to be
// re-issued each iteration.

void smk_cpu_nop(void) {
    __asm__ volatile("nop");
}
