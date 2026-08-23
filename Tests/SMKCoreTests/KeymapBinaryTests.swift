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

@Test func zeroByZeroMatrixWithLayersIsRejected() {
    // The exact six-byte payload the whole-branch review found: rowCount=0,
    // colCount=0, layerCount=200. layerRegionBytes is layerCount * rowCount
    // * colCount * 2, which is 0 whenever rowCount or colCount is 0
    // regardless of layerCount -- so this used to pass the size check
    // (offset + 0 <= count) and decode into 200 layers that are each an
    // empty array of empty rows. A declared layer with no rows or columns
    // is never valid, so this must be refused at decode.
    let attack: [UInt8] = [0, 0, 1, 200, 0, 0]
    let p = attack.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: attack.count)
    }
    #expect(p == nil)
}

@Test func layerCountZeroWithZeroSizedMatrixIsStillAccepted() {
    // The new rowCount>0/colCount>0 guard must only fire when layerCount >
    // 0 -- a macro-only payload legitimately has layerCount == 0, and
    // nothing about that requires a real matrix either. (In practice every
    // real payload has a non-empty matrix regardless; this just confirms
    // the guard's `layerCount == 0 ||` escape hatch doesn't overreach.)
    let b: [UInt8] = [0, 0, 1, 0, 0, 0]  // header only: 0x0 matrix, 0 layers, 0 macros
    let p = b.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: b.count)
    }
    #expect(p?.layers.isEmpty == true)
    #expect(p?.rows.isEmpty == true)
    #expect(p?.cols.isEmpty == true)
}

@Test func trailingBytesAfterAValidPayloadAreRejected() {
    // decodeMacroStep is strict that a repeat block's body consumes
    // exactly its declared bodyLength (see repeatBlockBodyLengthMismatchIsRejected
    // above) -- the top-level payload decode had no equivalent check that
    // decoding consumed the *whole* buffer. A trailing byte past everything
    // the header's declared counts account for is a format error, the same
    // as a mismatched repeat-block body, and must be refused rather than
    // silently ignored.
    var bytes = samplePayload(layerCount: 1)
    bytes.append(0xFF)
    let p = bytes.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: bytes.count)
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
//
// The step wire format below is the configurator compiler's actual format
// (opcodes 0x01-0x05, per-opcode field layouts, `repeatBlock`'s body given
// as a byte length rather than a step count) -- not an invented one. See
// the "wire format correction" section of task-2-report.md.

/// A 1x1-matrix, 0-layer payload carrying one macro entry (id 7, name "AB")
/// exercising every `MacroStep` kind, including a repeat block.
private func sampleMacroPayload() -> [UInt8] {
    var b: [UInt8] = [1, 1, 1, 0, 1, 0]  // header: 1x1 matrix, 0 layers, 1 macro
    b += [5]   // rows[]
    b += [6]   // cols[]

    b += [7]        // macro id
    b += [2, 0x41, 0x42]  // nameLen=2, name="AB" (decoded but not retained)
    b += [5]        // stepCount

    // keystroke: opcode(1) mods(1) keycode(1) holdMs(2 LE) -- holdMs=300
    b += [0x01, Modifier.leftShift.rawValue, KeyCode.b.rawValue, 0x2C, 0x01]
    // text: opcode(1) delivery(1) msPerChar(1) length(1) payload(length) -- "x", msPerChar=10
    b += [0x04, 0, 10, 1, UInt8(ascii: "x")]
    // delay: opcode(1) ms(2 LE) -- ms=500
    b += [0x02, 0xF4, 0x01]
    // layer: opcode(1) op(1) index(1) -- op=0 (momentary), n=2
    b += [0x03, 0, 2]
    // repeatBlock: opcode(1) count(1) bodyLength(2 LE) body(bodyLength) --
    // count=3, body is one delay step (ms=20), so bodyLength=3
    b += [0x05, 3, 3, 0]
    b += [0x02, 20, 0]  // the repeat's body: a single delay(ms: 20) step
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

    // Outer repeatBlock: opcode count=2, bodyLength=4, whose body is
    // exactly one nested step that is itself a repeatBlock (count=1,
    // empty body) -- must be refused before even reading the nested
    // repeat's own count/bodyLength.
    b += [0x05, 2, 4, 0]
    b += [0x05, 1, 0, 0]

    let p = b.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: b.count)
    }
    #expect(p == nil)
}

@Test func repeatBlockBodyLengthMismatchIsRejected() {
    // bodyLength is attacker-controlled. Here it under-declares the body
    // (2, but the one step inside it is 3 bytes) -- the buffer has enough
    // real bytes that decoding the step reads past the declared bodyEnd
    // without leaving the actual buffer (no memory-safety issue), but the
    // result must still be refused: a body that doesn't parse as an exact
    // sequence of steps is a format error, not something to accept with a
    // mismatched length.
    var b: [UInt8] = [1, 1, 1, 0, 1, 0]
    b += [5]           // rows[]
    b += [6]           // cols[]
    b += [1]           // macro id
    b += [0]           // nameLen=0
    b += [1]           // stepCount=1
    b += [0x05, 1, 2, 0]   // repeatBlock: count=1, bodyLength=2 (claimed, too small)
    b += [0x02, 20, 0]     // body's actual content: one delay step, 3 bytes
    let p = b.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: b.count)
    }
    #expect(p == nil)
}

// MARK: - Compiled-in default keymap (generate_default_keymap.sh)

// The real deliverable of Task 7: this is the only thing that catches
// generator/decoder drift on every future run. `defaultKeymapBytes` lives in
// the generated Sources/SMKCore/DefaultKeymapGenerated.swift -- a second,
// independent encoder for the exact format `decodeKeymapPayload` above
// reads, and nothing but this test keeps the two honest with each other.

@Test func compiledDefaultKeymapRoundTrips() {
    let bytes = defaultKeymapBytes
    let payload = bytes.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: bytes.count)
    }
    #expect(payload != nil)
    guard let payload else { return }

    // Matches ~/esp/SMK/keymap.json's "matrix" object -- the smk_kbd
    // board's GPIO map (5 rows, 12 cols, COL2ROW).
    #expect(payload.rows == [0, 1, 2, 3, 5])
    #expect(payload.cols == [6, 7, 8, 14, 15, 18, 19, 20, 21, 22, 23, 17])
    #expect(payload.colsAreDriven == true)
    #expect(payload.layers.count == 2)
    #expect(payload.macros.isEmpty)

    // Sample cells from keymap.json's two layers, not just the matrix
    // header -- a header-only check would miss a generator bug that
    // scrambles cell order or the tag table.
    #expect(payload.layers[0][0][0] == KeyAction.key(.k1))          // layer 0, row 0, col 0: "key:1"
    #expect(payload.layers[0][4][3] == KeyAction.momentaryLayer(1)) // layer 0, row 4, col 3: "mo:1"
    #expect(payload.layers[1][0][0] == KeyAction.toggleConnection)  // layer 1, row 0, col 0: "toggle_conn"
    #expect(payload.layers[1][2][6] == KeyAction.key(.leftArrow))   // layer 1, row 2, col 6: "key:left"
    #expect(payload.layers[1][4][6] == KeyAction.none)              // layer 1, row 4, col 6: "none"
}

@Test func compiledDefaultKeymapMatchesTheSizeEstimate() {
    // 6-byte header + 5 rows + 12 cols + 2 layers * 5 * 12 * 2 bytes/cell
    // = 263 bytes, against ~1575 bytes of keymap.json text. If this drifts
    // far from 263, either the generator or keymap.json changed in a way
    // that should be looked at, not silently accepted.
    #expect(defaultKeymapBytes.count == 263)
}
