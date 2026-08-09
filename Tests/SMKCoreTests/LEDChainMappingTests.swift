import Testing
@testable import SMKCore

@Test func ledChainIndexEvenRowsRunLeftToRight() {
    #expect(ledChainIndex(row: 0, col: 0, colCount: 12) == 0)
    #expect(ledChainIndex(row: 0, col: 5, colCount: 12) == 5)
    #expect(ledChainIndex(row: 0, col: 11, colCount: 12) == 11)
}

@Test func ledChainIndexOddRowsRunRightToLeft() {
    #expect(ledChainIndex(row: 1, col: 0, colCount: 12) == 23)
    #expect(ledChainIndex(row: 1, col: 11, colCount: 12) == 12)
}

@Test func ledChainIndexStaysAdjacentAcrossRowBoundary() {
    // last LED of row 0 must be chain-adjacent to the first LED of row 1
    #expect(ledChainIndex(row: 0, col: 11, colCount: 12) == 11)
    #expect(ledChainIndex(row: 1, col: 11, colCount: 12) == 12)
}
