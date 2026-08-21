import Testing
@testable import SMKCore

@Test func idlePlayerEmitsNothing() {
    var player = MacroPlayer()
    #expect(player.isActive == false)
    #expect(player.tick() == .idle)
}

@Test func msRoundsUpToWholeTicks() {
    #expect(macroTicks(forMs: 0) == 0)
    #expect(macroTicks(forMs: 1) == 1)   // must not vanish
    #expect(macroTicks(forMs: 10) == 1)
    #expect(macroTicks(forMs: 11) == 2)
    #expect(macroTicks(forMs: 40) == 4)
}

@Test func keystrokeHoldsThenReleases() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .keystroke(mods: 0, key: KeyCode.b.rawValue, holdMs: 40)
    ]))
    for _ in 0..<4 {
        guard case .report(let r) = player.tick() else {
            Issue.record("expected a held report"); return
        }
        #expect(r.keys[0] == KeyCode.b.rawValue)
    }
    guard case .report(let release) = player.tick() else {
        Issue.record("expected a release report"); return
    }
    #expect(release.keys[0] == 0)   // without this the key sticks down
    #expect(player.tick() == .finished)
}

@Test func keystrokeCarriesModifiers() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .keystroke(mods: Modifier.leftGUI.rawValue, key: KeyCode.b.rawValue, holdMs: 10)
    ]))
    guard case .report(let r) = player.tick() else {
        Issue.record("expected a report"); return
    }
    #expect(r.modifier == Modifier.leftGUI.rawValue)
}

@Test func delayEmitsEmptyReports() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.delay(ms: 30)]))
    for _ in 0..<3 {
        guard case .report(let r) = player.tick() else {
            Issue.record("expected an empty report"); return
        }
        #expect(r == HIDReport())
    }
    #expect(player.tick() == .finished)
}

@Test func textTypesOneCharacterAtATime() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.text("ab", msPerChar: 10)]))
    guard case .report(let first) = player.tick() else {
        Issue.record("expected 'a'"); return
    }
    #expect(first.keys[0] == KeyCode.a.rawValue)
    _ = player.tick()   // release between characters
    guard case .report(let second) = player.tick() else {
        Issue.record("expected 'b'"); return
    }
    #expect(second.keys[0] == KeyCode.b.rawValue)
}

@Test func uppercaseTextCarriesShift() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.text("A", msPerChar: 10)]))
    guard case .report(let r) = player.tick() else {
        Issue.record("expected a report"); return
    }
    #expect(r.keys[0] == KeyCode.a.rawValue)
    #expect(r.modifier == Modifier.leftShift.rawValue)
}

@Test func unmappableCharacterAbortsRatherThanGuessing() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.text("\u{7F}", msPerChar: 10)]))
    #expect(player.tick() == .finished)
}

@Test func repeatBlockRunsItsBodyNTimes() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .repeatBlock(count: 3, steps: [.delay(ms: 10)])
    ]))
    var ticks = 0
    while player.tick() != .finished {
        ticks += 1
        if ticks > 20 { Issue.record("did not terminate"); return }
    }
    #expect(ticks == 3)
}

@Test func repeatCountZeroSkipsTheBody() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .repeatBlock(count: 0, steps: [.delay(ms: 100)])
    ]))
    #expect(player.tick() == .finished)
}

@Test func retriggeringMidPlaybackIsIgnored() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.delay(ms: 100)]))
    _ = player.tick()
    player.start(MacroDefinition(id: 1, steps: [.delay(ms: 10)]))
    #expect(player.activeMacroID == 0)
}

@Test func emptyMacroFinishesImmediately() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: []))
    #expect(player.tick() == .finished)
}
