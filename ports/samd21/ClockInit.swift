// SAMD21 clock bring-up for the Seeed XIAO M0: DFLL48M in crystalless
// USB-clock-recovery mode, selected as GCLK0 (the CPU clock). The XIAO M0
// has no external crystal, so this is the same configuration its stock UF2
// bootloader (Seeed's uf2-samdx1 build, CRYSTALLESS) uses: before USB
// enumerates the DFLL free-runs off the factory coarse calibration
// (accurate to a few percent — fine for the CPU); once the host connects,
// USB start-of-frame pulses discipline it to 48MHz ±0.25%, which is also
// what makes crystalless USB legal on this part.
//
// Register offsets and bit positions verified against the vendored
// Microchip DFP (hw/mcu/microchip/samd21/include/, fetched via TinyUSB's
// tools/get_deps.py) — component/sysctrl.h, gclk.h, nvmctrl.h and
// samd21g18a.h — not assumed:
//   NVMCTRL 0x4100_4000: CTRLB 0x04 (RWS field at bits [4:1])
//   SYSCTRL 0x4000_0800: PCLKSR 0x0C (DFLLRDY bit 4),
//     DFLLCTRL 0x24 (16-bit: ENABLE 1, MODE 2, USBCRM 5, ONDEMAND 7,
//     CCDIS 8), DFLLVAL 0x28 (FINE [9:0], COARSE [15:10]),
//     DFLLMUL 0x2C (MUL [15:0], FSTEP [25:16], CSTEP [31:26])
//   GCLK 0x4000_0C00: STATUS 0x01 (8-bit, SYNCBUSY bit 7),
//     CLKCTRL 0x02 (16-bit), GENCTRL 0x04, GENDIV 0x08
//   Factory DFLL48M coarse calibration: OTP4 fuse word at 0x0080_6024,
//     bits [31:26] (FUSES_DFLL48M_COARSE_CAL, component/nvmctrl.h)
//
// Same fail-stop busy-wait pattern as the other ports' ClockInit files.
// Polls read swift-mmio registers (volatile), so empty loop bodies are
// correct here. Every register keeps the access width the old pointer-based
// code used (8-bit GCLK STATUS, 16-bit DFLLCTRL/CLKCTRL, 32-bit elsewhere).
//
// The GCLK and PM blocks below are also used by UsbHid.swift and
// UartDebug.swift (this target compiles flat, so each block is defined once).

@RegisterBlock
struct SAMD21NVMCTRL {
    @RegisterBlock(offset: 0x04) var ctrlb: Register<GPIOWord>
}

@RegisterBlock
struct SAMD21SYSCTRL {
    @RegisterBlock(offset: 0x0C) var pclksr: Register<SYSCTRL_PCLKSR>
    @RegisterBlock(offset: 0x24) var dfllctrl: Register<SYSCTRL_DFLLCTRL>
    @RegisterBlock(offset: 0x28) var dfllval: Register<GPIOWord>
    @RegisterBlock(offset: 0x2C) var dfllmul: Register<GPIOWord>
}

@Register(bitWidth: 32)
struct SYSCTRL_PCLKSR {
    @ReadOnly(bits: 4..<5, as: Bool.self) var dfllrdy: DFLLRDY
}

@Register(bitWidth: 16)
struct SYSCTRL_DFLLCTRL {
    @ReadWrite(bits: 1..<2, as: Bool.self) var enable: ENABLE
    // MODE: 1 = closed loop. (No trailing comments on macro-annotated
    // fields: swift-mmio 0.1.1 splices them into its expansion.)
    @ReadWrite(bits: 2..<3, as: Bool.self) var mode: MODE
    @ReadWrite(bits: 5..<6, as: Bool.self) var usbcrm: USBCRM
    @ReadWrite(bits: 8..<9, as: Bool.self) var ccdis: CCDIS
}

@RegisterBlock
struct SAMD21GCLK {
    @RegisterBlock(offset: 0x01) var status: Register<GCLK_STATUS>
    // CLKCTRL is 16-bit; writing just its low byte (ID) selects which
    // channel a following 16-bit read reports — UsbHid.swift's read-back.
    @RegisterBlock(offset: 0x02) var clkctrl: Register<MMIOHalf>
    @RegisterBlock(offset: 0x02) var clkctrlId: Register<MMIOByte>
    @RegisterBlock(offset: 0x04) var genctrl: Register<GPIOWord>
    @RegisterBlock(offset: 0x08) var gendiv: Register<GPIOWord>
}

@Register(bitWidth: 8)
struct GCLK_STATUS {
    @ReadOnly(bits: 7..<8, as: Bool.self) var syncbusy: SYNCBUSY
}

@RegisterBlock
struct SAMD21PM {
    @RegisterBlock(offset: 0x14) var ahbmask: Register<GPIOWord>
    @RegisterBlock(offset: 0x1C) var apbbmask: Register<GPIOWord>
    @RegisterBlock(offset: 0x20) var apbcmask: Register<GPIOWord>
}

private let nvmctrl = SAMD21NVMCTRL(unsafeAddress: 0x4100_4000)
let sysctrl = SAMD21SYSCTRL(unsafeAddress: 0x4000_0800)
let gclk = SAMD21GCLK(unsafeAddress: 0x4000_0C00)
let pm = SAMD21PM(unsafeAddress: 0x4000_0400)

private let nvmctrlCtrlbRws1: UInt32 = 1 << 1 // one wait state, required at 48MHz/3.3V

private let genCtrlSrcOsc8m: UInt32 = 0x6 << 8   // GCLK_GENCTRL_SRC_OSC8M_Val
private let genCtrlSrcDfll48m: UInt32 = 0x7 << 8 // GCLK_GENCTRL_SRC_DFLL48M_Val
private let genCtrlGenEn: UInt32 = 1 << 16
private let genCtrlIdc: UInt32 = 1 << 17

// Factory coarse calibration for the DFLL, burnt at production (OTP4 fuse
// word, read-only — read as a whole 32-bit word like the old code).
private let dfllCoarseCalWord = Register<GPIOWord>(unsafeAddress: 0x0080_6024)

@inline(__always)
private func waitDfllReady() {
    while !sysctrl.pclksr.read().dfllrdy {}
}

@inline(__always)
private func waitGclkSync() {
    while gclk.status.read().syncbusy {}
}

@c
func smk_clock_init() {
    // 0. Park the CPU on OSC8M first. The XIAO M0's UF2 bootloader hands
    //    over with GCLK0 (the CPU clock) already sourced from the DFLL —
    //    it needs 48MHz for its own USB — so reconfiguring the DFLL below
    //    while still executing from it stalls the CPU the moment the DFLL
    //    output glitches (found on hardware: one LED marker, then a hang
    //    inside this function). OSC8M is enabled at reset and always
    //    available; its default /8 prescaler (1MHz CPU) is fine for the
    //    few microseconds this takes.
    gclk.genctrl.write { $0.value = genCtrlSrcOsc8m | genCtrlGenEn } // ID 0
    waitGclkSync()

    // 1. Flash wait state for 48MHz operation, before any clock raise.
    nvmctrl.ctrlb.modify { $0.value |= nvmctrlCtrlbRws1 }

    // 2. Errata 1.2.1/9905: the DFLL must be enabled (with ONDEMAND clear —
    //    the reset default puts the whole register at 0 apart from ONDEMAND,
    //    so write ENABLE alone) and ready before DFLLVAL/DFLLMUL are
    //    touched, or those writes can deadlock the module.
    sysctrl.dfllctrl.write { $0.enable = true }
    waitDfllReady()

    // 3. Load the factory coarse calibration (0x3F means an unprogrammed
    //    fuse — fall back to midscale, same guard uf2-samdx1 uses) and a
    //    midscale fine value.
    var coarse = (dfllCoarseCalWord.read().value >> 26) & 0x3F
    if coarse == 0x3F { coarse = 0x1F }
    sysctrl.dfllval.write { $0.value = (coarse << 10) | 512 }
    waitDfllReady()

    // 4. Multiplier for USB clock recovery: 48000 DFLL cycles per 1kHz USB
    //    frame. CSTEP/FSTEP bound how fast the tuner may move per
    //    comparison; 1/1 is the conservative choice.
    sysctrl.dfllmul.write { $0.value = (1 << 26) | (1 << 16) | 48000 }

    // 5. Closed-loop against USB SOF (USBCRM), chill cycle disabled as the
    //    datasheet requires for USB recovery mode. Free-runs near the
    //    coarse-calibrated 48MHz until a host actually provides SOFs.
    sysctrl.dfllctrl.write {
        $0.enable = true
        $0.mode = true
        $0.usbcrm = true
        $0.ccdis = true
    }
    waitDfllReady()

    // 6. Route DFLL48M to GCLK generator 0 (the CPU clock), divide-by-1,
    //    improved duty cycle. GENDIV before GENCTRL, then wait for the
    //    generator write to synchronize.
    gclk.gendiv.write { $0.value = 0 } // ID 0, DIV 0 (= /1)
    gclk.genctrl.write { $0.value = genCtrlSrcDfll48m | genCtrlIdc | genCtrlGenEn } // ID 0
    waitGclkSync()

    // 7. Feed GCLK generator 2 with DFLL48M as well. Found on hardware via
    //    an LED-encoded register dump: the XIAO M0's Seeed UF2 bootloader
    //    leaves the USB GCLK channel pointed at GEN2 with WRTLOCK set —
    //    locked until a power-on reset, so the application CANNOT re-route
    //    USB to GEN0 (writes to that CLKCTRL channel are silently ignored;
    //    an earlier bring-up build proved this by reading GEN=2 back after
    //    writing GEN=0). Rather than fight the lock, run GEN2 at the 48MHz
    //    the locked channel expects.
    gclk.gendiv.write { $0.value = 2 } // ID 2, DIV 0 (= /1)
    gclk.genctrl.write { $0.value = 2 | genCtrlSrcDfll48m | genCtrlIdc | genCtrlGenEn } // ID 2
    waitGclkSync()
}
