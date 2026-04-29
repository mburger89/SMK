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

enum ConnectionMode {
    case wired
    case bluetooth

    mutating func toggle() {
        if self == .wired {
            self = .bluetooth
        } else {
            self = .wired
        }
    }
}

struct HIDReport {
    var modifier: UInt8 = 0
    var keys: [UInt8] = [0, 0, 0, 0, 0, 0]

    mutating func reset() {
        modifier = 0
        for i in 0..<keys.count { keys[i] = 0 }
    }

    mutating func addKey(_ keycode: UInt8) {
        if keycode == 0 { return }
        for i in 0..<keys.count {
            if keys[i] == 0 {
                keys[i] = keycode
                return
            }
        }
    }

    mutating func addModifier(_ mod: Modifier) {
        modifier |= mod.rawValue
    }
}

struct Config {
    var rowPins: [Int32] = []
    var colPins: [Int32] = []

    static func fromJson(_ json: String) -> Config {
        var cfg = Config()
        guard let root = cJSON_Parse(json) else { return cfg }
        defer { cJSON_Delete(root) }

        if let matrix = cJSON_GetObjectItem(root, "matrix") {
            if let rows = cJSON_GetObjectItem(matrix, "rows") {
                for i in 0..<cJSON_GetArraySize(rows) {
                    if let item = cJSON_GetArrayItem(rows, i) {
                        cfg.rowPins.append(Int32(item.pointee.valuedouble))
                    }
                }
            }
            if let cols = cJSON_GetObjectItem(matrix, "cols") {
                for i in 0..<cJSON_GetArraySize(cols) {
                    if let item = cJSON_GetArrayItem(cols, i) {
                        cfg.colPins.append(Int32(item.pointee.valuedouble))
                    }
                }
            }
        }
        return cfg
    }
}

@_cdecl("app_main_swift")
func app_main_swift() {
    kb_log("Initialising SMK Keyboard...")

    // Sample JSON Configuration (Includes matrix definition)
    let configJson = """
    {
        "matrix": {
            "rows": [0, 1, 2, 3, 4],
            "cols": [5, 6, 7, 9, 10, 11, 18, 19, 20, 21, 22, 23]
        },
        "layers": [
            [
                ["key:a", "key:s", "key:d", "key:f", "key:g", "key:h", "key:j", "key:k", "key:l", "key:enter", "none", "none"],
                ["none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none"],
                ["none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none"],
                ["none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none"],
                ["mod:leftShift", "mo:1", "tg:2", "toggle_conn", "none", "none", "none", "none", "none", "none", "none", "none"]
            ],
            [
                ["key:1", "key:2", "key:3", "key:4", "key:5", "key:6", "key:7", "key:8", "key:9", "key:0", "none", "none"],
                ["none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none"],
                ["none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none"],
                ["none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none", "none"],
                ["trans", "trans", "trans", "none", "none", "none", "none", "none", "none", "none", "none", "none"]
            ]
        ]
    }
    """

    let cfg = Config.fromJson(configJson)
    if cfg.rowPins.isEmpty || cfg.colPins.isEmpty {
        kb_log("Critical Error: No matrix defined in JSON")
        return
    }

    // Initialize Hardware with dynamic pins
    let matrix = KeyMatrix(rowPins: cfg.rowPins, colPins: cfg.colPins)
    var debouncer = DebouncedMatrix(totalKeys: cfg.rowPins.count * cfg.colPins.count)
    var engine = LayerEngine()
    var report = HIDReport()

    // Initialize BLE Link
    init_ble_hid()

    // Initialize Wired Link (CH9350)
    init_wired_link()

    var currentMode = ConnectionMode.wired
    kb_log("Default connection mode: WIRED")

    engine.loadKeymap(json: configJson)

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

                switch action {
                case .toggleLayer(let l):
                    engine.toggleLayer(l)
                case .momentaryLayer(let l):
                    engine.addMomentaryLayer(l)
                case .toggleConnection:
                    currentMode.toggle()
                    if currentMode == .wired {
                        kb_log("Connection switched to: WIRED")
                    } else {
                        kb_log("Connection switched to: BLUETOOTH")
                    }
                default:
                    break
                }
            } else if !lastScan[i] && cleanScan[i] == false { // Key Released
                let action = pressedActions[i]

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

        vTaskDelay(10) 
    }
}
