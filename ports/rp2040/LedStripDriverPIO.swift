// SK6812MINI-E chain driver (PIO-based), smk_kbd_rp2040 board only —
// Swift port of the former ports/rp2040/platform/led_strip_driver.c.
// State-machine claiming/program-loading stays in ws2812_pio_shim.c (see
// that file's header comment for why); everything else — pixel buffer
// management, the GRB packing, the FIFO push loop, board config — is
// Swift.

@_extern(c, "smk_ws2812_pio_start")
func smk_ws2812_pio_start(_ gpioNum: UInt32, _ outPio: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ outSm: UnsafeMutablePointer<UInt32>) -> Int32

// pio_sm_put_blocking itself is `static inline` in hardware/pio.h with no
// non-static instantiation anywhere in the pico-sdk, so it is not a
// linkable C symbol an `@_extern(c, ...)` declaration could bind to
// directly (verified against ~/pico-sdk/src/rp2_common/hardware_pio/
// include/hardware/pio.h and pio.c — same unlinkable-inline trap flagged
// in Tasks 8/9's reviews). ws2812_pio_shim.c's smk_ws2812_put_blocking is
// a real, exported wrapper around it.
@_extern(c, "smk_ws2812_put_blocking")
func smk_ws2812_put_blocking(_ pio: UnsafeMutableRawPointer?, _ sm: UInt32, _ data: UInt32)

// sleep_us (pico/time.h) is a real non-static, exported symbol (defined in
// pico-sdk's src/common/pico_time/time.c) — confirmed linkable directly.
@_extern(c, "sleep_us")
func sleep_us(_ us: UInt64)

private let ledStripMaxLeds = 60 // matches ROWS*COLS in generate_kbd_rp2040.py

private var pio: UnsafeMutableRawPointer? = nil
private var sm: UInt32 = 0
private var pixels = [UInt8](repeating: 0, count: ledStripMaxLeds * 3)
private var numLeds = 0
private var ready = false

func led_strip_driver_init(_ gpioNum: Int32, _ requestedNumLeds: Int32) {
    numLeds = smkLedStripClampCount(requestedNumLeds, maxLeds: ledStripMaxLeds)
    for i in 0..<pixels.count { pixels[i] = 0 }

    // smk_ws2812_pio_start's doc comment (ws2812_pio_shim.c) documents a
    // 0-on-success return convention. Its implementation currently has no
    // failure path (always returns 0), so this was previously harmless in
    // practice — but discarding the result and setting `ready` unconditionally
    // meant the one signal that would indicate a real failure (both PIO
    // blocks full, no free state machine) was already thrown away, which
    // would have let led_strip_set_pixel/led_strip_refresh push FIFO words
    // to an invalid/unclaimed pio/sm pair the moment that C-side error path
    // is ever added.
    ready = smk_ws2812_pio_start(UInt32(gpioNum), &pio, &sm) == 0
}

func led_strip_set_pixel(_ index: Int32, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
    guard ready else { return }
    smkLedStripSetPixel(&pixels, index: index, numLeds: numLeds, r: r, g: g, b: b)
}

func led_strip_refresh() {
    guard ready else { return }
    for i in 0..<numLeds {
        // ws2812_program_init configured an autopull, left-justified
        // 24-bit OSR shift (rgbw=false), so the packed GRB triplet must
        // be shifted up into the top 24 bits of the 32-bit FIFO word.
        let grb = (UInt32(pixels[i * 3 + 0]) << 16) | (UInt32(pixels[i * 3 + 1]) << 8) | UInt32(pixels[i * 3 + 2])
        smk_ws2812_put_blocking(pio, sm, grb << 8)
    }
    sleep_us(300) // >=280us low period latches the frame on WS2812/SK6812
}

func led_strip_clear() {
    guard ready else { return }
    for i in 0..<(numLeds * 3) { pixels[i] = 0 }
    led_strip_refresh()
}

// This board always has real SK6812MINI-E hardware on a fixed pin
// (unlike ESP32-C6's Kconfig-gated version), so RGB is simply always-on.
// GPIO17 = RGB_GPIO per generate_kbd_rp2040.py's GPIO map.
func smk_has_rgb_backlight() -> Int32 { 1 }
func smk_rgb_gpio() -> Int32 { 17 }
