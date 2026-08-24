import Foundation
import Testing
@testable import SMKCore

// Every board's compiled payload, decoded and compared against the JSON it
// was compiled from.
//
// This is the mitigation named in
// docs/superpowers/specs/2026-08-21-retire-cjson-design.md's "The risk,
// stated plainly": the eight board layouts are hand-maintained fixtures,
// six of the eight cannot be tested on real hardware today, and a single
// mistyped GPIO number in the migration would be invisible until someone
// flashed that board and found a dead column. Comparing decoded bytes back
// against the source JSON is mechanical and catches that whole class.
//
// It does NOT catch a board JSON that was already wrong before the
// migration -- that is a pre-existing condition, and out of scope here.
//
// Foundation is used deliberately: tests are host-only, and reading the
// JSON independently of the generator is exactly what makes this a real
// check rather than a tautology. The firmware itself no longer has any way
// to parse this.

/// Repo root, derived from this file's own path rather than a working
/// directory -- `swift test` makes no promise about cwd.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // SMKCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // repo root

private func boardSpec(_ name: String) throws -> [String: Any] {
    let url = repoRoot.appendingPathComponent("boards/\(name).json")
    let data = try Data(contentsOf: url)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func layers(of spec: [String: Any]) throws -> [[[String]]] {
    if let from = spec["layersFrom"] as? String {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(from))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["layers"] as? [[[String]]])
    }
    return try #require(spec["layers"] as? [[[String]]])
}

/// What the JSON token *means*, resolved through the same grammar the JSON
/// path used before this migration (`KeyAction.fromCString`) -- so a token
/// that meant one thing under cJSON cannot silently mean another now.
private func expectedAction(_ token: String) -> KeyAction {
    token.withCString { KeyAction.fromCString($0) }
}

@Test func everyBoardPayloadDecodesToItsJSON() throws {
    #expect(generatedBoardPayloads.count == 8)

    for board in generatedBoardPayloads {
        let spec = try boardSpec(board.board)
        let matrix = try #require(spec["matrix"] as? [String: Any])
        let jsonRows = try #require(matrix["rows"] as? [Int]).map { UInt8($0) }
        let jsonCols = try #require(matrix["cols"] as? [Int]).map { UInt8($0) }
        let jsonDriven = try #require(matrix["colsAreDriven"] as? Int) != 0
        let jsonLayers = try layers(of: spec)

        let decoded = board.bytes.withUnsafeBufferPointer {
            decodeKeymapPayload($0.baseAddress, count: $0.count)
        }
        let payload = try #require(decoded, "\(board.board) payload did not decode")

        #expect(payload.rows == jsonRows, "\(board.board) rows")
        #expect(payload.cols == jsonCols, "\(board.board) cols")
        #expect(payload.colsAreDriven == jsonDriven, "\(board.board) colsAreDriven")
        #expect(payload.macros.isEmpty, "\(board.board) macros")

        // A board with no matrix wired (feather_nrf52840) encodes zero
        // layers on purpose -- see generate_default_keymap.sh's
        // compile_board, and KeymapBinary.swift's 0x0-matrix guard for why
        // a declared layer over a 0x0 matrix must be refused.
        if jsonRows.isEmpty || jsonCols.isEmpty {
            #expect(payload.layers.isEmpty, "\(board.board) should encode no layers")
            continue
        }

        #expect(payload.layers.count == jsonLayers.count, "\(board.board) layer count")
        for (li, layer) in jsonLayers.enumerated() {
            #expect(payload.layers[li].count == layer.count, "\(board.board) layer \(li) rows")
            for (ri, row) in layer.enumerated() {
                #expect(payload.layers[li][ri].count == row.count,
                        "\(board.board) layer \(li) row \(ri) cols")
                for (ci, token) in row.enumerated() {
                    #expect(payload.layers[li][ri][ci] == expectedAction(token),
                            "\(board.board) layer \(li) row \(ri) col \(ci) token \(token)")
                }
            }
        }
    }
}

/// Guards the `#if` chain's fallback ordering: `defaultKeymapBytes` on a
/// build with no SMK_BOARD_* flag -- which is every host test run -- must be
/// the smk_kbd board, not whichever board happens to sit first in the
/// generator's list. Silent breakage otherwise: the ESP32-C6 reference board
/// takes the same fallback branch.
@Test func hostBuildFallsBackToTheSmkKbdBoard() throws {
    let smkKbd = try #require(generatedBoardPayloads.first { $0.board == "smk_kbd" })
    #expect(defaultKeymapBytes == smkKbd.bytes)
}
