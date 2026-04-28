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

    static func fromName(_ name: String) -> KeyCode {
        switch name {
        case "a": return .a
        case "b": return .b
        case "c": return .c
        case "d": return .d
        case "e": return .e
        case "f": return .f
        case "g": return .g
        case "h": return .h
        case "i": return .i
        case "j": return .j
        case "k": return .k
        case "l": return .l
        case "m": return .m
        case "n": return .n
        case "o": return .o
        case "p": return .p
        case "q": return .q
        case "r": return .r
        case "s": return .s
        case "t": return .t
        case "u": return .u
        case "v": return .v
        case "w": return .w
        case "x": return .x
        case "y": return .y
        case "z": return .z
        case "1": return .k1
        case "2": return .k2
        case "3": return .k3
        case "4": return .k4
        case "5": return .k5
        case "6": return .k6
        case "7": return .k7
        case "8": return .k8
        case "9": return .k9
        case "0": return .k0
        case "enter": return .enter
        case "escape": return .escape
        case "backspace": return .backspace
        case "tab": return .tab
        case "space": return .space
        default: return .noKey
        }
    }
}

extension Modifier {
    static func fromName(_ name: String) -> Modifier {
        switch name {
        case "leftCtrl": return .leftCtrl
        case "leftShift": return .leftShift
        case "leftAlt": return .leftAlt
        case "leftGUI": return .leftGUI
        case "rightCtrl": return .rightCtrl
        case "rightShift": return .rightShift
        case "rightAlt": return .rightAlt
        case "rightGUI": return .rightGUI
        default: return .leftCtrl // Default fallback
        }
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

    static func fromString(_ str: String) -> KeyAction {
        if str == "none" { return .none }
        if str == "trans" || str == "transparent" { return .transparent }
        if str == "toggle_conn" { return .toggleConnection }

        // Manual prefix parsing for Embedded Swift
        if str.hasPrefix("key:") {
            let name = String(str.dropFirst(4))
            return .key(KeyCode.fromName(name))
        }
        if str.hasPrefix("mod:") {
            let name = String(str.dropFirst(4))
            return .modifier(Modifier.fromName(name))
        }
        if str.hasPrefix("mo:") {
            let val = Int(str.dropFirst(3)) ?? 0
            return .momentaryLayer(val)
        }
        if str.hasPrefix("tg:") {
            let val = Int(str.dropFirst(3)) ?? 0
            return .toggleLayer(val)
        }

        return .none
    }
}

struct LayerEngine {
    private var toggledLayers: [Bool] = [Bool](repeating: false, count: 16)
    private var momentaryCounts: [Int] = [Int](repeating: 0, count: 16)

    // Dynamic keymap
    private(set) var keymaps: [[[KeyAction]]] = [
        [ // Default fallback keymap (Layer 0)
            [.key(.a), .key(.enter), .none, .none, .none, .none, .none, .none, .none, .none, .none, .none],
            [.none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none],
            [.none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none],
            [.none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none],
            [.modifier(.leftShift), .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none]
        ]
    ]
    
    mutating func loadKeymap(json: String) {
        guard let root = cJSON_Parse(json) else {
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
                        let actionStr = String(cString: cStr)
                        row.append(KeyAction.fromString(actionStr))
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
