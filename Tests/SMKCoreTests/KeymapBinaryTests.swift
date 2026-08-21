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

// The tests above never exercise macroCount > 0 -- none of the brief's given
// tests do. Macro-entry parsing (name/step-count bounds checks, and the
// nested-repeat-block refusal called out as a landmine the brief itself
// cannot pin with a byte layout) is otherwise entirely untested code, so
// these are added beyond the brief to verify it directly.

/// A 1x1-matrix, 0-layer payload carrying one macro entry (id 7, name "AB")
/// exercising every `MacroStep` kind, including a repeat block.
private func sampleMacroPayload() -> [UInt8] {
    var b: [UInt8] = [1, 1, 1, 0, 1, 0]  // header: 1x1 matrix, 0 layers, 1 macro
    b += [5]   // rows[]
    b += [6]   // cols[]

    b += [7]        // macro id
    b += [2, 0x41, 0x42]  // nameLen=2, name="AB" (decoded but not retained)
    b += [5]        // stepCount

    b += [0, Modifier.leftShift.rawValue, KeyCode.b.rawValue, 0x2C, 0x01]  // keystroke, holdMs=300
    b += [1, 1, UInt8(ascii: "x"), 10, 0]                                  // text "x", msPerChar=10
    b += [2, 0xF4, 0x01]                                                   // delay ms=500
    b += [3, 1, 2]                                                         // layer momentary n=2
    b += [4, 3, 1, 2, 20, 0]     // repeatBlock count=3, 1 nested step: delay ms=20
    return b
}

@Test func macroEntryDecodesEveryStepKind() {
    let bytes = sampleMacroPayload()
    let p = bytes.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: bytes.count)
    }
    #expect(p?.macros.count == 1)
    #expect(p?.macros[0].id == 7)
    #expect(p?.macros[0].steps == [
        .keystroke(mods: Modifier.leftShift.rawValue, key: KeyCode.b.rawValue, holdMs: 300),
        .text("x", msPerChar: 10),
        .delay(ms: 500),
        .layer(momentary: true, n: 2),
        .repeatBlock(count: 3, steps: [.delay(ms: 20)]),
    ])
}

@Test func truncatedMacroPayloadIsRejectedNotIndexed() {
    let full = sampleMacroPayload()
    for cut in 1..<full.count {
        let short = Array(full[0..<cut])
        let p = short.withUnsafeBufferPointer {
            decodeKeymapPayload($0.baseAddress!, count: short.count)
        }
        #expect(p == nil, "macro prefix of length \(cut) should have been rejected")
    }
}

@Test func nestedRepeatBlockIsRejectedAtDecode() {
    // The player uses a single loop counter, not a stack, so a repeat block
    // whose own steps contain another repeat block must never reach it --
    // refused here, at decode, rather than defended against during playback.
    var b: [UInt8] = [1, 1, 1, 0, 1, 0]  // header: 1x1 matrix, 0 layers, 1 macro
    b += [5]           // rows[]
    b += [6]           // cols[]
    b += [1]           // macro id
    b += [0]           // nameLen=0
    b += [1]           // stepCount=1
    b += [4, 2, 1]     // outer repeatBlock: count=2, 1 nested step
    b += [4, 1, 0]     // nested step is itself a repeatBlock -- must be refused
    let p = b.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: b.count)
    }
    #expect(p == nil)
}
