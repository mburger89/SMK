import Testing
@testable import SMKCore

@Test func configTakesRowsColsAndColsAreDrivenFromThePayloadHeader() throws {
    let bytes = payloadBytes(rows: [0, 1, 2], cols: [3, 4], colsAreDriven: true,
                             layers: [[["key:a", "key:b"], ["key:c", "key:d"],
                                       ["key:e", "key:f"]]])
    let payload = try #require(bytes.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress, count: $0.count)
    })
    let cfg = Config(payload: payload)
    #expect(cfg.rowPins == [0, 1, 2])
    #expect(cfg.colPins == [3, 4])
    #expect(cfg.colsAreDriven == true)
}

@Test func configHasNoPinsWhenThePayloadDeclaresAnEmptyMatrix() throws {
    // feather_nrf52840 is exactly this shape: no matrix is wired to that
    // board, so its payload is a bare header. app_main_swift's
    // rowPins.isEmpty check is what acts on it.
    let bytes: [UInt8] = [0, 0, 0, 0, 0, 0]
    let payload = try #require(bytes.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress, count: $0.count)
    })
    let cfg = Config(payload: payload)
    #expect(cfg.rowPins.isEmpty)
    #expect(cfg.colPins.isEmpty)
    #expect(cfg.colsAreDriven == false)
}
