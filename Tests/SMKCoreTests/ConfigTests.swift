import Testing
@testable import SMKCore

@Test func configParsesMatrixRowsColsAndColsAreDriven() {
    let json = """
    { "matrix": { "rows": [0, 1, 2], "cols": [3, 4], "colsAreDriven": 1 } }
    """
    let cfg = Config.fromJson(json)
    #expect(cfg.rowPins == [0, 1, 2])
    #expect(cfg.colPins == [3, 4])
    #expect(cfg.colsAreDriven == true)
}

@Test func configDefaultsColsAreDrivenToFalseWhenAbsent() {
    let json = """
    { "matrix": { "rows": [0], "cols": [1] } }
    """
    let cfg = Config.fromJson(json)
    #expect(cfg.colsAreDriven == false)
}

@Test func configReturnsEmptyPinsOnMalformedJson() {
    let cfg = Config.fromJson("not json")
    #expect(cfg.rowPins.isEmpty)
    #expect(cfg.colPins.isEmpty)
}

@Test func configReturnsEmptyPinsWhenMatrixKeyMissing() {
    let cfg = Config.fromJson("{}")
    #expect(cfg.rowPins.isEmpty)
    #expect(cfg.colPins.isEmpty)
}
