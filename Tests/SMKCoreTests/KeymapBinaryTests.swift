import Testing
@testable import SMKCore

@Test func everyActionRoundTripsThroughTwoBytes() {
    let cases: [KeyAction] = [
        .none,
        .key(.a), .key(.z), .key(.f12),
        .modifier(.leftShift), .modifier(.rightGUI),
        .momentaryLayer(0), .momentaryLayer(15),
        .toggleLayer(0), .toggleLayer(15),
        .transparent,
        .toggleConnection,
        .macro(0), .macro(255),
    ]
    for action in cases {
        let (tag, param) = encodeCell(action)
        #expect(decodeCell(tag, param) == action, "round trip failed for \(action)")
    }
}

@Test func unknownTagDecodesToNone() {
    // A tag this build has no case for must not index into anything.
    #expect(decodeCell(200, 42) == KeyAction.none)
}

@Test func cellIsExactlyTwoBytes() {
    // The whole storage claim rests on this stride. If a cell ever needs
    // three bytes, 16 layers no longer fit and the spec's arithmetic breaks.
    let (tag, param) = encodeCell(.key(.a))
    #expect(MemoryLayout.size(ofValue: tag) == 1)
    #expect(MemoryLayout.size(ofValue: param) == 1)
}

/// Builds a minimal valid payload: 1x2 matrix, `layerCount` layers, no macros.
private func samplePayload(layerCount: Int) -> [UInt8] {
    var b: [UInt8] = [1, 2, 1, UInt8(layerCount), 0, 0]  // header
    b += [5]        // rows[]  GPIO 5
    b += [6, 7]     // cols[]  GPIO 6,7
    for _ in 0..<layerCount {
        b += [1, KeyCode.a.rawValue]   // key:a
        b += [5, 0]                    // trans
    }
    return b
}

@Test func decodesMatrixLayersAndCells() {
    let bytes = samplePayload(layerCount: 2)
    let p = bytes.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: bytes.count)
    }
    #expect(p?.rows == [5])
    #expect(p?.cols == [6, 7])
    #expect(p?.colsAreDriven == true)
    #expect(p?.layers.count == 2)
    #expect(p?.layers[0][0][0] == KeyAction.key(.a))
    #expect(p?.layers[1][0][1] == KeyAction.transparent)
}

@Test func truncatedPayloadIsRejectedNotIndexed() {
    // Binary loses JSON's free bounds checking. Every prefix of a valid
    // payload must be refused rather than read past its end.
    let full = samplePayload(layerCount: 2)
    for cut in 1..<full.count {
        let short = Array(full[0..<cut])
        let p = short.withUnsafeBufferPointer {
            decodeKeymapPayload($0.baseAddress!, count: short.count)
        }
        #expect(p == nil, "prefix of length \(cut) should have been rejected")
    }
}

@Test func emptyPayloadIsRejected() {
    var empty: [UInt8] = []
    let p = empty.withUnsafeMutableBufferPointer { buf -> KeymapPayload? in
        guard let base = buf.baseAddress else { return decodeKeymapPayload(nil, count: 0) }
        return decodeKeymapPayload(base, count: 0)
    }
    #expect(p == nil)
}

@Test func absurdCountsAreRejectedBeforeAllocating() {
    // A corrupt header claiming 200 layers of a 200x200 matrix must be
    // refused on arithmetic, not attempted.
    var b: [UInt8] = [200, 200, 1, 200, 0, 0]
    b += [UInt8](repeating: 0, count: 8)
    let p = b.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: b.count)
    }
    #expect(p == nil)
}

@Test func sixteenLayersFitTheExistingCeiling() {
    // The claim this entire change rests on. 16 layers of a 5x12 board must
    // fit inside smkKeymapMaxLen with room left for macros -- that is why
    // no port needs a larger region, a partition table, or a migration.
    let rows = 5, cols = 12, layers = 16
    let headerBytes = 6 + rows + cols
    let layerBytes = layers * rows * cols * 2
    #expect(headerBytes + layerBytes == 1943)
    #expect(headerBytes + layerBytes < smkKeymapMaxLen)
    #expect(smkKeymapMaxLen - (headerBytes + layerBytes) > 2000)
}
