import Testing
@testable import SMKCore

@Test func debounceRequiresFiveConsecutiveSamplesToFlip() {
    var matrix = DebouncedMatrix(totalKeys: 1)
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [false])
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [false])
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [false])
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [false])
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [true])
}

@Test func debounceBounceResetsCounter() {
    var matrix = DebouncedMatrix(totalKeys: 1)
    _ = matrix.update(rawScan: bits([true]))
    _ = matrix.update(rawScan: bits([true]))
    _ = matrix.update(rawScan: bits([true]))
    _ = matrix.update(rawScan: bits([false])) // bounces back to the still-stable `false`, resets the counter
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [false])
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [false])
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [false])
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [false])
    #expect(bools(matrix.update(rawScan: bits([true])), 1) == [true])
}

@Test func debounceAppliesSameThresholdOnRelease() {
    var matrix = DebouncedMatrix(totalKeys: 1)
    for _ in 0..<5 { _ = matrix.update(rawScan: bits([true])) }
    #expect(bools(matrix.update(rawScan: bits([false])), 1) == [true])
    #expect(bools(matrix.update(rawScan: bits([false])), 1) == [true])
    #expect(bools(matrix.update(rawScan: bits([false])), 1) == [true])
    #expect(bools(matrix.update(rawScan: bits([false])), 1) == [true])
    #expect(bools(matrix.update(rawScan: bits([false])), 1) == [false])
}

@Test func debounceTracksKeysIndependently() {
    var matrix = DebouncedMatrix(totalKeys: 2)
    for _ in 0..<5 { _ = matrix.update(rawScan: bits([true, false])) }
    #expect(bools(matrix.update(rawScan: bits([true, false])), 2) == [true, false])
}

@Test func debounceHandlesTheLastPosition() {
    var m = DebouncedMatrix(totalKeys: 256)
    var raw = KeyBitset(); raw[255] = true
    for _ in 0..<4 { #expect(m.update(rawScan: raw)[255] == false) }
    #expect(m.update(rawScan: raw)[255] == true)
}
