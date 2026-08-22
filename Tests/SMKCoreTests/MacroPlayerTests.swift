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

@Test func zeroHoldMsStillPressesTheKeyForOneTick() {
    // FIX 4: macroTicks(forMs: 0) == 0, so without a clamp this step would
    // fall straight to tickKeystroke()'s release branch and the key would
    // never be pressed at all -- a keystroke that "runs" but types nothing.
    // The editor's UI sliders bound holdMs away from 0, but an imported or
    // hand-edited macro's JSON decode defaults do not.
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .keystroke(mods: 0, key: KeyCode.b.rawValue, holdMs: 0)
    ]))
    guard case .report(let held, _) = player.tick() else {
        Issue.record("expected the key to be pressed for at least one tick"); return
    }
    #expect(held.keys[0] == KeyCode.b.rawValue)
    guard case .report(let release, _) = player.tick() else {
        Issue.record("expected a release report"); return
    }
    #expect(release.keys[0] == 0)
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

@Test func zeroMsPerCharStillTypesEachCharacterForOneTick() {
    // FIX 4: same clamp as the keystroke case, for text. Without it,
    // "cpm": 0 (which the JSON decode path doesn't bound away, unlike the
    // editor's UI slider) would emit one empty report per character and
    // run for the "right" total duration while typing nothing at all.
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.text("ab", msPerChar: 0)]))
    guard case .report(let first, _) = player.tick() else {
        Issue.record("expected 'a' to actually be pressed"); return
    }
    #expect(first.keys[0] == KeyCode.a.rawValue)
    _ = player.tick()   // release between characters
    guard case .report(let second, _) = player.tick() else {
        Issue.record("expected 'b' to actually be pressed"); return
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
    #expect(firstEffects == [.momentary(layer: 2, count: 1)])

    // Tick 2: the release report, no new layer step reached yet.
    guard case .report(let release, let releaseEffects) = player.tick() else {
        Issue.record("expected the release report"); return
    }
    #expect(release == HIDReport())
    #expect(releaseEffects == [])

    // Tick 3: the trailing .layer step is the last thing in the macro, so
    // it rides along with `.finished` instead of a report -- immediately
    // followed by both momentary pushes this run ever made (2, then 0)
    // being released. Release order is by layer index now (see
    // `finish()`'s doc comment -- it no longer matters for correctness),
    // which for layers 0 and 2 happens to read the same as reverse-push
    // order.
    guard case .finished(let lastEffects) = player.tick() else {
        Issue.record("expected finished"); return
    }
    #expect(lastEffects == [
        .momentary(layer: 0, count: 1),
        .momentaryRelease(layer: 0, count: 1),
        .momentaryRelease(layer: 2, count: 1),
    ])
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
    #expect(effects == [.momentary(layer: 1, count: 1), .toggle(2)])
}

// MARK: - Unbounded recursion (FIX 1) and unbounded allocation (heap-fix review)

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
    // number of zero-tick steps in constant stack space.
    //
    // A follow-up review found the loop-based fix had traded that stack
    // crash for an equally lethal *heap* crash: `pendingLayerEffects` used
    // to be a `[LayerEffect]` array that grew one element per `.layer` step,
    // so this exact payload built a ~5.5MB array (LayerEffect's stride is
    // 16 bytes on 64-bit) in one `tick()` call -- on hardware with
    // 264-512KB of total RAM. This test used to assert
    // `effects.count == bodyLength * repeatCount` (344,250), which is the
    // old bug enshrined as a passing assertion: it demanded exactly the
    // giant allocation that made the payload lethal. The fix (see
    // `MacroPlayer.pendingMomentaryPushCounts`/`momentaryPushCounts`)
    // collapses per-layer effects to fixed-size counters (16 layers exist),
    // so no `LayerEffect` list this produces can ever exceed 16 entries --
    // asserted below instead of the old exact count.
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
    // At most one entry per layer (16 layers exist) -- not one per `.layer`
    // step, and nowhere near `bodyLength * repeatCount` (344,250).
    #expect(effects.count <= MacroPlayer.layerCount)
}

// MARK: - Momentary layers auto-release when a macro ends

// `applyMacroLayerEffects` (the real consumer of `LayerEffect`) lives in
// Sources/smk/Main.swift, which cannot be compiled or tested on the host
// (no ESP-IDF checkout; see Package.swift's comment on the `smk` target).
// This local duplicate lets these tests exercise the actual contract --
// MacroPlayer produces the right effects, and applying them via
// LayerEngine's own public momentary/toggle API produces the right engine
// state -- entirely within the host-testable SMKCore target.
private func apply(_ effects: [LayerEffect], to engine: inout LayerEngine) {
    for effect in effects {
        switch effect {
        case .momentary(let layer, let count):
            for _ in 0..<count { engine.addMomentaryLayer(layer) }
        case .toggle(let layer):
            engine.toggleLayer(layer)
        case .momentaryRelease(let layer, let count):
            for _ in 0..<count { engine.removeMomentaryLayer(layer) }
        }
    }
}

/// Pumps `player.tick()` (applying every effect it produces to `engine`
/// along the way, exactly like `Main.swift`'s scan loop would) until the
/// macro finishes or aborts.
private func runToCompletion(_ player: inout MacroPlayer, applying engine: inout LayerEngine, maxTicks: Int = 10_000) {
    for _ in 0..<maxTicks {
        switch player.tick() {
        case .report(_, let effects):
            apply(effects, to: &engine)
        case .finished(let effects):
            apply(effects, to: &engine)
            return
        case .idle:
            return
        }
    }
    Issue.record("macro did not finish within \(maxTicks) ticks")
}

@Test func momentaryLayerReleasesWhenMacroFinishes() {
    // The configurator's Layer step editor labels this step "Momentary
    // layer 2 *while running*" -- the layer is meant to be active only for
    // the remainder of the macro. There is no "release layer" step type a
    // macro author could write themselves, so the player itself must
    // release it when the macro ends.
    var engine = LayerEngine()
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .layer(momentary: true, n: 2),
        .keystroke(mods: 0, key: KeyCode.f1.rawValue, holdMs: 10),
    ]))

    guard case .report(_, let firstEffects) = player.tick() else {
        Issue.record("expected the keystroke's hold report"); return
    }
    apply(firstEffects, to: &engine)
    #expect(engine.isLayerActive(2) == true)   // pushed, and the macro is still running

    runToCompletion(&player, applying: &engine)
    #expect(engine.isLayerActive(2) == false)  // released now that the macro has ended
}

@Test func toggleLayerStaysActiveAfterMacroFinishes() {
    // Toggle is deliberately NOT auto-released -- persisting past the
    // macro is the whole point of `tg` versus `mo`.
    var engine = LayerEngine()
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.layer(momentary: false, n: 2)]))
    runToCompletion(&player, applying: &engine)
    #expect(engine.isLayerActive(2) == true)
}

@Test func pushingTheSameMomentaryLayerTwiceBalancesOnFinish() {
    var engine = LayerEngine()
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .layer(momentary: true, n: 2),
        .layer(momentary: true, n: 2),
    ]))
    runToCompletion(&player, applying: &engine)
    // Two pushes must be matched by exactly two releases -- if the player
    // only released once, momentaryCounts[2] would still be 1 and this
    // would incorrectly report active.
    #expect(engine.isLayerActive(2) == false)
}

@Test func pushingTwoDifferentMomentaryLayersBalancesOnFinish() {
    var engine = LayerEngine()
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .layer(momentary: true, n: 2),
        .layer(momentary: true, n: 3),
    ]))
    runToCompletion(&player, applying: &engine)
    #expect(engine.isLayerActive(2) == false)
    #expect(engine.isLayerActive(3) == false)
}

@Test func momentaryLayerReleasesOnAbortToo() {
    // An unmappable character aborts a macro mid-run (see
    // unmappableCharacterAbortsRatherThanGuessing). If that path skipped
    // releasing momentary layers, the stuck-layer defect would come back
    // through the abort door alone -- releases must happen on every
    // termination path, not just clean completion.
    var engine = LayerEngine()
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .layer(momentary: true, n: 2),
        .text("\u{7F}", msPerChar: 10),
    ]))
    runToCompletion(&player, applying: &engine)
    #expect(player.isActive == false)
    #expect(engine.isLayerActive(2) == false)
}
