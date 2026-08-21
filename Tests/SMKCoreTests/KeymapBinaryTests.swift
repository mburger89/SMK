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
