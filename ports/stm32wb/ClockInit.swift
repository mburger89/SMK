// NUCLEO-WB55RG clock bring-up: HSE (32MHz, the Nucleo board's HSE crystal —
// see CMakeLists.txt's -DHSE_VALUE=32000000U) selected directly as SYSCLK,
// no PLL needed (32MHz is already CPU1's native/well-within-limits clock —
// confirmed during this plan's research). Separately, HSI48 + CRS (Clock
// Recovery System) are brought up to provide USB's dedicated 48MHz clock —
// a different mechanism from STM32F4's PLLQ-derived USB clock (see
// ports/stm32f4/ClockInit.swift). CRS is configured to trim HSI48 against
// USB SOF once USB enumerates (Task 5); it's harmless to configure now with
// no active sync source yet — CRS just stays idle until real SOF pulses
// start arriving, matching ST's own default SYNCSRC choice for this use
// case (see below).
//
// All register offsets and bit positions below were confirmed against the
// real vendored header `cmsis-device-wb`'s `Include/stm32wb55xx.h` (RCC_TypeDef,
// FLASH_TypeDef, PWR_TypeDef, CRS_TypeDef and their bit-definition blocks),
// NOT assumed from STM32F4 precedent — WB55's bus mapping and several bit
// layouts genuinely differ (see inline notes). Where the exact numeric
// default (CRS RELOAD/FELIM) wasn't derivable from first principles alone,
// it was cross-checked against ST's own STM32CubeWB HAL headers
// (`stm32wbxx_ll_crs.h`'s LL_CRS_RELOADVALUE_DEFAULT/LL_CRS_ERRORLIMIT_DEFAULT)
// and a real ST example's SystemClock_Config (P-NUCLEO-WB55.USBDongle's
// BLE_p2pClient), both present on disk in this environment (~/btstack's
// vendored copy of the WB55 HAL headers, and ~/STM32CubeWB respectively) —
// not guessed.
//
// This is a busy-wait bring-up routine with no timeout: if HSE never
// stabilizes, there is nothing meaningful to do but hang — same fail-stop
// pattern ports/stm32f4/ClockInit.swift and
// ports/nrf52840/MpslGlue.swift use.
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

// RCC: base AHB4PERIPH_BASE (0x58000000) + 0 — differs from STM32F4, where
// RCC lives on AHB1PERIPH_BASE. Confirmed via stm32wb55xx.h's `#define
// RCC_BASE (AHB4PERIPH_BASE + 0x00000000UL)`.
private let rccBase: UInt32 = 0x5800_0000
private let rccCr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x00))!
private let rccCfgr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x08))!
private let rccApb1Enr1 = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x58))!
private let rccCrrcr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x98))!

// PWR: base AHB4PERIPH_BASE + 0x400. Needed to select Voltage Scale Range 1
// before running SYSCLK at 32MHz — WB55 resets into Range 2 (max 16MHz),
// confirmed necessary (not just F4-precedent copy-paste) by ST's own
// SystemClock_Config for this exact board/HSE-32MHz configuration, which
// calls __HAL_PWR_VOLTAGESCALING_CONFIG(PWR_REGULATOR_VOLTAGE_SCALE1) before
// touching RCC at all.
private let pwrBase: UInt32 = 0x5800_0400
private let pwrCr1 = UnsafeMutablePointer<UInt32>(bitPattern: UInt(pwrBase + 0x00))!
private let pwrSr2 = UnsafeMutablePointer<UInt32>(bitPattern: UInt(pwrBase + 0x14))!

// FLASH: base AHB4PERIPH_BASE + 0x4000. 1 wait state is required at 32MHz
// in Voltage Range 1 (RM0434's flash latency table) — again confirmed via
// ST's own SystemClock_Config for this board, which passes
// FLASH_LATENCY_1 to HAL_RCC_ClockConfig for this identical HSE-32MHz case.
private let flashBase: UInt32 = 0x5800_4000
private let flashAcr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(flashBase + 0x00))!

// CRS: a standalone peripheral on WB (unlike RCC-embedded USB trim on some
// STM32 families), base APB1PERIPH_BASE (0x40000000) + 0x6000. Confirmed
// via stm32wb55xx.h's `#define CRS_BASE (APB1PERIPH_BASE + 0x00006000UL)`.
private let crsBase: UInt32 = 0x4000_6000
private let crsCr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(crsBase + 0x00))!
private let crsCfgr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(crsBase + 0x04))!

// --- RCC_CR ------------------------------------------------------------
// HSEON/HSERDY happen to sit at the same bit positions as STM32F4 (16/17),
// but this was independently confirmed against stm32wb55xx.h's RCC_CR bit
// block, not assumed — WB55's CR register has additional CPU2-related
// fields (e.g. HSIASFS, CSSHSEON) interleaved elsewhere in the same
// register that F4 doesn't have.
private let rccCrHseOn: UInt32 = 1 << 16
private let rccCrHseRdy: UInt32 = 1 << 17

// --- RCC_APB1ENR1 --------------------------------------------------------
// Confirmed via RCC_APB1ENR1_CRSEN_Pos in stm32wb55xx.h. (There is no
// RCC_APB1ENR1_PWREN on WB55 — unlike F4, PWR's peripheral clock is not
// gated here, confirmed by its absence from the real header; no PWR
// clock-enable step is needed before touching PWR_CR1 below.)
private let rccApb1Enr1CrsEn: UInt32 = 1 << 24

// --- RCC_CFGR ------------------------------------------------------------
// SW/SWS encoding confirmed via ST's own stm32wbxx_ll_rcc.h (not assumed
// from F4, whose SW field encodes PLL selection differently): 00=MSI,
// 01=HSI16, 10=HSE, 11=PLL — LL_RCC_SYS_CLKSOURCE_HSE == RCC_CFGR_SW_1,
// i.e. bit pattern 0b10, at bit-position 0 (SW) / bit-position 2 (SWS).
private let rccCfgrSwMask: UInt32 = 0b11
private let rccCfgrSwHse: UInt32 = 0b10
private let rccCfgrSwsMask: UInt32 = 0b11 << 2
private let rccCfgrSwsHse: UInt32 = 0b10 << 2

// --- RCC_CRRCR (HSI48) ---------------------------------------------------
// Confirmed via RCC_CRRCR_HSI48ON_Pos (0) / RCC_CRRCR_HSI48RDY_Pos (1) in
// stm32wb55xx.h.
private let rccCrrcrHsi48On: UInt32 = 1 << 0
private let rccCrrcrHsi48Rdy: UInt32 = 1 << 1

// --- PWR_CR1 / PWR_SR2 (Voltage Scale Range 1) ----------------------------
// VOS field confirmed via PWR_CR1_VOS_Pos (9) in stm32wb55xx.h; the Range-1
// encoding (0b01) confirmed via ST's stm32wbxx_hal_pwr_ex.h
// (PWR_REGULATOR_VOLTAGE_SCALE1 == PWR_CR1_VOS_0, "system frequency up to
// 64MHz"). VOSF (bit 10 of SR2) confirmed via PWR_SR2_VOSF_Pos — polled
// until clear, meaning the voltage scaling change has taken effect.
private let pwrCr1VosMask: UInt32 = 0b11 << 9
private let pwrCr1VosRange1: UInt32 = 0b01 << 9
private let pwrSr2Vosf: UInt32 = 1 << 10

// --- FLASH_ACR -------------------------------------------------------------
// Bit positions confirmed via stm32wb55xx.h's FLASH_ACR bit block — happen
// to match STM32F4's layout (LATENCY[2:0] at bit 0, PRFTEN/ICEN/DCEN at
// bits 8/9/10) but independently confirmed here, not copy-pasted.
private let flashAcrLatency1Ws: UInt32 = 0b001 // RM0434: 1 WS required >18MHz in Range 1
private let flashAcrPrften: UInt32 = 1 << 8
private let flashAcrIcen: UInt32 = 1 << 9
private let flashAcrDcen: UInt32 = 1 << 10

// --- CRS_CR ----------------------------------------------------------------
// Confirmed via CRS_CR_CEN_Pos (5) / CRS_CR_AUTOTRIMEN_Pos (6) in
// stm32wb55xx.h.
private let crsCrCen: UInt32 = 1 << 5
private let crsCrAutotrimen: UInt32 = 1 << 6

// --- CRS_CFGR ----------------------------------------------------------------
// RELOAD/FELIM defaults confirmed via ST's stm32wbxx_ll_crs.h
// (LL_CRS_RELOADVALUE_DEFAULT = 0xBB7F, i.e. (48_000_000/1_000) - 1 for a
// 1kHz USB full-speed SOF reference; LL_CRS_ERRORLIMIT_DEFAULT = 0x22).
// SYNCSRC confirmed via CRS_CFGR_SYNCSRC_1 in stm32wb55xx.h combined with
// stm32wbxx_ll_crs.h's LL_CRS_SYNC_SOURCE_USB == CRS_CFGR_SYNCSRC_1 (the
// USB-SOF choice ST's own HAL treats as the default sync source for this
// exact HSI48-for-USB use case). SYNCDIV (/1) and SYNCPOL (rising) both
// encode as 0, i.e. reset default, so no explicit bits are needed for
// those two fields.
private let crsCfgrReloadDefault: UInt32 = 0xBB7F
private let crsCfgrFelimDefault: UInt32 = 0x22 << 16
private let crsCfgrSyncSrcUsb: UInt32 = 0b10 << 28

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

    // 2. Select Voltage Scale Range 1 (required for SYSCLK > 16MHz) and
    //    wait for the regulator to settle.
    pwrCr1.pointee = (pwrCr1.pointee & ~pwrCr1VosMask) | pwrCr1VosRange1
    while (pwrSr2.pointee & pwrSr2Vosf) != 0 { smk_cpu_nop() }

    // 3. Flash wait states for 32MHz in Range 1, plus prefetch/instruction/
    //    data caches.
    flashAcr.pointee = flashAcrLatency1Ws | flashAcrPrften | flashAcrIcen | flashAcrDcen

    // 4. Switch SYSCLK to HSE and wait for the switch to take effect.
    rccCfgr.pointee = (rccCfgr.pointee & ~rccCfgrSwMask) | rccCfgrSwHse
    while (rccCfgr.pointee & rccCfgrSwsMask) != rccCfgrSwsHse { smk_cpu_nop() }

    // 5. Start HSI48 (USB's dedicated 48MHz clock) and wait for it to
    //    stabilize.
    rccCrrcr.pointee |= rccCrrcrHsi48On
    while (rccCrrcr.pointee & rccCrrcrHsi48Rdy) == 0 { smk_cpu_nop() }

    // 6. Enable CRS's peripheral clock, configure it to trim HSI48 against
    //    USB SOF (RELOAD/FELIM/SYNCSRC), then enable counting + auto-trim.
    //    No SOF pulses exist yet at this point in boot (USB isn't brought
    //    up until Task 5) — CRS simply stays idle with HSI48 running at its
    //    factory-trimmed accuracy until the device enumerates and real SOF
    //    sync events start arriving, exactly as intended.
    rccApb1Enr1.pointee |= rccApb1Enr1CrsEn
    crsCfgr.pointee = crsCfgrReloadDefault | crsCfgrFelimDefault | crsCfgrSyncSrcUsb
    crsCr.pointee |= crsCrCen | crsCrAutotrimen
}
