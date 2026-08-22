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
        guard case .report(let r, _) = player.tick() else {
            Issue.record("expected a held report"); return
        }
        #expect(r.keys[0] == KeyCode.b.rawValue)
    }
    guard case .report(let release, _) = player.tick() else {
        Issue.record("expected a release report"); return
    }
    #expect(release.keys[0] == 0)   // without this the key sticks down
    #expect(player.tick() == .finished())
}

@Test func keystrokeCarriesModifiers() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .keystroke(mods: Modifier.leftGUI.rawValue, key: KeyCode.b.rawValue, holdMs: 10)
    ]))
    guard case .report(let r, _) = player.tick() else {
        Issue.record("expected a report"); return
    }
    #expect(r.modifier == Modifier.leftGUI.rawValue)
}

@Test func delayEmitsEmptyReports() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.delay(ms: 30)]))
    for _ in 0..<3 {
        guard case .report(let r, _) = player.tick() else {
            Issue.record("expected an empty report"); return
        }
        #expect(r == HIDReport())
    }
    #expect(player.tick() == .finished())
}

@Test func textTypesOneCharacterAtATime() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.text("ab", msPerChar: 10)]))
    guard case .report(let first, _) = player.tick() else {
        Issue.record("expected 'a'"); return
    }
    #expect(first.keys[0] == KeyCode.a.rawValue)
    _ = player.tick()   // release between characters
    guard case .report(let second, _) = player.tick() else {
        Issue.record("expected 'b'"); return
    }
    #expect(second.keys[0] == KeyCode.b.rawValue)
}

@Test func uppercaseTextCarriesShift() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.text("A", msPerChar: 10)]))
    guard case .report(let r, _) = player.tick() else {
        Issue.record("expected a report"); return
    }
    #expect(r.keys[0] == KeyCode.a.rawValue)
    #expect(r.modifier == Modifier.leftShift.rawValue)
}

@Test func unmappableCharacterAbortsRatherThanGuessing() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.text("\u{7F}", msPerChar: 10)]))
    #expect(player.tick() == .finished())
}

@Test func repeatBlockRunsItsBodyNTimes() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .repeatBlock(count: 3, steps: [.delay(ms: 10)])
    ]))
    var ticks = 0
    while player.tick() != .finished() {
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
    #expect(player.tick() == .finished())
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
    #expect(player.tick() == .finished())
}

// MARK: - Layer effects (FIX 2: .layer steps must not be silently discarded)

@Test func layerStepsProduceEffectsInOrder() {
    // The exact shape the whole-branch review flagged: MO(2), F1, MO(0).
    // Before this fix, both `.layer` steps were no-ops and vanished; now
    // each must surface, in order, on the `Output` of the tick that reaches
    // it -- attached to whatever the player would otherwise have returned.
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .layer(momentary: true, n: 2),
        .keystroke(mods: 0, key: KeyCode.f1.rawValue, holdMs: 10),
        .layer(momentary: true, n: 0),
    ]))

    // Tick 1: the leading .layer step consumes no tick of its own, so it
    // chains straight into the keystroke's first (and only, holdMs: 10 is
    // one tick) hold report -- both surface together.
    guard case .report(let held, let firstEffects) = player.tick() else {
        Issue.record("expected the keystroke's hold report"); return
    }
    #expect(held.keys[0] == KeyCode.f1.rawValue)
    #expect(firstEffects == [.momentary(2)])

    // Tick 2: the release report, no new layer step reached yet.
    guard case .report(let release, let releaseEffects) = player.tick() else {
        Issue.record("expected the release report"); return
    }
    #expect(release == HIDReport())
    #expect(releaseEffects == [])

    // Tick 3: the trailing .layer step is the last thing in the macro, so
    // it rides along with `.finished` instead of a report.
    guard case .finished(let lastEffects) = player.tick() else {
        Issue.record("expected finished"); return
    }
    #expect(lastEffects == [.momentary(0)])
}

@Test func toggleLayerStepProducesToggleEffect() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.layer(momentary: false, n: 5)]))
    guard case .finished(let effects) = player.tick() else {
        Issue.record("expected finished"); return
    }
    #expect(effects == [.toggle(5)])
}

@Test func consecutiveZeroTickLayerStepsAllSurfaceOnTheSameTick() {
    // Multiple .layer steps in a row each consume no tick, so
    // loadNextStepAndTick() chains through all of them before it reaches a
    // step that actually produces output (here, a delay) -- every effect
    // collected along the way must appear on that one tick's Output, in
    // the order encountered, not just the most recent one.
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .layer(momentary: true, n: 1),
        .layer(momentary: false, n: 2),
        .delay(ms: 10),
    ]))
    guard case .report(_, let effects) = player.tick() else {
        Issue.record("expected the delay's report"); return
    }
    #expect(effects == [.momentary(1), .toggle(2)])
}

// MARK: - Unbounded recursion (FIX 1)

@Test func hugeChainOfZeroTickStepsDoesNotOverflowTheStack() {
    // Regression for the whole-branch review's stack-overflow finding:
    // loadNextStepAndTick() used to `return` a fresh recursive call for
    // every step that consumes no tick (.layer, a zero-length .delay, an
    // exhausted .text step), so a repeat block built entirely of such steps
    // recursed once per step with no tick ever unwinding the stack in
    // between. This macro -- one repeatBlock(count: 255, body: ~1350 layer
    // steps), the exact shape cited in the review -- is well inside the
    // payload size limit and passes every bounds check, yet would have
    // recursed roughly 345,000 levels deep in a single tick() call: a
    // FreeRTOS stack-overflow panic on ESP32-C6, silent memory corruption on
    // RP2040 (no MPU stack guard), on every press since the keymap lives in
    // flash. The `while true` loop this was rewritten as processes any
    // number of zero-tick steps in constant stack space -- this test's own
    // survival (and the correct effect count) is the regression guard.
    let bodyLength = 1350
    let repeatCount = 255
    let body = (0..<bodyLength).map { MacroStep.layer(momentary: false, n: $0 % 16) }
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .repeatBlock(count: repeatCount, steps: body)
    ]))

    guard case .finished(let effects) = player.tick() else {
        Issue.record("expected the whole chain to finish within a single tick() call"); return
    }
    #expect(effects.count == bodyLength * repeatCount)
}
