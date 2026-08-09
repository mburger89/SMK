import Testing
@testable import SMKCore

@Test func layerEngineLoadsBasicKeymapAndResolvesLayerZero() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a", "key:b"] ] ] }
    """)
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
    #expect(engine.getAction(row: 0, col: 1) == .key(.b))
}

@Test func layerEngineOutOfRangePositionReturnsNone() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ] ] }
    """)
    #expect(engine.getAction(row: 5, col: 5) == .none)
}

@Test func layerEngineLayerZeroIsAlwaysActive() {
    let engine = LayerEngine()
    #expect(engine.isLayerActive(0) == true)
}

@Test func layerEngineMomentaryLayerActivatesOnAddAndDeactivatesOnRemove() {
    var engine = LayerEngine()
    #expect(engine.isLayerActive(1) == false)
    engine.addMomentaryLayer(1)
    #expect(engine.isLayerActive(1) == true)
    engine.removeMomentaryLayer(1)
    #expect(engine.isLayerActive(1) == false)
}

@Test func layerEngineToggleLayerFlipsActiveState() {
    var engine = LayerEngine()
    engine.toggleLayer(2)
    #expect(engine.isLayerActive(2) == true)
    engine.toggleLayer(2)
    #expect(engine.isLayerActive(2) == false)
}

@Test func layerEngineTransparentFallsThroughToLowerActiveLayer() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ], [ ["trans"] ] ] }
    """)
    engine.addMomentaryLayer(1)
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
}

@Test func layerEngineHigherActiveLayerOverridesLower() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ], [ ["key:b"] ] ] }
    """)
    engine.addMomentaryLayer(1)
    #expect(engine.getAction(row: 0, col: 0) == .key(.b))
}

@Test func layerEngineLoadKeymapLeavesKeymapsEmptyOnMalformedJSON() {
    var engine = LayerEngine()
    engine.loadKeymap(json: "not json")
    #expect(engine.keymaps.isEmpty)
}

@Test func layerEngineLoadKeymapLeavesKeymapsEmptyWhenLayersKeyMissing() {
    var engine = LayerEngine()
    engine.loadKeymap(json: "{}")
    #expect(engine.keymaps.isEmpty)
}

@Test func layerEngineLoadKeymapLeavesKeymapsEmptyWhenLayersArrayIsEmpty() {
    var engine = LayerEngine()
    engine.loadKeymap(json: #"{"layers": []}"#)
    #expect(engine.keymaps.isEmpty)
}

@Test func layerEngineLoadKeymapKeepsPreviousKeymapWhenSubsequentLoadFails() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ] ] }
    """)
    #expect(!engine.keymaps.isEmpty)
    engine.loadKeymap(json: "not json")
    #expect(!engine.keymaps.isEmpty)
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
}

@Test func keyActionFromCStringParsesAllPrefixes() {
    #expect("none".withCString { KeyAction.fromCString($0) } == .none)
    #expect("trans".withCString { KeyAction.fromCString($0) } == .transparent)
    #expect("toggle_conn".withCString { KeyAction.fromCString($0) } == .toggleConnection)
    #expect("key:a".withCString { KeyAction.fromCString($0) } == .key(.a))
    #expect("mod:leftShift".withCString { KeyAction.fromCString($0) } == .modifier(.leftShift))
    #expect("mo:2".withCString { KeyAction.fromCString($0) } == .momentaryLayer(2))
    #expect("tg:3".withCString { KeyAction.fromCString($0) } == .toggleLayer(3))
    #expect("garbage".withCString { KeyAction.fromCString($0) } == .none)
}
