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

/// One macro's playback state. A playing macro owns the report it produces:
/// `start(_:)` is ignored while another macro is already active, so a held
/// macro key does not retrigger/restart mid-playback.
struct MacroPlayer {
    enum Output: Equatable {
        case idle
        case report(HIDReport)
        case finished
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
    }

    /// Advances playback by exactly one scan tick and returns the report
    /// (or lack thereof) the caller should send this tick.
    mutating func tick() -> Output {
        guard activeMacroID != nil else { return .idle }

        switch leafKind {
        case .none:
            return loadNextStepAndTick()
        case .keystroke:
            return tickKeystroke()
        case .delay:
            return tickDelay()
        case .text:
            return tickText()
        }
    }

    /// Pulls the next atomic step off the cursor (transparently expanding
    /// repeat blocks) and begins executing it, returning that step's first
    /// tick of output. Returns `.finished` once the whole macro is done.
    private mutating func loadNextStepAndTick() -> Output {
        guard let step = consumeNextStep() else {
            activeMacroID = nil
            return .finished
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
                return loadNextStepAndTick()
            }
            leafKind = .delay
            leafRemainingTicks = ticks
            return tickDelay()

        case .text(let string, let msPerChar):
            leafTextBytes = Array(string.utf8)
            leafTextIndex = 0
            leafTextMsPerChar = msPerChar
            leafTextReleased = false
            return beginTextChar()

        case .layer:
            // Layer switching during macro playback is main-loop
            // arbitration wiring, out of scope for this task (see the
            // design doc's task breakdown) -- this step is a no-op here
            // and consumes no tick of its own.
            return loadNextStepAndTick()

        case .repeatBlock:
            // consumeNextStep() always expands repeat blocks into their
            // body internally and never returns this case; unreachable.
            return loadNextStepAndTick()
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

    /// Begins the next character of the current text step: validates it
    /// maps to a keystroke, aborting the whole macro (rather than typing a
    /// substitute) if it does not, and starts that character's hold ticks.
    /// Falls through to the next macro step once every character has been
    /// typed.
    private mutating func beginTextChar() -> Output {
        guard leafTextIndex < leafTextBytes.count else {
            leafKind = .none
            return loadNextStepAndTick()
        }
        guard let (usage, shift) = asciiKeystroke(leafTextBytes[leafTextIndex]) else {
            activeMacroID = nil
            return .finished
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
