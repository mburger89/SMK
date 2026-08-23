# Firmware Macro Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the configurator's macro JSON actually execute on a board — a key bound to `macro:N` plays its steps back as real HID reports.

**Architecture:** A pure `MacroPlayer` state machine in `SMKCore`, advanced once per 10ms scan tick by the existing main loop. While it is active its report *is* the HID report. Macros are parsed from the `"macros"` key of the uploaded `keymap.json` by `LayerEngine`, using the cJSON it already uses for layers. Storage ceilings become per-port, with a dedicated flash partition on ESP32-C6 and a boot migration on RP2040.

**Tech Stack:** Swift 6 / Embedded Swift, Swift Testing (`import Testing`, bare `@Test func`), ESP-IDF (ESP32-C6), pico-sdk (RP2040), cJSON.

**Spec:** `docs/superpowers/specs/2026-08-21-firmware-macro-playback-design.md`

## Global Constraints

- **Test with `SMK_HOST_TESTS_ONLY=1 swift test`.** Not a bare `swift test` — with that variable unset, `swift-mmio` becomes a dependency and the resolve churns `Package.resolved`, which is deliberately untracked.
- **THE TRAP: a new file in `Sources/SMKCore/` is invisible to every embedded build until it is listed in all six CMakeLists that enumerate SMKCore sources explicitly** — `main/CMakeLists.txt` plus `ports/{rp2040,nrf52840,samd21,stm32f4,stm32wb}/CMakeLists.txt`. `Package.swift` globs the directory, so a missing CMake entry **still passes `swift test`** and only surfaces as a link failure on real hardware. This plan adds two new SMKCore files. Every task that adds one must edit all six.
- **`SMKCore` compiles under Embedded Swift for the boards.** No `Any`, no reflection, no existentials, no `Codable`. Structs, enums, arrays and non-escaping closures only — match what `processKeyEvents` and `LayerEngine` already do.
- **The byte contract is fixed and already shipped.** `~/esp/smk_configurator/CLAUDE.md` specifies opcodes, endianness, modifier bit order, keycode derivation and the JSON schema. Do not redesign it; implement it. Any disagreement between this firmware and that document is a bug in this firmware.
- **Timing quantizes to the scan tick.** `CONFIG_FREERTOS_HZ=100`, so 10 ms. Convert milliseconds to ticks with `(ms + 9) / 10` — rounding **up**, so a 5 ms delay is never silently zero.
- **A playing macro owns the HID report.** Live keys produce nothing until it finishes.
- Commit after every task. Do not push.

---

## File Structure

**Create:**
- `Sources/SMKCore/MacroPlayer.swift` — the macro model, parsing, and the playback state machine
- `Sources/SMKCore/AsciiKeycodes.swift` — printable-ASCII → (HID usage, shift) table
- `Tests/SMKCoreTests/MacroPlayerTests.swift`
- `Tests/SMKCoreTests/AsciiKeycodesTests.swift`
- `partitions.csv` — custom partition table with a dedicated `keymap` region
- `Sources/smk/KeymapStorePartition.swift` — ESP32-C6 backend replacing `KeymapStoreNVS.swift`

**Modify:**
- `Sources/SMKCore/LayerEngine.swift` — `KeyAction.macro`, parse `"macros"`
- `Sources/SMKCore/KeyEventProcessing.swift` — emit `macroEvents`
- `Sources/SMKCore/KeymapFrame.swift` — per-port `smkKeymapMaxLen`
- `Sources/SMKCore/KeymapProtocol.swift` — `CAPS` opcode `0x05`
- `Sources/smk/Main.swift` — player arbitration in the scan loop
- `ports/rp2040/KeymapStoreFlash.swift` — 4 sectors + boot migration
- `main/CMakeLists.txt`, `ports/{rp2040,nrf52840,samd21,stm32f4,stm32wb}/CMakeLists.txt`
- `sdkconfig.defaults` — custom partition table
- `CLAUDE.md`

---

### Task 1: `macro:N` action token and macro parsing

**Files:**
- Modify: `Sources/SMKCore/LayerEngine.swift`
- Create: `Sources/SMKCore/MacroPlayer.swift`
- Test: `Tests/SMKCoreTests/MacroPlayerTests.swift`
- Modify: all six CMakeLists (see Global Constraints)

**Interfaces:**
- Consumes: nothing
- Produces: `KeyAction.macro(Int)`, `MacroStep`, `MacroDefinition`, `LayerEngine.macros`

- [ ] **Step 1: Write the failing test**

Create `Tests/SMKCoreTests/MacroPlayerTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func macroActionParsesFromKeymap() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["macro:3", "none"] ] ] }
    """)
    #expect(engine.getAction(row: 0, col: 0) == .macro(3))
}

@Test func malformedMacroTokenIsNone() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["macro:abc"] ] ] }
    """)
    #expect(engine.getAction(row: 0, col: 0) == .none)
}

@Test func macrosArrayParsesEveryStepType() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["macro:0"] ] ],
      "macros": [ { "id": 0, "name": "t", "steps": [
        { "t": "key",   "k": "key:b", "mods": ["leftGUI"], "hold": 40 },
        { "t": "delay", "ms": 400 },
        { "t": "text",  "s": "hi", "cpm": 20, "delivery": "keystrokes" },
        { "t": "layer", "op": "mo", "n": 1 },
        { "t": "rpt",   "count": 2, "steps": [ { "t": "delay", "ms": 10 } ] }
      ] } ] }
    """)
    #expect(engine.macros.count == 1)
    #expect(engine.macros[0].id == 0)
    #expect(engine.macros[0].steps.count == 5)
}

@Test func absentMacrosKeyYieldsNoMacros() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ] ] }
    """)
    #expect(engine.macros.isEmpty)
}

@Test func nestedRepeatBlockIsRejected() {
    // The player uses a single loop counter, not a stack. A nested block
    // from some other tool must not be executed as one.
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["macro:0"] ] ],
      "macros": [ { "id": 0, "name": "n", "steps": [
        { "t": "rpt", "count": 2, "steps": [ { "t": "rpt", "count": 3, "steps": [] } ] }
      ] } ] }
    """)
    #expect(engine.macros[0].steps.isEmpty)
}

@Test func stepWithUnknownTypeIsSkipped() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["macro:0"] ] ],
      "macros": [ { "id": 0, "name": "n", "steps": [
        { "t": "hologram", "intensity": 3 },
        { "t": "delay", "ms": 10 }
      ] } ] }
    """)
    // The unknown step cannot be executed, but it must not take the rest
    // of the macro down with it.
    #expect(engine.macros[0].steps.count == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter macroActionParsesFromKeymap`
Expected: compile failure — `type 'KeyAction' has no member 'macro'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/SMKCore/LayerEngine.swift`, add to `KeyAction`:

```swift
    /// Runs the macro stored in slot `n`. Must stay in lockstep with
    /// `ActionToken.macro` in the configurator
    /// (`~/esp/smk_configurator/Sources/SMKConfigurator/Model/ActionToken.swift`).
    case macro(Int)
```

and to `fromCString`, before the final `return .none`:

```swift
        if strncmp(cStr, "macro:", 6) == 0 {
            let val = Int(atoi(cStr.advanced(by: 6)))
            return .macro(val)
        }
```

Note `atoi` returns 0 for non-numeric input, which would make `"macro:abc"`
parse as `.macro(0)` — a real macro slot. Guard it: only treat it as a macro
when the first character after the prefix is a digit, otherwise fall through
to `.none`. The `malformedMacroTokenIsNone` test pins this.

Create `Sources/SMKCore/MacroPlayer.swift` with the model:

```swift
/// One step of a macro, mirroring the `"macros"` schema the configurator
/// writes. The byte layout these compile to is specified in
/// `~/esp/smk_configurator/CLAUDE.md` — this firmware implements that
/// contract rather than defining it.
enum MacroStep: Equatable {
    case keystroke(mods: UInt8, key: UInt8, holdMs: Int)
    case text(String, msPerChar: Int)
    case delay(ms: Int)
    case layer(momentary: Bool, n: Int)
    case repeatBlock(count: Int, steps: [MacroStep])
}

struct MacroDefinition: Equatable {
    var id: Int
    var steps: [MacroStep]
}
```

`mods` is the packed HID modifier byte, not a list — the bit order is
specified in the configurator's `CLAUDE.md` and matches `Modifier.rawValue`.
`key` is the HID usage from `KeyCode`.

Then extend `LayerEngine` with `private(set) var macros: [MacroDefinition] = []`
and parse the `"macros"` array inside `loadKeymap(cJsonStr:)` alongside
`"layers"`, using the same cJSON calls. A step whose `"t"` is unrecognized is
skipped; a `rpt` whose steps contain another `rpt` yields no steps.

The `delivery` field is parsed and discarded — the byte exists in the layout
as reserved, but `paste` is unimplementable board-side (the board cannot
write the host's clipboard) and the configurator no longer offers it.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS, existing suite plus 6 new tests.

- [ ] **Step 5: Add the new file to all six embedded builds**

`Package.swift` globs `Sources/SMKCore/`, so `swift test` already passes —
this step is invisible to it and only fails on hardware. Add
`MacroPlayer.swift` to the SMKCore source list in each of:

```
main/CMakeLists.txt
ports/rp2040/CMakeLists.txt
ports/nrf52840/CMakeLists.txt
ports/samd21/CMakeLists.txt
ports/stm32f4/CMakeLists.txt
ports/stm32wb/CMakeLists.txt
```

Verify by grepping that the count of files listed matches the directory:
`ls Sources/SMKCore/*.swift | wc -l` against each CMakeLists' entry count.

- [ ] **Step 6: Commit**

```bash
git add Sources/SMKCore/LayerEngine.swift Sources/SMKCore/MacroPlayer.swift Tests/SMKCoreTests/MacroPlayerTests.swift main/CMakeLists.txt ports/rp2040/CMakeLists.txt ports/nrf52840/CMakeLists.txt ports/samd21/CMakeLists.txt ports/stm32f4/CMakeLists.txt ports/stm32wb/CMakeLists.txt
git commit -m "Parse macros and the macro:N action token"
```

---

### Task 2: The printable-ASCII keycode table

**Files:**
- Create: `Sources/SMKCore/AsciiKeycodes.swift`
- Test: `Tests/SMKCoreTests/AsciiKeycodesTests.swift`
- Modify: all six CMakeLists

**Interfaces:**
- Consumes: `KeyCode` from `KeyCodesGenerated.swift`
- Produces: `asciiKeystroke(_ byte: UInt8) -> (usage: UInt8, shift: Bool)?`

- [ ] **Step 1: Write the failing test**

Create `Tests/SMKCoreTests/AsciiKeycodesTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func lowercaseLettersNeedNoShift() {
    let a = asciiKeystroke(UInt8(ascii: "a"))
    #expect(a?.usage == KeyCode.a.rawValue)
    #expect(a?.shift == false)
}

@Test func uppercaseLettersAreShiftedLowercase() {
    let upper = asciiKeystroke(UInt8(ascii: "A"))
    let lower = asciiKeystroke(UInt8(ascii: "a"))
    #expect(upper?.usage == lower?.usage)
    #expect(upper?.shift == true)
}

@Test func digitsAndTheirShiftedSymbols() {
    #expect(asciiKeystroke(UInt8(ascii: "1"))?.shift == false)
    let bang = asciiKeystroke(UInt8(ascii: "!"))
    #expect(bang?.usage == asciiKeystroke(UInt8(ascii: "1"))?.usage)
    #expect(bang?.shift == true)
}

@Test func spaceMapsToTheSpaceUsage() {
    #expect(asciiKeystroke(UInt8(ascii: " "))?.usage == KeyCode.space.rawValue)
}

@Test func everyPrintableAsciiByteMaps() {
    // 0x20...0x7E inclusive — the whole printable range, no holes.
    for b in UInt8(0x20)...UInt8(0x7E) {
        #expect(asciiKeystroke(b) != nil, "no mapping for byte \(b)")
    }
}

@Test func nonPrintableBytesAreRejected() {
    #expect(asciiKeystroke(0x00) == nil)
    #expect(asciiKeystroke(0x1F) == nil)
    #expect(asciiKeystroke(0x7F) == nil)
    #expect(asciiKeystroke(0x80) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter asciiKeystroke`
Expected: compile failure — `cannot find 'asciiKeystroke' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SMKCore/AsciiKeycodes.swift` mapping every byte in
`0x20...0x7E` to a `KeyCode` usage plus a shift flag.

This table cannot be derived from `keycodes.json`: that manifest maps key
*names* to usages and carries no shift state, so `'A'` and `'!'` have no
entry there. It is written by hand and pinned by the tests above against
`KeyCode`'s values, so it cannot drift from the generated vocabulary.

Document that **US QWERTY on the host is assumed** — the same text macro
produces different characters on a host set to another layout, and the board
has no way to detect that.

Return `nil` outside the printable range rather than substituting anything.
The caller rejects the macro; it never types a guess.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Add to all six CMakeLists**

Same six files as Task 1. Same trap: `swift test` passes without this.

- [ ] **Step 6: Commit**

```bash
git add Sources/SMKCore/AsciiKeycodes.swift Tests/SMKCoreTests/AsciiKeycodesTests.swift main/CMakeLists.txt ports/rp2040/CMakeLists.txt ports/nrf52840/CMakeLists.txt ports/samd21/CMakeLists.txt ports/stm32f4/CMakeLists.txt ports/stm32wb/CMakeLists.txt
git commit -m "Add the printable-ASCII keycode table for text steps"
```

---

### Task 3: The playback state machine

The heart of the feature, and entirely host-testable because it touches no
hardware.

**Files:**
- Modify: `Sources/SMKCore/MacroPlayer.swift`
- Test: `Tests/SMKCoreTests/MacroPlayerTests.swift`

**Interfaces:**
- Consumes: `MacroDefinition`, `MacroStep`, `asciiKeystroke`, `HIDReport`
- Produces: `MacroPlayer`, `MacroPlayer.start(_:)`, `MacroPlayer.tick() -> MacroPlayer.Output`, `MacroPlayer.isActive`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SMKCoreTests/MacroPlayerTests.swift`:

```swift
@Test func idlePlayerEmitsNothing() {
    var player = MacroPlayer()
    #expect(player.isActive == false)
    #expect(player.tick() == .idle)
}

@Test func keystrokeStepHoldsForItsDurationThenReleases() {
    var player = MacroPlayer()
    // hold 40ms at a 10ms tick == 4 ticks held, then a release tick.
    player.start(MacroDefinition(id: 0, steps: [
        .keystroke(mods: 0, key: KeyCode.b.rawValue, holdMs: 40)
    ]))
    for _ in 0..<4 {
        guard case .report(let r) = player.tick() else {
            Issue.record("expected a held report"); return
        }
        #expect(r.keys[0] == KeyCode.b.rawValue)
    }
    // The key must be released before the macro ends, or it sticks.
    guard case .report(let release) = player.tick() else {
        Issue.record("expected a release report"); return
    }
    #expect(release.keys[0] == 0)
    #expect(player.tick() == .finished)
}

@Test func delayEmitsAnEmptyReportForItsDuration() {
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

@Test func subTickDelayStillTakesOneTick() {
    // (ms + 9) / 10 rounds up: a 5ms delay must not vanish.
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.delay(ms: 5)]))
    #expect(player.tick() != .finished)
    #expect(player.tick() == .finished)
}

@Test func keystrokeCarriesItsModifiers() {
    var player = MacroPlayer()
    let gui = Modifier.leftGUI.rawValue
    player.start(MacroDefinition(id: 0, steps: [
        .keystroke(mods: gui, key: KeyCode.b.rawValue, holdMs: 10)
    ]))
    guard case .report(let r) = player.tick() else {
        Issue.record("expected a report"); return
    }
    #expect(r.modifier == gui)
}

@Test func textStepTypesOneCharacterPerInterval() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.text("ab", msPerChar: 10)]))
    guard case .report(let first) = player.tick() else {
        Issue.record("expected 'a'"); return
    }
    #expect(first.keys[0] == KeyCode.a.rawValue)
    _ = player.tick() // release between characters
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

@Test func repeatBlockRunsItsBodyTheGivenNumberOfTimes() {
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

@Test func repeatCountOfZeroSkipsTheBody() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [
        .repeatBlock(count: 0, steps: [.delay(ms: 100)])
    ]))
    #expect(player.tick() == .finished)
}

@Test func startingWhileActiveIsIgnored() {
    // Retriggering mid-playback must not restart or corrupt the run.
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: [.delay(ms: 100)]))
    _ = player.tick()
    player.start(MacroDefinition(id: 1, steps: [.delay(ms: 10)]))
    #expect(player.activeMacroID == 0)
}

@Test func anEmptyMacroFinishesImmediately() {
    var player = MacroPlayer()
    player.start(MacroDefinition(id: 0, steps: []))
    #expect(player.tick() == .finished)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter MacroPlayer`
Expected: compile failure — `cannot find 'MacroPlayer' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/SMKCore/MacroPlayer.swift`:

```swift
/// Plays one macro back as a sequence of HID reports, advanced once per
/// scan tick by the main loop. Pure: no hardware calls, no logging, no
/// time source of its own — the caller's tick cadence IS the clock. That
/// is what makes every timing rule here testable on the host.
///
/// Timing quantizes to the 10ms scan tick (`CONFIG_FREERTOS_HZ=100`).
/// Milliseconds are converted with `(ms + 9) / 10`, rounding up so a
/// sub-tick duration is never silently zero.
struct MacroPlayer {
    enum Output: Equatable {
        case idle
        case report(HIDReport)
        case finished
    }

    private(set) var activeMacroID: Int? = nil
    var isActive: Bool { activeMacroID != nil }

    // program counter, per-step cursor, tick countdown, repeat counter
    // ...

    /// Ignored when a macro is already playing — retriggering mid-run must
    /// not restart or interleave.
    mutating func start(_ macro: MacroDefinition) { /* ... */ }

    mutating func tick() -> Output { /* ... */ }
}

/// Ticks a duration in milliseconds, rounding up.
func macroTicks(forMs ms: Int) -> Int { (max(0, ms) + 9) / 10 }
```

Implementation notes the tests pin:

- A keystroke holds for its tick count, then emits **one release report**
  before advancing. Without that release the key stays down in the host's
  view for the rest of the macro.
- A text step walks its bytes, emitting press then release per character.
  A byte `asciiKeystroke` rejects aborts the macro rather than typing a
  substitute.
- `repeatBlock` uses a single counter, not a stack — nested blocks were
  already stripped at parse (Task 1).
- `finished` is returned exactly once; subsequent ticks return `.idle`.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SMKCore/MacroPlayer.swift Tests/SMKCoreTests/MacroPlayerTests.swift
git commit -m "Add the macro playback state machine"
```

---

### Task 4: Trigger the player from key events, and arbitrate in the main loop

**Files:**
- Modify: `Sources/SMKCore/KeyEventProcessing.swift`, `Sources/smk/Main.swift`
- Test: `Tests/SMKCoreTests/KeyEventProcessingTests.swift`

**Interfaces:**
- Consumes: `KeyAction.macro`, `MacroPlayer`
- Produces: `KeyEventProcessingResult.macroEvents: [Int]`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SMKCoreTests/KeyEventProcessingTests.swift`:

```swift
@Test func macroPressEmitsAMacroEvent() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["macro:2", "key:a"] ] ] }
    """)
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
    // The macro key itself types nothing; the player produces the output.
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["macro:2"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(result.report == HIDReport())
}

@Test func resettingLastScanRepressesAStillHeldKey() {
    // The stuck-key guard, at the level that IS host-testable. When
    // playback ends, Main.swift forces lastScan to all-false so the next
    // cycle re-observes every physically-held key as a fresh press. This
    // pins that the engine actually behaves that way -- a key still down
    // must produce a press transition and land in the report again,
    // rather than being treated as already-known and dropped.
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true],
        lastScan: [false],   // the forced reset
        colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(result.report.keys[0] == KeyCode.a.rawValue)
    #expect(result.transitions.first?.pressed == true)
}

@Test func macroReleaseEmitsNoEvent() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["macro:2"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.macro(2)]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [false], lastScan: [true], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(result.macroEvents.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter macroPress`
Expected: failure — `KeyEventProcessingResult` has no member `macroEvents`.

- [ ] **Step 3: Write minimal implementation**

Add `var macroEvents: [Int] = []` to `KeyEventProcessingResult`, and in
`processKeyEvents`' press branch append the slot for `.macro(n)` — exactly
as `toggleConnection` already appends to `connectionEvents` rather than
acting on it. The function stays pure.

In `Sources/smk/Main.swift`'s scan loop, after `processKeyEvents`:

```swift
        if !macroPlayer.isActive, let slot = result.macroEvents.first,
           let macro = engine.macros.first(where: { $0.id == slot }) {
            macroPlayer.start(macro)
        }

        if macroPlayer.isActive {
            switch macroPlayer.tick() {
            case .report(let r): report = r
            case .finished:
                // Resume from the CURRENT scan, not the stale lastScan:
                // a key released during playback was never observed as a
                // transition and would otherwise stay down forever.
                lastScan = [Bool](repeating: false, count: cleanScan.count)
                report = HIDReport()
            case .idle: break
            }
        } else {
            report = result.report
        }
```

The `lastScan` reset is the load-bearing line. Forcing it to all-false makes
the next cycle re-observe every physically-held key as a fresh press, so a
key released mid-macro cannot stick.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SMKCore/KeyEventProcessing.swift Sources/smk/Main.swift Tests/SMKCoreTests/KeyEventProcessingTests.swift
git commit -m "Trigger macro playback from key presses"
```

---

### Task 5: Per-port keymap ceiling

**Files:**
- Modify: `Sources/SMKCore/KeymapFrame.swift`
- Test: `Tests/SMKCoreTests/KeymapFrameTests.swift`

**Interfaces:**
- Produces: per-target `smkKeymapMaxLen`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SMKCoreTests/KeymapFrameTests.swift` a test asserting that
`smkKeymapFrameValidate` rejects a frame whose declared JSON length exceeds
`smkKeymapMaxLen`, and accepts one exactly at it — so the boundary is pinned
whatever the per-port value resolves to on the host build.

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter KeymapFrame`
Expected: the new boundary test fails until the constant is parameterized.

- [ ] **Step 3: Write minimal implementation**

Replace the single `public let smkKeymapMaxLen: Int = 4085` with a
compile-time per-target value, matching the platform-conditional idiom
`CLAUDE.md` documents. The **frame format is unchanged** — magic, version,
length, CRC32 — only the ceiling varies. The host test build takes the
largest value so the boundary test exercises the real arithmetic.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SMKCore/KeymapFrame.swift Tests/SMKCoreTests/KeymapFrameTests.swift
git commit -m "Make the keymap ceiling per-port"
```

---

### Task 6: `CAPS` opcode

**Files:**
- Modify: `Sources/SMKCore/KeymapProtocol.swift`
- Test: `Tests/SMKCoreTests/KeymapProtocolTests.swift`

**Interfaces:**
- Produces: `smkKeymapOpCaps: UInt8 = 0x05`, a `caps` closure parameter on `smkKeymapDispatchPacket`

- [ ] **Step 1: Write the failing test**

`smkKeymapDispatchPacket` already injects its storage operations so host
tests can substitute fakes — follow that exact pattern. Append a test that
dispatches a `0x05` packet and asserts the response carries `macroBytes`
(2 bytes LE), `macroSlots` (1), and `keymapMaxLen` (2 bytes LE), plus a test
that an unknown opcode still returns the error status.

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter KeymapProtocol`
Expected: failure — no `caps` parameter.

- [ ] **Step 3: Write minimal implementation**

Add the opcode constant and a `caps: () -> (UInt16, UInt8, UInt16)` injected
closure, writing the values into `response` little-endian to match the rest
of the protocol. Then thread the real per-port values through from each
port's transport layer.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SMKCore/KeymapProtocol.swift Tests/SMKCoreTests/KeymapProtocolTests.swift
git commit -m "Add the CAPS opcode so the board reports its macro capacity"
```

---

### Task 7: ESP32-C6 dedicated keymap partition

Hardware-specific and not host-testable. Verify by flashing.

**Files:**
- Create: `partitions.csv`, `Sources/smk/KeymapStorePartition.swift`
- Delete: `Sources/smk/KeymapStoreNVS.swift`
- Modify: `sdkconfig.defaults`, `main/CMakeLists.txt`

- [ ] **Step 1: Write the partition table**

Create `partitions.csv` keeping `nvs`, `phy_init` and `factory` at
**byte-identical offsets and sizes** to the current table — decoded from
`build/partition_table/partition-table.bin` as nvs 24K@0x9000, phy_init
4K@0xf000, factory 1024K@0x10000 — then append:

```
keymap,   data, 0x40, 0x110000, 64K,
```

Keeping the existing three unmoved is what preserves BLE bonding keys and
PHY calibration across the repartition. Changing any of their offsets
invalidates them.

- [ ] **Step 2: Point the build at it**

In `sdkconfig.defaults`, replace `CONFIG_PARTITION_TABLE_SINGLE_APP` with
the custom-table settings naming `partitions.csv`. Delete the stale
generated table so it is regenerated: `rm -rf build/partition_table`.

- [ ] **Step 3: Write the storage backend**

Create `Sources/smk/KeymapStorePartition.swift` implementing the same five
functions `KeymapStoreNVS.swift` provides — `smk_keymap_begin_write`,
`write_chunk`, `commit`, `erase`, `load` — against the `keymap` partition
via `esp_partition_find_first` / `esp_partition_read` / `_write` / `_erase_range`,
reusing `smkKeymapFrameValidate` unchanged.

This removes the keymap from NVS entirely, so it no longer competes with
NimBLE's bonding storage for space or garbage-collection headroom.

Delete `KeymapStoreNVS.swift` and update `main/CMakeLists.txt`.

- [ ] **Step 4: Verify on hardware**

Build and flash: `bash flash_esp32c6.sh`. Confirm from the log that the
partition is found, upload a keymap from the configurator, power-cycle, and
confirm it survives. Then confirm a previously-paired host **still pairs
without re-bonding** — that is the check that proves NVS was left intact.

- [ ] **Step 5: Commit**

```bash
git add partitions.csv sdkconfig.defaults Sources/smk/KeymapStorePartition.swift main/CMakeLists.txt
git rm Sources/smk/KeymapStoreNVS.swift
git commit -m "Give ESP32-C6 a dedicated keymap partition instead of an NVS blob"
```

---

### Task 8: RP2040 four-sector region with boot migration

Hardware-specific. Verify by flashing an RP2040 board.

**Files:**
- Modify: `ports/rp2040/KeymapStoreFlash.swift`

- [ ] **Step 1: Enlarge the region**

`flashOffset()` is `smk_pico_flash_size_bytes() - flashSectorSize`, anchoring
the region to the end of flash. Change it to reserve four sectors. `erase`
and `commit` must erase all four, and the linker's reserved tail grows by
12KB.

- [ ] **Step 2: Add the boot migration**

Before falling back to the compiled default, check the **old** offset
(`flash_size - 4096`) for a valid frame using `smkKeymapFrameValidate`. If
one is there, rewrite it at the new offset and erase the old sector.

The frame's magic (`"SMKM"`), version byte and CRC32 make this a reliable
detection rather than a guess: erased flash is `0xFF` and fails the magic
check immediately.

Log both outcomes distinctly so the boot log says which path ran.

- [ ] **Step 3: Verify the fallback still fails safe**

With **no** valid frame at either offset, `smk_keymap_load` must still return
-1 so `Main.swift` logs "Stored keymap invalid" and uses the compiled
default. The migration must not turn a clean fallback into a hang or a
garbage read.

- [ ] **Step 4: Verify on hardware**

Flash an RP2040 board **that already has a stored keymap from the old
firmware**, and confirm the boot log reports a migration and the keymap
survives. That is the entire point of this task — testing it only on a
freshly-erased board proves nothing.

- [ ] **Step 5: Commit**

```bash
git add ports/rp2040/KeymapStoreFlash.swift
git commit -m "Enlarge RP2040's keymap region and migrate existing frames on boot"
```

---

### Task 9: Document the coupling

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write the documentation**

Add to the firmware's `CLAUDE.md`:

- `MacroPlayer` and its tick-quantized timing — including that milliseconds
  round **up** to ticks, and that a playing macro owns the HID report
- The `"macros"` JSON key and that the byte contract is specified in the
  configurator's `CLAUDE.md`, which is authoritative
- `AsciiKeycodes` assumes US QWERTY on the host, and why the table cannot be
  generated from `keycodes.json`
- The per-port `smkKeymapMaxLen` and each port's value
- ESP32-C6's dedicated `keymap` partition, and that `nvs` must keep its
  current offset or BLE bonds are lost
- RP2040's boot migration, and that it can be removed once no board is
  running pre-migration firmware
- `CAPS` opcode `0x05`

Extend the existing warning about the six CMakeLists to name the two new
SMKCore files.

- [ ] **Step 2: Verify**

Read the edited sections back against the code. Confirm every claim is true
of this tree — a false statement here is worse than an absent one, since the
configurator's own `CLAUDE.md` already made one claim about enforcement that
was untrue when written.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document macro playback and its per-port storage"
```

---

## Out of scope

- Recording keystrokes from the board (sub-project 4)
- Conditions, flows and Paste — all need the host helper
- The editor-side follow-ups this creates (10ms quantization, removing the
  Paste toggle, ASCII validation at save, wiring `CAPS` into the capacity
  meter, bumping `firmwareVersionLabel`). Those belong in a separate PR
  against `~/esp/smk_configurator`, listed in the spec.
