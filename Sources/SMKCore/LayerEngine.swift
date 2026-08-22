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
    /// Macros decoded from the version-2 binary payload by
    /// `loadKeymap(binary:count:)`. Always empty on the JSON
    /// (`loadKeymap(json:)`/`loadKeymap(cJsonStr:)`) path -- macros never
    /// rode in the JSON format.
    private(set) var macros: [MacroDefinition] = []

    mutating func loadKeymap(json: String) {
        json.withCString { loadKeymap(cJsonStr: $0) }
    }

    // Loads a keymap from a version-2 binary payload -- the bytes
    // immediately following the 11-byte frame header, once
    // `smkKeymapFrameValidate` has already confirmed the frame's magic,
    // version, length and CRC. `bytes` must point to at least `count`
    // readable bytes. See KeymapBinary.swift and
    // docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md for
    // the payload layout this decodes.
    //
    // Mirrors loadKeymap(cJsonStr:)'s caution around a malformed/empty
    // result: an undecodable payload or a payload with zero layers leaves
    // `keymaps` untouched rather than clobbering a previously-loaded (or
    // compiled-in default) keymap with nothing. `macros` is always replaced
    // with whatever decoded, including an empty list -- a keymap legitimately
    // can have zero macros, unlike zero layers.
    mutating func loadKeymap(binary bytes: UnsafePointer<UInt8>, count: Int) {
        guard let payload = decodeKeymapPayload(bytes, count: count) else {
            kb_log("Binary keymap payload invalid")
            return
        }

        // `decodeKeymapPayload` now refuses a declared layer with a 0x0
        // matrix at the source, so `payload.layers` being non-empty should
        // already guarantee usable cells -- but `getAction`'s only defense
        // for a keyboard is the data actually loaded here, so check for
        // real content directly rather than trusting that invariant to
        // hold forever as the decoder evolves. A layers array whose every
        // layer is itself empty (no rows, or rows with no cells) is exactly
        // as unusable as an empty layers array: every `getAction` call
        // would resolve to `.none`, forever, recoverable only via the
        // reset-held boot path -- so it must be refused the same way.
        let hasUsableCells = payload.layers.contains { layer in
            layer.contains { row in !row.isEmpty }
        }
        // All-or-nothing: an invalid payload must not clobber working
        // state, and that has to include `macros`, not just `keymaps`. This
        // used to assign `self.macros = payload.macros` unconditionally,
        // so a rejected (e.g. `layerCount == 0`) payload still installed
        // its macros while the keymap fell back to the compiled default --
        // contradicting the rule stated above. Harmless today only because
        // the compiled default has no `macro:` cells to trigger them; still
        // wrong on its own terms.
        if !payload.layers.isEmpty && hasUsableCells {
            self.keymaps = payload.layers
            self.macros = payload.macros
            // Says "binary" rather than just "loaded" because the JSON
            // loader below logs from the same message otherwise, and after
            // the v1->v2 format migration the one thing worth knowing from
            // a boot log is which format the board actually accepted.
            // Reading the source to work that out -- as I had to after the
            // first hardware flash -- is exactly the diagnosis this line
            // should be saving someone.
            kb_log("Keymap loaded successfully (binary)")
        }
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
            // See the binary loader's note: these two must stay
            // distinguishable in a boot log.
            kb_log("Keymap loaded successfully (JSON)")
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
