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

// --- RCC_HSECR (HSE capacitor tuning) -------------------------------------
// Offset 0x9C confirmed via stm32wb55xx.h's RCC_TypeDef layout comment
// ("RCC HSE Clock Register, Address offset: 0x9C"). HSETUNE is a 6-bit
// field at bits [13:8] (RCC_HSECR_HSETUNE_Msk = 0x3F00), confirmed via the
// same header's RCC_HSECR bit-definition block. The unlock key and the
// unlock-then-modify write sequence match ST's own
// LL_RCC_HSE_SetCapacitorTuning (stm32wbxx_ll_rcc.h): writing this key
// value un-write-protects HSECR for the following write; the register does
// not retain the key itself.
private let rccHsecr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x9C))!
private let rccHsecrUnlockKey: UInt32 = 0xCAFE_CAFE
private let rccHsecrHseTuneMask: UInt32 = 0x3F << 8
private let rccHsecrHseTunePos: UInt32 = 8

// --- Factory HSE trim (OTP) ------------------------------------------------
// The WB55's 1KB OTP area (0x1FFF7000-0x1FFF73FF, confirmed via
// stm32wb55xx.h's OTP_AREA_BASE/OTP_AREA_END_ADDR) is plain memory-mapped
// flash, readable without any driver. ST's OTP manager (Middlewares/ST/
// STM32_WPAN/utilities/otp.c — not vendored into this project, since it's
// SLA0044-licensed like the IPCC transport files; see CLAUDE.md's STM32WB
// license note) packs 8-byte records back-to-front from the top of the
// area: 6 bytes of payload, then a 1-byte "hse_tuning" field, then a
// 1-byte id at the very end of each record. Record id 0 (OTP_ID0, ST's
// factory-programmed board-identity record) is what carries the per-die
// HSE trim value; this walks the same 8-byte-record layout independently
// re-derived from the public register/memory-map facts above, not copied
// from ST's implementation.
private let otpAreaBase: UInt32 = 0x1FFF_7000
private let otpAreaEnd: UInt32 = 0x1FFF_73FF
private let otpRecordSize: UInt32 = 8
private let otpId0: UInt8 = 0

private func readFactoryHseTuning() -> UInt8? {
    var recordAddr = otpAreaEnd - (otpRecordSize - 1)
    while recordAddr >= otpAreaBase {
        let record = UnsafePointer<UInt8>(bitPattern: UInt(recordAddr))!
        if record[7] == otpId0 {
            return record[6]
        }
        if recordAddr < otpAreaBase + otpRecordSize { break }
        recordAddr -= otpRecordSize
    }
    return nil
}

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

// --- RCC_BDCR / RCC_CSR (LSE + RF wakeup clock, used by BLE bring-up) ------
// BDCR at 0x90 / CSR at 0x94, confirmed via stm32wb55xx.h's RCC_TypeDef.
// Bit positions confirmed via the same header's bit-definition blocks:
// RCC_BDCR_LSEON_Pos (0), RCC_BDCR_LSERDY_Pos (1), RCC_BDCR_LSEDRV_Pos (3,
// 2-bit field), RCC_CSR_RFWKPSEL_Pos (14, 2-bit field; RCC_CSR_RFWKPSEL_0 ==
// 0x4000 == "LSE selected"), RCC_APB1ENR1_RTCAPBEN_Pos (10), PWR_CR1_DBP_Pos
// (8).
private let rccBdcr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x90))!
private let rccCsr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x94))!
private let rccApb1Enr1RtcApbEn: UInt32 = 1 << 10
private let pwrCr1Dbp: UInt32 = 1 << 8
private let rccBdcrLseOn: UInt32 = 1 << 0
private let rccBdcrLseRdy: UInt32 = 1 << 1
private let rccBdcrLseDrvMask: UInt32 = 0b11 << 3
private let rccCsrRfwkpselMask: UInt32 = 0b11 << 14
private let rccCsrRfwkpselLse: UInt32 = 0b01 << 14

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

// Guaranteed-issued, guaranteed-ordered MMIO read (also in
// platform/cortex_m_intrinsics.c). smk_cpu_nop() keeps a loop alive, but a
// `.pointee` load can still be folded away entirely (store-to-load
// forwarding of a bit this code just set) or hoisted above unrelated MMIO
// writes — both observed in smk_enable_lse_and_rf_wakeup_clock()'s first
// build. Use this for any read whose *existence or position* matters:
// post-clock-enable read-backs, and reads ordered against other registers'
// writes. Hardware-status polls that only re-read one register (HSERDY etc.)
// are safe with the smk_cpu_nop() pattern above.
@_extern(c, "smk_mmio_read32")
func smk_mmio_read32(_ addr: UInt32) -> UInt32

@_cdecl("smk_clock_init")
func smk_clock_init() {
    // 1. Start HSE and wait for it to stabilize.
    rccCr.pointee |= rccCrHseOn
    while (rccCr.pointee & rccCrHseRdy) == 0 { smk_cpu_nop() }

    // 1b. Apply the factory-programmed HSE capacitor trim, if OTP has one.
    //     Matches ST's own Config_HSE()/LL_RCC_HSE_SetCapacitorTuning
    //     sequence: unlock, then read-modify-write just the HSETUNE field.
    //     Silently left at HSECR's power-on-reset trim value if OTP wasn't
    //     programmed (e.g. some dev boards) — same fallback ST's own code
    //     has, since OTP_Read returning null there just skips the call.
    if let hseTuning = readFactoryHseTuning() {
        // HSETUNE is a 6-bit field; mask defensively so an out-of-range OTP
        // byte can't bleed into HSECR's adjacent HSEGMC bits.
        let tuneBits = (UInt32(hseTuning) << rccHsecrHseTunePos) & rccHsecrHseTuneMask
        rccHsecr.pointee = rccHsecrUnlockKey
        rccHsecr.pointee = (rccHsecr.pointee & ~rccHsecrHseTuneMask) | tuneBits
    }

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

// The radio's low-speed/wakeup clock, needed only by the BLE path — called
// from platform/ble_hid_wb.c's init_ble_hid() before anything can release
// CPU2, not from smk_clock_init() (nothing before BLE needs the backup
// domain). Ported from that file's former C implementation; mirrors ST's own
// SystemClock_Config for this board (BLE_HeartRate/Core/Src/main.c:
// __HAL_RCC_LSEDRIVE_CONFIG(RCC_LSEDRIVE_LOW), RCC_OSCILLATORTYPE_LSE,
// RFWakeUpClockSelection = RCC_RFWKPCLKSOURCE_LSE).
//
// NUCLEO-WB55RG (MB1355) is fitted with a 32.768kHz LSE crystal (X3), so
// this is expected to succeed on real hardware; like smk_clock_init() above
// this is a fail-stop busy-wait with no timeout.
@_cdecl("smk_enable_lse_and_rf_wakeup_clock")
func smk_enable_lse_and_rf_wakeup_clock() {
    // RTCAPB clock gates access to the backup-domain registers (BDCR). The
    // C original followed the |= with `(void)RCC->APB1ENR1;` — a volatile
    // read-back ensuring the clock-enable has propagated before the
    // backup-domain accesses below. Every read in this function goes through
    // the opaque smk_mmio_read32() because the first build of this function
    // proved plain `.pointee` reads here get folded away or hoisted (see
    // that declaration's comment).
    rccApb1Enr1.pointee |= rccApb1Enr1RtcApbEn
    _ = smk_mmio_read32(rccBase + 0x58)

    // Backup-domain writes are protected out of reset.
    pwrCr1.pointee |= pwrCr1Dbp
    while (smk_mmio_read32(pwrBase + 0x00) & pwrCr1Dbp) == 0 { }

    if (smk_mmio_read32(rccBase + 0x90) & rccBdcrLseRdy) == 0 {
        // RCC_LSEDRIVE_LOW, ST's choice for this board.
        rccBdcr.pointee = smk_mmio_read32(rccBase + 0x90) & ~rccBdcrLseDrvMask
        rccBdcr.pointee = smk_mmio_read32(rccBase + 0x90) | rccBdcrLseOn
        while (smk_mmio_read32(rccBase + 0x90) & rccBdcrLseRdy) == 0 { }
    }

    // RFWKPSEL[1:0] = 01 -> LSE feeds the RF wakeup logic.
    rccCsr.pointee = (smk_mmio_read32(rccBase + 0x94) & ~rccCsrRfwkpselMask) | rccCsrRfwkpselLse
}
