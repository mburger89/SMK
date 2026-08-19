// TEMPORARY bring-up UART: blocking, TX-only, SERCOM0 on PA06 (115200 8N1).
// Added specifically to get real diagnostic text instead of decoding
// multi-bit values from LED blink counts, which turned out to be
// unreliable once the USB bring-up needed byte-wide register dumps.
//
// Pin/pad mapping verified against TinyUSB's own hw/bsp/samd2x_l2x/family.c
// (the generic SAMD family board driver, not the seeeduino_xiao board.h —
// that board.h declares UART_TX_PIN=5/RX_PIN=4 but never defines
// UART_SERCOM, so those constants are dead/unwired in TinyUSB's own tree).
// The Seeed XIAO SAMD21's silkscreened TX/RX pins are D6/D7 = PA06/PA07,
// which IS a real, non-#error branch in that same family.c: PA06 ->
// PINMUX_PA06D_SERCOM0_PAD2 (function D), matching the SAMD21 datasheet's
// standard PA04-07 -> SERCOM0 PAD0-3 (function D) multiplexing group.
// TX-only: RX (PA07) is left as a plain input, unused.
//
// Register facts verified against the vendored DFP (component/{pm,gclk,
// port,sercom}.h, instance/sercom0.h):
//   PM 0x4000_0400: APBCMASK 0x20 (SERCOM0 bit 2)
//   GCLK 0x4000_0C00: CLKCTRL 16-bit @ 0x02, ID_SERCOM0_CORE = 0x14 (20)
//   PORT group A 0x4100_4400: PMUX pair 3 (pins 6/7) at 0x30+3=0x33,
//     PINCFG for pin 6 at 0x40+6=0x46 (PMUXEN bit 0)
//   SERCOM0 base 0x4200_0800 (USART mode): CTRLA +0x00 (SWRST bit0,
//     ENABLE bit1, MODE [4:2], SAMPR [15:13], TXPO [17:16], RXPO [21:20],
//     DORD bit30), CTRLB +0x04 (TXEN bit16), BAUD +0x0C (16-bit, fractional
//     mode: FP [15:13] | BAUD [12:0] — FP=0,BAUD=26 gives 115200 at the
//     48MHz GCLK0 this port already runs SERCOM cores from, same constant
//     TinyUSB's family.c uses), SYNCBUSY +0x1C (SWRST bit0, ENABLE bit1),
//     INTFLAG +0x18 (8-bit, TXC bit1), DATA +0x28 (16-bit, low byte used)

private let pmApbcMask = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x4000_0400 + 0x20))!
private let pmApbcMaskSercom0: UInt32 = 1 << 2

private let gclkClkCtrl16b = UnsafeMutablePointer<UInt16>(bitPattern: UInt(0x4000_0C02))!
private let clkCtrlIdSercom0Core: UInt16 = 20
private let clkCtrlGen0b: UInt16 = 0 << 8
private let clkCtrlClkEnB: UInt16 = 1 << 14

private let portAPmux3 = UnsafeMutablePointer<UInt8>(bitPattern: UInt(0x4100_4400 + 0x30 + 3))! // pins 6/7
private let portAPinCfg6 = UnsafeMutablePointer<UInt8>(bitPattern: UInt(0x4100_4400 + 0x40 + 6))!
private let pinCfgPmuxEnB: UInt8 = 1 << 0
private let pmuxFunctionD: UInt8 = 3

private let sercom0Base: UInt32 = 0x4200_0800
private let sercom0CtrlA = UnsafeMutablePointer<UInt32>(bitPattern: UInt(sercom0Base + 0x00))!
private let sercom0CtrlB = UnsafeMutablePointer<UInt32>(bitPattern: UInt(sercom0Base + 0x04))!
private let sercom0Baud = UnsafeMutablePointer<UInt16>(bitPattern: UInt(sercom0Base + 0x0C))!
private let sercom0IntFlag = UnsafeMutablePointer<UInt8>(bitPattern: UInt(sercom0Base + 0x18))!
private let sercom0SyncBusy = UnsafeMutablePointer<UInt32>(bitPattern: UInt(sercom0Base + 0x1C))!
private let sercom0Data = UnsafeMutablePointer<UInt16>(bitPattern: UInt(sercom0Base + 0x28))!

private let ctrlaSwrst: UInt32 = 1 << 0
private let ctrlaEnable: UInt32 = 1 << 1
private let ctrlaModeUsartIntClk: UInt32 = 1 << 2
private let ctrlaSampr1: UInt32 = 1 << 13 // fractional baud rate
private let ctrlaTxpoPad2: UInt32 = 1 << 16
private let ctrlaRxpoPad3: UInt32 = 3 << 20
private let ctrlaDord: UInt32 = 1 << 30 // LSB first

private let ctrlbTxen: UInt32 = 1 << 16

private let syncBusySwrst: UInt32 = 1 << 0
private let syncBusyEnable: UInt32 = 1 << 1

private let intFlagTxc: UInt8 = 1 << 1

@_extern(c, "smk_cpu_nop")
func smk_cpu_nop_uart()

func uartDebugInit() {
    pmApbcMask.pointee |= pmApbcMaskSercom0
    gclkClkCtrl16b.pointee = clkCtrlIdSercom0Core | clkCtrlGen0b | clkCtrlClkEnB

    portAPmux3.pointee = pmuxFunctionD // pin 6 (even, low nibble); pin 7 left as GPIO
    portAPinCfg6.pointee = pinCfgPmuxEnB

    sercom0CtrlA.pointee = ctrlaSwrst
    while (sercom0SyncBusy.pointee & syncBusySwrst) != 0 { smk_cpu_nop_uart() }

    sercom0CtrlA.pointee = ctrlaSampr1 | ctrlaDord | ctrlaModeUsartIntClk | ctrlaRxpoPad3 | ctrlaTxpoPad2
    sercom0CtrlB.pointee = ctrlbTxen
    sercom0Baud.pointee = 26 // FP=0, BAUD=26 -> 115200 @ 48MHz, SAMPR=1

    sercom0CtrlA.pointee |= ctrlaEnable
    while (sercom0SyncBusy.pointee & syncBusyEnable) != 0 { smk_cpu_nop_uart() }
}

private func uartPutChar(_ c: UInt8) {
    sercom0Data.pointee = UInt16(c)
    while (sercom0IntFlag.pointee & intFlagTxc) == 0 { smk_cpu_nop_uart() }
}

func uartDebugWrite(_ s: String) {
    for byte in s.utf8 {
        if byte == 0x0A { uartPutChar(0x0D) } // CRLF
        uartPutChar(byte)
    }
}

@_cdecl("uart_debug_init")
func uart_debug_init() {
    uartDebugInit()
}

@_cdecl("uart_debug_write_cstr")
func uart_debug_write_cstr(_ cstr: UnsafePointer<Int8>?) {
    guard let cstr = cstr else { return }
    uartDebugWrite(String(cString: cstr))
    uartDebugWrite("\n")
}

func uartDebugWriteHex(_ label: String, _ value: UInt32) {
    let hexDigits = Array("0123456789ABCDEF".utf8)
    var out = "\(label): 0x"
    var shift = 28
    var started = false
    while shift >= 0 {
        let nibble = Int((value >> UInt32(shift)) & 0xF)
        if nibble != 0 || started || shift == 0 {
            out.append(Character(UnicodeScalar(hexDigits[nibble])))
            started = true
        }
        shift -= 4
    }
    out.append("\n")
    uartDebugWrite(out)
}
