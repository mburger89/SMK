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

// Test helpers: build a KeyBitset from a Bool list, and read the first `n`
// positions back out, so scan/debounce tests stay readable as literals.
func bits(_ b: [Bool]) -> KeyBitset {
    var s = KeyBitset()
    for (i, v) in b.enumerated() { s[i] = v }
    return s
}

func bools(_ s: KeyBitset, _ n: Int) -> [Bool] { (0..<n).map { s[$0] } }
