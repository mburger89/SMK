import Foundation
import Testing
@testable import SMKCore

@Test func configParsesMatrixRowsColsAndColsAreDriven() {
    let json = """
    { "matrix": { "rows": [0, 1, 2], "cols": [3, 4], "colsAreDriven": 1 } }
    """
    let cfg = Config.fromJson(json)
    #expect(cfg.rowPins == [0, 1, 2])
    #expect(cfg.colPins == [3, 4])
    #expect(cfg.colsAreDriven == true)
}

@Test func configDefaultsColsAreDrivenToFalseWhenAbsent() {
    let json = """
    { "matrix": { "rows": [0], "cols": [1] } }
    """
    let cfg = Config.fromJson(json)
    #expect(cfg.colsAreDriven == false)
}

@Test func configReturnsEmptyPinsOnMalformedJson() {
    let cfg = Config.fromJson("not json")
    #expect(cfg.rowPins.isEmpty)
    #expect(cfg.colPins.isEmpty)
}

@Test func configReturnsEmptyPinsWhenMatrixKeyMissing() {
    let cfg = Config.fromJson("{}")
    #expect(cfg.rowPins.isEmpty)
    #expect(cfg.colPins.isEmpty)
}

// MARK: - Migration to the binary payload

// TEMPORARY, deleted with Config.fromJson itself: this is the equivalence
// pin for the cJSON retirement
// (docs/superpowers/specs/2026-08-21-retire-cjson-design.md). It exists to
// prove Config(payload:) reproduces exactly what fromJson produced, for
// every board, before fromJson is removed -- not to specify behaviour that
// outlives the migration.
@Test func configFromPayloadMatchesConfigFromJson() throws {
    for board in generatedBoardPayloads {
        let decoded = board.bytes.withUnsafeBufferPointer {
            decodeKeymapPayload($0.baseAddress, count: $0.count)
        }
        let payload = try #require(decoded, "\(board.board) payload did not decode")
        let fromPayload = Config(payload: payload)

        let specURL = repoRootForConfigTests.appendingPathComponent("boards/\(board.board).json")
        let json = try String(contentsOf: specURL, encoding: .utf8)
        let fromJson = Config.fromJson(json)

        #expect(fromPayload.rowPins == fromJson.rowPins, "\(board.board) rowPins")
        #expect(fromPayload.colPins == fromJson.colPins, "\(board.board) colPins")
        #expect(fromPayload.colsAreDriven == fromJson.colsAreDriven, "\(board.board) colsAreDriven")
    }
}

private let repoRootForConfigTests = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
