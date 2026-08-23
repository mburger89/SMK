# Binary Keymap Format Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store and load the keymap — matrix, layers and macros — as a compact binary payload instead of JSON, and play macros back on the board.

**Architecture:** A bounds-checked binary decoder in `SMKCore` replaces the cJSON keymap path. Cells are two bytes: an action tag and a parameter. Macros decode into `MacroStep` values that a pure `MacroPlayer` state machine plays back, advanced once per 10 ms scan tick by the existing main loop. The compiled-in default keymap becomes a build-time generated binary literal, so cJSON leaves the keymap path entirely.

**Tech Stack:** Swift 6 / Embedded Swift, Swift Testing (`import Testing`, bare `@Test func`), ESP-IDF, pico-sdk.

**Spec:** `docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md`
(supersedes `2026-08-21-firmware-macro-playback-design.md`)

## Global Constraints

- **Test with `SMK_HOST_TESTS_ONLY=1 swift test`.** Not a bare `swift test` — with that variable unset, `swift-mmio` becomes a dependency and the resolve churns the deliberately-untracked `Package.resolved`.
- **THE TRAP: a new file in `Sources/SMKCore/` is invisible to every embedded build until listed in all six CMakeLists** that enumerate SMKCore sources — `main/CMakeLists.txt` plus `ports/{rp2040,nrf52840,samd21,stm32f4,stm32wb}/CMakeLists.txt`. `Package.swift` globs the directory, so a missing entry **still passes `swift test`** and only surfaces as a link failure on hardware. This plan adds **four** such files.
- **`SMKCore` compiles under Embedded Swift.** No `Any`, no reflection, no existentials, no `Codable`. Structs, enums, arrays, non-escaping closures — match `processKeyEvents` and `LayerEngine`.
- **The byte layout is a cross-repo contract.** `~/esp/smk_configurator/CLAUDE.md` and the spec above define it. The configurator's compiler and this decoder must agree exactly; a disagreement is a bug wherever it is found.
- **Binary loses the bounds-checking JSON gave for free.** Every length and index read out of the payload must be validated against the payload's actual size before it is used. A malformed blob must be rejected, never indexed.
- **Timing quantizes to the 10 ms scan tick.** `(ms + 9) / 10`, rounding **up**, so a sub-tick duration is never silently zero.
- **A playing macro owns the HID report.** Live keys produce nothing until it finishes.
- Commit after every task. Do not push.

---

## File Structure

**Create:**
- `Sources/SMKCore/KeymapBinary.swift` — payload decoding, cell tags, bounds checks
- `Sources/SMKCore/MacroPlayer.swift` — macro model and playback state machine
- `Sources/SMKCore/AsciiKeycodes.swift` — printable-ASCII → (usage, shift)
- `Sources/SMKCore/DefaultKeymapGenerated.swift` — **generated**, do not edit
- `generate_default_keymap.sh`
- `Tests/SMKCoreTests/KeymapBinaryTests.swift`
- `Tests/SMKCoreTests/MacroPlayerTests.swift`
- `Tests/SMKCoreTests/AsciiKeycodesTests.swift`

**Modify:**
- `Sources/SMKCore/LayerEngine.swift` — `KeyAction.macro`, load from binary
- `Sources/SMKCore/KeyEventProcessing.swift` — emit `macroEvents`
- `Sources/SMKCore/KeymapFrame.swift` — frame version 2
- `Sources/SMKCore/KeymapProtocol.swift` — `CAPS` opcode `0x05`
- `Sources/smk/Main.swift` — binary default, player arbitration
- All six CMakeLists
- `CLAUDE.md`

**Unchanged, deliberately:** `ports/rp2040/KeymapStoreFlash.swift`,
`Sources/smk/KeymapStoreNVS.swift`, `sdkconfig.defaults`. No region moves, no
partition table, no migration — that is the point of this change.

---

### Task 1: Cell encoding and the `macro:N` token

The smallest testable unit of the format: one cell in, one `KeyAction` out.

**Files:**
- Create: `Sources/SMKCore/KeymapBinary.swift`, `Tests/SMKCoreTests/KeymapBinaryTests.swift`
- Modify: `Sources/SMKCore/LayerEngine.swift`, all six CMakeLists

**Interfaces:**
- Produces: `KeyAction.macro(Int)`, `KeymapCellTag`, `decodeCell(_:_:) -> KeyAction`, `encodeCell(_:) -> (UInt8, UInt8)`

- [ ] **Step 1: Write the failing test**

Create `Tests/SMKCoreTests/KeymapBinaryTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func everyActionRoundTripsThroughTwoBytes() {
    let cases: [KeyAction] = [
        .none,
        .key(.a), .key(.z), .key(.f12),
        .modifier(.leftShift), .modifier(.rightGUI),
        .momentaryLayer(0), .momentaryLayer(15),
        .toggleLayer(0), .toggleLayer(15),
        .transparent,
        .toggleConnection,
        .macro(0), .macro(255),
    ]
    for action in cases {
        let (tag, param) = encodeCell(action)
        #expect(decodeCell(tag, param) == action, "round trip failed for \(action)")
    }
}

@Test func unknownTagDecodesToNone() {
    // A tag this build has no case for must not index into anything.
    #expect(decodeCell(200, 42) == KeyAction.none)
}

@Test func cellIsExactlyTwoBytes() {
    // The whole storage claim rests on this stride. If a cell ever needs
    // three bytes, 16 layers no longer fit and the spec's arithmetic breaks.
    let (tag, param) = encodeCell(.key(.a))
    #expect(MemoryLayout.size(ofValue: tag) == 1)
    #expect(MemoryLayout.size(ofValue: param) == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter everyActionRoundTrips`
Expected: compile failure — `cannot find 'encodeCell' in scope`.

- [ ] **Step 3: Write minimal implementation**

Add to `KeyAction` in `Sources/SMKCore/LayerEngine.swift`:

```swift
    /// Runs the macro in slot `n`. Must stay in lockstep with
    /// `ActionToken.macro` in the configurator.
    case macro(Int)
```

Create `Sources/SMKCore/KeymapBinary.swift` with the tag table from the spec
— `none` 0, `key` 1, `mod` 2, `mo` 3, `tg` 4, `trans` 5, `toggle_conn` 6,
`macro` 7 — and the two functions. An unrecognized tag decodes to `.none`
rather than trapping: a corrupt byte must degrade, not crash a keyboard.

`fromCString` also gains `macro:` for the on-disk JSON path the configurator
still writes, guarding that the character after the prefix is a digit so
`"macro:abc"` does not become `.macro(0)` via `atoi`.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Add `KeymapBinary.swift` to all six CMakeLists**

`swift test` passes without this; hardware does not. Add to:
`main/`, `ports/rp2040/`, `ports/nrf52840/`, `ports/samd21/`,
`ports/stm32f4/`, `ports/stm32wb/`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SMKCore/KeymapBinary.swift Sources/SMKCore/LayerEngine.swift Tests/SMKCoreTests/KeymapBinaryTests.swift main/CMakeLists.txt ports/*/CMakeLists.txt
git commit -m "Encode a keymap cell as an action tag and parameter"
```

---

### Task 2: Payload decoding, with bounds checks

Where the safety JSON used to provide has to be written by hand.

**Files:**
- Modify: `Sources/SMKCore/KeymapBinary.swift`, `Tests/SMKCoreTests/KeymapBinaryTests.swift`

**Interfaces:**
- Consumes: `decodeCell`
- Produces: `KeymapPayload` (matrix, layers, macros), `decodeKeymapPayload(_:count:) -> KeymapPayload?`, **and the macro value types every later task builds on**:

```swift
/// One step of a macro. `mods` is the packed HID modifier byte (bit order
/// per the configurator's CLAUDE.md, matching `Modifier.rawValue`), `key`
/// is a HID usage from `KeyCode`.
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

Task 5's player and Task 6's trigger both depend on these exact signatures.
A repeat block whose steps contain another repeat block is **refused at
decode** — the player uses a single loop counter, not a stack — so nesting
never reaches playback.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SMKCoreTests/KeymapBinaryTests.swift`:

```swift
/// Builds a minimal valid payload: 1x2 matrix, `layerCount` layers, no macros.
private func samplePayload(layerCount: Int) -> [UInt8] {
    var b: [UInt8] = [1, 2, 1, UInt8(layerCount), 0, 0]  // header
    b += [5]        // rows[]  GPIO 5
    b += [6, 7]     // cols[]  GPIO 6,7
    for _ in 0..<layerCount {
        b += [1, KeyCode.a.rawValue]   // key:a
        b += [5, 0]                    // trans
    }
    return b
}

@Test func decodesMatrixLayersAndCells() {
    let bytes = samplePayload(layerCount: 2)
    let p = bytes.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: bytes.count)
    }
    #expect(p?.rows == [5])
    #expect(p?.cols == [6, 7])
    #expect(p?.colsAreDriven == true)
    #expect(p?.layers.count == 2)
    #expect(p?.layers[0][0][0] == KeyAction.key(.a))
    #expect(p?.layers[1][0][1] == KeyAction.transparent)
}

@Test func truncatedPayloadIsRejectedNotIndexed() {
    // Binary loses JSON's free bounds checking. Every prefix of a valid
    // payload must be refused rather than read past its end.
    let full = samplePayload(layerCount: 2)
    for cut in 1..<full.count {
        let short = Array(full[0..<cut])
        let p = short.withUnsafeBufferPointer {
            decodeKeymapPayload($0.baseAddress!, count: short.count)
        }
        #expect(p == nil, "prefix of length \(cut) should have been rejected")
    }
}

@Test func emptyPayloadIsRejected() {
    var empty: [UInt8] = []
    let p = empty.withUnsafeMutableBufferPointer { buf -> KeymapPayload? in
        guard let base = buf.baseAddress else { return decodeKeymapPayload(nil, count: 0) }
        return decodeKeymapPayload(base, count: 0)
    }
    #expect(p == nil)
}

@Test func absurdCountsAreRejectedBeforeAllocating() {
    // A corrupt header claiming 200 layers of a 200x200 matrix must be
    // refused on arithmetic, not attempted.
    var b: [UInt8] = [200, 200, 1, 200, 0, 0]
    b += [UInt8](repeating: 0, count: 8)
    let p = b.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress!, count: b.count)
    }
    #expect(p == nil)
}

@Test func sixteenLayersFitTheExistingCeiling() {
    // The claim this entire change rests on. 16 layers of a 5x12 board must
    // fit inside smkKeymapMaxLen with room left for macros -- that is why
    // no port needs a larger region, a partition table, or a migration.
    let rows = 5, cols = 12, layers = 16
    let headerBytes = 6 + rows + cols
    let layerBytes = layers * rows * cols * 2
    #expect(headerBytes + layerBytes == 1943)
    #expect(headerBytes + layerBytes < smkKeymapMaxLen)
    #expect(smkKeymapMaxLen - (headerBytes + layerBytes) > 2000)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter decodesMatrixLayers`
Expected: compile failure — `cannot find 'decodeKeymapPayload' in scope`.

- [ ] **Step 3: Write minimal implementation**

Add `KeymapPayload` and `decodeKeymapPayload` to `KeymapBinary.swift`.

Validate **before** every read, in this order: the fixed 6-byte header fits;
`rowCount + colCount` fits; the computed layer region
(`layerCount * rowCount * colCount * 2`) fits in the remaining bytes; each
macro's declared name length and step count fit before they are read.
Return `nil` on any failure. Never index first and check after.

Compute sizes in `Int`, not `UInt8`/`UInt16` arithmetic, so a corrupt header
cannot overflow into a small number that then passes a bounds check.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS. Note `truncatedPayloadIsRejectedNotIndexed` runs every prefix
— if any one reads out of bounds the test crashes rather than fails, which is
itself the signal.

- [ ] **Step 5: Commit**

```bash
git add Sources/SMKCore/KeymapBinary.swift Tests/SMKCoreTests/KeymapBinaryTests.swift
git commit -m "Decode a binary keymap payload with explicit bounds checks"
```

---

### Task 3: Frame version 2, and loading binary into LayerEngine

**Files:**
- Modify: `Sources/SMKCore/KeymapFrame.swift`, `Sources/SMKCore/LayerEngine.swift`
- Test: `Tests/SMKCoreTests/KeymapFrameTests.swift`

**Interfaces:**
- Consumes: `decodeKeymapPayload`
- Produces: `smkKeymapFrameVersion = 2`, `LayerEngine.loadKeymap(binary:count:)`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SMKCoreTests/KeymapFrameTests.swift`:

```swift
/// Wraps a payload in a frame: "SMKM" + version + length(LE) + crc32(LE).
private func frame(payload: [UInt8], version: UInt8) -> [UInt8] {
    var f: [UInt8] = Array("SMKM".utf8)
    f.append(version)
    f.append(UInt8(payload.count & 0xFF))
    f.append(UInt8((payload.count >> 8) & 0xFF))
    let crc = smkCrc32(payload)          // existing helper
    f.append(UInt8(crc & 0xFF))
    f.append(UInt8((crc >> 8) & 0xFF))
    f.append(UInt8((crc >> 16) & 0xFF))
    f.append(UInt8((crc >> 24) & 0xFF))
    return f + payload
}

@Test func versionOneFrameIsRejected() {
    // The migration story: the frame never moves, so an old JSON frame
    // fails a clean version check rather than being read as garbage.
    let payload = samplePayload(layerCount: 1)
    let f = frame(payload: payload, version: 1)
    let ok = f.withUnsafeBufferPointer {
        smkKeymapFrameValidate($0.baseAddress!, frameLen: f.count)
    }
    #expect(ok == nil)
}

@Test func versionTwoFrameValidates() {
    let payload = samplePayload(layerCount: 1)
    let f = frame(payload: payload, version: 2)
    let len = f.withUnsafeBufferPointer {
        smkKeymapFrameValidate($0.baseAddress!, frameLen: f.count)
    }
    #expect(len == payload.count)
}

@Test func versionTwoFrameWithBadCrcIsRejected() {
    var f = frame(payload: samplePayload(layerCount: 1), version: 2)
    f[11] ^= 0xFF                        // corrupt the first payload byte
    let ok = f.withUnsafeBufferPointer {
        smkKeymapFrameValidate($0.baseAddress!, frameLen: f.count)
    }
    #expect(ok == nil)
}

@Test func engineLoadsActionsFromBinary() {
    var engine = LayerEngine()
    let payload = samplePayload(layerCount: 1)
    payload.withUnsafeBufferPointer {
        engine.loadKeymap(binary: $0.baseAddress!, count: payload.count)
    }
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
    #expect(engine.getAction(row: 0, col: 1) == .transparent)
}
```

`samplePayload` is the helper from Task 2 — move it somewhere both test files
can reach, or duplicate it with a comment saying why. Check the existing CRC
helper's real name in `KeymapFrame.swift` before using `smkCrc32`; match
whatever is already there rather than introducing a second spelling.

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter KeymapFrame`
Expected: the version-rejection test fails — version 1 is currently accepted.

- [ ] **Step 3: Write minimal implementation**

Bump the frame version constant to 2 and have `smkKeymapFrameValidate`
reject anything else. **The frame layout, offset and size are unchanged** —
only the payload's format and the version byte differ, which is what makes
this migration a clean version check rather than a garbage read at a moved
offset.

Add `loadKeymap(binary:count:)` to `LayerEngine`, decoding the payload and
populating `keymaps` and `macros`. Keep the existing `loadKeymap(json:)` for
now — many tests use it and Task 6 retires it.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SMKCore/KeymapFrame.swift Sources/SMKCore/LayerEngine.swift Tests/SMKCoreTests/KeymapFrameTests.swift
git commit -m "Bump the frame to version 2 and load keymaps from binary"
```

---

### Task 4: The printable-ASCII keycode table

**Files:**
- Create: `Sources/SMKCore/AsciiKeycodes.swift`, `Tests/SMKCoreTests/AsciiKeycodesTests.swift`
- Modify: all six CMakeLists

**Interfaces:**
- Produces: `asciiKeystroke(_ byte: UInt8) -> (usage: UInt8, shift: Bool)?`

- [ ] **Step 1: Write the failing test**

Create `Tests/SMKCoreTests/AsciiKeycodesTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func lowercaseNeedsNoShift() {
    let a = asciiKeystroke(UInt8(ascii: "a"))
    #expect(a?.usage == KeyCode.a.rawValue)
    #expect(a?.shift == false)
}

@Test func uppercaseIsShiftedLowercase() {
    #expect(asciiKeystroke(UInt8(ascii: "A"))?.usage == KeyCode.a.rawValue)
    #expect(asciiKeystroke(UInt8(ascii: "A"))?.shift == true)
}

@Test func shiftedSymbolsShareTheirDigitsUsage() {
    #expect(asciiKeystroke(UInt8(ascii: "!"))?.usage
            == asciiKeystroke(UInt8(ascii: "1"))?.usage)
    #expect(asciiKeystroke(UInt8(ascii: "!"))?.shift == true)
}

@Test func everyPrintableByteMaps() {
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

Create `Sources/SMKCore/AsciiKeycodes.swift` mapping `0x20...0x7E` to a
`KeyCode` usage plus a shift flag.

It cannot be derived from `keycodes.json` — that manifest maps key *names* to
usages and carries no shift state, so `'A'` and `'!'` have no entry. It is
hand-written and pinned by the tests above against `KeyCode`, so it cannot
drift from the generated vocabulary.

Document that **US QWERTY on the host is assumed**: the same text macro types
different characters on a host set to another layout, and the board cannot
detect that. Return `nil` outside the range rather than substituting — the
caller rejects the macro instead of typing a guess.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Add to all six CMakeLists, then commit**

```bash
git add Sources/SMKCore/AsciiKeycodes.swift Tests/SMKCoreTests/AsciiKeycodesTests.swift main/CMakeLists.txt ports/*/CMakeLists.txt
git commit -m "Add the printable-ASCII keycode table for text steps"
```

---

### Task 5: The playback state machine

**Files:**
- Create: `Sources/SMKCore/MacroPlayer.swift`, `Tests/SMKCoreTests/MacroPlayerTests.swift`
- Modify: all six CMakeLists

**Interfaces:**
- Consumes: `MacroDefinition`/`MacroStep` (decoded in Task 2), `asciiKeystroke`, `HIDReport`
- Produces: `MacroPlayer`, `.start(_:)`, `.tick() -> MacroPlayer.Output`, `.isActive`, `.activeMacroID`, `macroTicks(forMs:)`

- [ ] **Step 1: Write the failing test**

Create `Tests/SMKCoreTests/MacroPlayerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter MacroPlayer`
Expected: compile failure — `cannot find 'MacroPlayer' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SMKCore/MacroPlayer.swift`:

```swift
/// Plays one macro back as a sequence of HID reports, advanced once per
/// scan tick by the main loop. Pure: no hardware calls, no logging, no
/// time source of its own -- the caller's tick cadence IS the clock, which
/// is what makes every timing rule here testable on the host.
///
/// Timing quantizes to the 10ms scan tick (`CONFIG_FREERTOS_HZ=100`).
struct MacroPlayer {
    enum Output: Equatable {
        case idle
        case report(HIDReport)
        case finished
    }

    private(set) var activeMacroID: Int? = nil
    var isActive: Bool { activeMacroID != nil }

    /// Ignored while a macro is already playing -- retriggering must not
    /// restart or interleave.
    mutating func start(_ macro: MacroDefinition) { /* ... */ }

    mutating func tick() -> Output { /* ... */ }
}

/// Ticks for a duration in milliseconds, rounding up so a sub-tick
/// duration is never silently zero.
func macroTicks(forMs ms: Int) -> Int { (max(0, ms) + 9) / 10 }
```

Behaviours the tests pin: a keystroke emits **one release report** before
advancing; a text step emits press then release per character and aborts on a
byte `asciiKeystroke` rejects; `repeatBlock` uses a single counter (nested
blocks were already refused at decode); `finished` is returned exactly once,
subsequent ticks return `.idle`.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Add to all six CMakeLists, then commit**

```bash
git add Sources/SMKCore/MacroPlayer.swift Tests/SMKCoreTests/MacroPlayerTests.swift main/CMakeLists.txt ports/*/CMakeLists.txt
git commit -m "Add the macro playback state machine"
```

---

### Task 6: Trigger playback, and arbitrate in the main loop

**Files:**
- Modify: `Sources/SMKCore/KeyEventProcessing.swift`, `Sources/smk/Main.swift`
- Test: `Tests/SMKCoreTests/KeyEventProcessingTests.swift`

**Interfaces:**
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

@Test func resettingLastScanRepressesAStillHeldKey() {
    // The stuck-key guard, at the level that IS host-testable. When
    // playback ends, Main.swift forces lastScan to all-false so the next
    // cycle re-observes every physically-held key as a fresh press --
    // otherwise a key released during playback was never seen as a
    // transition and stays down forever.
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(result.report.keys[0] == KeyCode.a.rawValue)
    #expect(result.transitions.first?.pressed == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter macroPress`
Expected: failure — no `macroEvents` member.

- [ ] **Step 3: Write minimal implementation**

Add `var macroEvents: [Int] = []` to `KeyEventProcessingResult` and append the
slot on a `.macro(n)` press — exactly as `toggleConnection` already appends to
`connectionEvents` rather than acting on it. The function stays pure.

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
                // Resume from the CURRENT scan, not the stale lastScan: a
                // key released during playback was never observed as a
                // transition and would otherwise stay down forever.
                lastScan = [Bool](repeating: false, count: cleanScan.count)
                report = HIDReport()
            case .idle: break
            }
        } else {
            report = result.report
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SMKCore/KeyEventProcessing.swift Sources/smk/Main.swift Tests/SMKCoreTests/KeyEventProcessingTests.swift
git commit -m "Trigger macro playback from key presses"
```

---

### Task 7: Generate the compiled-in default keymap as binary

Retires cJSON from the keymap path — the flash saving only materialises when
nothing needs the parser.

**Files:**
- Create: `generate_default_keymap.sh`, `Sources/SMKCore/DefaultKeymapGenerated.swift`
- Modify: `Sources/smk/Main.swift`, `CLAUDE.md`, all six CMakeLists

- [ ] **Step 1: Write the generator**

Create `generate_default_keymap.sh`, compiling `keymap.json` to a Swift byte
array literal in `Sources/SMKCore/DefaultKeymapGenerated.swift`, matching the
established idiom of `generate_keycodes.sh` and `generate_ble_uuids.sh` —
including a "generated, do not edit" banner naming the script.

It emits the same payload format Task 2 decodes. **This is a second encoder**
— the configurator has the first — so the format now lives in two
implementations plus the spec. Task 9's cross-repo pin is what keeps them
honest.

- [ ] **Step 2: Verify the generated default round-trips**

Add a test asserting `decodeKeymapPayload` accepts the generated bytes and
that the decoded matrix and layer count match `keymap.json`. That is the
check that catches generator/decoder drift on every run.

Run: `SMK_HOST_TESTS_ONLY=1 swift test`

- [ ] **Step 3: Switch Main.swift to the binary default**

Replace `engine.loadKeymap(json: configJson)` with the generated binary, and
remove `configJson`. Confirm nothing else in the keymap path calls cJSON;
if the dependency is now unused, note it in the commit rather than removing
it in this task.

- [ ] **Step 4: Commit**

```bash
git add generate_default_keymap.sh Sources/SMKCore/DefaultKeymapGenerated.swift Sources/smk/Main.swift main/CMakeLists.txt ports/*/CMakeLists.txt
git commit -m "Generate the compiled-in default keymap as binary"
```

---

### Task 8: `CAPS` opcode

**Files:**
- Modify: `Sources/SMKCore/KeymapProtocol.swift`, `Tests/SMKCoreTests/KeymapProtocolTests.swift`

**Interfaces:**
- Produces: `smkKeymapOpCaps: UInt8 = 0x05`, a `caps` closure on `smkKeymapDispatchPacket`

- [ ] **Step 1: Write the failing test**

`smkKeymapDispatchPacket` already injects its storage operations so host tests
can substitute fakes — follow that pattern exactly. Add a test dispatching a
`0x05` packet, asserting the response carries `macroBytes` (2 bytes LE),
`macroSlots` (1) and `keymapMaxLen` (2 bytes LE); plus a test that an unknown
opcode still returns the error status.

- [ ] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter KeymapProtocol`
Expected: failure — no `caps` parameter.

- [ ] **Step 3: Write minimal implementation**

Add the opcode and a `caps: () -> (UInt16, UInt8, UInt16)` injected closure,
writing values little-endian to match the rest of the protocol. Thread the
real values through each port's transport layer.

- [ ] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`

- [ ] **Step 5: Commit**

```bash
git add Sources/SMKCore/KeymapProtocol.swift Tests/SMKCoreTests/KeymapProtocolTests.swift
git commit -m "Add the CAPS opcode so the board reports its macro capacity"
```

---

### Task 9: Document the format and its couplings

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write the documentation**

Under firmware coupling, record:

- The binary payload layout — header, cell tags, macro entries — and that
  the configurator's `CLAUDE.md` carries the same contract. **Three
  implementations now exist** (this decoder, `generate_default_keymap.sh`,
  the configurator's compiler); name all three so the next person knows what
  must change together.
- Frame **version 2**, and that version 1 frames are rejected and fall back
  to the compiled default.
- `DefaultKeymapGenerated.swift` is generated by `generate_default_keymap.sh`
  from `keymap.json` — do not edit.
- `AsciiKeycodes` assumes US QWERTY, and why it cannot be generated from
  `keycodes.json`.
- `MacroPlayer`'s tick quantization, that milliseconds round **up**, and that
  a playing macro owns the HID report.
- `CAPS` opcode `0x05`.
- **That 16 layers now fit**, with the arithmetic, since the previously
  documented ceiling was unreachable at ~5 layers.

Extend the six-CMakeLists warning to name the four new SMKCore files.

- [ ] **Step 2: Verify**

Read it back against the code. Every claim must be true of this tree — the
configurator's `CLAUDE.md` already shipped one claim about enforcement that
was false when written, and a firmware author trusting a false statement here
has no way to discover it except on hardware.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document the binary keymap format"
```

---

## Out of scope

- Recording keystrokes from the board (sub-project 4)
- Conditions, flows and Paste — all need the host helper
- Variable-width cell encoding — revisit only if a board appears whose
  layers do not fit at a flat two bytes
- **The cross-repo byte-layout pin.** The spec calls for the layout to be
  tested against the configurator's compiler. That test cannot live here:
  this repo has no access to the editor's Swift. It belongs on the editor
  side, which already reaches into this repo for `KeyVocabularyTests`
  (reading `~/esp/SMK/keycodes.json`). The editor plan owns it — with three
  implementations of this format now in existence, it is the only thing
  keeping them honest.
- **The editor side**, which is a separate plan against
  `~/esp/smk_configurator`: the compiler, sending binary instead of JSON,
  refusing unknown tokens, the honest capacity meter, 10 ms quantization,
  removing Paste, ASCII validation, and `firmwareVersionLabel`. The firmware
  is useless without it and vice versa — they land together or not at all.
