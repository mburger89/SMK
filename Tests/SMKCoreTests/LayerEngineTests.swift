import Testing
@testable import SMKCore

@Test func layerEngineLoadsBasicKeymapAndResolvesLayerZero() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["key:a", "key:b"]]])
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
    #expect(engine.getAction(row: 0, col: 1) == .key(.b))
}

@Test func layerEngineOutOfRangePositionReturnsNone() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["key:a"]]])
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
    engine.loadTestKeymap([[["key:a"]], [["trans"]]])
    engine.addMomentaryLayer(1)
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
}

@Test func layerEngineHigherActiveLayerOverridesLower() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["key:a"]], [["key:b"]]])
    engine.addMomentaryLayer(1)
    #expect(engine.getAction(row: 0, col: 0) == .key(.b))
}

// These three used to feed malformed JSON ("not json", "{}", an empty
// "layers" array). With cJSON retired the equivalent malformed inputs are
// bytes: one that cannot decode at all, and one that decodes cleanly but
// declares no layers. Both must leave `keymaps` untouched -- the load path
// is all-or-nothing by design (see LayerEngine.loadKeymap(binary:count:)).
@Test func layerEngineLoadKeymapLeavesKeymapsEmptyOnUndecodablePayload() {
    var engine = LayerEngine()
    // Header claims a 5x12 matrix but the payload stops after the header,
    // so the bounds check rejects it before any cell is read.
    let truncated: [UInt8] = [5, 12, 1, 1, 0, 0]
    truncated.withUnsafeBufferPointer {
        engine.loadKeymap(binary: $0.baseAddress!, count: truncated.count)
    }
    #expect(engine.keymaps.isEmpty)
}

@Test func layerEngineLoadKeymapLeavesKeymapsEmptyWhenPayloadDeclaresNoLayers() {
    var engine = LayerEngine()
    let noLayers: [UInt8] = [1, 1, 0, 0, 0, 0, 0, 0]   // 1x1 matrix, zero layers
    noLayers.withUnsafeBufferPointer {
        engine.loadKeymap(binary: $0.baseAddress!, count: noLayers.count)
    }
    #expect(engine.keymaps.isEmpty)
}

@Test func layerEngineLoadKeymapKeepsPreviousKeymapWhenSubsequentLoadFails() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["key:a"]]])
    #expect(!engine.keymaps.isEmpty)
    let truncated: [UInt8] = [5, 12, 1, 1, 0, 0]
    truncated.withUnsafeBufferPointer {
        engine.loadKeymap(binary: $0.baseAddress!, count: truncated.count)
    }
    #expect(!engine.keymaps.isEmpty)
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
}

@Test func layerEngineRejectsSixByteEmptyLayerAttack() {
    // FIX 3: [0, 0, 1, 200, 0, 0] used to decode into 200 layers that were
    // each an empty array of empty rows (rowCount/colCount both 0, so
    // layerRegionBytes was 0 regardless of layerCount). `!layers.isEmpty`
    // was true for that (200 elements), so it would replace a working
    // keymap with one where every cell resolves to .none forever,
    // recoverable only via the reset-held boot path. Guarded now both at
    // decode (decodeKeymapPayload) and here (the `hasUsableCells` check),
    // so a previously-loaded working keymap must survive the attack intact.
    var engine = LayerEngine()
    engine.loadTestKeymap([[["key:a"]]])
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))

    let attack: [UInt8] = [0, 0, 1, 200, 0, 0]
    attack.withUnsafeBufferPointer {
        engine.loadKeymap(binary: $0.baseAddress!, count: attack.count)
    }
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
