// Per-key RGB backlighting over an SK6812MINI-E chain.
//
// Opt-in on ESP32-C6 (stock smk_kbd PCB has no addressable LED chain — only
// a single fixed charge-status LED — so there's nothing to drive unless
// you've wired one up yourself; guarded by -DSMK_RGB_AVAILABLE in
// main/CMakeLists.txt, instantiated at runtime only if `idf.py menuconfig`
// -> SMK_HAS_RGB_BACKLIGHT is enabled, see Main.swift). Compiled in
// unconditionally (hardware always present) for the smk_kbd_rp2040 board —
// see ports/rp2040/CMakeLists.txt. nRF52840 doesn't include this file.
//
// If you wire one up: the chain is assumed wired serpentine/boustrophedon,
// not raster — ledChainIndex below must mirror however you actually wired
// it (or your PCB generator's led_chain_index(), if you have one). Even
// rows run col 0->COLS-1, odd rows run COLS-1->0, so chain-adjacent LEDs
// stay physically adjacent. Getting this wrong doesn't break compilation or
// scanning — it just lights the wrong LED under the wrong key, silently.

// led_strip_driver_init/led_strip_set_pixel/led_strip_refresh/led_strip_clear:
// on ESP32-C6 these are same-module Swift definitions in
// LedStripDriverRMT.swift (RMT-based driver, formerly
// Sources/components/led_strip_driver.c) — no @_extern declaration is
// needed or permitted there; a same-module Swift function definition can't
// coexist with an @_extern(c, ...) forward declaration of the same name
// ("invalid redeclaration"), same class of stale-prototype pitfall Task 8
// hit with Bridging.h, just caught at compile time instead of silently
// shadowed since both sides are Swift here. On RP2040 (smk_kbd_rp2040
// board only) these stay real external C symbols
// (ports/rp2040/platform/led_strip_driver.c, PIO-based) reached via
// @_extern below — RP2040's own BridgingHeader.h also declares C
// prototypes for them, but only inside `#ifdef SMK_RGB_AVAILABLE`, which
// never fires there: SMK_RGB_AVAILABLE is passed as a bare swiftc `-D`
// (Swift-level conditional compilation flag), never as `-Xcc -D`, so it's
// not visible to the C preprocessor that parses a bridging header. That
// bridging-header guard has therefore always been dead code; @_extern below
// is what has actually been supplying these symbols to RP2040 Swift code.
#if !SMK_TARGET_ESP32C6
@_extern(c, "led_strip_driver_init")
func led_strip_driver_init(_ gpioNum: Int32, _ numLeds: Int32)

@_extern(c, "led_strip_set_pixel")
func led_strip_set_pixel(_ index: Int32, _ r: UInt8, _ g: UInt8, _ b: UInt8)

@_extern(c, "led_strip_refresh")
func led_strip_refresh()

@_extern(c, "led_strip_clear")
func led_strip_clear()
#endif

struct RGBLighting {
    let rowCount: Int
    let colCount: Int
    private var dirty = false

    init(gpioNum: Int32, rowCount: Int, colCount: Int) {
        self.rowCount = rowCount
        self.colCount = colCount
        led_strip_driver_init(gpioNum, Int32(rowCount * colCount))
        led_strip_clear()
    }

    mutating func setKey(row: Int, col: Int, r: UInt8, g: UInt8, b: UInt8) {
        guard row >= 0, row < rowCount, col >= 0, col < colCount else { return }
        let idx = ledChainIndex(row: row, col: col, colCount: colCount)
        led_strip_set_pixel(Int32(idx), r, g, b)
        dirty = true
    }

    mutating func refreshIfDirty() {
        if dirty {
            led_strip_refresh()
            dirty = false
        }
    }

    mutating func clearAll() {
        led_strip_clear()
        dirty = false
    }
}
