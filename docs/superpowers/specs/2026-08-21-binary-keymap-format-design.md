# Binary keymap format — design

Date: 2026-08-21
Supersedes: `2026-08-21-firmware-macro-playback-design.md` (its player and
ASCII-table sections survive; its storage sections do not)
Companion: `~/esp/smk_configurator/docs/superpowers/specs/2026-08-20-macro-creation-design.md`

## Problem

The board stores its keymap as the `keymap.json` text the configurator
uploads, parsed at boot with cJSON. Measured against this repo's own
reference keymap, that costs **11.9 bytes per cell** — 712 bytes for one
5×12 layer.

Two consequences, one of them already biting:

**The advertised 16-layer ceiling has never been reachable.**
`LayerEngine` sizes `toggledLayers`/`momentaryCounts` at 16 and the editor
enforces `maxLayerCount = 16`, but 16 layers of a 5×12 board is ~11.1 KB of
JSON against a 4085-byte store. The real limit is about **five layers**.
Nothing reports this; a user simply fails to upload.

**Macros make it worse.** Macros were specified to ride inside the same
JSON document, competing with layers for the same 4085 bytes, at similar
JSON overhead.

The earlier response was to enlarge storage: four flash sectors and a boot
migration on RP2040, a dedicated 64 KB partition on ESP32-C6. That pays real
costs — 12 KB of program flash, 4× erase wear, a custom partition table, a
migration path — to carry an encoding that is six times larger than it needs
to be.

## The measurement

| | JSON | Binary (2 bytes/cell) |
|---|---|---|
| Per cell | 11.9 B | 2 B |
| Per layer (5×12) | 712 B | 120 B |
| 16 layers | ~11.1 KB | **1,920 B** |

At 2 bytes per cell, all 16 layers fit inside the **existing** 4085-byte
ceiling with roughly 2 KB left for macros. The storage problem largely
dissolves instead of being paid for.

## Decision

Compile the whole keymap — matrix, layers and macros — to a binary payload.
JSON remains the on-disk format the user edits; binary is the wire and
storage format.

**Consequences that make this cheaper than it sounds:**

- RP2040 keeps its single 4096-byte sector. No enlargement, no boot
  migration, no 12 KB of program flash surrendered, no extra erase wear.
- ESP32-C6 keeps NVS. No custom partition table, no new storage backend, no
  risk to NimBLE's bonding keys.
- The frame stays at the same offset and the same size. Nothing is orphaned
  by a moved region.
- cJSON leaves the keymap path entirely (see "The compiled-in default").

## Format

The existing 11-byte frame header is unchanged — magic `"SMKM"`, version,
length (LE), CRC32 (LE) — with **version bumped to 2**. The payload becomes:

```
header    rowCount(1) colCount(1) colsAreDriven(1)
          layerCount(1) macroCount(1) reserved(1)
          rows[rowCount](1 each)   GPIO numbers
          cols[colCount](1 each)
layers    layerCount * rowCount * colCount * 2 bytes
macros    macroCount entries
```

**A cell is two bytes:** an action tag, then its parameter.

| Tag | Action | Parameter |
|---|---|---|
| 0 | `none` | 0 |
| 1 | `key:` | HID usage |
| 2 | `mod:` | modifier bit |
| 3 | `mo:` | layer index |
| 4 | `tg:` | layer index |
| 5 | `trans` | 0 |
| 6 | `toggle_conn` | 0 |
| 7 | `macro:` | slot |

Two bytes rather than one because a HID usage needs all eight bits of the
parameter. A variable-width encoding would save more, but 16 layers already
fit at a flat two bytes, and a fixed stride keeps the decoder a bounds-checked
index rather than a parser.

Macro entries keep the step layout already specified in
`~/esp/smk_configurator/CLAUDE.md` — opcodes, endianness, modifier bit order,
keycode derivation. That contract stops being vestigial: these are now the
bytes actually stored, which is what the editor's capacity meter always
claimed to measure.

### What binary costs: lossless save

`KeymapDocument` keeps cells as raw strings so a token this build does not
understand survives a load/save round-trip. A two-byte cell cannot encode an
arbitrary string, so that guarantee cannot cross the wire.

The resolution is a split rather than a loss: **the on-disk `keymap.json`
keeps raw strings and stays lossless**, and the *compiler* refuses to encode
an unknown token, naming it. This is honest — a token the firmware has no tag
for is one the board could not execute anyway, so refusing to flash it is
better than silently dropping it. The file keeps it; the board never
pretends to have it.

### The compiled-in default

`Main.swift` currently does `engine.loadKeymap(json: configJson)` with a JSON
string literal. If that stays, cJSON stays linked and the flash saving
shrinks.

Instead a `generate_default_keymap.sh` compiles `keymap.json` to a binary
literal at build time, matching the codegen idiom this repo already uses for
`generate_keycodes.sh` and `generate_ble_uuids.sh`. With uploads and the
default both binary, cJSON leaves the keymap path.

### Version handling

New firmware reads the version byte. A version 1 (JSON) frame is **rejected**,
logged distinctly, and the compiled default loads — the same safe fallback
that already exists for a corrupt frame. The user re-uploads once.

This is a far gentler migration than moving a flash region: the frame never
moves, so the failure is a clean version check rather than a garbage read at
a wrong offset.

## Editor changes

Larger than the follow-ups the superseded spec listed, because the compiler
lives here:

1. **A compiler**: `KeymapDocument` → binary payload, including macro steps
2. **Upload sends the binary payload** instead of `{"layers":…,"macros":…}`
3. **Unknown tokens refuse to compile**, naming the offending cell and token
4. **The capacity meter measures the real blob** — and `compiledSize` finally
   describes bytes that exist
5. Timing quantized to 10 ms, Paste removed, text validated to printable
   ASCII, `CAPS` wired in, `firmwareVersionLabel` bumped (carried over)

`keymap.json` on disk is unchanged. Import/export stay JSON.

## Firmware changes

1. **A binary decoder in `SMKCore`** — host-testable, replacing the cJSON
   keymap path
2. `MacroPlayer` and the ASCII table, unchanged from the superseded spec
3. `KeyAction.macro`, `macroEvents`, main-loop arbitration, unchanged
4. `generate_default_keymap.sh` and the generated default
5. `CAPS` opcode `0x05`
6. **No** per-port ceiling change, **no** partition table, **no** boot
   migration

## Testing

- Cell round-trip for every action tag, including the parameter boundaries
- 16 layers of a 5×12 board encode within the existing ceiling — the claim
  this whole change rests on, pinned as a test
- A truncated or over-long payload is rejected without indexing out of range;
  binary loses the bounds-checking JSON gave for free, so this is deliberate
- A version 1 frame is rejected and falls back to the compiled default
- Unknown token refuses to compile, on the editor side
- Byte layout pinned against the editor's compiler, cross-repo, the same
  discipline `KeyVocabularyTests` uses for the vocabulary
- The generated default matches `keymap.json` compiled at build time

## Out of scope

- Recording from the board (sub-project 4)
- Conditions, flows and Paste — all need the host helper
- Variable-width cell encoding. Worth revisiting only if a board appears
  whose layers do not fit at a flat two bytes.
