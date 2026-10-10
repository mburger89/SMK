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
// Polls read swift-mmio registers (volatile), so empty loop bodies are correct here.
//
// The RCC and PWR register blocks below are shared with HwIpcc.swift,
// GPIOInit.swift and UsbHid.swift (this target compiles flat into one
// module, so each block is declared exactly once, here). Every bit field
// is declared @ReadWrite even where the hardware bit is read-only (HSERDY,
// SWS, ...): a `modify { }` then writes back exactly the value it read for
// those bits, which is what the previous `reg.pointee |= bit` code did, and
// keeps each register's Read and Write views symmetric. Multi-bit fields
// carry no `as:` projection (swift-mmio only allows a projection type whose
// bit width matches the field's) and are accessed through `.raw.<field>`.

// RCC: base AHB4PERIPH_BASE (0x58000000) + 0 — differs from STM32F4, where
// RCC lives on AHB1PERIPH_BASE. Confirmed via stm32wb55xx.h's `#define
// RCC_BASE (AHB4PERIPH_BASE + 0x00000000UL)`. Offsets from RCC_TypeDef:
// CR 0x00, CFGR 0x08, AHB2ENR 0x4C, AHB3ENR 0x50, APB1ENR1 0x58, BDCR 0x90,
// CSR 0x94, CRRCR 0x98, HSECR 0x9C, C2AHB3ENR 0x150.
@RegisterBlock
struct WBRCC {
    @RegisterBlock(offset: 0x00) var cr: Register<RCC_CR>
    @RegisterBlock(offset: 0x08) var cfgr: Register<RCC_CFGR>
    @RegisterBlock(offset: 0x4C) var ahb2enr: Register<RCC_AHB2ENR>
    @RegisterBlock(offset: 0x50) var ahb3enr: Register<RCC_AHB3ENR>
    @RegisterBlock(offset: 0x58) var apb1enr1: Register<RCC_APB1ENR1>
    @RegisterBlock(offset: 0x90) var bdcr: Register<RCC_BDCR>
    @RegisterBlock(offset: 0x94) var csr: Register<RCC_CSR>
    @RegisterBlock(offset: 0x98) var crrcr: Register<RCC_CRRCR>
    @RegisterBlock(offset: 0x9C) var hsecr: Register<RCC_HSECR>
    @RegisterBlock(offset: 0x150) var c2ahb3enr: Register<RCC_AHB3ENR>
}
let rcc = WBRCC(unsafeAddress: 0x5800_0000)

// PWR: base AHB4PERIPH_BASE + 0x400. Needed to select Voltage Scale Range 1
// before running SYSCLK at 32MHz — WB55 resets into Range 2 (max 16MHz),
// confirmed necessary (not just F4-precedent copy-paste) by ST's own
// SystemClock_Config for this exact board/HSE-32MHz configuration, which
// calls __HAL_PWR_VOLTAGESCALING_CONFIG(PWR_REGULATOR_VOLTAGE_SCALE1) before
// touching RCC at all. Offsets from PWR_TypeDef: CR1 0x00, CR2 0x04,
// CR4 0x0C, SR2 0x14.
@RegisterBlock
struct WBPWR {
    @RegisterBlock(offset: 0x00) var cr1: Register<PWR_CR1>
    @RegisterBlock(offset: 0x04) var cr2: Register<PWR_CR2>
    @RegisterBlock(offset: 0x0C) var cr4: Register<PWR_CR4>
    @RegisterBlock(offset: 0x14) var sr2: Register<PWR_SR2>
}
let pwr = WBPWR(unsafeAddress: 0x5800_0400)

// FLASH: base AHB4PERIPH_BASE + 0x4000. 1 wait state is required at 32MHz
// in Voltage Range 1 (RM0434's flash latency table) — again confirmed via
// ST's own SystemClock_Config for this board, which passes
// FLASH_LATENCY_1 to HAL_RCC_ClockConfig for this identical HSE-32MHz case.
@RegisterBlock
struct WBFlash {
    @RegisterBlock(offset: 0x00) var acr: Register<FLASH_ACR>
}
private let flash = WBFlash(unsafeAddress: 0x5800_4000)

// CRS: a standalone peripheral on WB (unlike RCC-embedded USB trim on some
// STM32 families), base APB1PERIPH_BASE (0x40000000) + 0x6000. Confirmed
// via stm32wb55xx.h's `#define CRS_BASE (APB1PERIPH_BASE + 0x00006000UL)`.
@RegisterBlock
struct WBCRS {
    @RegisterBlock(offset: 0x00) var cr: Register<CRS_CR>
    @RegisterBlock(offset: 0x04) var cfgr: Register<CRS_CFGR>
}
private let crs = WBCRS(unsafeAddress: 0x4000_6000)

// --- RCC_HSECR (HSE capacitor tuning) -------------------------------------
// Offset 0x9C confirmed via stm32wb55xx.h's RCC_TypeDef layout comment
// ("RCC HSE Clock Register, Address offset: 0x9C"). HSETUNE is a 6-bit
// field at bits [13:8] (RCC_HSECR_HSETUNE_Msk = 0x3F00), confirmed via the
// same header's RCC_HSECR bit-definition block. The unlock key and the
// unlock-then-modify write sequence match ST's own
// LL_RCC_HSE_SetCapacitorTuning (stm32wbxx_ll_rcc.h): writing this key
// value un-write-protects HSECR for the following write; the register does
// not retain the key itself.
@Register(bitWidth: 32)
struct RCC_HSECR {
    @ReadWrite(bits: 8..<14) var hsetune: HSETUNE
}
private let rccHsecrUnlockKey: UInt32 = 0xCAFE_CAFE
private let rccHsecrHseTuneFieldMask: UInt32 = 0x3F

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
//
// Each OTP byte is read through an 8-bit swift-mmio register — the same
// byte-wide access width the previous `UnsafePointer<UInt8>` reads used.
private let otpAreaBase: UInt32 = 0x1FFF_7000
private let otpAreaEnd: UInt32 = 0x1FFF_73FF
private let otpRecordSize: UInt32 = 8
private let otpId0: UInt8 = 0

@Register(bitWidth: 8)
struct OTPByte {
    @ReadWrite(bits: 0..<8, as: UInt8.self) var value: VALUE
}

private func otpByte(_ address: UInt32) -> UInt8 {
    Register<OTPByte>(unsafeAddress: UInt(address)).read().value
}

private func readFactoryHseTuning() -> UInt8? {
    var recordAddr = otpAreaEnd - (otpRecordSize - 1)
    while recordAddr >= otpAreaBase {
        if otpByte(recordAddr + 7) == otpId0 {
            return otpByte(recordAddr + 6)
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
@Register(bitWidth: 32)
struct RCC_CR {
    @ReadWrite(bits: 16..<17, as: Bool.self) var hseon: HSEON
    @ReadWrite(bits: 17..<18, as: Bool.self) var hserdy: HSERDY
}

// --- RCC_AHB2ENR / RCC_AHB3ENR / RCC_C2AHB3ENR (clock gates) ---------------
// AHB2ENR (0x4C): GPIOAEN bit 0, GPIOBEN bit 1 (RCC_AHB2ENR_GPIOAEN_Pos /
// RCC_AHB2ENR_GPIOBEN_Pos) — used by UsbHid.swift and GPIOInit.swift.
// AHB3ENR (0x50) and C2AHB3ENR (0x150) both carry IPCCEN at bit 20
// (RCC_AHB3ENR_IPCCEN_Pos / RCC_C2AHB3ENR_IPCCEN_Pos) — used by HwIpcc.swift.
@Register(bitWidth: 32)
struct RCC_AHB2ENR {
    @ReadWrite(bits: 0..<1, as: Bool.self) var gpioaen: GPIOAEN
    @ReadWrite(bits: 1..<2, as: Bool.self) var gpioben: GPIOBEN
}

@Register(bitWidth: 32)
struct RCC_AHB3ENR {
    @ReadWrite(bits: 20..<21, as: Bool.self) var ipccen: IPCCEN
}

// --- RCC_APB1ENR1 --------------------------------------------------------
// CRSEN confirmed via RCC_APB1ENR1_CRSEN_Pos (24) in stm32wb55xx.h;
// RTCAPBEN (10) and USBEN (26, used by UsbHid.swift) likewise. (There is no
// RCC_APB1ENR1_PWREN on WB55 — unlike F4, PWR's peripheral clock is not
// gated here, confirmed by its absence from the real header; no PWR
// clock-enable step is needed before touching PWR_CR1 below.)
@Register(bitWidth: 32)
struct RCC_APB1ENR1 {
    @ReadWrite(bits: 10..<11, as: Bool.self) var rtcapben: RTCAPBEN
    @ReadWrite(bits: 24..<25, as: Bool.self) var crsen: CRSEN
    @ReadWrite(bits: 26..<27, as: Bool.self) var usben: USBEN
}

// --- RCC_CFGR ------------------------------------------------------------
// SW/SWS encoding confirmed via ST's own stm32wbxx_ll_rcc.h (not assumed
// from F4, whose SW field encodes PLL selection differently): 00=MSI,
// 01=HSI16, 10=HSE, 11=PLL — LL_RCC_SYS_CLKSOURCE_HSE == RCC_CFGR_SW_1,
// i.e. bit pattern 0b10, at bit-position 0 (SW) / bit-position 2 (SWS).
@Register(bitWidth: 32)
struct RCC_CFGR {
    @ReadWrite(bits: 0..<2) var sw: SW
    @ReadWrite(bits: 2..<4) var sws: SWS
}
private let rccCfgrSwHse: UInt32 = 0b10

// --- RCC_CRRCR (HSI48) ---------------------------------------------------
// Confirmed via RCC_CRRCR_HSI48ON_Pos (0) / RCC_CRRCR_HSI48RDY_Pos (1) in
// stm32wb55xx.h.
@Register(bitWidth: 32)
struct RCC_CRRCR {
    @ReadWrite(bits: 0..<1, as: Bool.self) var hsi48on: HSI48ON
    @ReadWrite(bits: 1..<2, as: Bool.self) var hsi48rdy: HSI48RDY
}

// --- PWR_CR1 / PWR_SR2 (Voltage Scale Range 1) ----------------------------
// VOS field confirmed via PWR_CR1_VOS_Pos (9) in stm32wb55xx.h; the Range-1
// encoding (0b01) confirmed via ST's stm32wbxx_hal_pwr_ex.h
// (PWR_REGULATOR_VOLTAGE_SCALE1 == PWR_CR1_VOS_0, "system frequency up to
// 64MHz"). VOSF (bit 10 of SR2) confirmed via PWR_SR2_VOSF_Pos — polled
// until clear, meaning the voltage scaling change has taken effect.
// DBP (PWR_CR1_DBP_Pos, 8) unlocks the backup domain, see below.
@Register(bitWidth: 32)
struct PWR_CR1 {
    @ReadWrite(bits: 8..<9, as: Bool.self) var dbp: DBP
    @ReadWrite(bits: 9..<11) var vos: VOS
}
private let pwrCr1VosRange1: UInt32 = 0b01

@Register(bitWidth: 32)
struct PWR_SR2 {
    @ReadWrite(bits: 10..<11, as: Bool.self) var vosf: VOSF
}

// PWR_CR2 USV (bit 10) — VDDUSB supply valid, used by UsbHid.swift (see the
// comment there). PWR_CR4 C2BOOT (bit 15) — releases CPU2 from reset, used
// by HwIpcc.swift.
@Register(bitWidth: 32)
struct PWR_CR2 {
    @ReadWrite(bits: 10..<11, as: Bool.self) var usv: USV
}

@Register(bitWidth: 32)
struct PWR_CR4 {
    @ReadWrite(bits: 15..<16, as: Bool.self) var c2boot: C2BOOT
}

// --- FLASH_ACR -------------------------------------------------------------
// Bit positions confirmed via stm32wb55xx.h's FLASH_ACR bit block — happen
// to match STM32F4's layout (LATENCY[2:0] at bit 0, PRFTEN/ICEN/DCEN at
// bits 8/9/10) but independently confirmed here, not copy-pasted.
@Register(bitWidth: 32)
struct FLASH_ACR {
    @ReadWrite(bits: 0..<3) var latency: LATENCY
    @ReadWrite(bits: 8..<9, as: Bool.self) var prften: PRFTEN
    @ReadWrite(bits: 9..<10, as: Bool.self) var icen: ICEN
    @ReadWrite(bits: 10..<11, as: Bool.self) var dcen: DCEN
}
private let flashAcrLatency1Ws: UInt32 = 0b001 // RM0434: 1 WS required >18MHz in Range 1

// --- RCC_BDCR / RCC_CSR (LSE + RF wakeup clock, used by BLE bring-up) ------
// BDCR at 0x90 / CSR at 0x94, confirmed via stm32wb55xx.h's RCC_TypeDef.
// Bit positions confirmed via the same header's bit-definition blocks:
// RCC_BDCR_LSEON_Pos (0), RCC_BDCR_LSERDY_Pos (1), RCC_BDCR_LSEDRV_Pos (3,
// 2-bit field), RCC_CSR_RFWKPSEL_Pos (14, 2-bit field; RCC_CSR_RFWKPSEL_0 ==
// 0x4000 == "LSE selected"), RCC_APB1ENR1_RTCAPBEN_Pos (10), PWR_CR1_DBP_Pos
// (8).
@Register(bitWidth: 32)
struct RCC_BDCR {
    @ReadWrite(bits: 0..<1, as: Bool.self) var lseon: LSEON
    @ReadWrite(bits: 1..<2, as: Bool.self) var lserdy: LSERDY
    @ReadWrite(bits: 3..<5) var lsedrv: LSEDRV
}

@Register(bitWidth: 32)
struct RCC_CSR {
    @ReadWrite(bits: 14..<16) var rfwkpsel: RFWKPSEL
}
private let rccCsrRfwkpselLse: UInt32 = 0b01

// --- CRS_CR ----------------------------------------------------------------
// Confirmed via CRS_CR_CEN_Pos (5) / CRS_CR_AUTOTRIMEN_Pos (6) in
// stm32wb55xx.h.
@Register(bitWidth: 32)
struct CRS_CR {
    @ReadWrite(bits: 5..<6, as: Bool.self) var cen: CEN
    @ReadWrite(bits: 6..<7, as: Bool.self) var autotrimen: AUTOTRIMEN
}

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
@Register(bitWidth: 32)
struct CRS_CFGR {
    @ReadWrite(bits: 0..<16) var reload: RELOAD
    @ReadWrite(bits: 16..<24) var felim: FELIM
    @ReadWrite(bits: 28..<30) var syncsrc: SYNCSRC
}
private let crsCfgrReloadDefault: UInt32 = 0xBB7F
private let crsCfgrFelimDefault: UInt32 = 0x22
private let crsCfgrSyncSrcUsb: UInt32 = 0b10

@c
func smk_clock_init() {
    // 1. Start HSE and wait for it to stabilize.
    rcc.cr.modify { $0.hseon = true }
    while !rcc.cr.read().hserdy {}

    // 1b. Apply the factory-programmed HSE capacitor trim, if OTP has one.
    //     Matches ST's own Config_HSE()/LL_RCC_HSE_SetCapacitorTuning
    //     sequence: unlock, then read-modify-write just the HSETUNE field.
    //     Silently left at HSECR's power-on-reset trim value if OTP wasn't
    //     programmed (e.g. some dev boards) — same fallback ST's own code
    //     has, since OTP_Read returning null there just skips the call.
    if let hseTuning = readFactoryHseTuning() {
        // HSETUNE is a 6-bit field; mask defensively so an out-of-range OTP
        // byte can't bleed into HSECR's adjacent HSEGMC bits (swift-mmio
        // would trap on an over-wide field value rather than truncate it).
        let tune = UInt32(hseTuning) & rccHsecrHseTuneFieldMask
        rcc.hsecr.write { $0.raw.storage = rccHsecrUnlockKey }
        rcc.hsecr.modify { $0.raw.hsetune = tune }
    }

    // 2. Select Voltage Scale Range 1 (required for SYSCLK > 16MHz) and
    //    wait for the regulator to settle.
    pwr.cr1.modify { $0.raw.vos = pwrCr1VosRange1 }
    while pwr.sr2.read().vosf {}

    // 3. Flash wait states for 32MHz in Range 1, plus prefetch/instruction/
    //    data caches.
    flash.acr.write {
        $0.raw.latency = flashAcrLatency1Ws
        $0.prften = true
        $0.icen = true
        $0.dcen = true
    }

    // 4. Switch SYSCLK to HSE and wait for the switch to take effect.
    rcc.cfgr.modify { $0.raw.sw = rccCfgrSwHse }
    while rcc.cfgr.read().raw.sws != rccCfgrSwHse {}

    // 5. Start HSI48 (USB's dedicated 48MHz clock) and wait for it to
    //    stabilize.
    rcc.crrcr.modify { $0.hsi48on = true }
    while !rcc.crrcr.read().hsi48rdy {}

    // 6. Enable CRS's peripheral clock, configure it to trim HSI48 against
    //    USB SOF (RELOAD/FELIM/SYNCSRC), then enable counting + auto-trim.
    //    No SOF pulses exist yet at this point in boot (USB isn't brought
    //    up until Task 5) — CRS simply stays idle with HSI48 running at its
    //    factory-trimmed accuracy until the device enumerates and real SOF
    //    sync events start arriving, exactly as intended.
    rcc.apb1enr1.modify { $0.crsen = true }
    crs.cfgr.write {
        $0.raw.reload = crsCfgrReloadDefault
        $0.raw.felim = crsCfgrFelimDefault
        $0.raw.syncsrc = crsCfgrSyncSrcUsb
    }
    crs.cr.modify {
        $0.cen = true
        $0.autotrimen = true
    }
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
@c
func smk_enable_lse_and_rf_wakeup_clock() {
    // RTCAPB clock gates access to the backup-domain registers (BDCR). The
    // C original followed the |= with `(void)RCC->APB1ENR1;` — a volatile
    // read-back ensuring the clock-enable has propagated before the
    // backup-domain accesses below. swift-mmio reads are volatile, so this
    // read-back (and every read below) is really issued, in program order
    // — the store-forwarding/hoisting a plain `.pointee` read suffered in
    // this function's first build cannot happen.
    rcc.apb1enr1.modify { $0.rtcapben = true }
    _ = rcc.apb1enr1.read()

    // Backup-domain writes are protected out of reset.
    pwr.cr1.modify { $0.dbp = true }
    while !pwr.cr1.read().dbp {}

    if !rcc.bdcr.read().lserdy {
        // RCC_LSEDRIVE_LOW, ST's choice for this board.
        rcc.bdcr.modify { $0.raw.lsedrv = 0 }
        rcc.bdcr.modify { $0.lseon = true }
        while !rcc.bdcr.read().lserdy {}
    }

    // RFWKPSEL[1:0] = 01 -> LSE feeds the RF wakeup logic.
    rcc.csr.modify { $0.raw.rfwkpsel = rccCsrRfwkpselLse }
}
