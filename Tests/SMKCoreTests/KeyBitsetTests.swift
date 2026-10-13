import Testing
@testable import SMKCore

@Test func bitsetStartsEmpty() {
    let b = KeyBitset()
    for i in 0..<KeyBitset.capacity { #expect(b[i] == false) }
}

@Test func bitsetSetsAndClearsIndependentBits() {
    var b = KeyBitset()
    b[0] = true; b[31] = true; b[32] = true; b[255] = true
    #expect(b[0] && b[31] && b[32] && b[255])
    #expect(!b[1] && !b[33] && !b[254])
    b[31] = false
    #expect(!b[31] && b[32])
}

@Test func bitsetEqualityComparesEveryWord() {
    var a = KeyBitset(), b = KeyBitset()
    #expect(a == b)
    b[255] = true
    #expect(a != b)
    a[255] = true
    #expect(a == b)
}

@Test func capacityMatchesMatrixCap() {
    #expect(KeyBitset.capacity == smkMaxMatrixPositions)
}
