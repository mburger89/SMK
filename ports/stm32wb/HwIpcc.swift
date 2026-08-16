// STM32WB IPCC (Inter-Processor Communication Controller) hardware layer —
// the `HW_IPCC_*` function family the vendored transport layer
// (ports/stm32wb/platform/tl_mbox.c) calls into, plus the two NVIC vectors
// that drive it.
//
// This is NOT vendored code. Unlike tl_mbox.c/shci.c/hci_tl.c (shared
// middleware, copied verbatim from STM32CubeWB v1.24.0), ST ships hw_ipcc.c
// per-example under each project's own STM32_WPAN/Target/ directory — it is
// meant to be reimplemented per integration, not vendored. This file is a
// Swift reimplementation of the BLE-only subset of
// STM32CubeWB v1.24.0's
// Projects/P-NUCLEO-WB55.Nucleo/Applications/BLE/BLE_HeartRate/STM32_WPAN/
// Target/hw_ipcc.c (the Thread / Zigbee / MAC-802.15.4 / LLD-tests branches
// of that file are all `#ifdef`-guarded on protocol macros this project
// never defines, so they are simply absent here rather than compiled out).
//
// Swift-vs-C decision (the brief deliberately left this open until the real
// signatures were known): every function ST's hw.h declares in this family
// is `void f(void)` except `HW_IPCC_MM_SendFreeBuf(void (*cb)(void))`, and
// the two IRQ entry points are plain weak-symbol vector-table overrides.
// All of that crosses the C ABI trivially — `@_cdecl` for the eleven
// exports plus the two vectors, `@_extern(c, ...)` for the five `*_Not`
// callbacks tl_mbox.c defines — so Swift it is, per this project's
// Swift-first preference. The one thing Swift genuinely cannot express is
// the handful of `asm volatile` CMSIS core intrinsics (PRIMASK critical
// sections, SEV/WFE); those live in the deliberately-tiny
// platform/cortex_m_intrinsics.c, the same "non-inline wrapper for
// something Swift can't bind to" pattern as
// ports/rp2040/platform/flash_irq_wrappers.c.
//
// Nothing calls into this file yet — Task 6 is a standalone compile/link
// check. Task 7 wires up the real CPU2 boot sequence (TL_Enable/TL_Init/
// TL_BLE_Init/shci_init) that reaches this code. The two IRQ vectors below
// are, however, live from the moment this links: they override
// cmsis-device-wb's weak Default_Handler aliases. That is harmless while
// HW_IPCC_Init() is never called (the IPCC peripheral clock stays gated and
// neither NVIC line is enabled, so neither vector can fire).
//
// Every register address and bit position below was read out of the real
// vendored headers, not assumed:
//   - IPCC_TypeDef layout + IPCC_BASE, RCC AHB3ENR/C2AHB3ENR offsets and
//     IPCCEN bit, PWR_CR4 offset and C2BOOT bit, EXTI RTSR2/C2EMR2 offsets
//     and line-41 bit, IPCC_C1_RX_IRQn/IPCC_C1_TX_IRQn numbers:
//     ~/cmsis-device-wb/Include/stm32wb55xx.h
//   - the exact read/write semantics of each LL_C1_IPCC_* helper ST's
//     hw_ipcc.c calls, and LL_IPCC_CHANNEL_n's numeric values:
//     stm32wbxx_ll_ipcc.h (present on disk in BTstack's vendored copy of
//     ST's HAL, ~/btstack/port/stm32-wb55xx-nucleo-freertos/Drivers/
//     STM32WBxx_HAL_Driver/Inc/). ST's LL driver is not linked into this
//     build; only its semantics are reproduced.

// MARK: - Register addresses

// IPCC: AHB4PERIPH_BASE (0x5800_0000) + 0xC00. Register offsets from
// IPCC_TypeDef: C1CR 0x00, C1MR 0x04, C1SCR 0x08, C1TOC2SR 0x0C,
// C2TOC1SR 0x1C. (The C2* control/mask/status-set registers at 0x10-0x18
// are CPU2's side and are never touched from here.)
private let ipccBase: UInt32 = 0x5800_0C00
private let ipccC1cr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(ipccBase + 0x00))!
private let ipccC1mr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(ipccBase + 0x04))!
private let ipccC1scr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(ipccBase + 0x08))!
private let ipccC1toc2sr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(ipccBase + 0x0C))!
private let ipccC2toc1sr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(ipccBase + 0x1C))!
// CPU2's mask/status-set-clear registers — normally CPU2's side and left
// alone; touched only by smk_ipcc_reset() below, which runs while CPU2 is
// still held in reset. Offsets confirmed via IPCC_TypeDef: C2MR 0x14,
// C2SCR 0x18.
private let ipccC2mr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(ipccBase + 0x14))!
private let ipccC2scr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(ipccBase + 0x18))!

// RCC: same 0x5800_0000 base ports/stm32wb/ClockInit.swift and
// ports/stm32wb/UsbHid.swift already use (their copies are file-private).
// AHB3ENR at 0x50 gates IPCC's clock for CPU1; C2AHB3ENR at 0x150 does the
// same for CPU2. Both bits are IPCCEN, bit 20.
private let rccBase: UInt32 = 0x5800_0000
private let rccAhb3Enr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x050))!
private let rccC2Ahb3Enr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x150))!
private let rccAhb3EnrIpccEn: UInt32 = 1 << 20 // RCC_AHB3ENR_IPCCEN_Pos / RCC_C2AHB3ENR_IPCCEN_Pos

// PWR: AHB4PERIPH_BASE + 0x400 (same base ClockInit.swift uses). CR4 at
// offset 0x0C; C2BOOT is bit 15 — setting it releases CPU2 from reset so it
// starts running the wireless-coprocessor firmware.
private let pwrCr4 = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x5800_0400 + 0x0C))!
private let pwrCr4C2Boot: UInt32 = 1 << 15 // PWR_CR4_C2BOOT_Pos

// EXTI: AHB4PERIPH_BASE + 0x800. RTSR2 (rising-trigger select, lines 32-63)
// at 0x20; C2EMR2 (CPU2 event mask, lines 32-63) at 0xD4. EXTI line 41 is
// the IPCC CPU2 wakeup line, so its bit within the "2" (lines 32-63)
// registers is 41 - 32 = 9 — confirmed by stm32wb55xx.h's own
// EXTI_RTSR2_RT41_Pos (9) and EXTI_C2EMR2_EM41_Pos (9).
private let extiBase: UInt32 = 0x5800_0800
private let extiRtsr2 = UnsafeMutablePointer<UInt32>(bitPattern: UInt(extiBase + 0x20))!
private let extiC2emr2 = UnsafeMutablePointer<UInt32>(bitPattern: UInt(extiBase + 0xD4))!
private let extiLine41Bit: UInt32 = 1 << 9

// NVIC ISER: standard Cortex-M SCS address, 0xE000_E100, an array of 32-bit
// set-enable registers. IPCC_C1_RX_IRQn = 44 and IPCC_C1_TX_IRQn = 45
// (stm32wb55xx.h's IRQn_Type), so both live in ISER[1] at bits 12 and 13.
private let nvicIser = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0xE000_E100))!
private let ipccC1RxIrqn: UInt32 = 44
private let ipccC1TxIrqn: UInt32 = 45

// MARK: - IPCC control-register bits

private let ipccC1crRxoie: UInt32 = 1 << 0  // IPCC_C1CR_RXOIE_Pos
private let ipccC1crTxfie: UInt32 = 1 << 16 // IPCC_C1CR_TXFIE_Pos

// Within C1MR: bits 0-5 are the receive-channel ("channel occupied")
// interrupt masks, bits 16-21 the transmit-channel ("channel free") masks.
// Within C1SCR: bits 0-5 clear a receive flag, bits 16-21 set a transmit
// flag. In every case a channel's bit is `channelMask << shift`, where
// channelMask is LL_IPCC_CHANNEL_n (1 << (n - 1)).
private let c1mrTxShift: UInt32 = 16  // IPCC_C1MR_CH1FM_Pos
private let c1scrTxShift: UInt32 = 16 // IPCC_C1SCR_CH1S_Pos

// MARK: - Channel assignment
//
// From the vendored platform/mbox_def.h, which maps each logical mailbox
// channel onto LL_IPCC_CHANNEL_n (= 1 << (n - 1)). Only the channels this
// BLE-only build actually uses are named here; mbox_def.h's Thread/Zigbee/
// MAC/LLD aliases share the same underlying channel numbers and are simply
// unused.
//
// CPU1 -> CPU2 (transmit):
private let chBleCmd: UInt32 = 1 << 0        // LL_IPCC_CHANNEL_1
private let chSystemCmdRsp: UInt32 = 1 << 1  // LL_IPCC_CHANNEL_2
private let chMmReleaseBuffer: UInt32 = 1 << 3 // LL_IPCC_CHANNEL_4
private let chHciAclData: UInt32 = 1 << 5    // LL_IPCC_CHANNEL_6
// CPU2 -> CPU1 (receive):
private let chBleEvent: UInt32 = 1 << 0      // LL_IPCC_CHANNEL_1
private let chSystemEvent: UInt32 = 1 << 1   // LL_IPCC_CHANNEL_2
private let chTraces: UInt32 = 1 << 3        // LL_IPCC_CHANNEL_4

// MARK: - Cortex-M intrinsics (platform/cortex_m_intrinsics.c)

@_extern(c, "smk_irq_disable_save")
func smk_irq_disable_save() -> UInt32

@_extern(c, "smk_irq_restore")
func smk_irq_restore(_ primask: UInt32)

@_extern(c, "smk_cpu_sev")
func smk_cpu_sev()

@_extern(c, "smk_cpu_wfe")
func smk_cpu_wfe()

// MARK: - Notification callbacks implemented by the vendored tl_mbox.c
//
// ST's own hw_ipcc.c declares these `__weak` no-ops so it can link into
// projects that don't use the transport layer. Here tl_mbox.c is always
// linked and always defines all five strongly (verified with `nm` on the
// compiled object during this task), so no weak fallbacks are needed.

@_extern(c, "HW_IPCC_BLE_RxEvtNot")
func HW_IPCC_BLE_RxEvtNot()

@_extern(c, "HW_IPCC_BLE_AclDataAckNot")
func HW_IPCC_BLE_AclDataAckNot()

@_extern(c, "HW_IPCC_SYS_CmdEvtNot")
func HW_IPCC_SYS_CmdEvtNot()

@_extern(c, "HW_IPCC_SYS_EvtNot")
func HW_IPCC_SYS_EvtNot()

@_extern(c, "HW_IPCC_TRACES_EvtNot")
func HW_IPCC_TRACES_EvtNot()

// MARK: - LL_C1_IPCC_* equivalents
//
// One-for-one with ST's stm32wbxx_ll_ipcc.h inline functions. "Enable" means
// *clearing* the channel's mask bit (a set bit masks the interrupt off).

@inline(__always)
private func enableReceiveChannel(_ channel: UInt32) {
    ipccC1mr.pointee &= ~channel
}

@inline(__always)
private func enableTransmitChannel(_ channel: UInt32) {
    ipccC1mr.pointee &= ~(channel << c1mrTxShift)
}

@inline(__always)
private func disableTransmitChannel(_ channel: UInt32) {
    ipccC1mr.pointee |= (channel << c1mrTxShift)
}

/// Raise this CPU's flag on a CPU1->CPU2 channel (C1SCR CHxS, write-only).
@inline(__always)
private func setFlag(_ channel: UInt32) {
    ipccC1scr.pointee = channel << c1scrTxShift
}

/// Acknowledge a CPU2->CPU1 channel (C1SCR CHxC, write-only).
@inline(__always)
private func clearFlag(_ channel: UInt32) {
    ipccC1scr.pointee = channel
}

/// Is CPU1's own flag still raised on this channel? (i.e. CPU2 has not yet
/// consumed what we posted.)
@inline(__always)
private func isActiveFlagC1(_ channel: UInt32) -> Bool {
    (ipccC1toc2sr.pointee & channel) == channel
}

/// Has CPU2 raised its flag on this channel? (i.e. something is waiting for us.)
@inline(__always)
private func isActiveFlagC2(_ channel: UInt32) -> Bool {
    (ipccC2toc1sr.pointee & channel) == channel
}

// ST's HW_IPCC_RX_PENDING / HW_IPCC_TX_PENDING macros, verbatim in intent:
// a channel is serviceable only if the flag is in the right state AND this
// CPU has that channel's interrupt unmasked (mask bit clear in C1MR).

@inline(__always)
private func rxPending(_ channel: UInt32) -> Bool {
    isActiveFlagC2(channel) && ((~ipccC1mr.pointee) & channel) != 0
}

@inline(__always)
private func txPending(_ channel: UInt32) -> Bool {
    !isActiveFlagC1(channel) && ((~ipccC1mr.pointee) & (channel << c1mrTxShift)) != 0
}

@inline(__always)
private func criticalSection(_ body: () -> Void) {
    let primask = smk_irq_disable_save()
    body()
    smk_irq_restore(primask)
}

@inline(__always)
private func nvicEnableIrq(_ irqn: UInt32) {
    nvicIser.advanced(by: Int(irqn >> 5)).pointee = 1 << (irqn & 0x1F)
}

// MARK: - Interrupt vectors
//
// Weak-symbol overrides of cmsis-device-wb's startup_stm32wb55xx_cm4.s
// vector-table entries `IPCC_C1_RX_IRQHandler` / `IPCC_C1_TX_IRQHandler`
// (both weak-aliased to Default_Handler by default) — the same
// `@_cdecl`-named-weak-symbol-override pattern ports/stm32wb/UsbHid.swift
// already uses for USB_HP_IRQHandler / USB_LP_IRQHandler. In ST's own
// projects these two vectors live in stm32wbxx_it.c and do nothing but call
// HW_IPCC_Rx_Handler()/HW_IPCC_Tx_Handler().

@_cdecl("IPCC_C1_RX_IRQHandler")
func IPCC_C1_RX_IRQHandler() {
    HW_IPCC_Rx_Handler()
}

@_cdecl("IPCC_C1_TX_IRQHandler")
func IPCC_C1_TX_IRQHandler() {
    HW_IPCC_Tx_Handler()
}

// MARK: - Dispatch

@_cdecl("HW_IPCC_Rx_Handler")
func HW_IPCC_Rx_Handler() {
    if rxPending(chSystemEvent) {
        // System (SHCI) asynchronous event from CPU2.
        HW_IPCC_SYS_EvtNot()
        clearFlag(chSystemEvent)
    } else if rxPending(chBleEvent) {
        // BLE (HCI) event from CPU2.
        HW_IPCC_BLE_RxEvtNot()
        clearFlag(chBleEvent)
    } else if rxPending(chTraces) {
        HW_IPCC_TRACES_EvtNot()
        clearFlag(chTraces)
    }
}

@_cdecl("HW_IPCC_Tx_Handler")
func HW_IPCC_Tx_Handler() {
    if txPending(chSystemCmdRsp) {
        // CPU2 consumed our system command; its response is ready.
        criticalSection { disableTransmitChannel(chSystemCmdRsp) }
        HW_IPCC_SYS_CmdEvtNot()
    } else if txPending(chMmReleaseBuffer) {
        // CPU2 consumed the previous free-buffer post; send the next batch.
        criticalSection { disableTransmitChannel(chMmReleaseBuffer) }
        freeBufCb?()
        setFlag(chMmReleaseBuffer)
    } else if txPending(chHciAclData) {
        criticalSection { disableTransmitChannel(chHciAclData) }
        HW_IPCC_BLE_AclDataAckNot()
    }
}

// MARK: - General

@_cdecl("HW_IPCC_Enable")
func HW_IPCC_Enable() {
    // Keep IPCC clocked from CPU2's side too, so the IP stays available to
    // CPU2 while CPU1 is in deep sleep (ST's own comment; matters once FUS
    // is running on CPU2).
    rccC2Ahb3Enr.pointee |= rccAhb3EnrIpccEn

    // Coming out of standby, CPU2 is woken through EXTI line 41 rather than
    // by the IPCC flag directly, so arm the rising-edge trigger and unmask
    // the line as a CPU2 *event*.
    extiRtsr2.pointee |= extiLine41Bit
    extiC2emr2.pointee |= extiLine41Bit

    // ST requires at least one system clock cycle between arming the rising
    // trigger (the RTSR2 write) and the SEV below. Nothing extra is needed
    // to satisfy that: the C2EMR2 write between them IS the intervening
    // cycle. Keep these three statements in this order.
    //
    // Set the internal event flag and signal CPU2, then immediately consume
    // the local flag so it can't make a later WFE fall straight through.
    smk_cpu_sev()
    smk_cpu_wfe()

    // Release CPU2 from reset. Note this is a one-shot: once C2BOOT has been
    // set, clearing and re-setting it has no effect — a warm restart of CPU2
    // needs SHCI_C2_Reinit() plus the event above instead. Setting both (as
    // here, and as ST does) is the configuration-independent default.
    pwrCr4.pointee |= pwrCr4C2Boot
}

// BTstack's WB55 port calls this "ipcc_reset" (btstack_port.c:260-294) and
// runs it before TL_Init(). On a cold boot the IPCC is already at its reset
// values, but CPU1 can be reset independently of CPU2 (a debugger attach, a
// CPU1-only software reset) and then the leftover channel flags would make
// TL_Init()/TL_Enable() see phantom traffic. Ported from
// platform/ble_hid_wb.c's former C implementation — semantics per
// stm32wbxx_ll_ipcc.h: C1SCR/C2SCR bits 0-5 are write-1-to-clear receive
// flags, C1MR/C2MR bits 0-5 mask receive and bits 16-21 mask transmit (a
// *set* mask bit disables). Called from ble_hid_wb.c's transport_init()
// before TL_Init().
private let ipccAllChannels: UInt32 = 0x3F // LL_IPCC_CHANNEL_1..6 == (1<<0)..(1<<5)

@_cdecl("smk_ipcc_reset")
func smk_ipcc_reset() {
    // The C original followed the |= with `(void)RCC->AHB3ENR;` so the
    // clock-enable takes effect before the IPCC register writes below. A
    // `.pointee` read-back gets folded away by the optimizer (see
    // ClockInit.swift's smk_mmio_read32 comment), so the read goes through
    // that opaque C helper instead.
    rccAhb3Enr.pointee |= rccAhb3EnrIpccEn
    _ = smk_mmio_read32(rccBase + 0x050)

    ipccC1scr.pointee = ipccAllChannels                             // clear CPU1's receive flags
    ipccC2scr.pointee = ipccAllChannels                             // clear CPU2's receive flags
    ipccC1mr.pointee = (ipccAllChannels << 16) | ipccAllChannels    // mask everything off
    ipccC2mr.pointee = (ipccAllChannels << 16) | ipccAllChannels
}

@_cdecl("HW_IPCC_Init")
func HW_IPCC_Init() {
    rccAhb3Enr.pointee |= rccAhb3EnrIpccEn

    ipccC1cr.pointee |= ipccC1crRxoie // RX "channel occupied" interrupt
    ipccC1cr.pointee |= ipccC1crTxfie // TX "channel free" interrupt

    nvicEnableIrq(ipccC1RxIrqn)
    nvicEnableIrq(ipccC1TxIrqn)
}

// MARK: - BLE

@_cdecl("HW_IPCC_BLE_Init")
func HW_IPCC_BLE_Init() {
    criticalSection { enableReceiveChannel(chBleEvent) }
}

@_cdecl("HW_IPCC_BLE_SendCmd")
func HW_IPCC_BLE_SendCmd() {
    setFlag(chBleCmd)
}

@_cdecl("HW_IPCC_BLE_SendAclData")
func HW_IPCC_BLE_SendAclData() {
    setFlag(chHciAclData)
    criticalSection { enableTransmitChannel(chHciAclData) }
}

// MARK: - System (SHCI)

@_cdecl("HW_IPCC_SYS_Init")
func HW_IPCC_SYS_Init() {
    criticalSection { enableReceiveChannel(chSystemEvent) }
}

@_cdecl("HW_IPCC_SYS_SendCmd")
func HW_IPCC_SYS_SendCmd() {
    setFlag(chSystemCmdRsp)
    criticalSection { enableTransmitChannel(chSystemCmdRsp) }
}

// MARK: - Memory manager

// Set while a free-buffer post is in flight, then invoked from
// HW_IPCC_Tx_Handler once CPU2 has consumed the previous one. Plain
// `@convention(c)` function pointer — no closure context, nothing heap
// allocated, so this stays valid Embedded Swift.
private var freeBufCb: (@convention(c) () -> Void)?

@_cdecl("HW_IPCC_MM_SendFreeBuf")
func HW_IPCC_MM_SendFreeBuf(_ cb: @convention(c) () -> Void) {
    if isActiveFlagC1(chMmReleaseBuffer) {
        // Previous post not yet consumed by CPU2 — defer to the TX handler.
        freeBufCb = cb
        criticalSection { enableTransmitChannel(chMmReleaseBuffer) }
    } else {
        cb()
        setFlag(chMmReleaseBuffer)
    }
}

// MARK: - Traces

@_cdecl("HW_IPCC_TRACES_Init")
func HW_IPCC_TRACES_Init() {
    criticalSection { enableReceiveChannel(chTraces) }
}
