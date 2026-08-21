#if canImport(CJSON)
import CJSON
#endif

// Host-only: strcmp/strncmp/atoi come from the bridging header (newlib) on
// the embedded builds, but the host SMKCore build needs them imported
// explicitly since cJSON.h only pulls in <stddef.h>, not <string.h>.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// KeyCode lives in KeyCodesGenerated.swift now -- generated from
// ~/esp/SMK/keycodes.json by generate_keycodes.sh, which emits the matching
// KeyName into smk_configurator from the same manifest. The grammar below
// (KeyAction's key:/mod:/mo:/tg: prefix dispatch) stays hand-written; only the
// vocabulary it dispatches into is generated.

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

enum KeyAction: Equatable {
    case none
    case key(KeyCode)
    case modifier(Modifier)
    case momentaryLayer(Int)
    case toggleLayer(Int)
    case transparent
    case toggleConnection
    /// Runs the macro in slot `n`. Must stay in lockstep with
    /// `ActionToken.macro` in the configurator.
    case macro(Int)

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
        if strncmp(cStr, "macro:", 6) == 0 {
            let rest = cStr.advanced(by: 6)
            // atoi returns 0 for non-numeric input, which would silently
            // turn "macro:abc" into .macro(0) -- a real macro slot. Guard
            // that the first character after the prefix is actually a
            // digit before trusting atoi's result.
            let firstChar = rest.pointee
            if firstChar >= 0x30 && firstChar <= 0x39 {
                return .macro(Int(atoi(rest)))
            }
            return .none
        }

        return .none
    }
}

struct LayerEngine {
    private var toggledLayers: [Bool] = [Bool](repeating: false, count: 16)
    private var momentaryCounts: [Int] = [Int](repeating: 0, count: 16)

    private(set) var keymaps: [[[KeyAction]]] = []
    
    mutating func loadKeymap(json: String) {
        json.withCString { loadKeymap(cJsonStr: $0) }
    }

    // Parses a keymap already available as a C string — used both by
    // loadKeymap(json:) above (compiled-in default) and by Main.swift's
    // stored-keymap boot path (a null-terminated buffer read from the
    // on-device keymap store), which is already a C buffer and shouldn't be
    // round-tripped through a Swift String just to get back to one.
    mutating func loadKeymap(cJsonStr: UnsafePointer<Int8>) {
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
