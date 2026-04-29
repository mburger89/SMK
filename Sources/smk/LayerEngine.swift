// Keycodes based on HID standards
enum KeyCode: UInt8 {
    case noKey
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case k1, k2, k3, k4, k5, k6, k7, k8, k9, k0
    case enter
    case escape
    case backspace
    case tab
    case space
    case transparent // Like QMK's KC_TRNS

    var rawValue: UInt8 {
        switch self {
        case .noKey: return 0x00
        case .a: return 0x04
        case .b: return 0x05
        case .c: return 0x06
        case .d: return 0x07
        case .e: return 0x08
        case .f: return 0x09
        case .g: return 0x0A
        case .h: return 0x0B
        case .i: return 0x0C
        case .j: return 0x0D
        case .k: return 0x0E
        case .l: return 0x0F
        case .m: return 0x10
        case .n: return 0x11
        case .o: return 0x12
        case .p: return 0x13
        case .q: return 0x14
        case .r: return 0x15
        case .s: return 0x16
        case .t: return 0x17
        case .u: return 0x18
        case .v: return 0x19
        case .w: return 0x1A
        case .x: return 0x1B
        case .y: return 0x1C
        case .z: return 0x1D
        case .k1: return 0x1E
        case .k2: return 0x1F
        case .k3: return 0x20
        case .k4: return 0x21
        case .k5: return 0x22
        case .k6: return 0x23
        case .k7: return 0x24
        case .k8: return 0x25
        case .k9: return 0x26
        case .k0: return 0x27
        case .enter: return 0x28
        case .escape: return 0x29
        case .backspace: return 0x2A
        case .tab: return 0x2B
        case .space: return 0x2C
        case .transparent: return 0xFF
        }
    }

    static func fromCString(_ cStr: UnsafePointer<Int8>) -> KeyCode {
        // Use strcmp for direct byte comparison to avoid Swift String normalization
        if strcmp(cStr, "a") == 0 { return .a }
        if strcmp(cStr, "b") == 0 { return .b }
        if strcmp(cStr, "c") == 0 { return .c }
        if strcmp(cStr, "d") == 0 { return .d }
        if strcmp(cStr, "e") == 0 { return .e }
        if strcmp(cStr, "f") == 0 { return .f }
        if strcmp(cStr, "g") == 0 { return .g }
        if strcmp(cStr, "h") == 0 { return .h }
        if strcmp(cStr, "i") == 0 { return .i }
        if strcmp(cStr, "j") == 0 { return .j }
        if strcmp(cStr, "k") == 0 { return .k }
        if strcmp(cStr, "l") == 0 { return .l }
        if strcmp(cStr, "m") == 0 { return .m }
        if strcmp(cStr, "n") == 0 { return .n }
        if strcmp(cStr, "o") == 0 { return .o }
        if strcmp(cStr, "p") == 0 { return .p }
        if strcmp(cStr, "q") == 0 { return .q }
        if strcmp(cStr, "r") == 0 { return .r }
        if strcmp(cStr, "s") == 0 { return .s }
        if strcmp(cStr, "t") == 0 { return .t }
        if strcmp(cStr, "u") == 0 { return .u }
        if strcmp(cStr, "v") == 0 { return .v }
        if strcmp(cStr, "w") == 0 { return .w }
        if strcmp(cStr, "x") == 0 { return .x }
        if strcmp(cStr, "y") == 0 { return .y }
        if strcmp(cStr, "z") == 0 { return .z }
        if strcmp(cStr, "1") == 0 { return .k1 }
        if strcmp(cStr, "2") == 0 { return .k2 }
        if strcmp(cStr, "3") == 0 { return .k3 }
        if strcmp(cStr, "4") == 0 { return .k4 }
        if strcmp(cStr, "5") == 0 { return .k5 }
        if strcmp(cStr, "6") == 0 { return .k6 }
        if strcmp(cStr, "7") == 0 { return .k7 }
        if strcmp(cStr, "8") == 0 { return .k8 }
        if strcmp(cStr, "9") == 0 { return .k9 }
        if strcmp(cStr, "0") == 0 { return .k0 }
        if strcmp(cStr, "enter") == 0 { return .enter }
        if strcmp(cStr, "escape") == 0 { return .escape }
        if strcmp(cStr, "backspace") == 0 { return .backspace }
        if strcmp(cStr, "tab") == 0 { return .tab }
        if strcmp(cStr, "space") == 0 { return .space }
        return .noKey
    }
}

extension Modifier {
    static func fromCString(_ cStr: UnsafePointer<Int8>) -> Modifier {
        if strcmp(cStr, "leftCtrl") == 0 { return .leftCtrl }
        if strcmp(cStr, "leftShift") == 0 { return .leftShift }
        if strcmp(cStr, "leftAlt") == 0 { return .leftAlt }
        if strcmp(cStr, "leftGUI") == 0 { return .leftGUI }
        if strcmp(cStr, "rightCtrl") == 0 { return .rightCtrl }
        if strcmp(cStr, "rightShift") == 0 { return .rightShift }
        if strcmp(cStr, "rightAlt") == 0 { return .rightAlt }
        if strcmp(cStr, "rightGUI") == 0 { return .rightGUI }
        return .leftCtrl
    }
}

enum KeyAction {
    case none
    case key(KeyCode)
    case modifier(Modifier)
    case momentaryLayer(Int)
    case toggleLayer(Int)
    case transparent
    case toggleConnection

    static func fromCString(_ cStr: UnsafePointer<Int8>) -> KeyAction {
        if strcmp(cStr, "none") == 0 { return .none }
        if strcmp(cStr, "trans") == 0 || strcmp(cStr, "transparent") == 0 { return .transparent }
        if strcmp(cStr, "toggle_conn") == 0 { return .toggleConnection }

        if strncmp(cStr, "key:", 4) == 0 {
            return .key(KeyCode.fromCString(cStr.advanced(by: 4)))
        }
        if strncmp(cStr, "mod:", 4) == 0 {
            return .modifier(Modifier.fromCString(cStr.advanced(by: 4)))
        }
        if strncmp(cStr, "mo:", 3) == 0 {
            let val = Int(atoi(cStr.advanced(by: 3)))
            return .momentaryLayer(val)
        }
        if strncmp(cStr, "tg:", 3) == 0 {
            let val = Int(atoi(cStr.advanced(by: 3)))
            return .toggleLayer(val)
        }

        return .none
    }
}

struct LayerEngine {
    private var toggledLayers: [Bool] = [Bool](repeating: false, count: 16)
    private var momentaryCounts: [Int] = [Int](repeating: 0, count: 16)

    private(set) var keymaps: [[[KeyAction]]] = []
    
    mutating func loadKeymap(json: String) {
        // Use JSON as a C string to avoid Swift String processing
        json.withCString { cJsonStr in
            guard let root = cJSON_Parse(cJsonStr) else {
                kb_log("JSON Parse Error")
                return
            }
            defer { cJSON_Delete(root) }

            guard let layersArray = cJSON_GetObjectItem(root, "layers") else {
                kb_log("JSON Missing 'layers' key")
                return
            }

            let layerCount = cJSON_GetArraySize(layersArray)
            if layerCount == 0 { return }

            var newKeymaps: [[[KeyAction]]] = []

            for i in 0..<layerCount {
                guard let layerObj = cJSON_GetArrayItem(layersArray, i) else { continue }
                let rowCount = cJSON_GetArraySize(layerObj)
                var layer: [[KeyAction]] = []

                for r in 0..<rowCount {
                    guard let rowObj = cJSON_GetArrayItem(layerObj, r) else { continue }
                    let colCount = cJSON_GetArraySize(rowObj)
                    var row: [KeyAction] = []

                    for c in 0..<colCount {
                        guard let cellObj = cJSON_GetArrayItem(rowObj, c) else { continue }
                        if let cStr = cellObj.pointee.valuestring {
                            row.append(KeyAction.fromCString(cStr))
                        } else {
                            row.append(.none)
                        }
                    }
                    layer.append(row)
                }
                newKeymaps.append(layer)
            }

            if !newKeymaps.isEmpty {
                self.keymaps = newKeymaps
                kb_log("Keymap loaded successfully")
            }
        }
    }

    mutating func toggleLayer(_ layer: Int) {
        if layer >= 0 && layer < toggledLayers.count {
            toggledLayers[layer].toggle()
        }
    }

    mutating func addMomentaryLayer(_ layer: Int) {
        if layer >= 0 && layer < momentaryCounts.count {
            momentaryCounts[layer] += 1
        }
    }

    mutating func removeMomentaryLayer(_ layer: Int) {
        if layer >= 0 && layer < momentaryCounts.count {
            momentaryCounts[layer] = max(0, momentaryCounts[layer] - 1)
        }
    }

    func isLayerActive(_ layer: Int) -> Bool {
        if layer == 0 { return true }
        if layer < 0 || layer >= 16 { return false }
        return toggledLayers[layer] || momentaryCounts[layer] > 0
    }

    func getAction(row: Int, col: Int) -> KeyAction {
        for layerIndex in (0..<keymaps.count).reversed() {
            if isLayerActive(layerIndex) {
                if row < keymaps[layerIndex].count && col < keymaps[layerIndex][row].count {
                    let action = keymaps[layerIndex][row][col]
                    if case .transparent = action {
                        continue
                    }
                    return action
                }
            }
        }
        return .none
    }
}
