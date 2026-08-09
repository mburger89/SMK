// The Swift Programming Language
// https://docs.swift.org/swift-book

@_extern(c, "init_ble_hid")
func init_ble_hid()

@_extern(c, "send_keyboard_report")
func send_keyboard_report(_ modifier: UInt8, _ keycodes: UnsafePointer<UInt8>)

@_extern(c, "init_wired_link")
func init_wired_link()

@_extern(c, "send_wired_report")
func send_wired_report(_ modifier: UInt8, _ keycodes: UnsafePointer<UInt8>)

@_extern(c, "vTaskDelay")
func vTaskDelay(_ xTicksToDelay: UInt32)

@_extern(c, "kb_log")
func kb_log(_ msg: UnsafePointer<Int8>)

// Board/connection-mode config — ESP32-C6 provides these as plain Swift
// functions (SmkConfig.swift, part of this same module, backed by
// Kconfig); RP2040 provides them as hardcoded C functions
// (ports/rp2040/platform/platform_glue.c, since that build always has real
// native-USB wired HID), so only that build declares them here as extern
// symbols to link against.
#if !SMK_TARGET_ESP32C6
@_extern(c, "smk_has_wired_bridge")
func smk_has_wired_bridge() -> Int32

@_extern(c, "smk_default_mode_is_wired")
func smk_default_mode_is_wired() -> Int32
#endif

// Runtime keymap store — see Sources/componets/smk_keymap_store.c (ESP32)
// and ports/rp2040/platform/smk_keymap_store.c (RP2040).
@_extern(c, "smk_keymap_load")
func smk_keymap_load(_ buf: UnsafeMutablePointer<Int8>, _ bufSize: UInt32) -> Int32

@_extern(c, "smk_keymap_erase")
func smk_keymap_erase()

// RGB backlight config — only declared/referenced when this build compiles
// RGBLighting.swift in (ESP32-C6, via -DSMK_RGB_AVAILABLE in
// main/CMakeLists.txt). RP2040 doesn't include RGBLighting.swift at all, so
// this whole block must not exist there either, or the type lookup fails.
// Within that, ESP32-C6 provides these as plain Swift functions
// (SmkConfig.swift); only smk_kbd_rp2040 (the other SMK_RGB_AVAILABLE
// board) needs the extern — it backs them with hardcoded C functions since
// that board always has the RGB chain wired.
#if SMK_RGB_AVAILABLE
#if !SMK_TARGET_ESP32C6
@_extern(c, "smk_has_rgb_backlight")
func smk_has_rgb_backlight() -> Int32

@_extern(c, "smk_rgb_gpio")
func smk_rgb_gpio() -> Int32
#endif
#endif

@_cdecl("app_main_swift")
func app_main_swift() {
    kb_log("Initialising SMK Keyboard...")

    // Board pin maps. Exactly one of these is compiled in, selected by the
    // build (SMK_TARGET_BOARD in ports/rp2040/CMakeLists.txt / the ESP32
    // main/CMakeLists.txt always defines the ESP32 one). Both boards share
    // the same COL2ROW matrix topology and keymap layout — only the GPIO
    // numbers differ.
#if SMK_BOARD_KBD_RP2040
    // smk_kbd_rp2040 board (RP2040 QFN-56 chip-down) — GPIO map per
    // generate_kbd_rp2040.py (source of truth for this board's pin
    // assignments; see that file's header docstring for verification notes):
    //   ROW0-4 = GPIO0-4 (sense inputs, pull-down)
    //   COL0-11 = GPIO5-16 (strobe outputs)
    //   RGB_GPIO = GPIO17 (SK6812MINI-E chain, via level shifter U7)
    //   VBAT_SENSE = GPIO26/ADC0 — reserved, not used by the matrix
    //   GPIO18-23 + GPIO28 are the CYW43439 BLE UART link (BT_REG_ON,
    //   BT_DEV_WAKE, BT_UART_*, BT_HOST_WAKE) — see ble_hid_kbd_uart.c
    // colsAreDriven:1 for the same reason as the ESP32 board below — this
    // board's matrix is also COL2ROW (diode anode at the column/switch
    // side) — see KeyMatrix.swift.
    //
    // Row 4 layout is irregular per the PCB: 5 keys (cols 0-4), one 2U key
    // (col 5), no switch at col 6, then 5 more keys (cols 7-11) — 59
    // physical keys total over the 5x12 = 60 matrix positions.
    let configJson = """
    {
        "matrix": {
            "rows": [0, 1, 2, 3, 4],
            "cols": [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
            "colsAreDriven": 1
        },
        "layers": [
            [
                ["key:1", "key:2", "key:3", "key:4", "key:5", "key:6", "key:7", "key:8", "key:9", "key:0", "key:minus", "key:backspace"],
                ["key:tab", "key:q", "key:w", "key:e", "key:r", "key:t", "key:y", "key:u", "key:i", "key:o", "key:p", "key:backslash"],
                ["key:escape", "key:a", "key:s", "key:d", "key:f", "key:g", "key:h", "key:j", "key:k", "key:l", "key:semicolon", "key:enter"],
                ["mod:leftShift", "key:z", "key:x", "key:c", "key:v", "key:b", "key:n", "key:m", "key:comma", "key:period", "key:slash", "mod:rightShift"],
                ["mod:leftCtrl", "mod:leftGUI", "mod:leftAlt", "mo:1", "mod:leftShift", "key:space", "none", "mod:rightShift", "mo:1", "mod:rightAlt", "mod:rightGUI", "mod:rightCtrl"]
            ],
            [
                ["toggle_conn", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans"],
                ["trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans"],
                ["trans", "trans", "trans", "trans", "trans", "trans", "key:left", "key:down", "key:up", "key:right", "trans", "trans"],
                ["trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans"],
                ["trans", "trans", "trans", "trans", "trans", "trans", "none", "trans", "trans", "trans", "trans", "trans"]
            ]
        ]
    }
    """
#else
    // smk_kbd board (ESP32-C6-MINI-1) — GPIO map per that PCB's
    // README (source of truth for firmware pin assignments):
    //   ROW0-3 = IO0-IO3, ROW4 = IO5 (sense inputs, pull-down)
    //   COL0-11 = IO6, IO7, IO8, IO14, IO15, IO18, IO19, IO20, IO21, IO22,
    //             IO23, IO17 (strobe outputs)
    //   IO4 is reserved for the battery-sense ADC (VBAT/2 divider) on this
    //   board and must NOT be used by the matrix.
    // colsAreDriven:1 because this board's matrix is COL2ROW (diode anode
    // at the column/switch side) — see KeyMatrix.swift for why that means
    // columns must be the driven/output side, not rows.
    //
    // Row 4 layout is irregular per the PCB: 5 keys (cols 0-4), one 2U key
    // (col 5), no switch at col 6, then 5 more keys (cols 7-11) — 59
    // physical keys total over the 5x12 = 60 matrix positions.
    //
    // This board has no per-key RGB chain and no CH9350 wired-HID bridge —
    // see notes below on both. Also the default for plain Pico/Pico W builds
    // (SMK_TARGET_BOARD unset) — rewire your own dev board to match, or edit
    // this JSON, per the RP2040 port README.
    let configJson = """
    {
        "matrix": {
            "rows": [0, 1, 2, 3, 5],
            "cols": [6, 7, 8, 14, 15, 18, 19, 20, 21, 22, 23, 17],
            "colsAreDriven": 1
        },
        "layers": [
            [
                ["key:1", "key:2", "key:3", "key:4", "key:5", "key:6", "key:7", "key:8", "key:9", "key:0", "key:minus", "key:backspace"],
                ["key:tab", "key:q", "key:w", "key:e", "key:r", "key:t", "key:y", "key:u", "key:i", "key:o", "key:p", "key:backslash"],
                ["key:escape", "key:a", "key:s", "key:d", "key:f", "key:g", "key:h", "key:j", "key:k", "key:l", "key:semicolon", "key:enter"],
                ["mod:leftShift", "key:z", "key:x", "key:c", "key:v", "key:b", "key:n", "key:m", "key:comma", "key:period", "key:slash", "mod:rightShift"],
                ["mod:leftCtrl", "mod:leftGUI", "mod:leftAlt", "mo:1", "mod:leftShift", "key:space", "none", "mod:rightShift", "mo:1", "mod:rightAlt", "mod:rightGUI", "mod:rightCtrl"]
            ],
            [
                ["toggle_conn", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans"],
                ["trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans"],
                ["trans", "trans", "trans", "trans", "trans", "trans", "key:left", "key:down", "key:up", "key:right", "trans", "trans"],
                ["trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans", "trans"],
                ["trans", "trans", "trans", "trans", "trans", "trans", "none", "trans", "trans", "trans", "trans", "trans"]
            ]
        ]
    }
    """
#endif

    let cfg = Config.fromJson(configJson)
    if cfg.rowPins.isEmpty || cfg.colPins.isEmpty {
        kb_log("Critical Error: No matrix defined in JSON")
        return
    }

    // Initialize Hardware with dynamic pins
    let matrix = KeyMatrix(rowPins: cfg.rowPins, colPins: cfg.colPins, colsAreDriven: cfg.colsAreDriven)
    var debouncer = DebouncedMatrix(totalKeys: cfg.rowPins.count * cfg.colPins.count)
    var engine = LayerEngine()
    var report = HIDReport()

    // Per-key RGB backlight — opt-in, off by default. The stock smk_kbd
    // PCB has no SK6812MINI-E chain (just a fixed charge-status LED), so
    // there's nothing to drive unless you've wired one up yourself. Enable
    // via `idf.py menuconfig` -> SMK Keyboard Configuration ->
    // SMK_HAS_RGB_BACKLIGHT, and set SMK_RGB_GPIO to match your wiring
    // (defaults to IO16, the PCB's one documented spare/unconnected pad).
    // Guarded against colliding with a matrix pin, since GPIO0 (the old
    // hardcoded default) is ROW0 here and would silently break scanning.
    #if SMK_RGB_AVAILABLE
    var rgb: RGBLighting? = nil
    if smk_has_rgb_backlight() != 0 {
        let ledPin = smk_rgb_gpio()
        if cfg.rowPins.contains(ledPin) || cfg.colPins.contains(ledPin) {
            kb_log("RGB backlight disabled: SMK_RGB_GPIO collides with a matrix pin")
        } else {
            rgb = RGBLighting(gpioNum: ledPin, rowCount: cfg.rowPins.count, colCount: cfg.colPins.count)
            kb_log("RGB backlight enabled")
        }
    }
    #endif

    // Initialize BLE Link
    init_ble_hid()

    // Initialize Wired Link — only if this board actually has the CH9350
    // bridge (Kconfig SMK_HAS_WIRED_BRIDGE / RP2040 hardcoded true). The
    // smk_kbd board doesn't: its UART1 RX pin (GPIO20) is also a
    // matrix column, so claiming it for UART here would break scanning.
    let hasWiredBridge = smk_has_wired_bridge() != 0
    if hasWiredBridge {
        init_wired_link()
    }

    var currentMode: ConnectionMode = (hasWiredBridge && smk_default_mode_is_wired() != 0) ? .wired : .bluetooth
    kb_log(currentMode == .wired ? "Default connection mode: WIRED" : "Default connection mode: BLUETOOTH")

    // Factory-reset escape hatch: hold the key at row 0 / col 0 during boot
    // to erase the stored keymap and fall back to the compiled default.
    // Uses the same per-iteration vTaskDelay(1) unit as the main scan loop
    // below, so the actual wall-clock hold time follows whatever "1 tick"
    // means on this platform already (~1s intended — time it with a
    // stopwatch during hardware testing and adjust resetHoldScans if it
    // feels too short or too long). This runs before the store is even
    // consulted, so it works even if a bad uploaded keymap somehow makes
    // the upload/erase command itself unreachable.
    let resetHoldScans = 100
    var resetHeld = true
    for _ in 0..<resetHoldScans {
        if !matrix.scan()[0] { // row 0, col 0
            resetHeld = false
            break
        }
        vTaskDelay(1)
    }
    if resetHeld {
        smk_keymap_erase()
        kb_log("Factory reset: stored keymap erased, using compiled default")
    }

    // Load a previously-uploaded keymap from the on-device store in place
    // of the compiled default. keymapBufSize must exceed the store's
    // SMK_KEYMAP_MAX_LEN (4085) by at least 1 byte for the null terminator.
    let keymapBufSize = 4096
    var keymapBuf = [Int8](repeating: 0, count: keymapBufSize)
    var loadedFromStore = false
    if !resetHeld {
        let storedLen = keymapBuf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return smk_keymap_load(base, UInt32(ptr.count))
        }
        if storedLen >= 0 {
            keymapBuf[Int(storedLen)] = 0
            loadedFromStore = true
        }
    }

    if loadedFromStore {
        keymapBuf.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                engine.loadKeymap(cJsonStr: base)
            }
        }
        if engine.keymaps.isEmpty {
            kb_log("Stored keymap invalid, falling back to compiled default")
            engine.loadKeymap(json: configJson)
        } else {
            kb_log("Loaded keymap from on-device store")
        }
    } else {
        engine.loadKeymap(json: configJson)
    }

    let totalKeys = cfg.rowPins.count * cfg.colPins.count
    let colCount = cfg.colPins.count
    var lastScan = [Bool](repeating: false, count: totalKeys)
    var pressedActions: [KeyAction] = [KeyAction](repeating: .none, count: totalKeys)

    while true {
        let rawScan = matrix.scan()
        let cleanScan = debouncer.update(rawScan: rawScan)

        // 1. Process Edges (Press/Release)
        for i in 0..<totalKeys {
            let row = i / colCount
            let col = i % colCount

            if cleanScan[i] && !lastScan[i] {
                // Key Pressed
                let action = engine.getAction(row: row, col: col)
                pressedActions[i] = action
                #if SMK_RGB_AVAILABLE
                rgb?.setKey(row: row, col: col, r: 255, g: 255, b: 255)
                #endif

                switch action {
                case .toggleLayer(let l):
                    engine.toggleLayer(l)
                case .momentaryLayer(let l):
                    engine.addMomentaryLayer(l)
                case .toggleConnection:
                    if hasWiredBridge {
                        currentMode.toggle()
                        kb_log(currentMode == .wired ? "Connection switched to: WIRED" : "Connection switched to: BLUETOOTH")
                    } else {
                        kb_log("toggle_conn ignored: this board has no wired HID bridge")
                    }
                default:
                    break
                }
            } else if lastScan[i] && !cleanScan[i] { // Key Released
                let action = pressedActions[i]
                #if SMK_RGB_AVAILABLE
                rgb?.setKey(row: row, col: col, r: 0, g: 0, b: 0)
                #endif

                switch action {
                case .momentaryLayer(let l):
                    engine.removeMomentaryLayer(l)
                default:
                    break
                }
                pressedActions[i] = .none
            }
        }
        lastScan = cleanScan
        #if SMK_RGB_AVAILABLE
        rgb?.refreshIfDirty()
        #endif

        // 2. Build and Send HID Report
        report.reset()
        for i in 0..<totalKeys {
            if cleanScan[i] {
                let action = pressedActions[i]
                switch action {
                case .key(let code):
                    report.addKey(code.rawValue)
                case .modifier(let mod):
                    report.addModifier(mod)
                default:
                    break
                }
            }
        }

        // 3. Dispatch Reports based on active mode
        report.keys.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                if currentMode == .bluetooth {
                    send_keyboard_report(report.modifier, base)
                } else {
                    send_wired_report(report.modifier, base)
                }
            }
        }

        vTaskDelay(1)
    }
}
