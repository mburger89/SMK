// Per-key RGB backlighting over the SK6812MINI-E chain (driven via RMT,
// see led_strip_driver.c).
//
// The chain is wired serpentine/boustrophedon, not raster — this mirrors
// tools/generate_pcb.py's led_chain_index() in the PCB repo exactly. Even
// rows run col 0->COLS-1, odd rows run COLS-1->0, so chain-adjacent LEDs
// stay physically adjacent. Getting this wrong doesn't break compilation or
// scanning — it just lights the wrong LED under the wrong key, silently.

@_extern(c, "led_strip_driver_init")
func led_strip_driver_init(_ gpioNum: Int32, _ numLeds: Int32)

@_extern(c, "led_strip_set_pixel")
func led_strip_set_pixel(_ index: Int32, _ r: UInt8, _ g: UInt8, _ b: UInt8)

@_extern(c, "led_strip_refresh")
func led_strip_refresh()

@_extern(c, "led_strip_clear")
func led_strip_clear()

/// Chain position (0-indexed) of key (row, col) — must match
/// generate_pcb.py's `led_chain_index`.
func ledChainIndex(row: Int, col: Int, colCount: Int) -> Int {
    if row % 2 == 0 {
        return row * colCount + col
    } else {
        return row * colCount + (colCount - 1 - col)
    }
}

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
