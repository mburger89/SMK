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

/// A layer-state change a `.layer` macro step asks the caller to apply.
/// `MacroPlayer` cannot touch `LayerEngine` itself (see the file comment --
/// staying pure is what makes every timing rule here host-testable), so it
/// hands these back through `tick()`'s `Output` for `Main.swift`, which
/// already owns the engine, to apply via `engine.toggleLayer`/
/// `engine.addMomentaryLayer`. Mirrors the two cases `KeyEventProcessing`
/// forwards for a real key's *press* transition -- a macro step is a single
/// instant, not a hold, so there is no corresponding release/pop; an
/// `.momentary` effect is a one-shot push exactly like the wire format's
/// `op == 0` ("mo"), and pairing it with a later release is the macro
/// author's responsibility, same as it is for a physical key.
enum LayerEffect: Equatable {
    case momentary(Int)
    case toggle(Int)
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

    // Layer effects collected by `.layer` steps consumed so far during the
    // *current* `tick()` call -- possibly more than one, since a `.layer`
    // step consumes no tick and `loadNextStepAndTick()` keeps pulling steps
    // until one actually produces output. Drained and cleared by `tick()`
    // itself right before returning, so it never leaks into the next call.
    private var pendingLayerEffects: [LayerEffect] = []

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
        pendingLayerEffects = []
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

    /// Merges any layer effects accumulated this call onto `output` and
    /// clears them, so a single `tick()` call reports every `.layer` step it
    /// passed through -- not just the last one -- while still returning
    /// exactly one `Output` value.
    private mutating func attachPendingLayerEffects(to output: Output) -> Output {
        guard !pendingLayerEffects.isEmpty else { return output }
        defer { pendingLayerEffects = [] }
        switch output {
        case .idle:
            return output
        case .report(let report, let more):
            return .report(report, layerEffects: pendingLayerEffects + more)
        case .finished(let more):
            return .finished(layerEffects: pendingLayerEffects + more)
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
    private mutating func loadNextStepAndTick() -> Output {
        while true {
            guard let step = consumeNextStep() else {
                activeMacroID = nil
                return .finished()
            }

            switch step {
            case .keystroke(let mods, let key, let holdMs):
                leafKind = .keystroke
                leafMods = mods
                leafKey = key
                leafRemainingTicks = macroTicks(forMs: holdMs)
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
                // call eventually produces (see `pendingLayerEffects`) and
                // moves on; the step itself consumes no tick of its own.
                pendingLayerEffects.append(momentary ? .momentary(n) : .toggle(n))
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
            activeMacroID = nil
            return .finished()
        }
        leafKind = .text
        leafMods = shift ? Modifier.leftShift.rawValue : 0
        leafKey = usage
        leafRemainingTicks = macroTicks(forMs: leafTextMsPerChar)
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
