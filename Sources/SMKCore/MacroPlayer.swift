// Plays one macro back as a sequence of HID reports, advanced once per scan
// tick by the main loop. Pure: no hardware calls, no logging, no time source
// of its own -- the caller's tick cadence IS the clock, which is what makes
// every timing rule here testable on the host with no hardware and no
// sleeping. See docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md.
//
// Timing quantizes to the 10ms scan tick (`CONFIG_FREERTOS_HZ=100`) via
// `macroTicks(forMs:)`, which rounds UP so a sub-tick duration is never
// silently zero (a 5ms delay must still take one tick).

/// Ticks for a duration in milliseconds, rounding up so a sub-tick duration
/// is never silently zero.
func macroTicks(forMs ms: Int) -> Int { (max(0, ms) + 9) / 10 }

/// A layer-state change a `.layer` macro step (or the end of a macro run)
/// asks the caller to apply. `MacroPlayer` cannot touch `LayerEngine`
/// itself (see the file comment -- staying pure is what makes every timing
/// rule here host-testable), so it hands these back through `tick()`'s
/// `Output` for `Main.swift`, which already owns the engine, to apply via
/// `engine.addMomentaryLayer`/`engine.toggleLayer`/`engine.removeMomentaryLayer`.
///
/// `.momentary` and `.toggle` mirror the two cases `KeyEventProcessing`
/// forwards for a real key's *press* transition, and match the wire
/// format's `op == 0` ("mo") / `op == 1` ("tg"). The two ops are NOT
/// symmetric here: the configurator's Layer step editor labels a momentary
/// step "Momentary layer N *while running*" -- the layer is meant to be
/// active only for the remainder of the macro, released when it ends.
/// Unlike a physical key, a macro step has no release edge and the format
/// has no "release layer" step type, so the author has no way to write
/// that release even if they wanted to -- the player itself tracks every
/// layer it pushed and emits a matching `.momentaryRelease` (see `finish()`)
/// when the macro terminates, on every path (clean completion or an abort),
/// so `engine.momentaryCounts` always returns to where it started. `.toggle`
/// is deliberately not tracked this way: a toggle is meant to persist past
/// the macro, which is the whole point of the two ops being different.
/// `momentary`/`momentaryRelease` carry a `count` because a single tick can
/// legitimately push (or need to release) the same layer far more than once
/// -- a `repeatBlock` whose body is all `.layer` steps chains through all of
/// them in one `tick()` call (see `loadNextStepAndTick`'s doc comment), and
/// each repetition is a real push that must be balanced by a real release.
/// Collapsing those into a single `count`-bearing effect per layer (instead
/// of one effect per push) is what keeps `pendingLayerEffects` and
/// `finish()`'s release list bounded to at most 16 entries each -- see
/// `MacroPlayer`'s `pendingMomentaryPushCounts`/`momentaryPushCounts` doc
/// comments for why that bound matters. Applying `count` pushes (or
/// releases) at once via a loop over `engine.addMomentaryLayer`/
/// `removeMomentaryLayer` is exactly equivalent to applying them one at a
/// time: both increment/decrement a single per-layer `Int` counter, which is
/// commutative and order-independent.
enum LayerEffect: Equatable {
    case momentary(layer: Int, count: Int)
    case toggle(Int)
    /// Releases one momentary layer this player pushed earlier in the same
    /// run, emitted when the macro terminates. Never produced for `.toggle`.
    case momentaryRelease(layer: Int, count: Int)
}

/// One macro's playback state. A playing macro owns the report it produces:
/// `start(_:)` is ignored while another macro is already active, so a held
/// macro key does not retrigger/restart mid-playback.
struct MacroPlayer {
    enum Output: Equatable {
        case idle
        /// `layerEffects` are the layer changes (in order) that occurred
        /// while reaching this report -- `.layer` steps consume no tick of
        /// their own, so a chain of them can precede the step that actually
        /// produced this tick's report. Empty on every tick that continues
        /// an already-in-flight keystroke/delay/text step, since those
        /// don't consume a fresh step off the cursor.
        case report(HIDReport, layerEffects: [LayerEffect] = [])
        /// Same `layerEffects` meaning as `report`, for the tick that drains
        /// the last step(s) of the macro.
        case finished(layerEffects: [LayerEffect] = [])
    }

    private(set) var activeMacroID: Int? = nil
    var isActive: Bool { activeMacroID != nil }

    // The top-level step sequence being played, and the index of the next
    // step to pull from it.
    private var topSteps: [MacroStep] = []
    private var topIndex: Int = 0

    // Repeat-block state. Nested repeat blocks are already refused at
    // decode (Task 2), so at most one of these is ever active -- a single
    // counter suffices, no stack is needed.
    private var inRepeat: Bool = false
    private var repeatBody: [MacroStep] = []
    private var repeatIndex: Int = 0
    private var repeatRemaining: Int = 0

    // The atomic action currently in flight -- spans multiple ticks for
    // keystroke/text (hold ticks, then one release tick) and delay (N empty
    // ticks). `.none` means the next tick() call must pull a fresh step.
    private enum LeafKind {
        case none
        case keystroke
        case delay
        case text
    }
    private var leafKind: LeafKind = .none
    private var leafMods: UInt8 = 0
    private var leafKey: UInt8 = 0
    private var leafRemainingTicks: Int = 0

    // Text-step-only progress: the pending characters and where we are in
    // them. `leafTextReleased` marks that the current character's hold
    // ticks are done and its release report has already been emitted, so
    // the next tick() call should advance to the following character.
    private var leafTextBytes: [UInt8] = []
    private var leafTextIndex: Int = 0
    private var leafTextMsPerChar: Int = 0
    private var leafTextReleased: Bool = false

    // Only 16 layers exist (LayerEngine.toggledLayers/momentaryCounts are
    // both sized 16), so every per-layer accumulator below is a fixed-size
    // array, never one that grows with the number of `.layer` steps seen.
    static let layerCount = 16

    // FIX 2: caps how many steps `loadNextStepAndTick()`'s loop processes
    // in one `tick()` call, so a pathological macro degrades into running
    // slowly across several ticks instead of stalling the board on one.
    //
    // Sizing: the reviewer measured the ~345,000-step attack payload
    // (repeatBlock(count: 255, body: ~1350 .layer steps)) at ~0.1-0.2s on
    // real hardware, i.e. roughly 1.7M-3.5M steps/sec at 160MHz. At that
    // rate, 2000 steps costs on the order of 0.6-1.2ms -- a small slice of
    // the 10ms scan tick (CONFIG_FREERTOS_HZ=100), leaving the rest of the
    // tick for matrix scan/debounce, HID report send, and BLE servicing,
    // so the freeze this budget exists to prevent cannot recur even if a
    // macro keeps hitting the cap tick after tick. On the other side, no
    // hand-authored macro plausibly chains anywhere near 2000 zero-tick
    // `.layer`/zero-length-`.delay`/empty-`.text` steps back to back in a
    // single unbroken run -- a macro editor UI has no reason to ever
    // generate that shape, and even a generously long real macro's
    // occasional pair or trio of consecutive layer switches is 2-3 orders
    // of magnitude under this cap -- so no realistic macro's timing is
    // ever affected by it.
    static let stepBudgetPerTick = 2000

    // Per-layer state for `.layer` steps consumed so far during the
    // *current* `tick()` call. A `repeatBlock` built entirely of `.layer`
    // steps can chain through hundreds of thousands of them in one
    // `loadNextStepAndTick()` call (see that function's doc comment), so
    // this used to be a `[LayerEffect]` array that grew one element per
    // step -- a ~345,000-step attack payload built a multi-megabyte array
    // in one tick() call, on devices with 264-512KB of total RAM. Since
    // `toggledLayers`/`momentaryCounts` are separate fixed-size arrays and
    // a layer's push-count/toggle-parity is all that ultimately reaches
    // them, collecting per-layer counts here first and only turning them
    // into `LayerEffect` values when `tick()` actually returns (see
    // `drainPendingLayerEffects()`) is exactly equivalent to the old
    // one-entry-per-step scheme, and bounds `pendingLayerEffects` to at
    // most `layerCount` momentary entries plus `layerCount` toggle entries
    // -- 32 total, regardless of how many `.layer` steps fed into it.
    // Drained and zeroed by `tick()` itself right before returning, so
    // nothing leaks into the next call.
    private var pendingMomentaryPushCounts = [Int](repeating: 0, count: MacroPlayer.layerCount)
    private var pendingToggleFlips = [Bool](repeating: false, count: MacroPlayer.layerCount)

    // How many times a `.momentary` step has pushed each layer during the
    // *whole* current run (not just this tick) -- index is the layer
    // number, value is the outstanding push count. Same rationale as
    // `pendingMomentaryPushCounts`: this used to be a `[Int]` array with one
    // entry appended per push (unbounded across a whole run -- e.g.
    // `repeat 255 { 1200x MO(n), delay(10ms) }` grows it by 306,000 entries
    // over ~2.5s), and is now a fixed 16-slot array of counts instead.
    // `finish()` reads this to emit exactly enough `.momentaryRelease`
    // effects (at most one per layer, each carrying its own count) to leave
    // `engine.momentaryCounts` balanced. `.toggle` steps never touch this.
    private var momentaryPushCounts = [Int](repeating: 0, count: MacroPlayer.layerCount)

    /// Begins playing `macro`. Ignored while a macro is already playing.
    mutating func start(_ macro: MacroDefinition) {
        guard activeMacroID == nil else { return }
        activeMacroID = macro.id
        topSteps = macro.steps
        topIndex = 0
        inRepeat = false
        repeatBody = []
        repeatIndex = 0
        repeatRemaining = 0
        leafKind = .none
        leafTextReleased = false
        pendingMomentaryPushCounts = [Int](repeating: 0, count: MacroPlayer.layerCount)
        pendingToggleFlips = [Bool](repeating: false, count: MacroPlayer.layerCount)
        momentaryPushCounts = [Int](repeating: 0, count: MacroPlayer.layerCount)
    }

    /// Ends the current run and releases every momentary layer it pushed
    /// (one release per layer with an outstanding push, each carrying that
    /// layer's full count -- order between layers doesn't affect whether
    /// the counts balance) so `engine.momentaryCounts` returns to where it
    /// started. Called from every termination path: clean completion in
    /// `loadNextStepAndTick()` and the unmappable-character abort in
    /// `beginValidatedTextChar()` alike -- an abort that skipped this would
    /// leave the same stuck-layer defect back in the door FIX 2 closed.
    private mutating func finish() -> Output {
        activeMacroID = nil
        // At most `layerCount` (16) entries -- one per layer with an
        // outstanding push, each carrying that layer's full count, rather
        // than one entry per push (see `momentaryPushCounts`'s doc
        // comment). Release order no longer matters now that pushes are
        // collapsed to counts: `engine.removeMomentaryLayer` only ever
        // decrements a single per-layer counter, which doesn't care which
        // layer's counter is touched first.
        var releases: [LayerEffect] = []
        for layer in 0..<MacroPlayer.layerCount where momentaryPushCounts[layer] > 0 {
            releases.append(.momentaryRelease(layer: layer, count: momentaryPushCounts[layer]))
        }
        momentaryPushCounts = [Int](repeating: 0, count: MacroPlayer.layerCount)
        return .finished(layerEffects: releases)
    }

    /// Advances playback by exactly one scan tick and returns the report
    /// (or lack thereof) the caller should send this tick, plus any layer
    /// effects (see `LayerEffect`) that occurred while getting there.
    mutating func tick() -> Output {
        guard activeMacroID != nil else { return .idle }

        let output: Output
        switch leafKind {
        case .none:
            output = loadNextStepAndTick()
        case .keystroke:
            output = tickKeystroke()
        case .delay:
            output = tickDelay()
        case .text:
            output = tickText()
        }
        return attachPendingLayerEffects(to: output)
    }

    /// Turns this call's per-layer counters into a bounded `[LayerEffect]`
    /// list (at most `layerCount` momentary entries plus `layerCount`
    /// toggle entries -- 32 total) and zeroes them, regardless of how many
    /// `.layer` steps fed into them this tick.
    private mutating func drainPendingLayerEffects() -> [LayerEffect] {
        var effects: [LayerEffect] = []
        for layer in 0..<MacroPlayer.layerCount {
            if pendingMomentaryPushCounts[layer] > 0 {
                effects.append(.momentary(layer: layer, count: pendingMomentaryPushCounts[layer]))
                pendingMomentaryPushCounts[layer] = 0
            }
            if pendingToggleFlips[layer] {
                effects.append(.toggle(layer))
                pendingToggleFlips[layer] = false
            }
        }
        return effects
    }

    /// Merges any layer effects accumulated this call onto `output`, so a
    /// single `tick()` call reports every `.layer` step it passed through --
    /// not just the last one -- while still returning exactly one `Output`
    /// value.
    private mutating func attachPendingLayerEffects(to output: Output) -> Output {
        let pending = drainPendingLayerEffects()
        guard !pending.isEmpty else { return output }
        switch output {
        case .idle:
            return output
        case .report(let report, let more):
            return .report(report, layerEffects: pending + more)
        case .finished(let more):
            return .finished(layerEffects: pending + more)
        }
    }

    /// Pulls steps off the cursor (transparently expanding repeat blocks),
    /// applying each one that consumes no tick of its own -- `.layer`, a
    /// zero-length `.delay`, an empty `.text` step -- inline and moving on
    /// to the next, until one actually produces output (or the macro runs
    /// out). Returns `.finished` once the whole macro is done.
    ///
    /// This is a loop, not recursion, on purpose: a step that consumes no
    /// tick used to `return` a fresh recursive call to this same function,
    /// so a repeat block built entirely of such steps recursed once per
    /// step with no tick ever unwinding the stack in between -- unbounded
    /// by any size limit this format's own bounds checks enforce (a
    /// well-under-the-payload-limit `repeatBlock(count: 255, body: ~1350
    /// zero-tick steps)` recurses roughly 345,000 levels deep in a single
    /// call). That is a stack-overflow panic on ESP32-C6 and silent memory
    /// corruption on RP2040 (no MPU stack guard), on every press, since the
    /// keymap lives in flash. A `while true` loop processes any number of
    /// zero-tick steps in constant stack space.
    ///
    /// The loop is also capped at `stepBudgetPerTick` steps per call (see
    /// its doc comment): with the stack/heap risks fixed, the same
    /// ~345,000-step payload still runs entirely within one `Main.swift`
    /// `tick()` call with no `vTaskDelay` in between -- a fraction-of-a-
    /// second freeze with no matrix scan, HID report, or BLE servicing.
    /// Hitting the cap parks the cursor exactly where it is (every field
    /// `consumeNextStep()` advances -- `topIndex`/`repeatIndex`/
    /// `repeatRemaining` -- is a stored property, so there is no separate
    /// state to save) and returns a neutral all-keys-up report for this
    /// tick; the next `tick()` call resumes the loop from that same cursor,
    /// so a pathological macro spreads across extra ticks instead of
    /// stalling the board on one.
    private mutating func loadNextStepAndTick() -> Output {
        var stepsThisCall = 0
        while true {
            if stepsThisCall >= Self.stepBudgetPerTick {
                return .report(HIDReport())
            }

            guard let step = consumeNextStep() else {
                return finish()
            }
            stepsThisCall += 1

            switch step {
            case .keystroke(let mods, let key, let holdMs):
                leafKind = .keystroke
                leafMods = mods
                leafKey = key
                // `macroTicks` rounds up specifically so a sub-tick duration
                // is never silently zero -- but it cannot save an actual
                // `holdMs == 0` (the round-up formula is `(0 + 9) / 10 ==
                // 0`), and the JSON decode path's defaults don't bound it
                // away the way the editor's UI sliders do. Without this
                // clamp the step falls straight to the release branch below
                // and the key is never pressed at all: the report goes
                // out with the key already released, on every hold this
                // short. `max(1, ...)` matches the round-up rule's own
                // stated intent -- every keystroke holds for at least one
                // tick.
                leafRemainingTicks = max(1, macroTicks(forMs: holdMs))
                return tickKeystroke()

            case .delay(let ms):
                let ticks = macroTicks(forMs: ms)
                guard ticks > 0 else {
                    // A zero-length delay consumes no tick of its own.
                    continue
                }
                leafKind = .delay
                leafRemainingTicks = ticks
                return tickDelay()

            case .text(let string, let msPerChar):
                leafTextBytes = Array(string.utf8)
                leafTextIndex = 0
                leafTextMsPerChar = msPerChar
                leafTextReleased = false
                guard leafTextIndex < leafTextBytes.count else {
                    // An empty text step consumes no tick of its own.
                    leafKind = .none
                    continue
                }
                return beginValidatedTextChar()

            case .layer(let momentary, let n):
                // A layer switch is main-loop arbitration -- this player is
                // pure and cannot touch `LayerEngine` itself, so it records
                // the effect for `tick()` to attach to whatever Output this
                // call eventually produces (see `pendingMomentaryPushCounts`/
                // `pendingToggleFlips`) and moves on; the step itself
                // consumes no tick of its own. Momentary pushes are also
                // remembered so `finish()` can release them when the macro
                // ends -- toggle is not, since a toggle is meant to persist
                // past the macro. `n` comes straight off the wire and is
                // not bounds-checked upstream, so guard the accumulator
                // index here the same way `LayerEngine.addMomentaryLayer`/
                // `toggleLayer` guard theirs -- an out-of-range layer is
                // already a no-op end-to-end (nothing ever reads a counter
                // outside 0..<16), so dropping it here is exactly
                // equivalent, not a behavior change.
                if n >= 0 && n < MacroPlayer.layerCount {
                    if momentary {
                        pendingMomentaryPushCounts[n] += 1
                        momentaryPushCounts[n] += 1
                    } else {
                        pendingToggleFlips[n].toggle()
                    }
                }
                continue

            case .repeatBlock:
                // consumeNextStep() always expands repeat blocks into their
                // body internally and never returns this case -- unreachable,
                // but skip rather than recurse if it ever were.
                continue
            }
        }
    }

    /// Returns the next atomic (non-repeat-block) step to execute, or `nil`
    /// once the whole macro -- including any in-progress repeat -- is
    /// exhausted. Repeat blocks are expanded transparently: a count of zero
    /// skips the body entirely, and the single `repeatRemaining` counter is
    /// decremented each time the body runs out, looping back to its start
    /// until exhausted.
    private mutating func consumeNextStep() -> MacroStep? {
        while true {
            if inRepeat {
                if repeatIndex < repeatBody.count {
                    let step = repeatBody[repeatIndex]
                    repeatIndex += 1
                    return step
                }
                repeatRemaining -= 1
                if repeatRemaining > 0 {
                    repeatIndex = 0
                    continue
                }
                inRepeat = false
                continue
            }

            guard topIndex < topSteps.count else { return nil }
            let step = topSteps[topIndex]
            topIndex += 1

            if case .repeatBlock(let count, let body) = step {
                guard count > 0 else { continue }
                inRepeat = true
                repeatBody = body
                repeatIndex = 0
                repeatRemaining = count
                continue
            }
            return step
        }
    }

    // MARK: - Keystroke

    private mutating func tickKeystroke() -> Output {
        if leafRemainingTicks > 0 {
            leafRemainingTicks -= 1
            var report = HIDReport()
            report.modifier = leafMods
            report.addKey(leafKey)
            return .report(report)
        }
        // Hold ticks exhausted (or the step held for zero ticks): emit the
        // release report before advancing. Without this the key stays down
        // in the host's view for the rest of the macro.
        leafKind = .none
        return .report(HIDReport())
    }

    // MARK: - Delay

    private mutating func tickDelay() -> Output {
        leafRemainingTicks -= 1
        if leafRemainingTicks <= 0 {
            leafKind = .none
        }
        return .report(HIDReport())
    }

    // MARK: - Text

    /// Begins the next character of the current text step, or falls through
    /// to the next macro step once every character has been typed. The
    /// fall-through is a single hand-off to `loadNextStepAndTick()` (itself
    /// a loop, not recursion) -- it fires at most once per character, never
    /// chained, so it carries none of the unbounded-recursion risk a
    /// zero-tick *macro step* used to.
    private mutating func beginTextChar() -> Output {
        guard leafTextIndex < leafTextBytes.count else {
            leafKind = .none
            return loadNextStepAndTick()
        }
        return beginValidatedTextChar()
    }

    /// Validates the character at `leafTextIndex` maps to a keystroke,
    /// aborting the whole macro (rather than typing a substitute) if it does
    /// not, and starts that character's hold ticks. Assumes the caller has
    /// already checked `leafTextIndex < leafTextBytes.count`.
    private mutating func beginValidatedTextChar() -> Output {
        guard let (usage, shift) = asciiKeystroke(leafTextBytes[leafTextIndex]) else {
            // Abort still counts as termination: any momentary layer this
            // run pushed before hitting the unmappable character must still
            // be released here, or the stuck-layer defect comes back
            // through this path alone.
            return finish()
        }
        leafKind = .text
        leafMods = shift ? Modifier.leftShift.rawValue : 0
        leafKey = usage
        // Same reasoning as the keystroke step's clamp above: an imported
        // or hand-edited macro's "cpm": 0 survives JSON decode (only the
        // editor's UI sliders bound it away), and without this, a
        // `msPerChar == 0` text step would emit one empty report per
        // character and type nothing while still running for the right
        // total duration.
        leafRemainingTicks = max(1, macroTicks(forMs: leafTextMsPerChar))
        leafTextReleased = false
        return tickText()
    }

    private mutating func tickText() -> Output {
        if leafRemainingTicks > 0 {
            leafRemainingTicks -= 1
            var report = HIDReport()
            report.modifier = leafMods
            report.addKey(leafKey)
            return .report(report)
        }
        if !leafTextReleased {
            // One character's hold ticks are done: release it before
            // moving on to the next character, same as a keystroke step.
            leafTextReleased = true
            return .report(HIDReport())
        }
        leafTextIndex += 1
        return beginTextChar()
    }
}
