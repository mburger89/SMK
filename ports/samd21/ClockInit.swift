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
// Same fail-stop busy-wait pattern as the other ports' ClockInit files —
// every wait loop calls the opaque smk_cpu_nop() so LLVM can't delete it
// (see CLAUDE.md's register-polling note).

private let nvmctrlCtrlb = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x4100_4000 + 0x04))!
private let nvmctrlCtrlbRws1: UInt32 = 1 << 1 // one wait state, required at 48MHz/3.3V

private let sysctrlBase: UInt32 = 0x4000_0800
private let sysctrlPclksr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(sysctrlBase + 0x0C))!
private let sysctrlDfllCtrl = UnsafeMutablePointer<UInt16>(bitPattern: UInt(sysctrlBase + 0x24))!
private let sysctrlDfllVal = UnsafeMutablePointer<UInt32>(bitPattern: UInt(sysctrlBase + 0x28))!
private let sysctrlDfllMul = UnsafeMutablePointer<UInt32>(bitPattern: UInt(sysctrlBase + 0x2C))!

private let pclksrDfllRdy: UInt32 = 1 << 4
private let dfllCtrlEnable: UInt16 = 1 << 1
private let dfllCtrlModeClosed: UInt16 = 1 << 2
private let dfllCtrlUsbCrm: UInt16 = 1 << 5
private let dfllCtrlCcdis: UInt16 = 1 << 8

private let gclkBase: UInt32 = 0x4000_0C00
private let gclkStatus = UnsafeMutablePointer<UInt8>(bitPattern: UInt(gclkBase + 0x01))!
private let gclkClkCtrl = UnsafeMutablePointer<UInt16>(bitPattern: UInt(gclkBase + 0x02))!
private let gclkGenCtrl = UnsafeMutablePointer<UInt32>(bitPattern: UInt(gclkBase + 0x04))!
private let gclkGenDiv = UnsafeMutablePointer<UInt32>(bitPattern: UInt(gclkBase + 0x08))!

private let gclkStatusSyncBusy: UInt8 = 1 << 7
private let genCtrlSrcOsc8m: UInt32 = 0x6 << 8   // GCLK_GENCTRL_SRC_OSC8M_Val
private let genCtrlSrcDfll48m: UInt32 = 0x7 << 8 // GCLK_GENCTRL_SRC_DFLL48M_Val
private let genCtrlGenEn: UInt32 = 1 << 16
private let genCtrlIdc: UInt32 = 1 << 17

// Factory coarse calibration for the DFLL, burnt at production.
private let dfllCoarseCalWord = UnsafePointer<UInt32>(bitPattern: UInt(0x0080_6024))!

// Opaque no-op, implemented in platform/cortex_m_intrinsics.c — see header.
@_extern(c, "smk_cpu_nop")
func smk_cpu_nop()

@inline(__always)
private func waitDfllReady() {
    while (sysctrlPclksr.pointee & pclksrDfllRdy) == 0 { smk_cpu_nop() }
}

@_cdecl("smk_clock_init")
func smk_clock_init() {
    // 0. Park the CPU on OSC8M first. The XIAO M0's UF2 bootloader hands
    //    over with GCLK0 (the CPU clock) already sourced from the DFLL —
    //    it needs 48MHz for its own USB — so reconfiguring the DFLL below
    //    while still executing from it stalls the CPU the moment the DFLL
    //    output glitches (found on hardware: one LED marker, then a hang
    //    inside this function). OSC8M is enabled at reset and always
    //    available; its default /8 prescaler (1MHz CPU) is fine for the
    //    few microseconds this takes.
    gclkGenCtrl.pointee = genCtrlSrcOsc8m | genCtrlGenEn // ID 0
    while (gclkStatus.pointee & gclkStatusSyncBusy) != 0 { smk_cpu_nop() }

    // 1. Flash wait state for 48MHz operation, before any clock raise.
    nvmctrlCtrlb.pointee |= nvmctrlCtrlbRws1

    // 2. Errata 1.2.1/9905: the DFLL must be enabled (with ONDEMAND clear —
    //    the reset default puts the whole register at 0 apart from ONDEMAND,
    //    so write ENABLE alone) and ready before DFLLVAL/DFLLMUL are
    //    touched, or those writes can deadlock the module.
    sysctrlDfllCtrl.pointee = dfllCtrlEnable
    waitDfllReady()

    // 3. Load the factory coarse calibration (0x3F means an unprogrammed
    //    fuse — fall back to midscale, same guard uf2-samdx1 uses) and a
    //    midscale fine value.
    var coarse = (dfllCoarseCalWord.pointee >> 26) & 0x3F
    if coarse == 0x3F { coarse = 0x1F }
    sysctrlDfllVal.pointee = (coarse << 10) | 512
    waitDfllReady()

    // 4. Multiplier for USB clock recovery: 48000 DFLL cycles per 1kHz USB
    //    frame. CSTEP/FSTEP bound how fast the tuner may move per
    //    comparison; 1/1 is the conservative choice.
    sysctrlDfllMul.pointee = (1 << 26) | (1 << 16) | 48000

    // 5. Closed-loop against USB SOF (USBCRM), chill cycle disabled as the
    //    datasheet requires for USB recovery mode. Free-runs near the
    //    coarse-calibrated 48MHz until a host actually provides SOFs.
    sysctrlDfllCtrl.pointee = dfllCtrlEnable | dfllCtrlModeClosed | dfllCtrlUsbCrm | dfllCtrlCcdis
    waitDfllReady()

    // 6. Route DFLL48M to GCLK generator 0 (the CPU clock), divide-by-1,
    //    improved duty cycle. GENDIV before GENCTRL, then wait for the
    //    generator write to synchronize.
    gclkGenDiv.pointee = 0 // ID 0, DIV 0 (= /1)
    gclkGenCtrl.pointee = genCtrlSrcDfll48m | genCtrlIdc | genCtrlGenEn // ID 0
    while (gclkStatus.pointee & gclkStatusSyncBusy) != 0 { smk_cpu_nop() }

    // 7. Feed GCLK generator 2 with DFLL48M as well. Found on hardware via
    //    an LED-encoded register dump: the XIAO M0's Seeed UF2 bootloader
    //    leaves the USB GCLK channel pointed at GEN2 with WRTLOCK set —
    //    locked until a power-on reset, so the application CANNOT re-route
    //    USB to GEN0 (writes to that CLKCTRL channel are silently ignored;
    //    an earlier bring-up build proved this by reading GEN=2 back after
    //    writing GEN=0). Rather than fight the lock, run GEN2 at the 48MHz
    //    the locked channel expects.
    gclkGenDiv.pointee = 2 // ID 2, DIV 0 (= /1)
    gclkGenCtrl.pointee = 2 | genCtrlSrcDfll48m | genCtrlIdc | genCtrlGenEn // ID 2
    while (gclkStatus.pointee & gclkStatusSyncBusy) != 0 { smk_cpu_nop() }
}
