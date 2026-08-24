# Retire cJSON From The Firmware — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Remove cJSON from every SMK firmware target by compiling each board's matrix *and* layers into the version-2 binary keymap payload at build time, so no board parses JSON at boot.

**Architecture:** The eight `configJson` string literals move out of `Sources/smk/Main.swift` into per-board JSON files under `boards/`. `generate_default_keymap.sh` grows from compiling one keymap to compiling all eight, emitting a board-guarded `defaultKeymapBytes` plus a host-test fixture holding every board's payload. `Config` gains an initialiser taking a decoded `KeymapPayload` — the payload header already carries `rowCount`/`colCount`/`colsAreDriven`/`rows[]`/`cols[]`, which is everything `Config.fromJson` extracted. With both users gone, cJSON is deleted from `Package.swift`, six CMakeLists, six bridging headers, and the vendored shim.

**Tech Stack:** Swift 6 / Embedded Swift, Swift Testing (`import Testing`, bare `@Test func`), Python 3 (build-time generator), ESP-IDF (ESP32-C6), pico-sdk (RP2040/RP2350), CMake + Ninja (nRF52840, STM32F4, STM32WB, SAMD21).

**Spec:** `docs/superpowers/specs/2026-08-21-retire-cjson-design.md`

> **STATUS: COMPLETE**, 2026-08-23, on branch `retire-cjson` (commits
> `4b9c555`..`a9ec579`). All ten tasks executed; every checkbox below is
> ticked because it was actually done, not because the plan was filed. All
> eleven builds link and 127 host tests pass. Measured saving: 16-93 KB of
> `.text` per target -- see
> `docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md`.
>
> Deviations from the plan as written, all deliberate:
> - Task 1 (baseline) ran first rather than in the plan's stated order, so
>   the before-measurement was taken on an untouched tree.
> - Task 2 additionally moved each board's comment block into a `comment`
>   key in its JSON file, and corrected two stale references inside those
>   comments (a deleted `battery_adc.c` path, and "below"/"in this file"
>   pointing at a Main.swift board chain that no longer exists).
> - Task 8 also removed `espressif/cjson` from `main/idf_component.yml`
>   (the actual managed-component dependency, which the plan's file list
>   missed) and updated a stale cJSON reference in the STM32WB linker
>   script's heap comment.
> - Task 9's measurement found the spec's 15-25 KB estimate was low, not
>   high, for a reason nobody had identified: cJSON pulled newlib's
>   floating-point conversion machinery in transitively.
> - A pre-existing bug was found and deliberately NOT fixed: see the
>   feather_nrf52840 note in `CLAUDE.md` and the comment at
>   `Sources/smk/Main.swift`'s empty-matrix check.

## Global Constraints

- **Test with `SMK_HOST_TESTS_ONLY=1 swift test`.** Not a bare `swift test` — with that variable unset, `swift-mmio` becomes a dependency and the resolve churns `Package.resolved`, which is deliberately untracked.
- **THE TRAP: a new file in `Sources/SMKCore/` is invisible to every embedded build until it is listed in all six CMakeLists that enumerate SMKCore sources explicitly** — `main/CMakeLists.txt` plus `ports/{rp2040,nrf52840,samd21,stm32f4,stm32wb}/CMakeLists.txt`. `Package.swift` globs the directory, so a missing CMake entry **still passes `swift test`** and only surfaces as a link failure on real hardware. This plan adds no new SMKCore file, but it *deletes* references in all six — the same six must be edited together.
- **`SMKCore` compiles under Embedded Swift for the boards.** No `Any`, no reflection, no existentials, no `Codable`, no `Foundation`. Structs, enums, arrays and non-escaping closures only. `Foundation` is allowed in `Tests/` only, which is host-only.
- **The binary payload format is fixed and shipped.** `CLAUDE.md`'s "Binary Keymap Payload Format" section is the byte contract; `Sources/SMKCore/KeymapBinary.swift` is the decoder. This plan adds a *producer* for it, and must not change the format. Three implementations already have to agree (decoder, generator, configurator) — this plan makes the generator handle eight inputs instead of one, nothing more.
- **The `init?(rawValue:)` landmine.** Never pass a wire byte to `KeyCode(rawValue:)` / `Modifier(rawValue:)` — the synthesized initialiser matches ordinal position, not the overridden HID `rawValue`. The generator works in the opposite direction (token name → usage, read from `keycodes.json`), so it is unaffected; any *test* helper that decodes must follow `KeymapBinary.swift`'s `keyCode(fromHIDUsage:)` pattern.
- **Generated files are never hand-edited.** `Sources/SMKCore/DefaultKeymapGenerated.swift` and `Tests/SMKCoreTests/BoardPayloadsGenerated.swift` are both outputs of `./generate_default_keymap.sh`; edit the inputs and re-run, then commit the regenerated files.
- Commit after every task. Do not push.

---

## File Structure

**Create:**
- `boards/smk_kbd.json` — ESP32-C6 reference board (`#else` branch, and the host-test default)
- `boards/test_board.json` — `SMK_BOARD_TEST_BOARD`
- `boards/kbd_rp2040.json` — `SMK_BOARD_KBD_RP2040`
- `boards/nrf52840dk.json` — `SMK_BOARD_NRF52840DK`
- `boards/feather_nrf52840.json` — `SMK_BOARD_FEATHER_NRF52840`
- `boards/stm32f4_blackpill.json` — `SMK_BOARD_STM32F4_BLACKPILL`
- `boards/xiao_m0.json` — `SMK_BOARD_XIAO_M0`
- `boards/stm32wb_nucleo.json` — `SMK_BOARD_STM32WB_NUCLEO`
- `Tests/SMKCoreTests/BoardPayloadsGenerated.swift` — GENERATED: every board's payload, so host tests can round-trip all eight without board build flags
- `Tests/SMKCoreTests/PayloadBuilder.swift` — test-only encoder (tokens → payload bytes) replacing the JSON convenience the tests use today
- `Tests/SMKCoreTests/BoardPayloadRoundTripTests.swift` — per-board round-trip assertions
- `docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md` — measured before/after flash per port

**Modify:**
- `generate_default_keymap.sh` — one keymap in, eight payloads + a test fixture out
- `Sources/SMKCore/DefaultKeymapGenerated.swift` — REGENERATED, becomes board-guarded
- `Sources/SMKCore/Config.swift` — gains `init(payload:)`, loses `fromJson`
- `Sources/SMKCore/LayerEngine.swift:93-94, 157-227` — loses `loadKeymap(json:)` and `loadKeymap(cJsonStr:)`
- `Sources/smk/Main.swift:85-116, 175-435, 437` — loses eight `configJson` literals, boots matrix and layers from one payload
- `Package.swift:39-48, 55-58, 130` — loses the `CJSON` target, its dependency edge, and the include path
- `main/CMakeLists.txt:39, 192` — loses `cjson` from `REQUIRES` and the include dir
- `ports/rp2040/CMakeLists.txt:196-197, 384-388`, `ports/nrf52840/CMakeLists.txt:144, 183-187, 241, 259, 268`, `ports/stm32f4/CMakeLists.txt:137, 168-172, 194, 212, 221`, `ports/stm32wb/CMakeLists.txt:144, 186-190, 212, 281, 290`, `ports/samd21/CMakeLists.txt` — lose the vendored `cJSON.c` compile entry and every `-I…/espressif__cjson/cJSON`
- `Sources/smk/Bridging.h:7`, `ports/{rp2040,nrf52840,stm32f4,stm32wb,samd21}/BridgingHeader.h` — lose `#include "cJSON.h"` and its comment line
- `Tests/SMKCoreTests/ConfigTests.swift` — migrates off `Config.fromJson`
- `Tests/SMKCoreTests/LayerEngineTests.swift` (10 sites), `Tests/SMKCoreTests/KeyEventProcessingTests.swift` (12 sites) — migrate off `loadKeymap(json:)`
- `CLAUDE.md`, `README.md`, `docs/superpowers/specs/2026-08-21-retire-cjson-design.md` — documentation and spec status

**Delete:**
- `Sources/CJSON/` (the vendored host shim: `cJSON.c`, `include/`)
- `Tests/SMKCoreTests/CJSONSmokeTests.swift`

---

### Task 1: Baseline the flash sizes

Nothing in this plan is worth doing if the saving is not real, and the spec
says so outright: "the whole first argument for doing this is a number
nobody has measured yet." That number has to be taken **before** any code
changes, on a clean build of the current tree.

**Files:**
- Create: `docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md`

**Interfaces:**
- Produces: a committed before-column that Task 8 fills in the after-column of

- [x] **Step 1: Build every target on the unmodified tree**

Run each of these from the repo root. All seven succeed on this machine —
every dependency checkout and toolchain was verified present before this
plan was written.

```bash
export PICO_SDK_PATH=~/pico-sdk
export TINYUSB_PATH=~/tinyusb BTSTACK_PATH=~/btstack
export NRF5_SDK_PATH=~/nRF5_SDK NRFXLIB_PATH=~/sdk-nrfxlib
export CMSIS_CORE_PATH=~/CMSIS_6 CMSIS_F4_PATH=~/cmsis-device-f4
export CMSIS_WB_PATH=~/cmsis-device-wb STM32CUBEWB_PATH=~/STM32CubeWB

./build_rp2040.sh pico
./build_rp2040.sh pico_w
./build_rp2040.sh pico2
./build_rp2040.sh pico2_w
./build_rp2040.sh smk_kbd_rp2040
./build_nrf52840.sh
./build_nrf52840.sh feather
./build_stm32f4.sh
./build_stm32wb.sh
./build_samd21.sh
( . ~/.espressif/v6.0.1/esp-idf/export.sh && idf.py build )
```

- [x] **Step 2: Record the text sizes**

For the ARM targets, `arm-none-eabi-size` reports the linked image:

```bash
arm-none-eabi-size build_rp2040_pico/smk_rp2040.elf \
                   build_rp2040_smk_kbd_rp2040/smk_rp2040.elf \
                   build_nrf52840_nrf52840dk/smk_nrf52840.elf \
                   build_stm32f4/smk_stm32f4.elf \
                   build_stm32wb/smk_stm32wb.elf \
                   build_samd21/smk_samd21.elf
```

For ESP32-C6, `idf.py size` gives the equivalent breakdown:

```bash
( . ~/.espressif/v6.0.1/esp-idf/export.sh && idf.py size )
```

If an `.elf` path differs from the guess above, find it with
`ls build_*/*.elf` rather than assuming — the build directory names are
per-board and the plan's list is from a tree state that may have moved.

- [x] **Step 3: Write the note file**

Create `docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md` with a table
carrying one row per target and a `text` / `data` / `bss` column set, with
the after-columns left as `TBM` (to be measured) — Task 8 fills them. Also
record, for one target, the size of cJSON's own contribution as a sanity
check on the spec's 15–25 KB estimate:

```bash
arm-none-eabi-nm --print-size --size-sort build_stm32f4/smk_stm32f4.elf | grep -i cjson
```

- [x] **Step 4: Commit**

```bash
git add docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md
git commit -m "Record per-target flash sizes before retiring cJSON"
```

---

### Task 2: Extract the eight board layouts into `boards/`

Pure data movement, no behaviour change. Each board's JSON must come out of
`Main.swift` **byte-for-byte** — retyping a GPIO number here is precisely
the silent-breakage risk the spec names, and four of the eight boards cannot
be tested on this machine.

**Files:**
- Create: `boards/{smk_kbd,test_board,kbd_rp2040,nrf52840dk,feather_nrf52840,stm32f4_blackpill,xiao_m0,stm32wb_nucleo}.json`
- Read (do not yet modify): `Sources/smk/Main.swift:175-435`

**Interfaces:**
- Produces: eight board files, each `{"board", "define", "matrix", and one of "layers"/"layersFrom"}`

- [x] **Step 1: Copy each literal out mechanically**

The eight literals sit at these exact line ranges in `Sources/smk/Main.swift`
(the `"""`-delimited body, not the `#if` line):

| Board file | `define` | Literal body lines |
|---|---|---|
| `nrf52840dk.json` | `SMK_BOARD_NRF52840DK` | 182–204 |
| `feather_nrf52840.json` | `SMK_BOARD_FEATHER_NRF52840` | 217–226 |
| `stm32f4_blackpill.json` | `SMK_BOARD_STM32F4_BLACKPILL` | 235–257 |
| `xiao_m0.json` | `SMK_BOARD_XIAO_M0` | 268–281 |
| `stm32wb_nucleo.json` | `SMK_BOARD_STM32WB_NUCLEO` | 290–312 |
| `kbd_rp2040.json` | `SMK_BOARD_KBD_RP2040` | 332–354 |
| `test_board.json` | `SMK_BOARD_TEST_BOARD` | 375–388 |
| `smk_kbd.json` | *(none — the `#else` default)* | 411–433 |

Extract with `sed`, not by hand, so no digit can be mistyped:

```bash
mkdir -p boards
sed -n '182,204p' Sources/smk/Main.swift | sed 's/^    //' > boards/nrf52840dk.json
```

Repeat per row. The leading four-space indent of the Swift literal is
stripped; the JSON body is otherwise untouched. Verify each file parses:

```bash
for f in boards/*.json; do python3 -c "import json,sys; json.load(open('$f'))" || echo "BAD $f"; done
```

- [x] **Step 2: Add the `board` and `define` keys**

Each file gains two keys at the top level, alongside the `matrix` and
`layers` it already has. For `boards/nrf52840dk.json`:

```json
{
    "board": "nrf52840dk",
    "define": "SMK_BOARD_NRF52840DK",
    "matrix": { ... unchanged ... },
    "layers": [ ... unchanged ... ]
}
```

`boards/smk_kbd.json` gets `"define": null` — it is the `#else` fallback of
the generated `#if` chain, so it has no flag of its own.

- [x] **Step 3: Deduplicate the three boards that share `keymap.json`**

`nrf52840dk`, `kbd_rp2040` and `smk_kbd` carry layers byte-identical to the
repo-root `keymap.json` — that equivalence is already established and is why
those three load `defaultKeymapBytes` today. Keeping three copies would let
them drift. Replace each of those three files' `"layers"` array with:

```json
    "layersFrom": "keymap.json"
```

Before deleting anything, prove the equivalence rather than trusting the
existing comment:

```bash
python3 - <<'EOF'
import json
ref = json.load(open("keymap.json"))["layers"]
for b in ("nrf52840dk", "kbd_rp2040", "smk_kbd"):
    got = json.load(open("boards/%s.json" % b))["layers"]
    print(b, "MATCH" if got == ref else "DIFFERS")
EOF
```

All three must print `MATCH`. If one does not, **stop** — the premise that
those three share a layout is wrong, and that board keeps its own inline
`"layers"` instead. Report which board and how it differs.

- [x] **Step 4: Commit**

```bash
git add boards/
git commit -m "Move the eight board layouts out of Main.swift into boards/"
```

---

### Task 3: Teach the generator to compile every board

**Files:**
- Modify: `generate_default_keymap.sh`
- Regenerate: `Sources/SMKCore/DefaultKeymapGenerated.swift`
- Create: `Tests/SMKCoreTests/BoardPayloadsGenerated.swift` (generated)

**Interfaces:**
- Consumes: `boards/*.json` from Task 2
- Produces: `defaultKeymapBytes: [UInt8]` (board-guarded, same name as today), and `generatedBoardPayloads: [GeneratedBoardPayload]` for tests

- [x] **Step 1: Replace the single-keymap driver with a board loop**

`generate_default_keymap.sh` already has the whole cell encoder (`encode_cell`,
`usage_by_token`, `modifier_bits`, the `TAG_*` constants) and the header/
payload writer. Keep every one of those unchanged — the format is fixed.
What changes is the input: one hardcoded `keymap.json` becomes an ordered
board list, and the output gains a `#if` chain.

Insert this ordered list, replacing the current
`keymap_json_text = open("keymap.json").read()` block through the end of
`payload` construction:

```python
# Ordered deliberately: the generated #if/#elseif chain follows this order
# and smk_kbd MUST be last, because it is the #else fallback -- both for the
# ESP32-C6 reference board (whose CMake defines no SMK_BOARD_* flag) and for
# the host `swift test` build (which defines none either). Adding a board
# means adding a file here AND to the same list in Main.swift's board
# comment.
BOARDS = [
    "nrf52840dk",
    "feather_nrf52840",
    "stm32f4_blackpill",
    "xiao_m0",
    "stm32wb_nucleo",
    "kbd_rp2040",
    "test_board",
    "smk_kbd",
]


def compile_board(name):
    spec = json.load(open("boards/%s.json" % name))
    matrix = spec["matrix"]
    rows = matrix["rows"]
    cols = matrix["cols"]
    cols_are_driven = 1 if matrix["colsAreDriven"] else 0

    if "layersFrom" in spec:
        layers = json.load(open(spec["layersFrom"]))["layers"]
    else:
        layers = spec["layers"]

    row_count = len(rows)
    col_count = len(cols)

    # A 0x0 matrix (feather_nrf52840: no matrix is wired to that board) can
    # carry no layers at all -- decodeKeymapPayload rejects a *declared*
    # layer whose matrix is 0x0, deliberately, because a six-byte payload
    # claiming 200 empty layers would otherwise blank a working keyboard
    # (see KeymapBinary.swift's guard). Encoding layerCount=0 is the correct
    # representation, and LayerEngine then leaves `keymaps` empty -- which
    # for a board with no matrix is behaviourally identical to the [[[]]]
    # its JSON declared: getAction() returns .none either way, and scan()
    # never reports a press because there are no pins to scan.
    if row_count == 0 or col_count == 0:
        for layer in layers:
            for row in layer:
                if row:
                    raise SystemExit(
                        "%s declares a 0x0 matrix but layer data is non-empty" % name)
        layers = []

    layer_count = len(layers)
    macro_count = 0  # No board layout carries macros; the format reserves the byte.

    for li, layer in enumerate(layers):
        if len(layer) != row_count:
            raise SystemExit("%s layer %d has %d rows, matrix declares %d"
                             % (name, li, len(layer), row_count))
        for ri, row in enumerate(layer):
            if len(row) != col_count:
                raise SystemExit("%s layer %d row %d has %d cols, matrix declares %d"
                                 % (name, li, ri, len(row), col_count))

    for field, value in (("rowCount", row_count), ("colCount", col_count),
                         ("layerCount", layer_count), ("macroCount", macro_count)):
        if not (0 <= value <= 0xFF):
            raise SystemExit("%s: %s=%d does not fit in one header byte"
                             % (name, field, value))
    for field, pins in (("row", rows), ("col", cols)):
        for pin in pins:
            if not (0 <= pin <= 0xFF):
                raise SystemExit("%s: %s pin %d does not fit in one byte"
                                 % (name, field, pin))

    payload = bytearray()
    payload += bytes([row_count, col_count, cols_are_driven,
                      layer_count, macro_count, 0])  # reserved=0
    payload += bytes(rows)
    payload += bytes(cols)
    for layer in layers:
        for row in layer:
            for token in row:
                tag, param = encode_cell(token)
                if not (0 <= param <= 0xFF):
                    raise SystemExit("%s: cell %r encodes a parameter that "
                                     "doesn't fit in one byte" % (name, token))
                payload += bytes([tag, param])
    return spec, payload


compiled = [(name,) + compile_board(name) for name in BOARDS]
```

- [x] **Step 2: Emit the board-guarded `defaultKeymapBytes`**

Replace the existing `lines = list(BANNER)` output block with one that walks
`compiled` and writes a `#if`/`#elseif`/`#else` chain. The public name stays
`defaultKeymapBytes`, so `Main.swift` and the existing
`compiledDefaultKeymapRoundTrips` test keep working unchanged:

```python
def byte_lines(payload, indent="    "):
    out = []
    for i in range(0, len(payload), 16):
        chunk = payload[i:i + 16]
        out.append(indent + ", ".join(str(b) for b in chunk) + ",")
    return out


lines = list(BANNER)
lines += [
    "/// Each board's keymap, pre-encoded in the version-2 binary payload",
    "/// format `decodeKeymapPayload` (KeymapBinary.swift) decodes -- so the",
    "/// boot path gets both the GPIO matrix (via `Config(payload:)`) and the",
    "/// layers without parsing any JSON. Compiled from boards/<name>.json;",
    "/// see docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md",
    "/// for the byte layout.",
    "///",
    "/// The `#else` board (smk_kbd) is also what the host `swift test` build",
    "/// sees, since no SMK_BOARD_* flag is defined there.",
]
for index, (name, spec, payload) in enumerate(compiled):
    define = spec.get("define")
    if define is None:
        if index != len(compiled) - 1:
            raise SystemExit("the board with no `define` must be last in BOARDS")
        lines.append("#else")
    else:
        lines.append(("#if " if index == 0 else "#elseif ") + define)
    lines.append("// %s" % name)
    lines.append("let defaultKeymapBytes: [UInt8] = [")
    lines += byte_lines(payload)
    lines.append("]")
lines += ["#endif", ""]

out = pathlib.Path("Sources/SMKCore/DefaultKeymapGenerated.swift")
out.write_text("\n".join(lines))
```

- [x] **Step 3: Emit the host-test fixture**

Every board's payload must be reachable from the host build to be
round-tripped, and only one is (the `#else` one). Emit a second, test-only
file carrying all eight:

```python
test_lines = list(BANNER)
test_lines += [
    "// Every board's compiled payload, so host tests can round-trip all of",
    "// them -- the shipped DefaultKeymapGenerated.swift exposes only the one",
    "// its board flags select, which on the host build is always smk_kbd.",
    "",
    "struct GeneratedBoardPayload {",
    "    let board: String",
    "    let bytes: [UInt8]",
    "}",
    "",
    "let generatedBoardPayloads: [GeneratedBoardPayload] = [",
]
for name, _spec, payload in compiled:
    test_lines.append('    GeneratedBoardPayload(board: "%s", bytes: [' % name)
    test_lines += byte_lines(payload, indent="        ")
    test_lines.append("    ]),")
test_lines += ["]", ""]

test_out = pathlib.Path("Tests/SMKCoreTests/BoardPayloadsGenerated.swift")
test_out.write_text("\n".join(test_lines))
print("wrote %s and %s (%d boards)" % (out, test_out, len(compiled)))
```

- [x] **Step 4: Run the generator**

Run: `./generate_default_keymap.sh`
Expected: prints `wrote Sources/SMKCore/DefaultKeymapGenerated.swift and Tests/SMKCoreTests/BoardPayloadsGenerated.swift (8 boards)`.

- [x] **Step 5: Verify the smk_kbd payload did not change**

This is the regression that matters: the `#else` board's bytes must be
identical to what the previous generator emitted, since nothing about that
board's input changed.

```bash
git diff Sources/SMKCore/DefaultKeymapGenerated.swift
```

Expected: the smk_kbd byte block is untouched; the only changes are the
added `#if` chain and the seven other boards' blocks. If the smk_kbd bytes
moved, **stop** — something in the encoder changed and the format contract
is at risk.

- [x] **Step 6: Run the host tests**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS, including the existing `compiledDefaultKeymapRoundTrips`.

- [x] **Step 7: Commit**

```bash
git add generate_default_keymap.sh Sources/SMKCore/DefaultKeymapGenerated.swift Tests/SMKCoreTests/BoardPayloadsGenerated.swift
git commit -m "Compile every board's keymap to a binary payload"
```

---

### Task 4: Per-board round-trip test

This is the spec's named mitigation for its own stated risk: "the generator
must round-trip each board's JSON through `decodeKeymapPayload` and assert
the decoded matrix and layers equal what the JSON said, per board, as a
test. That is mechanical and catches the whole class."

**Files:**
- Create: `Tests/SMKCoreTests/BoardPayloadRoundTripTests.swift`

**Interfaces:**
- Consumes: `generatedBoardPayloads` (Task 3), `decodeKeymapPayload` / `KeyAction` (`Sources/SMKCore/KeymapBinary.swift`)

- [x] **Step 1: Write the failing test**

Tests are host-only, so `Foundation` is available for reading and parsing
the board JSON — the thing the firmware is losing the ability to do is
exactly what makes this test an independent check rather than a tautology.

```swift
import Foundation
import Testing
@testable import SMKCore

/// Repo root, derived from this file's own path rather than a working
/// directory: `swift test` does not promise a cwd.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // SMKCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // repo root

private func boardSpec(_ name: String) throws -> [String: Any] {
    let url = repoRoot.appendingPathComponent("boards/\(name).json")
    let data = try Data(contentsOf: url)
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private func layers(of spec: [String: Any]) throws -> [[[String]]] {
    if let from = spec["layersFrom"] as? String {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(from))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return root["layers"] as! [[[String]]]
    }
    return spec["layers"] as! [[[String]]]
}

/// The token grammar, host-side and independent of the generator: this is
/// what the JSON *said*, to be compared against what the bytes decoded to.
/// It reuses `KeyAction.fromCString` (LayerEngine.swift) — the same grammar
/// the JSON path used before this migration — so a token that meant one
/// thing under cJSON cannot silently mean another now.
private func expectedAction(_ token: String) -> KeyAction {
    token.withCString { KeyAction.fromCString($0) }
}

@Test func everyBoardPayloadDecodesToItsJSON() throws {
    #expect(generatedBoardPayloads.count == 8)

    for board in generatedBoardPayloads {
        let spec = try boardSpec(board.board)
        let matrix = spec["matrix"] as! [String: Any]
        let jsonRows = (matrix["rows"] as! [Int]).map { UInt8($0) }
        let jsonCols = (matrix["cols"] as! [Int]).map { UInt8($0) }
        let jsonDriven = (matrix["colsAreDriven"] as! Int) != 0
        let jsonLayers = try layers(of: spec)

        let decoded = board.bytes.withUnsafeBufferPointer {
            decodeKeymapPayload($0.baseAddress, count: $0.count)
        }
        let payload = try #require(decoded, "\(board.board) payload did not decode")

        #expect(payload.rows == jsonRows, "\(board.board) rows")
        #expect(payload.cols == jsonCols, "\(board.board) cols")
        #expect(payload.colsAreDriven == jsonDriven, "\(board.board) colsAreDriven")
        #expect(payload.macros.isEmpty, "\(board.board) macros")

        // A board with no matrix wired (feather_nrf52840) encodes zero
        // layers on purpose — see generate_default_keymap.sh's compile_board.
        if jsonRows.isEmpty || jsonCols.isEmpty {
            #expect(payload.layers.isEmpty, "\(board.board) should encode no layers")
            continue
        }

        #expect(payload.layers.count == jsonLayers.count, "\(board.board) layer count")
        for (li, layer) in jsonLayers.enumerated() {
            #expect(payload.layers[li].count == layer.count, "\(board.board) layer \(li) rows")
            for (ri, row) in layer.enumerated() {
                #expect(payload.layers[li][ri].count == row.count,
                        "\(board.board) layer \(li) row \(ri) cols")
                for (ci, token) in row.enumerated() {
                    #expect(payload.layers[li][ri][ci] == expectedAction(token),
                            "\(board.board) layer \(li) row \(ri) col \(ci) token \(token)")
                }
            }
        }
    }
}
```

- [x] **Step 2: Run the test**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter BoardPayload`

`KeyAction` already conforms to `Equatable` (`Sources/SMKCore/LayerEngine.swift:34`),
so the `#expect(... == ...)` comparisons need no new conformance.

Expected: PASS for all eight boards. A failure here means a board's layout
changed in extraction — go back to Task 2 and re-extract that board with
`sed` rather than patching the JSON to match the bytes.

- [x] **Step 3: Commit**

```bash
git add Tests/SMKCoreTests/BoardPayloadRoundTripTests.swift
git commit -m "Round-trip every board's compiled payload against its JSON"
```

---

### Task 5: `Config` from a decoded payload

**Files:**
- Modify: `Sources/SMKCore/Config.swift`
- Test: `Tests/SMKCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces: `Config.init(payload: KeymapPayload)`
- Consumes: `KeymapPayload` (`Sources/SMKCore/KeymapBinary.swift:116-122`)

- [x] **Step 1: Write the failing test**

Append to `Tests/SMKCoreTests/ConfigTests.swift`. This test is the
**equivalence pin** the spec asks for — it exists to prove the new path
produces exactly what `fromJson` produced, and is deleted along with
`fromJson` in Task 7.

```swift
@Test func configFromPayloadMatchesConfigFromJson() throws {
    for board in generatedBoardPayloads {
        let decoded = board.bytes.withUnsafeBufferPointer {
            decodeKeymapPayload($0.baseAddress, count: $0.count)
        }
        let payload = try #require(decoded, "\(board.board) payload did not decode")
        let fromPayload = Config(payload: payload)

        let specURL = repoRootForConfigTests.appendingPathComponent("boards/\(board.board).json")
        let json = try String(contentsOf: specURL, encoding: .utf8)
        let fromJson = Config.fromJson(json)

        #expect(fromPayload.rowPins == fromJson.rowPins, "\(board.board) rowPins")
        #expect(fromPayload.colPins == fromJson.colPins, "\(board.board) colPins")
        #expect(fromPayload.colsAreDriven == fromJson.colsAreDriven, "\(board.board) colsAreDriven")
    }
}
```

Add the same `#filePath`-derived root this file needs, named distinctly so
it does not collide with `BoardPayloadRoundTripTests.swift`'s private one:

```swift
private let repoRootForConfigTests = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
```

and `import Foundation` at the top of the file if it is not already there.

- [x] **Step 2: Run test to verify it fails**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter Config`
Expected: FAIL to compile — `Config` has no `init(payload:)`.

- [x] **Step 3: Write minimal implementation**

Add to `Sources/SMKCore/Config.swift`, above `fromJson`:

```swift
    /// Builds the GPIO matrix config from a decoded binary keymap payload.
    /// The payload header already carries every field `fromJson` dug out of
    /// a `"matrix"` object -- `rows[]`, `cols[]` and `colsAreDriven` -- so
    /// the board's matrix and its layers come from one artifact instead of
    /// two representations that can disagree.
    ///
    /// Written as explicit loops rather than `map` to stay obviously
    /// allocation-shaped for Embedded Swift, matching how the rest of
    /// SMKCore builds arrays.
    init(payload: KeymapPayload) {
        self.init()
        rowPins.reserveCapacity(payload.rows.count)
        for pin in payload.rows { rowPins.append(Int32(pin)) }
        colPins.reserveCapacity(payload.cols.count)
        for pin in payload.cols { colPins.append(Int32(pin)) }
        colsAreDriven = payload.colsAreDriven
    }
```

- [x] **Step 4: Run test to verify it passes**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS — all eight boards agree between the two paths.

- [x] **Step 5: Commit**

```bash
git add Sources/SMKCore/Config.swift Tests/SMKCoreTests/ConfigTests.swift
git commit -m "Build Config from a decoded keymap payload"
```

---

### Task 6: Boot `Main.swift` from one payload

**Files:**
- Modify: `Sources/smk/Main.swift:85-116` (`loadCompiledDefaultKeymap`), `:175-435` (the eight literals), `:437` (`Config.fromJson`)

**Interfaces:**
- Consumes: `Config.init(payload:)` (Task 5), `defaultKeymapBytes` (Task 3)

- [x] **Step 1: Delete the eight literals**

Delete `Sources/smk/Main.swift` lines 175–435 entirely — the whole
`#if SMK_BOARD_NRF52840DK` … `#endif` chain, including each board's comment
block. **The comments are not disposable:** each carries a
placeholder-pins-must-be-replaced warning that is the only thing standing
between a future reader and flashing an unverified pin map. Move each
board's comment verbatim into a `"comment"` key at the top of its
`boards/<name>.json` file (JSON has no comment syntax; a string key is the
conventional substitute and the generator ignores unknown keys).

- [x] **Step 2: Replace the config and keymap load**

`Sources/smk/Main.swift:437`'s `let cfg = Config.fromJson(configJson)`
becomes a decode of the compiled-in payload:

```swift
    // Both the GPIO matrix and the layers come from the one compiled-in
    // binary payload (Sources/SMKCore/DefaultKeymapGenerated.swift,
    // generated from boards/<name>.json by ./generate_default_keymap.sh).
    // Decoded twice on purpose -- once here for the matrix, once in
    // loadCompiledDefaultKeymap below for the layers -- rather than adding
    // a payload-taking entry point to LayerEngine for a boot-time-only
    // saving of a few hundred bytes of transient allocation.
    let cfg: Config = defaultKeymapBytes.withUnsafeBufferPointer { ptr in
        guard let base = ptr.baseAddress,
              let payload = decodeKeymapPayload(base, count: ptr.count) else {
            // Unreachable short of a generator bug: these bytes are
            // compiled in, not read from storage. An empty Config means
            // zero rows and zero columns, so init_keyboard_pins touches no
            // GPIO and scan() reports no presses -- inert, not undefined.
            kb_log("Compiled-in keymap payload invalid")
            return Config()
        }
        return Config(payload: payload)
    }
```

- [x] **Step 3: Simplify `loadCompiledDefaultKeymap`**

The five-board `#if` in `Sources/smk/Main.swift:107-116` exists only to send
the JSON boards down the JSON path. Every board is a binary board now, so
the branch goes and the `configJson` parameter with it:

```swift
// Loads the compiled-in default keymap for this board -- the binary payload
// generated from boards/<name>.json into
// Sources/SMKCore/DefaultKeymapGenerated.swift by ./generate_default_keymap.sh.
// Every board takes this path now; the five bring-up boards that used to
// parse their own JSON literal here were migrated when cJSON was retired
// (docs/superpowers/specs/2026-08-21-retire-cjson-design.md).
//
// The board's GPIO matrix comes from the *same* payload, via
// `Config(payload:)` in app_main_swift -- one artifact, no second
// representation to disagree with.
func loadCompiledDefaultKeymap(into engine: inout LayerEngine) {
    defaultKeymapBytes.withUnsafeBufferPointer { ptr in
        if let base = ptr.baseAddress {
            engine.loadKeymap(binary: base, count: ptr.count)
        }
    }
}
```

Update both call sites (`Sources/smk/Main.swift:567` and `:572`) to drop the
`configJson:` argument.

- [x] **Step 4: Leave the stored-keymap path's matrix alone — deliberately**

An uploaded keymap payload carries its own `rows`/`cols` header, and it is
tempting to let a stored keymap re-map the GPIO matrix. **Do not.** Today
the stored payload contributes layers and macros only, and the matrix always
comes from the firmware build; a configurator that sent wrong pins could
otherwise leave a board unable to scan its own reset key. Keep
`Sources/smk/Main.swift`'s stored-keymap branch calling
`engine.loadKeymap(binary:count:)` exactly as it does now, and add a comment
at the `cfg` site saying the stored payload's matrix header is ignored on
purpose.

- [x] **Step 5: Verify the host build**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS. (`Main.swift` is not in the host target, so this only proves
nothing in SMKCore broke — Task 9 is what compiles `Main.swift`.)

- [x] **Step 6: Commit**

```bash
git add Sources/smk/Main.swift boards/
git commit -m "Boot every board from its compiled binary payload"
```

---

### Task 7: Migrate the tests off the JSON entry points

22 call sites use `loadKeymap(json:)` because a JSON literal is readable and
a byte array is not. Deleting the JSON path without replacing that
readability would make the test suite materially worse, so the replacement
comes first.

**Files:**
- Create: `Tests/SMKCoreTests/PayloadBuilder.swift`
- Modify: `Tests/SMKCoreTests/LayerEngineTests.swift` (10 sites), `Tests/SMKCoreTests/KeyEventProcessingTests.swift` (12 sites), `Tests/SMKCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces: `payloadBytes(rows:cols:colsAreDriven:layers:)`, `LayerEngine.loadTestKeymap(_:rows:cols:colsAreDriven:)`

- [x] **Step 1: Write the builder and its drift pin**

```swift
import Foundation
import Testing
@testable import SMKCore

/// Test-only encoder: keymap tokens -> version-2 binary payload bytes.
///
/// This is a fourth implementation of a format that already has three
/// (decoder, generate_default_keymap.sh, the configurator's compiler), which
/// is a real cost -- accepted because the alternative is either shipping a
/// JSON parser in firmware purely for test readability, or writing every
/// test's keymap as a hand-counted byte array. It is pinned against the
/// shell generator by `builderMatchesShellGenerator` below, so it cannot
/// drift silently.
func payloadBytes(rows: [UInt8], cols: [UInt8], colsAreDriven: Bool,
                  layers: [[[String]]]) -> [UInt8] {
    var out: [UInt8] = [
        UInt8(rows.count), UInt8(cols.count), colsAreDriven ? 1 : 0,
        UInt8(layers.count), 0, 0,
    ]
    out += rows
    out += cols
    for layer in layers {
        for row in layer {
            for token in row {
                out += encodeToken(token)
            }
        }
    }
    return out
}

/// Encodes one cell the way KeymapBinary.swift's `decodeCell` reads it.
/// Deliberately routed through `KeyAction.fromCString` and
/// `Modifier.fromCString` -- the same grammar the firmware uses -- so a
/// token spelled wrong in a test fails loudly here rather than encoding as
/// something plausible.
private func encodeToken(_ token: String) -> [UInt8] {
    let action = token.withCString { KeyAction.fromCString($0) }
    switch action {
    case .none: return [0, 0]
    case .key(let code): return [1, code.rawValue]
    case .modifier(let mod): return [2, mod.rawValue]
    case .momentaryLayer(let n): return [3, UInt8(n)]
    case .toggleLayer(let n): return [4, UInt8(n)]
    case .transparent: return [5, 0]
    case .toggleConnection: return [6, 0]
    case .macro(let slot): return [7, UInt8(slot)]
    }
}

extension LayerEngine {
    /// Loads a keymap written as tokens, the readability `loadKeymap(json:)`
    /// used to give. Row/col pin numbers default to 0..<n because most tests
    /// care only about the layer grid, not the GPIO map.
    mutating func loadTestKeymap(_ layers: [[[String]]],
                                 rows: [UInt8]? = nil,
                                 cols: [UInt8]? = nil,
                                 colsAreDriven: Bool = false) {
        let rowCount = layers.first?.count ?? 0
        let colCount = layers.first?.first?.count ?? 0
        let bytes = payloadBytes(
            rows: rows ?? Array(0..<UInt8(rowCount)),
            cols: cols ?? Array(0..<UInt8(colCount)),
            colsAreDriven: colsAreDriven,
            layers: layers)
        bytes.withUnsafeBufferPointer {
            if let base = $0.baseAddress { loadKeymap(binary: base, count: $0.count) }
        }
    }
}
```

The drift pin, in the same file — it compiles `keymap.json` through the
builder and asserts byte-equality with what the shell generator produced:

```swift
@Test func builderMatchesShellGenerator() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let boardData = try Data(contentsOf: root.appendingPathComponent("boards/smk_kbd.json"))
    let board = try JSONSerialization.jsonObject(with: boardData) as! [String: Any]
    let matrix = board["matrix"] as! [String: Any]
    let keymapData = try Data(contentsOf: root.appendingPathComponent("keymap.json"))
    let keymap = try JSONSerialization.jsonObject(with: keymapData) as! [String: Any]

    let built = payloadBytes(
        rows: (matrix["rows"] as! [Int]).map { UInt8($0) },
        cols: (matrix["cols"] as! [Int]).map { UInt8($0) },
        colsAreDriven: (matrix["colsAreDriven"] as! Int) != 0,
        layers: keymap["layers"] as! [[[String]]])

    #expect(built == defaultKeymapBytes)
}
```

- [x] **Step 2: Run it**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter builderMatchesShellGenerator`
Expected: PASS. A failure means the Swift builder and the Python generator
disagree about the format — fix the builder, never the generator, since the
generator's output is what ships.

If `KeyAction`'s case names differ from the `switch` above, read them from
`Sources/SMKCore/LayerEngine.swift` and correct the builder — do not add a
`default:` arm, because an unhandled case must fail the build here rather
than encode as something wrong.

- [x] **Step 3: Migrate the 22 call sites**

Mechanical. Each `loadKeymap(json:)` call takes a JSON string containing a
`"layers"` array; it becomes a `loadTestKeymap` call with the same grid.
Before:

```swift
    engine.loadKeymap(json: """
    {
        "layers": [
            [["key:a", "key:b"], ["mo:1", "key:d"]],
            [["key:x", "trans"], ["trans", "key:z"]]
        ]
    }
    """)
```

After:

```swift
    engine.loadTestKeymap([
        [["key:a", "key:b"], ["mo:1", "key:d"]],
        [["key:x", "trans"], ["trans", "key:z"]],
    ])
```

Find every site with:

```bash
grep -rn "loadKeymap(json:" Tests/
```

Work through them one file at a time, running the suite after each file.

- [x] **Step 4: Migrate `ConfigTests.swift`**

Four sites call `Config.fromJson` (`Tests/SMKCoreTests/ConfigTests.swift:8,
18, 23, 29`). Two of them assert malformed-input behaviour (`"not json"`,
`"{}"`), which has no analogue once JSON is gone — the equivalent
malformed-input contract is `decodeKeymapPayload` returning `nil`, and
`KeymapBinaryTests` already covers that thoroughly. Replace all four with
`Config(payload:)` tests over `generatedBoardPayloads`, plus one asserting
an all-zero/short byte array decodes to `nil` rather than a `Config` with
garbage pins:

```swift
@Test func configRejectsAShortPayload() {
    let short: [UInt8] = [5, 12, 1]
    let decoded = short.withUnsafeBufferPointer {
        decodeKeymapPayload($0.baseAddress, count: $0.count)
    }
    #expect(decoded == nil)
}
```

Keep `configFromPayloadMatchesConfigFromJson` (Task 5) for now — it is
deleted in Task 8 along with `fromJson` itself.

- [x] **Step 5: Run the full suite**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS, with zero remaining `loadKeymap(json:` hits in `Tests/`.

- [x] **Step 6: Commit**

```bash
git add Tests/
git commit -m "Move the tests off the JSON keymap entry points"
```

---

### Task 8: Delete cJSON

Only now, with nothing calling it, does the dependency come out. Doing this
earlier would have meant a broken tree between tasks.

**Files:**
- Modify: `Sources/SMKCore/Config.swift`, `Sources/SMKCore/LayerEngine.swift`, `Package.swift`, `main/CMakeLists.txt`, `ports/{rp2040,nrf52840,samd21,stm32f4,stm32wb}/CMakeLists.txt`, `Sources/smk/Bridging.h`, `ports/{rp2040,nrf52840,stm32f4,stm32wb,samd21}/BridgingHeader.h`
- Delete: `Sources/CJSON/`, `Tests/SMKCoreTests/CJSONSmokeTests.swift`

- [x] **Step 1: Delete the Swift entry points**

- `Sources/SMKCore/Config.swift`: delete `static func fromJson` (lines 10–34) and the `#if canImport(CJSON) import CJSON #endif` header (lines 1–3).
- `Sources/SMKCore/LayerEngine.swift`: delete `loadKeymap(json:)` (lines 93–94) and `loadKeymap(cJsonStr:)` (line 157 through the end of that method), plus the file's `import CJSON` and the `#include <string.h>` rationale comment at line 7 if it exists only for cJSON.
- `Tests/SMKCoreTests/ConfigTests.swift`: delete `configFromPayloadMatchesConfigFromJson` — its whole purpose was pinning the migration, and it cannot compile without `fromJson`.
- Update `Sources/SMKCore/LayerEngine.swift:86-90`'s doc comment on `macros`, which currently says macros are "always empty on the JSON path" — there is no JSON path.

- [x] **Step 2: Delete the build wiring**

```bash
git rm -r Sources/CJSON Tests/SMKCoreTests/CJSONSmokeTests.swift
```

Then, by hand:
- `Package.swift`: delete the `CJSON` target (lines 39–48), remove `"CJSON"` from `SMKCore`'s `dependencies` (line 57), and delete the `-Xcc -I…/espressif__cjson/cJSON` line (130).
- `main/CMakeLists.txt`: drop `cjson` from `REQUIRES` (line 39) and delete the include-dir line (192).
- `ports/rp2040/CMakeLists.txt`: delete the `cJSON.c` source entry (196–197) and the include path (388).
- `ports/nrf52840/CMakeLists.txt`: delete `NRF52840_CJSON_DIR` (187), the `-Xcc -I` (241), the `cJSON.c` source (259), the `target_include_directories` entry (268), and correct the stale comments at 144 and 183–186.
- `ports/stm32f4/CMakeLists.txt`: same five edits (172, 194, 212, 221, comments at 137/168–171).
- `ports/stm32wb/CMakeLists.txt`: same five edits (190, 212, 281, 290, comments at 144/186–189).
- `ports/samd21/CMakeLists.txt`: delete `SAMD21_CJSON_DIR` (154), the `-Xcc -I` (176), the `cJSON.c` source (197), and the `target_include_directories` entry (205).
- All six bridging headers: delete `#include "cJSON.h"` and the "cJSON (config / keymap parsing)" comment line.

- [x] **Step 3: Confirm nothing references it**

```bash
grep -rn -i "cjson" --exclude-dir=build --exclude-dir=.git --exclude-dir=managed_components . \
  | grep -v "docs/superpowers"
```

Expected: no hits outside `docs/` (the specs and plans legitimately discuss
it in past tense). `managed_components/espressif__cjson/` itself is an
ESP-IDF managed dependency directory, not this repo's source — leave it on
disk; ESP-IDF's component manager owns it, and it is no longer in any
`REQUIRES`, so it is not linked.

- [x] **Step 4: Run the host tests**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add -A
git commit -m "Delete cJSON from the firmware"
```

---

### Task 9: Build every target and measure the result

**Files:**
- Modify: `docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md`

- [x] **Step 1: Clean-build all seven targets**

Same environment exports as Task 1. Delete the build directories first so no
stale object file hides a missing include:

```bash
rm -rf build_rp2040_* build_nrf52840_* build_stm32f4 build_stm32wb build_samd21
./build_rp2040.sh pico && ./build_rp2040.sh pico_w && ./build_rp2040.sh pico2 \
  && ./build_rp2040.sh pico2_w && ./build_rp2040.sh smk_kbd_rp2040
./build_nrf52840.sh && ./build_nrf52840.sh feather
./build_stm32f4.sh && ./build_stm32wb.sh && ./build_samd21.sh
( . ~/.espressif/v6.0.1/esp-idf/export.sh && idf.py fullclean && idf.py build )
```

Every one must link. A link failure naming a `cJSON_*` symbol means a Swift
file still calls it; a failure naming a missing header means a bridging
header was missed.

- [x] **Step 2: Re-measure and fill in the table**

Same `arm-none-eabi-size` / `idf.py size` commands as Task 1, Step 2. Fill
the after-columns in `docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md`
and add a delta column.

Report the real number even if it is disappointing. The spec predicted
15–25 KB and explicitly flagged that estimate as unmeasured; if the actual
saving is smaller, that is the finding, and it belongs in the note rather
than being quietly omitted.

- [x] **Step 3: Commit**

```bash
git add docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md
git commit -m "Record the measured flash saving from retiring cJSON"
```

---

### Task 10: Documentation

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `docs/superpowers/specs/2026-08-21-retire-cjson-design.md`

- [x] **Step 1: Update `CLAUDE.md`**

The "Keymap Configuration" section currently states the opposite of what is
now true, at length — "**cJSON is not retired — do not assume it is**",
"five of the eight boards above still load their *layers* as JSON too", and
the eight-`configJson`-literals description. Rewrite it to say:

- every board's matrix and layers come from `boards/<name>.json`, compiled by
  `./generate_default_keymap.sh` into `Sources/SMKCore/DefaultKeymapGenerated.swift`
- the generated file is board-guarded, and the `#else` board (smk_kbd) is
  what the host test build sees
- `Config` is built from the payload header via `Config(payload:)`; there is
  no JSON parser in the firmware any more
- adding a board means a `boards/*.json` file plus an entry in
  `generate_default_keymap.sh`'s `BOARDS` list, in that order
- `feather_nrf52840` compiles to zero layers because it declares a 0x0
  matrix, and why that is correct rather than a data-loss bug
- the stored-keymap path ignores an uploaded payload's matrix header on
  purpose

Also update the `Sources/SMKCore/` file table's `Config.swift` row
("matrix-config JSON parsing") and `LayerEngine.swift` row ("keymap JSON
loading").

- [x] **Step 2: Update `README.md`**

Its "Known Issues / TODOs" section does not mention cJSON, so nothing needs
removing there — but if any build-prerequisite text names cJSON, update it.
Check with `grep -n -i "json" README.md`.

- [x] **Step 3: Mark the spec done**

`docs/superpowers/specs/2026-08-21-retire-cjson-design.md`'s header says
`Status: **deferred.** Written up while the context was fresh; not
scheduled.` Replace with a line naming this plan and the date it was
implemented, and append the measured flash numbers from Task 9 — the spec's
"Why bother" section leads with a flash figure that was a guess, and leaving
a guess next to a measurement invites someone to quote the guess.

- [x] **Step 4: Verify every claim**

Read the edited sections back against the tree. A false statement in
`CLAUDE.md` is worse than an absent one — this project has been bitten by
exactly that before (the configurator's own `CLAUDE.md` documented an
enforcement rule that was untrue when written, and the macro-playback spec's
storage section outlived its own supersession long enough to be planned
twice).

- [x] **Step 5: Commit**

```bash
git add CLAUDE.md README.md docs/superpowers/specs/2026-08-21-retire-cjson-design.md
git commit -m "Document the cJSON retirement"
```
