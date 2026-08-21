# Firmware macro playback — design

Date: 2026-08-21
Companion spec: `~/esp/smk_configurator/docs/superpowers/specs/2026-08-20-macro-creation-design.md`
(this is that document's sub-project 3)

## Problem

The configurator can now author macros — ordered sequences of keystroke,
text, delay, layer and repeat steps — and uploads them inside `keymap.json`
under a top-level `"macros"` array, with keys bound to them via a `macro:N`
action token. The board ignores all of it.

`KeyAction` has no macro case, `LayerEngine` never reads the `"macros"` key,
and nothing plays a sequence back. Until this lands, the editor produces
macro JSON that no keyboard executes.

The wire contract is already fixed and shipped: `~/esp/smk_configurator/CLAUDE.md`
specifies the bytecode layout, opcode values, endianness, modifier bit order,
keycode derivation, and the JSON schema. This document does not redesign
that; it specifies the firmware that honours it.

## Decisions taken

Three forks were settled before design.

1. **Macro timing quantizes to the scan tick.** The main loop runs at
   `CONFIG_FREERTOS_HZ=100`, so 10 ms. Playback is a state machine the
   existing loop advances once per tick. Rejected: raising the tick rate to
   1000 Hz (reschedules the whole system 10× more often for one feature, and
   changes debounce behaviour tuned against a 10 ms tick) and a separate
   high-resolution timer (two concurrent producers of HID reports, in a
   codebase deliberately single-threaded and pure).
2. **A playing macro owns the HID report.** Keys held or pressed during
   playback produce nothing until it finishes. Rejected: merging live keys
   with macro output (a held modifier silently corrupts what the macro
   types, and the same macro then behaves differently depending on what the
   other hand was doing) and cancel-on-any-keypress (an accidental brush
   truncates mid-word with no indication of what got through).
3. **Text steps are printable ASCII only, and Paste is dropped.** The board
   cannot put anything on the host's clipboard, so `delivery: paste` is
   unimplementable board-side and comes out of the editor. Rejected: paste
   compiling to a literal Cmd+V (the step's own text payload becomes dead
   weight) and full UTF-8 via host unicode sequences (depends on host OS and
   input-source configuration the board cannot detect, so it works on one
   machine and produces garbage on another).

## Design

### 1. The player

`MacroPlayer` lives in `Sources/SMKCore/`, holding the active macro, a
program counter, and a tick countdown. `tick()` returns either a HID report
to send or idle. No hardware calls, no logging — the same discipline
`processKeyEvents` already follows, so it is unit-testable on the host.

**Triggering follows the existing idiom.** `processKeyEvents` does not act on
`toggle_conn`; it returns `connectionEvents` and lets the caller decide. A
`.macro(n)` press adds a `macroEvents` entry the same way, and `Main.swift`
starts the player. The pure function stays pure.

**The main loop arbitrates.** If the player is active its report is the
report; otherwise `processKeyEvents`' report is. One branch, rather than
macro awareness smeared through the engine.

**Milliseconds stay in the wire format** and convert to ticks on load:
`ticks = (ms + 9) / 10`, rounding up so a 5 ms delay is not silently zero. If
the tick rate ever changes, existing macros keep their authored meaning
instead of running 10× fast.

**Release-during-playback is the failure mode to guard.** A key held when
playback starts is ignored during it, but if the user releases it mid-macro
the engine never observes that transition. When playback ends the player
must resume from the current scan rather than the stale `lastScan`, or that
key sticks down permanently. This gets an explicit test.

`macro:N` is added to `KeyAction.fromCString` in lockstep with the editor's
`ActionToken.macro`, and `LayerEngine` parses the `"macros"` array with the
cJSON it already uses for layers.

### 2. Storage and per-port capacity

`smkKeymapMaxLen` is currently a single `public let` in
`Sources/SMKCore/KeymapFrame.swift:9`, feeding `smkKeymapFrameValidate` and
all three storage backends. The capacity contract requires it to vary per
port, so it becomes a compile-time value selected per target, matching the
platform-conditional idiom `CLAUDE.md` documents rather than introducing a
fourth pattern. The frame *format* stays shared; only the ceiling varies.

| Port | Today | Proposed | Cost |
|---|---|---|---|
| RP2040 | last 1 flash sector, 4096 B frame | 4 sectors, 16384 B frame | 12 KB less program flash; every save erases 4 sectors instead of 1 — slower, and 4× the wear |
| ESP32-C6 | NVS blob, same 4085 ceiling | 16 KB blob | Default `SINGLE_APP` table gives NVS 24 KB; 16 KB plus NVS overhead is tight and must be verified against the real partition before committing to the number |
| nRF52840 | stub | stub, reports 0 macro bytes | None — the editor already treats this as authoring-and-export with flashing disabled and the reason shown |

**Raising RP2040's ceiling moves the reserved region's start address.** A
board already carrying a stored keymap would read its old frame from what is
now the wrong offset. This needs either a migration or an accepted one-time
"re-flash your keymap after this update" — a real user-facing cost, not just
a constant change.

### 3. `CAPS`

A new opcode `0x05` alongside BEGIN/CHUNK/COMMIT/ERASE, returning
`macroBytes`, `macroSlots` and `keymapMaxLen` in the existing 32-byte
response. `smkKeymapDispatchPacket` already injects its storage operations so
host tests can substitute fakes; the new opcode is testable the same way,
with no hardware.

This is what finally makes the editor's `.device` capacity source reachable —
until now it has always shown the floor profile labelled *(estimated)*.

### 4. The character table

95 entries for printable ASCII (`0x20`–`0x7E`), each mapping to a HID usage
plus a shift flag: `'A'` is shift+`a`, `'!'` is shift+`1`. US QWERTY on the
host is assumed and documented.

It cannot be derived from `keycodes.json` — that manifest maps *names* to
usages and carries no shift state — so it is hand-written but **pinned by
tests against `KeyName`'s usages**, so it cannot drift from the generated
vocabulary. Same discipline `KeyVocabularyTests` applies across the two
repos.

A byte outside the range is rejected at parse time and the macro is skipped
with a log line, rather than typed as garbage. The editor refuses it at save,
but the firmware does not trust that.

## Editor follow-ups

This sub-project creates a second PR against `~/esp/smk_configurator`:

1. Delay, hold and typing-speed controls quantize to 10 ms steps; duration
   estimates become truthful
2. The Paste toggle is removed from the inspector (the `delivery` byte stays
   in the layout as reserved, so the contract does not churn)
3. Text validated to printable ASCII at save, with a message naming the
   offending character
4. `CAPS` wired into `macroCapacity`/`macroCapacitySource`
5. `firmwareVersionLabel` bumped

## Testing

Mostly host-side, which is why the player belongs in `SMKCore`:

- Playback per step type, and tick counting for each
- Release-during-playback: the key must not stick when playback ends
- Nested repeat blocks rejected at parse
- `CAPS` via the existing injected-fake dispatch pattern
- Character table pinned against `KeyName`'s HID usages
- Per-port `maxLen` frame validation
- Byte widths pinned against the editor's `MacroStep.compiledSize`, cross-repo

## Out of scope

- Recording keystrokes from the board (sub-project 4)
- Conditions, flows, and Paste — all need the host helper, which is out of
  the program by decision
