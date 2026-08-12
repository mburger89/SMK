// STM32F411CEU6 RCC/PLL clock bring-up: HSE (25MHz, WeAct Black Pill's
// crystal) -> main PLL -> 96MHz SYSCLK, with PLLQ deriving an exact 48MHz
// USB OTG FS clock. See this plan's Task 2 for the PLL math and the
// register offsets' verification (RM0383 + cmsis-device-f4's headers).
//
// This is a busy-wait bring-up routine with no timeout: if HSE or the PLL
// never locks, there is nothing meaningful to do but hang — same fail-stop
// pattern ports/nrf52840/MpslGlue.swift uses for mpsl_init failures.
//
// IMPORTANT — every `while ... {}` poll below calls smk_cpu_nop() in its
// body, and must keep doing so. `UnsafeMutablePointer.pointee` is not a
// volatile access in Swift, so an empty-bodied loop that re-reads the same
// address looks loop-invariant to LLVM and gets deleted under the
// forward-progress rule (confirmed by disassembling a real build of this
// file: every wait had vanished, leaving straight-line register writes).
// The call to an opaque external C function
// (platform/cortex_m_intrinsics.c's smk_cpu_nop) is what forces the load to
// be re-issued each iteration. See CLAUDE.md's "Register polling loops in
// Swift" note.

private let rccBase: UInt32 = 0x40023800
private let rccCr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x00))!
private let rccPllcfgr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x04))!
private let rccCfgr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x08))!
private let rccApb1Enr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x40))!

private let pwrBase: UInt32 = 0x40007000
private let pwrCr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(pwrBase + 0x00))!

private let flashBase: UInt32 = 0x40023C00
private let flashAcr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(flashBase + 0x00))!

private let rccCrHseOn: UInt32 = 1 << 16
private let rccCrHseRdy: UInt32 = 1 << 17
private let rccCrPllOn: UInt32 = 1 << 24
private let rccCrPllRdy: UInt32 = 1 << 25

private let rccApb1EnrPwrEn: UInt32 = 1 << 28
private let pwrCrVosMask: UInt32 = 0b11 << 14
private let pwrCrVosScale1: UInt32 = 0b11 << 14 // reset default is Scale 2 (0b10) — Scale 1 needed above 84MHz

private let flashAcrLatency3Ws: UInt32 = 0b011      // RM0383 Table 10: 90-100MHz @ 2.7-3.6V
private let flashAcrPrften: UInt32 = 1 << 8
private let flashAcrIcen: UInt32 = 1 << 9
private let flashAcrDcen: UInt32 = 1 << 10

private let pllM: UInt32 = 25   // HSE(25MHz)/25 = 1MHz VCO input
private let pllN: UInt32 = 384  // 1MHz*384 = 384MHz VCO output
private let pllPBits: UInt32 = 0b01 // encoding: 00=/2 01=/4 10=/6 11=/8 -> PLLP=4, SYSCLK=384/4=96MHz
private let pllQ: UInt32 = 8    // 384/8 = 48MHz USB clock (must be exact)
private let rccPllcfgrPllsrcHse: UInt32 = 1 << 22

private let rccCfgrSwMask: UInt32 = 0b11
private let rccCfgrSwPll: UInt32 = 0b10
private let rccCfgrSwsMask: UInt32 = 0b11 << 2
private let rccCfgrSwsPll: UInt32 = 0b10 << 2
private let rccCfgrPpre1Mask: UInt32 = 0b111 << 10
private let rccCfgrPpre1Div2: UInt32 = 0b100 << 10 // APB1 max 50MHz: 96/2 = 48MHz

// Opaque no-op, implemented in platform/cortex_m_intrinsics.c. Called inside
// every busy-wait loop below so LLVM cannot prove the loop is invariant and
// delete it — see this file's header comment.
@_extern(c, "smk_cpu_nop")
func smk_cpu_nop()

@_cdecl("smk_clock_init")
func smk_clock_init() {
    // 1. Start HSE and wait for it to stabilize.
    rccCr.pointee |= rccCrHseOn
    while (rccCr.pointee & rccCrHseRdy) == 0 { smk_cpu_nop() }

    // 2. Power interface clock + Voltage Scale 1 (required above 84MHz).
    rccApb1Enr.pointee |= rccApb1EnrPwrEn
    pwrCr.pointee = (pwrCr.pointee & ~pwrCrVosMask) | pwrCrVosScale1

    // 3. Flash wait states for 96MHz, plus prefetch/instruction/data caches.
    flashAcr.pointee = flashAcrLatency3Ws | flashAcrPrften | flashAcrIcen | flashAcrDcen

    // 4. Configure the main PLL from HSE: PLLM/PLLN/PLLP/PLLQ, source = HSE.
    //    Must be written while the PLL is off (true here — POR default).
    rccPllcfgr.pointee = pllM | (pllN << 6) | (pllPBits << 16) | rccPllcfgrPllsrcHse | (pllQ << 24)

    // 5. Enable the PLL and wait for lock.
    rccCr.pointee |= rccCrPllOn
    while (rccCr.pointee & rccCrPllRdy) == 0 { smk_cpu_nop() }

    // 6. APB1 /2 (48MHz, within its 50MHz max); APB2 and AHB stay undivided
    //    (96MHz, within APB2's 100MHz max and AHB's 100MHz max) — both
    //    already 0 (not divided) at reset, so only PPRE1 needs setting.
    rccCfgr.pointee = (rccCfgr.pointee & ~rccCfgrPpre1Mask) | rccCfgrPpre1Div2

    // 7. Switch SYSCLK to the PLL and wait for the switch to take effect.
    rccCfgr.pointee = (rccCfgr.pointee & ~rccCfgrSwMask) | rccCfgrSwPll
    while (rccCfgr.pointee & rccCfgrSwsMask) != rccCfgrSwsPll { smk_cpu_nop() }
}
