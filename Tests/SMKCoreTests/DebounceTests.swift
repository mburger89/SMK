import Testing
@testable import SMKCore

@Test func debounceRequiresFiveConsecutiveSamplesToFlip() {
    var matrix = DebouncedMatrix(totalKeys: 1)
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [true])
}

@Test func debounceBounceResetsCounter() {
    var matrix = DebouncedMatrix(totalKeys: 1)
    _ = matrix.update(rawScan: [true])
    _ = matrix.update(rawScan: [true])
    _ = matrix.update(rawScan: [true])
    _ = matrix.update(rawScan: [false]) // bounces back to the still-stable `false`, resets the counter
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [true])
}

@Test func debounceAppliesSameThresholdOnRelease() {
    var matrix = DebouncedMatrix(totalKeys: 1)
    for _ in 0..<5 { _ = matrix.update(rawScan: [true]) }
    #expect(matrix.update(rawScan: [false]) == [true])
    #expect(matrix.update(rawScan: [false]) == [true])
    #expect(matrix.update(rawScan: [false]) == [true])
    #expect(matrix.update(rawScan: [false]) == [true])
    #expect(matrix.update(rawScan: [false]) == [false])
}

@Test func debounceTracksKeysIndependently() {
    var matrix = DebouncedMatrix(totalKeys: 2)
    for _ in 0..<5 { _ = matrix.update(rawScan: [true, false]) }
    #expect(matrix.update(rawScan: [true, false]) == [true, false])
}
