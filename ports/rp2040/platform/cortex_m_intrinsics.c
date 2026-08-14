// Opaque no-op for hardware-polling/electrical-settling busy-wait loops in
// shared Swift code (Sources/smk/KeyMatrix.swift). Same purpose as
// ports/stm32f4's and ports/stm32wb's own platform/cortex_m_intrinsics.c
// (same filename, same reason, applied here to RP2040/RP2350): Swift's
// `UnsafeMutablePointer.pointee` is NOT a volatile access, so a
// side-effect-free busy-wait loop looks loop-invariant to LLVM and gets
// deleted outright under the forward-progress rule — found as a real bug in
// KeyMatrix.swift's row/column settling delay, which had no such call and
// was silently compiled away to zero-length under -Osize.
//
// A call to an external C function the optimizer cannot see through defeats
// that: it may clobber arbitrary memory, so the loop must be kept and
// re-checked every iteration. Deliberately declared on the Swift side via
// @_extern(c, "smk_cpu_nop") — the whole point is that swiftc only ever
// sees the declaration, never the body.
void smk_cpu_nop(void) {
    __asm__ volatile("nop");
}
