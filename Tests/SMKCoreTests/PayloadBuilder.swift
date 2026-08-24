import Foundation
import Testing
@testable import SMKCore

// Test-only encoder: keymap tokens -> version-2 binary payload bytes.
//
// This is a fourth implementation of a format that already has three (the
// decoder in KeymapBinary.swift, generate_default_keymap.sh, and the
// configurator's compiler), which is a real cost. It is accepted because the
// alternatives are worse: either keep a JSON parser in the firmware purely
// so tests can stay readable, or write every test's keymap as a hand-counted
// byte array. `builderMatchesShellGenerator` below pins it against the
// generator whose output actually ships, so it cannot drift silently.

/// Encodes one cell the way `decodeCell` (KeymapBinary.swift) reads it.
///
/// Deliberately routed through `KeyAction.fromCString` -- the same token
/// grammar the JSON path used before cJSON was retired -- so a token spelled
/// wrong in a test fails loudly rather than encoding as something plausible.
/// The `switch` is exhaustive on purpose: a new `KeyAction` case must break
/// this build rather than fall into a `default` that encodes it wrong.
private func encodeToken(_ token: String) -> [UInt8] {
    let action = token.withCString { KeyAction.fromCString($0) }
    switch action {
    case .none: return [0, 0]
    case .key(let code): return [1, code.rawValue]
    case .modifier(let mod): return [2, mod.rawValue]
    case .momentaryLayer(let n): return [3, UInt8(n)]
    case .toggleLayer(let n): return [4, UInt8(n)]
    case .transparent: return [5, 0]
    case .toggleConnection: return [6, 0]
    case .macro(let slot): return [7, UInt8(slot)]
    }
}

/// Builds a binary keymap payload from token grids. Macros are not encodable
/// here -- `KeymapBinaryTests` builds those byte-by-byte, which is the right
/// level for testing a bytecode.
func payloadBytes(rows: [UInt8], cols: [UInt8], colsAreDriven: Bool,
                  layers: [[[String]]]) -> [UInt8] {
    var out: [UInt8] = [
        UInt8(rows.count), UInt8(cols.count), colsAreDriven ? 1 : 0,
        UInt8(layers.count), 0, 0,   // macroCount, reserved
    ]
    out += rows
    out += cols
    for layer in layers {
        for row in layer {
            for token in row {
                out += encodeToken(token)
            }
        }
    }
    return out
}

extension LayerEngine {
    /// Loads a keymap written as tokens -- the readability `loadKeymap(json:)`
    /// used to provide. Pin numbers default to `0..<n` because these tests
    /// care about the layer grid, not the GPIO map.
    mutating func loadTestKeymap(_ layers: [[[String]]],
                                 rows: [UInt8]? = nil,
                                 cols: [UInt8]? = nil,
                                 colsAreDriven: Bool = false) {
        let rowCount = layers.first?.count ?? 0
        let colCount = layers.first?.first?.count ?? 0
        let bytes = payloadBytes(
            rows: rows ?? Array(0..<UInt8(rowCount)),
            cols: cols ?? Array(0..<UInt8(colCount)),
            colsAreDriven: colsAreDriven,
            layers: layers)
        bytes.withUnsafeBufferPointer {
            if let base = $0.baseAddress { loadKeymap(binary: base, count: $0.count) }
        }
    }
}

/// The drift pin: compile keymap.json through this builder and assert it is
/// byte-identical to what generate_default_keymap.sh produced for the same
/// input. If they disagree, fix the builder -- the generator's output is
/// what ships.
@Test func builderMatchesShellGenerator() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let boardData = try Data(contentsOf: root.appendingPathComponent("boards/smk_kbd.json"))
    let board = try #require(try JSONSerialization.jsonObject(with: boardData) as? [String: Any])
    let matrix = try #require(board["matrix"] as? [String: Any])

    let keymapData = try Data(contentsOf: root.appendingPathComponent("keymap.json"))
    let keymap = try #require(try JSONSerialization.jsonObject(with: keymapData) as? [String: Any])

    let built = payloadBytes(
        rows: try #require(matrix["rows"] as? [Int]).map { UInt8($0) },
        cols: try #require(matrix["cols"] as? [Int]).map { UInt8($0) },
        colsAreDriven: try #require(matrix["colsAreDriven"] as? Int) != 0,
        layers: try #require(keymap["layers"] as? [[[String]]]))

    #expect(built == defaultKeymapBytes)
}
