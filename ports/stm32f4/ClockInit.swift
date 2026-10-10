// STM32F411CEU6 RCC/PLL clock bring-up: HSE (25MHz, WeAct Black Pill's
// crystal) -> main PLL -> 96MHz SYSCLK, with PLLQ deriving an exact 48MHz
// USB OTG FS clock. See this plan's Task 2 for the PLL math and the
// register offsets' verification (RM0383 + cmsis-device-f4's headers).
//
// This is a busy-wait bring-up routine with no timeout: if HSE or the PLL
// never locks, there is nothing meaningful to do but hang — same fail-stop
// pattern ports/nrf52840/MpslGlue.swift uses for mpsl_init failures.
//
// Polls read swift-mmio registers (volatile), so empty loop bodies are
// correct here.
//
// The RCC block below is the one definition for this target: GPIOInit.swift
// (AHB1ENR) and UsbHid.swift (AHB1ENR/AHB2ENR) use it too.

// Multi-bit fields are declared WITHOUT `as: UInt32.self` and accessed via
// `.raw.<field>`: swift-mmio's projection setter/getter preconditions that
// the field width equals the projected type's width (BitField.swift's
// preconditionMatchingBitWidth), so a 2-bit field projected `as: UInt32`
// compiles cleanly and then traps unconditionally (`udf` straight after the
// load — found by disassembling this file's first conversion). Only 1-bit
// `as: Bool.self` fields are projected.

// RCC base 0x4002_3800. Offsets from cmsis-device-f4's RCC_TypeDef.
@RegisterBlock
struct RCCBlock {
    @RegisterBlock(offset: 0x00) var cr: Register<RCC_CR>
    @RegisterBlock(offset: 0x04) var pllcfgr: Register<RCC_PLLCFGR>
    @RegisterBlock(offset: 0x08) var cfgr: Register<RCC_CFGR>
    @RegisterBlock(offset: 0x30) var ahb1enr: Register<RCC_AHB1ENR>
    @RegisterBlock(offset: 0x34) var ahb2enr: Register<RCC_AHB2ENR>
    @RegisterBlock(offset: 0x40) var apb1enr: Register<RCC_APB1ENR>
}

@Register(bitWidth: 32)
struct RCC_CR {
    @ReadWrite(bits: 16..<17, as: Bool.self) var hseon: HSEON
    @ReadOnly(bits: 17..<18, as: Bool.self) var hserdy: HSERDY
    @ReadWrite(bits: 24..<25, as: Bool.self) var pllon: PLLON
    @ReadOnly(bits: 25..<26, as: Bool.self) var pllrdy: PLLRDY
}

@Register(bitWidth: 32)
struct RCC_PLLCFGR {
    @ReadWrite(bits: 0..<6) var pllm: PLLM
    @ReadWrite(bits: 6..<15) var plln: PLLN
    // PLLP encoding: 00=/2 01=/4 10=/6 11=/8. (No trailing comment on a
    // field line: @Register pastes it into the generated enum name.)
    @ReadWrite(bits: 16..<18) var pllp: PLLP
    @ReadWrite(bits: 22..<23, as: Bool.self) var pllsrcHse: PLLSRC
    @ReadWrite(bits: 24..<28) var pllq: PLLQ
}

@Register(bitWidth: 32)
struct RCC_CFGR {
    @ReadWrite(bits: 0..<2) var sw: SW
    @ReadOnly(bits: 2..<4) var sws: SWS
    @ReadWrite(bits: 10..<13) var ppre1: PPRE1
}

@Register(bitWidth: 32)
struct RCC_AHB1ENR {
    @ReadWrite(bits: 0..<1, as: Bool.self) var gpioaen: GPIOAEN
    @ReadWrite(bits: 1..<2, as: Bool.self) var gpioben: GPIOBEN
}

@Register(bitWidth: 32)
struct RCC_AHB2ENR {
    @ReadWrite(bits: 7..<8, as: Bool.self) var otgfsen: OTGFSEN
}

@Register(bitWidth: 32)
struct RCC_APB1ENR {
    @ReadWrite(bits: 28..<29, as: Bool.self) var pwren: PWREN
}

// PWR base 0x4000_7000: CR +0x00.
@RegisterBlock
struct PWRBlock {
    @RegisterBlock(offset: 0x00) var cr: Register<PWR_CR>
}

@Register(bitWidth: 32)
struct PWR_CR {
    // Reset default is Scale 2 (0b10); Scale 1 (0b11) needed above 84MHz.
    @ReadWrite(bits: 14..<16) var vos: VOS
}

// FLASH interface base 0x4002_3C00: ACR +0x00.
@RegisterBlock
struct FlashBlock {
    @RegisterBlock(offset: 0x00) var acr: Register<FLASH_ACR>
}

@Register(bitWidth: 32)
struct FLASH_ACR {
    @ReadWrite(bits: 0..<4) var latency: LATENCY
    @ReadWrite(bits: 8..<9, as: Bool.self) var prften: PRFTEN
    @ReadWrite(bits: 9..<10, as: Bool.self) var icen: ICEN
    @ReadWrite(bits: 10..<11, as: Bool.self) var dcen: DCEN
}

let rcc = RCCBlock(unsafeAddress: 0x40023800)
private let pwr = PWRBlock(unsafeAddress: 0x40007000)
private let flash = FlashBlock(unsafeAddress: 0x40023C00)

private let pwrCrVosScale1: UInt32 = 0b11

private let flashAcrLatency3Ws: UInt32 = 0b011      // RM0383 Table 10: 90-100MHz @ 2.7-3.6V

private let pllM: UInt32 = 25   // HSE(25MHz)/25 = 1MHz VCO input
private let pllN: UInt32 = 384  // 1MHz*384 = 384MHz VCO output
private let pllPBits: UInt32 = 0b01 // encoding: 00=/2 01=/4 10=/6 11=/8 -> PLLP=4, SYSCLK=384/4=96MHz
private let pllQ: UInt32 = 8    // 384/8 = 48MHz USB clock (must be exact)

private let rccCfgrSwPll: UInt32 = 0b10
private let rccCfgrSwsPll: UInt32 = 0b10
private let rccCfgrPpre1Div2: UInt32 = 0b100 // APB1 max 50MHz: 96/2 = 48MHz

@c
func smk_clock_init() {
    // 1. Start HSE and wait for it to stabilize.
    rcc.cr.modify { _, w in w.hseon = true }
    while !rcc.cr.read().hserdy {}

    // 2. Power interface clock + Voltage Scale 1 (required above 84MHz).
    rcc.apb1enr.modify { $0.pwren = true }
    pwr.cr.modify { $0.raw.vos = pwrCrVosScale1 }

    // 3. Flash wait states for 96MHz, plus prefetch/instruction/data caches.
    //    Whole-word write (other ACR bits zero), as before.
    flash.acr.write {
        $0.raw.latency = flashAcrLatency3Ws
        $0.prften = true
        $0.icen = true
        $0.dcen = true
    }

    // 4. Configure the main PLL from HSE: PLLM/PLLN/PLLP/PLLQ, source = HSE.
    //    Must be written while the PLL is off (true here — POR default).
    //    Whole-word write (other PLLCFGR bits zero), as before.
    rcc.pllcfgr.write {
        $0.raw.pllm = pllM
        $0.raw.plln = pllN
        $0.raw.pllp = pllPBits
        $0.pllsrcHse = true
        $0.raw.pllq = pllQ
    }

    // 5. Enable the PLL and wait for lock.
    rcc.cr.modify { _, w in w.pllon = true }
    while !rcc.cr.read().pllrdy {}

    // 6. APB1 /2 (48MHz, within its 50MHz max); APB2 and AHB stay undivided
    //    (96MHz, within APB2's 100MHz max and AHB's 100MHz max) — both
    //    already 0 (not divided) at reset, so only PPRE1 needs setting.
    rcc.cfgr.modify { _, w in w.raw.ppre1 = rccCfgrPpre1Div2 }

    // 7. Switch SYSCLK to the PLL and wait for the switch to take effect.
    rcc.cfgr.modify { _, w in w.raw.sw = rccCfgrSwPll }
    while rcc.cfgr.read().raw.sws != rccCfgrSwsPll {}
}
