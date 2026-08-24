import Testing
@testable import SMKCore

@Test func keyEventProcessingBuildsReportForHeldKey() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["key:a", "none"]]])
    var pressedActions: [KeyAction] = [.none, .none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true, false],
        lastScan: [false, false],
        colCount: 2,
        pressedActions: &pressedActions,
        engine: &engine,
        hasWiredBridge: false,
        currentMode: &currentMode
    )

    #expect(result.report.keys == [KeyCode.a.rawValue, 0, 0, 0, 0, 0])
    #expect(result.transitions == [KeyTransition(position: KeyPosition(row: 0, col: 0), pressed: true)])
}

@Test func keyEventProcessingClearsActionOnRelease() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["key:a"]]])
    var pressedActions: [KeyAction] = [.key(.a)]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [false],
        lastScan: [true],
        colCount: 1,
        pressedActions: &pressedActions,
        engine: &engine,
        hasWiredBridge: false,
        currentMode: &currentMode
    )

    #expect(pressedActions == [.none])
    #expect(result.transitions == [KeyTransition(position: KeyPosition(row: 0, col: 0), pressed: false)])
    #expect(result.report.keys == [0, 0, 0, 0, 0, 0])
}

@Test func keyEventProcessingMomentaryLayerActivatesWhileHeld() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["mo:1"]], [["key:b"]]])
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    _ = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(engine.isLayerActive(1) == true)

    _ = processKeyEvents(
        cleanScan: [false], lastScan: [true], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(engine.isLayerActive(1) == false)
}

@Test func keyEventProcessingToggleLayerStaysActiveAfterRelease() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["tg:1"]]])
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    _ = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    _ = processKeyEvents(
        cleanScan: [false], lastScan: [true], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(engine.isLayerActive(1) == true)
}

@Test func keyEventProcessingTogglesConnectionModeWhenWiredBridgeAvailable() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["toggle_conn"]]])
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: true, currentMode: &currentMode
    )

    #expect(currentMode == .wired)
    #expect(result.connectionEvents == [.toggled(.wired)])
}

@Test func keyEventProcessingIgnoresConnectionToggleWithoutWiredBridge() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["toggle_conn"]]])
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )

    #expect(currentMode == .bluetooth)
    #expect(result.connectionEvents == [.ignored])
}

@Test func keyEventProcessingAddsModifierBitsSeparatelyFromKeys() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["mod:leftShift", "key:a"]]])
    var pressedActions: [KeyAction] = [.none, .none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true, true], lastScan: [false, false], colCount: 2,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )

    #expect(result.report.modifier == Modifier.leftShift.rawValue)
    #expect(result.report.keys == [KeyCode.a.rawValue, 0, 0, 0, 0, 0])
}

@Test func keyEventProcessingCapturesModeAtEachToggleInstantWhenTwoKeysToggleInOneCycle() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["toggle_conn", "toggle_conn"]]])
    var pressedActions: [KeyAction] = [.none, .none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true, true], lastScan: [false, false], colCount: 2,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: true, currentMode: &currentMode
    )

    #expect(result.connectionEvents == [.toggled(.wired), .toggled(.bluetooth)])
    #expect(currentMode == .bluetooth)
}

@Test func macroPressEmitsAMacroEvent() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["macro:2", "key:a"]]])
    var pressedActions: [KeyAction] = [.none, .none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true, false], lastScan: [false, false], colCount: 2,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(result.macroEvents == [2])
}

@Test func macroKeyContributesNothingToTheReport() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["macro:2"]]])
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(result.report == HIDReport())
}

@Test func macroReleaseEmitsNoEvent() {
    var engine = LayerEngine()
    engine.loadTestKeymap([[["macro:2"]]])
    var pressedActions: [KeyAction] = [.macro(2)]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [false], lastScan: [true], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(result.macroEvents.isEmpty)
}

@Test func heldKeyProducesNoFreshPressTransition() {
    // Pins the property Main.swift's macro-finish handling relies on: a
    // key already down in lastScan and still down in cleanScan is NOT a
    // press edge. This is why Main.swift deliberately does not reset
    // lastScan to all-false when a macro finishes -- doing so would make
    // a still-held macro key read as a fresh press and re-trigger the
    // macro for as long as the key stays down, i.e. reintroduce
    // auto-repeat. processKeyEvents observes a real release the instant
    // it happens (every tick, macro or not), so no such reset is needed
    // to "un-stick" a released key either -- see Main.swift's comment on
    // the `.finished` case for the full argument.
    var engine = LayerEngine()
    engine.loadTestKeymap([[["key:a"]]])
    var pressedActions: [KeyAction] = [.key(.a)]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true], lastScan: [true], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(result.transitions.isEmpty)
    #expect(result.report.keys[0] == KeyCode.a.rawValue)
}
