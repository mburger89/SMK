# Retire cJSON from the firmware — design

Date: 2026-08-21
Status: **implemented 2026-08-23**, per
`docs/superpowers/plans/2026-08-23-retire-cjson.md`. (Was: deferred, written
up while the context was fresh, not scheduled.)

> **Measured, after the fact.** The "Why bother" section below leads with an
> estimated 15-25 KB of flash. The real figure for cJSON's own linked text is
> **7.8 KB** -- `--gc-sections` had already dropped the printer, minifier and
> comparison helpers, leaving only the parser to remove. The realised
> per-target saving is larger than that, because each board's `configJson`
> string literal went too and its binary payload replacement is several times
> smaller; the measurements are in
> `docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md`. Quote those
> numbers, not the estimate.
Depends on: `2026-08-21-binary-keymap-format-design.md` landing first, in both
this repo and `~/esp/smk_configurator`.

## Problem

The binary keymap format removed JSON from the *uploaded* keymap path, but
cJSON is still linked into every board, because two users remain:

| User | Location | What it parses |
|---|---|---|
| `Config.fromJson` | `Sources/SMKCore/Config.swift:12` | `matrix.rows` / `cols` / `colsAreDriven`, for **every board, every boot** |
| `LayerEngine.loadKeymap(json:)` | `Sources/SMKCore/LayerEngine.swift:94` | layers, for **five of eight** compiled-in defaults |

`Sources/smk/Main.swift` carries **eight** `configJson` string literals — one
per supported board, with deliberately distinct bring-up layouts. The binary
keymap work converted the three that share `~/esp/SMK/keymap.json`
(`smk_kbd`'s `#else`, `NRF52840DK`, `KBD_RP2040`); the other five still parse
their own JSON, and all eight still get their matrix through
`Config.fromJson`.

So the earlier claim that "cJSON leaves the keymap path" is true, and the
easy misreading — that cJSON leaves the firmware — is not.

## Why bother

- **Flash.** `managed_components/espressif__cjson/cJSON/cJSON.c` is 3,206
  lines; expect roughly 15–25 KB of text once linked. Irrelevant on RP2040's
  2 MB, meaningful on SAMD21's 256 KB, which is the port most likely to run
  out of room first.
- **One less parser in the boot path.** A JSON parser handling data from
  flash is a larger attack and bug surface than an array index, and the
  binary decoder already exists and is bounds-checked and tested.
- **One representation.** Two ways to describe a matrix is one more than
  needed, and they can disagree.

Note the flash saving is the *weakest* of the three reasons on the boards
this project actually targets. If SAMD21 support is dropped, the case
weakens considerably — worth re-checking before scheduling this.

## Design

### 1. Generate a binary payload per board, not per repo

`generate_default_keymap.sh` currently compiles `~/esp/SMK/keymap.json` into
one `DefaultKeymapGenerated.swift` literal. It grows to emit one payload per
board, keyed by the same build flags `Main.swift` already switches on
(`SMK_TARGET_*` / board `#if`s).

The eight JSON literals move out of `Main.swift` and into per-board JSON
files under a directory the generator reads — which is a readability win on
its own, since the layouts stop being string literals buried in a 500-line
`main`.

### 2. Decode the matrix from the payload

The binary header already carries `rowCount`, `colCount`, `colsAreDriven`,
`rows[]` and `cols[]` — everything `Config.fromJson` extracts. So `Config`
gains an initialiser taking a decoded `KeymapPayload` and `Config.fromJson`
is deleted.

This is the step that actually removes the dependency; step 1 only removes
the layer half.

### 3. Delete the dependency

- The `CJSON` target and its `dependencies` entry in `Package.swift`
- `-Xcc -I…/espressif__cjson/cJSON` include paths in `Package.swift` and the
  port CMakeLists
- `cjson` from `main/CMakeLists.txt`'s `REQUIRES`
- The vendored `cJSON.c` compile entries in `ports/rp2040` and `ports/samd21`
- `LayerEngine.loadKeymap(json:)` / `loadKeymap(cJsonStr:)`
- `Tests/SMKCoreTests/CJSONSmokeTests.swift`

`Sources/CJSON/` itself is a vendored shim; delete it only after confirming
nothing else includes it.

## The risk, stated plainly

**The five bring-up board layouts are hand-maintained test fixtures.** They
exist to bring up new hardware, and four of the five cannot be tested on this
machine. Migrating them mechanically is exactly where a board's behaviour
changes silently — a wrong GPIO in a matrix row is invisible until someone
flashes that board and a column does nothing.

Mitigation: the generator must round-trip each board's JSON through
`decodeKeymapPayload` and assert the decoded matrix and layers equal what the
JSON said, per board, as a test. That is mechanical and catches the whole
class. It does not catch a JSON literal that was already wrong, which is a
pre-existing condition and out of scope.

## Testing

- Per-board round-trip: generated payload decodes to the same matrix and
  layers as that board's JSON
- `Config` built from a payload equals `Config.fromJson` on the same input —
  kept as a temporary test during migration, deleted with `fromJson` itself
- Existing `LayerEngineTests` migrate off `loadKeymap(json:)`, which is the
  bulk of the churn: many tests use the JSON convenience because it is
  readable, and a binary equivalent is not. Consider a **test-only** helper
  that compiles a JSON string to a payload, so tests stay legible without
  shipping a parser
- Flash size measured before and after, per port, and recorded — the whole
  first argument for doing this is a number nobody has measured yet

## Why this is deferred

It is genuinely independent of the binary keymap change, and separating them
means a broken board can be attributed to one thing rather than two. It will
be no harder later.

The honest sequencing argument: the binary format's value is that macros and
16 layers become possible. This project's value is 15–25 KB of flash on one
port. Doing the second before the first is finished would be optimising ahead
of shipping.
