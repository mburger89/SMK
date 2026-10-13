// The Swift Programming Language
// https://docs.swift.org/swift-book

// Platform functions the shared scan loop calls — init_ble_hid,
// send_keyboard_report, vTaskDelay, kb_log, smk_has_wired_bridge,
// smk_default_mode_is_wired — need no declaration in this file. On each
// target they are either a same-module Swift definition (ESP32-C6:
// BleHelper.swift/SmkConfig.swift; RP2040:
// BleHidPicoW.swift/BleHidKbdUart.swift/PlatformConfig.swift; nRF52840 and
// STM32WB: ports/common/BleHidGatt.swift for send_keyboard_report), or a C
// function whose prototype the target's bridging header already imports:
// vTaskDelay via FreeRTOS on ESP32-C6 (Sources/smk/Bridging.h), and the
// platform_glue.c / ble_hid_wb.c / BleHidSdc.swift-backed ones via
// ports/{nrf52840,samd21,stm32f4,stm32wb}/BridgingHeader.h. A redundant
// @_extern(c, ...) here would only shadow the imported prototype, and a
// same-module Swift definition can't coexist with one at all ("invalid
// redeclaration").
//
// init_wired_link/send_wired_report: every board backs these natively in
// Swift, same-module resolution — ESP32-C6 via WiredHidUart.swift, each
// ARM port via its own UsbHid.swift.

// RGB backlight config (smk_has_rgb_backlight/smk_rgb_gpio) — both boards
// that compile RGBLighting.swift in (ESP32-C6 via -DSMK_RGB_AVAILABLE in
// main/CMakeLists.txt; smk_kbd_rp2040 via SMK_RGB_AVAILABLE in
// ports/rp2040/CMakeLists.txt) now provide these as plain, same-module
// Swift functions — ESP32-C6 in SmkConfig.swift, RP2040 in
// ports/rp2040/LedStripDriverPIO.swift (Task 10). No @_extern declaration
// needed or permitted here for either: a same-module Swift definition can't
// coexist with an @_extern(c, ...) forward declaration of the same name
// ("invalid redeclaration").

// Loads this board's compiled-in default keymap -- the binary payload
// generated from boards/<name>.json into
// Sources/SMKCore/DefaultKeymapGenerated.swift by ./generate_default_keymap.sh.
//
// Every board takes this path. The five bring-up boards that used to parse
// their own JSON literal here were migrated when cJSON was retired
// (docs/superpowers/specs/2026-08-21-retire-cjson-design.md); the layout a
// board gets is selected by the same SMK_BOARD_* flags that used to select
// its literal, in the generated file's own `#if` chain.
//
// The board's GPIO matrix comes from the *same* payload, via
// `Config(payload:)` in app_main_swift below -- one artifact, so the matrix
// and the layers cannot disagree about how many rows and columns exist.
func loadCompiledDefaultKeymap(into engine: inout LayerEngine) {
    engine.loadKeymap(defaultKeymapBytes.span)
}

// Applies the layer effects `MacroPlayer.tick()` handed back for a `.layer`
// macro step (or for the end of a macro run) -- the player is pure and
// cannot call these itself (see MacroPlayer.swift's `LayerEffect` doc
// comment), so this main-loop arbitration is the only place that does.
// `.momentary`/`.toggle` mirror the press-transition half of
// `KeyEventProcessing.processKeyEvents`'s `.momentaryLayer`/`.toggleLayer`
// handling. `.momentaryRelease` is the player's own doing, not a macro
// step: it releases a momentary layer the same run pushed earlier, emitted
// when that run terminates (clean finish or an abort alike) so a momentary
// layer never stays stuck active with no macro left to release it -- there
// is no "release layer" step type a macro author could write themselves.
// Applied in order, since a single tick can carry more than one effect
// (consecutive `.layer` steps each consume no tick of their own, and a
// terminating tick's pushes-just-now precede that same tick's releases).
func applyMacroLayerEffects(_ effects: [LayerEffect], to engine: inout LayerEngine) {
    for effect in effects {
        switch effect {
        case .momentary(let layer, let count):
            // `count` collapses what used to be `count` separate
            // `.momentary` entries (one per push within a tick, or across
            // a whole run for the matching release below) into one -- see
            // `LayerEffect`'s doc comment. Applying it via `count`
            // individual pushes is exactly equivalent, since
            // `addMomentaryLayer` only ever increments one per-layer `Int`.
            for _ in 0..<count {
                engine.addMomentaryLayer(layer)
            }
        case .toggle(let layer):
            engine.toggleLayer(layer)
        case .momentaryRelease(let layer, let count):
            for _ in 0..<count {
                engine.removeMomentaryLayer(layer)
            }
        }
    }
}

@c
func app_main_swift() {
    kb_log("Initialising SMK Keyboard...")

    // Board pin map. Exactly one board's layout is compiled in, selected by
    // the build's SMK_BOARD_* flag (ports/*/CMakeLists.txt for every target
    // except ESP32-C6, whose main/CMakeLists.txt defines SMK_BOARD_TEST_BOARD
    // only when Kconfig's SMK_BOARD choice selects the test board, and
    // otherwise defines nothing so the generated file's `#else` -- the
    // reference smk_kbd board -- applies; see main/Kconfig.projbuild for why
    // that one target picks its board via Kconfig rather than a hardcoded
    // CMake define). The layouts themselves live in boards/*.json.
    //
    // All boards share the same keymap-cell vocabulary, but NOT the same
    // matrix topology: smk_kbd_rp2040, the ESP32-C6 smk_kbd board and the
    // SMK test board are all COL2ROW (`colsAreDriven: true` -- diode anode
    // at the column/switch side), while nrf52840dk is the opposite
    // (`colsAreDriven: false`) -- see KeyMatrix.swift for what that flag
    // changes about the scan direction.
    //
    // Both the matrix and the layers come from the one compiled-in binary
    // payload. It is decoded twice on purpose -- once here for the matrix,
    // once in loadCompiledDefaultKeymap below for the layers -- rather than
    // adding a payload-taking entry point to LayerEngine for a boot-time-only
    // saving of a few hundred bytes of transient allocation.
    //
    // Note this is always the *compiled-in* payload, never a stored one: an
    // uploaded keymap carries its own rows/cols header, but letting it
    // re-map GPIO would let a configurator bug leave a board unable to scan
    // even the keys needed to recover. A stored keymap contributes layers
    // and macros only (see the store path further down).
    let cfg: Config
    do { cfg = Config(payload: try decodeKeymapPayload(defaultKeymapBytes.span)) }
    catch {
        // Unreachable short of a generator bug -- these bytes are compiled
        // in, not read from storage. An empty Config makes the check below
        // fail loudly rather than scanning undefined pins.
        kb_log("Critical Error: compiled-in keymap payload did not decode")
        cfg = Config()
    }
    if cfg.rowPins.isEmpty || cfg.colPins.isEmpty {
        // KNOWN CONSEQUENCE, deliberately preserved rather than fixed here:
        // feather_nrf52840 declares an empty matrix on purpose (nothing is
        // wired to that board), so it takes this branch and app_main_swift
        // returns *before* init_wired_link() further down ever runs -- so
        // USB never initialises on the one board whose entire bring-up goal
        // is USB enumeration. This predates the cJSON retirement: the JSON
        // path hit the identical check with the identical result, so the
        // migration changed nothing about it. Fixing it is a separate
        // change; note that CLAUDE.md's Feather section currently attributes
        // that board's silence solely to a missing SCB->VTOR relocation.
        kb_log("Critical Error: no matrix defined for this board")
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

    // Initialize BLE Link. Skipped on the Feather nRF52840 Express bring-up
    // board: this pass's scope is USB HID enumeration only (see CLAUDE.md's
    // Feather nRF52840 Express section) — the BLE code itself is identical
    // to the nrf52840dk build (not board-gated at the platform_glue.c/
    // BleHidSdc.swift level), so it stays linked in but dormant here rather
    // than needing a separate build configuration.
    #if !SMK_BOARD_FEATHER_NRF52840
    init_ble_hid()
    #endif

    // Battery-level reporting (smk_kbd board / ESP32-C6 only — see
    // BatteryMonitor.swift). RP2040/nRF52840 have no VBAT ADC divider
    // wired to this firmware and no esp_hidd Battery Service, so this is
    // a no-op there rather than a stub function that would need externing.
    #if SMK_TARGET_ESP32C6
    initBatteryMonitor()
    #endif

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
    // SMK_KEYMAP_MAX_LEN (4085) -- the buffer now holds a raw binary
    // (frame version 2) payload, not a null-terminated JSON C string, so
    // the old "+1 for the null terminator" no longer applies; kept as
    // slack above smkKeymapMaxLen regardless. Stays a heap array: it is
    // filled once at boot, never per report, and 4 KB is too much to put
    // on the smaller ports' main stacks.
    let keymapBufSize = 4096
    var keymapBuf = [UInt8](repeating: 0, count: keymapBufSize)
    var loadedFromStore = false
    // Declared outside the `if !resetHeld` block: smk_keymap_load's return
    // is also the exact payload byte count `loadKeymap(_:)`'s span below
    // needs, not just a load/no-load flag.
    var storedLen: Int32 = -1
    if !resetHeld {
        storedLen = keymapBuf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return smk_keymap_load(base, UInt32(ptr.count))
        }
        if storedLen >= 0 {
            loadedFromStore = true
        }
    }

    if loadedFromStore {
        // smk_keymap_load already ran smkKeymapFrameValidate (magic,
        // frameVersion == 2, length, CRC32) before returning a
        // non-negative length, so what's sitting in keymapBuf is a
        // validated version-2 binary payload -- decode it as one, not as
        // a JSON C string (the two used to be the same null-terminated
        // buffer by coincidence; they have not been since the frame
        // format moved to binary). Span storedLen, the real payload byte
        // count, not keymapBufSize (the buffer's capacity) --
        // decodeKeymapPayload refuses trailing bytes by design, so a span
        // longer than the actual payload makes it reject good data instead
        // of accepting garbage.
        engine.loadKeymap(keymapBuf.span.extracting(0..<Int(storedLen)))
        if engine.keymaps.isEmpty {
            kb_log("Stored keymap invalid, falling back to compiled default")
            loadCompiledDefaultKeymap(into: &engine)
        } else {
            kb_log("Loaded keymap from on-device store")
        }
    } else {
        loadCompiledDefaultKeymap(into: &engine)
    }

    let totalKeys = cfg.rowPins.count * cfg.colPins.count
    let colCount = cfg.colPins.count
    var lastScan = KeyBitset()
    // Last report/mode actually handed to a transport — the send-on-change
    // gate at the bottom of the scan loop compares against these.
    var lastSentReport = HIDReport()
    var lastSentMode = currentMode
    var pressedActions: [KeyAction] = [KeyAction](repeating: .none, count: totalKeys)
    var macroPlayer = MacroPlayer()

    #if SMK_TARGET_ESP32C6
    // Battery voltage changes slowly, so polling it every scan tick would
    // just waste ADC conversion time for no benefit. vTaskDelay(1) below is
    // one real FreeRTOS tick (10ms at this project's default
    // CONFIG_FREERTOS_HZ=100), so 2000 scan iterations is roughly 20
    // seconds between reads — approximate, not calibrated against a
    // stopwatch on real hardware.
    let batteryPollIntervalScans = 2000
    var scansSinceLastBatteryPoll = 0
    #endif

    while true {
        let rawScan = matrix.scan()
        let cleanScan = debouncer.update(rawScan: rawScan)

        let result = processKeyEvents(
            cleanScan: cleanScan,
            lastScan: lastScan,
            keyCount: totalKeys,
            colCount: colCount,
            pressedActions: &pressedActions,
            engine: &engine,
            hasWiredBridge: hasWiredBridge,
            currentMode: &currentMode
        )
        lastScan = cleanScan

        if !macroPlayer.isActive, let slot = result.macroEvents.first,
           let macro = engine.macros.first(where: { $0.id == slot }) {
            macroPlayer.start(macro)
        }

        if macroPlayer.isActive {
            switch macroPlayer.tick() {
            case .report(let r, let layerEffects):
                report = r
                applyMacroLayerEffects(layerEffects, to: &engine)
            case .finished(let layerEffects):
                // No lastScan reset here, deliberately: processKeyEvents
                // runs every tick against the live matrix regardless of
                // macro state, so a key released mid-playback is already
                // observed the instant it happens -- nothing to repair
                // once the macro ends. A still-held macro key is exactly
                // that case: lastScan already shows it down, so this
                // frame's report clear does NOT produce a fresh press on
                // the next tick, and the macro fires once per press
                // rather than auto-repeating for as long as the key is
                // held. Forcing lastScan back to all-false here was tried
                // and reverted -- it reintroduced the "Repeat while held"
                // behavior this project deliberately dropped elsewhere for
                // having no model field behind it.
                report = HIDReport()
                applyMacroLayerEffects(layerEffects, to: &engine)
            case .idle: break
            }
        } else {
            report = result.report
        }

        #if SMK_RGB_AVAILABLE
        for t in result.transitions {
            if t.pressed {
                rgb?.setKey(row: t.position.row, col: t.position.col, r: 255, g: 255, b: 255)
            } else {
                rgb?.setKey(row: t.position.row, col: t.position.col, r: 0, g: 0, b: 0)
            }
        }
        rgb?.refreshIfDirty()
        #endif

        for event in result.connectionEvents {
            switch event {
            case .toggled(let mode):
                kb_log(mode == .wired ? "Connection switched to: WIRED" : "Connection switched to: BLUETOOTH")
            case .ignored:
                kb_log("toggle_conn ignored: this board has no wired HID bridge")
            }
        }

        // Send only when the report actually changed (or the transport mode
        // did) — HID hosts only need deltas. The previous unconditional
        // per-tick send meant a connected BLE host received a ~100Hz
        // notification stream around the clock (observed live against an
        // iPhone: thousands of identical notify procedures), wasting
        // airtime and battery on every target.
        if report != lastSentReport || currentMode != lastSentMode {
            report.withKeyBytes { base in
                if currentMode == .bluetooth {
                    send_keyboard_report(report.modifier, base)
                } else {
                    send_wired_report(report.modifier, base)
                }
            }
            lastSentReport = report
            lastSentMode = currentMode
        }

        #if SMK_TARGET_ESP32C6
        scansSinceLastBatteryPoll += 1
        if scansSinceLastBatteryPoll >= batteryPollIntervalScans {
            scansSinceLastBatteryPoll = 0
            pollBatteryLevel()
        }
        #endif

        vTaskDelay(1)
    }
}
