# Host Unit Tests for Hardware-Independent Logic

Date: 2026-08-09
Status: Approved, pending implementation plan

## Problem

SMK has no automated tests. The codebase is Embedded Swift plus C, most of
it directly touching hardware — raw GPIO registers (`GPIORegisters.swift`),
`@_extern(c, ...)` calls into ESP-IDF/pico-sdk/BTstack — none of which can
run in a host unit test (or on a simulator; there isn't one for this
target). Swift Testing/XCTest need a normal host runtime, which Embedded
Swift binaries don't have, and hardware calls would either fail to link on
host or (if stubbed) test a mock instead of real behavior.

At the same time, real hardware-independent logic exists — JSON keymap
parsing, layer resolution, debounce, HID report assembly — and some of the
most important behavior (what happens on a keypress: layer toggling,
momentary layers, report building) is currently inline inside the
hardware scan loop in `Main.swift`, with zero path to testing it.

## Scope decision

"Fully covered" means: 100% of hardware-independent logic gets host-side
Swift Testing coverage. Hardware-touching code (GPIO config/scan, BLE,
UART, RMT/PIO LED drivers, Kconfig-driven compile-time selection) is
explicitly out of scope for unit tests — flagged below, not silently
skipped. No protocol/mock seams are introduced for hardware-touching code
in this pass (e.g. `KeyMatrix`'s scan loop stays untested) — only logic
that is *already* hardware-independent, or trivially extractable as such,
is covered.

## Architecture

### Why a new `Sources/SMKCore/` directory, not a `smk`-target refactor

The real embedded builds don't use Swift modules at all: `main/CMakeLists.txt`
(ESP32-C6) and `ports/rp2040/CMakeLists.txt` (RP2040/RP2350) each pass a flat
list of `.swift` files to one `swiftc -wmo` invocation — there's no
`import` boundary between `Main.swift`/`KeyMatrix.swift`/etc. today, they
just see each other's top-level types directly. `Package.swift` is
IDE/LSP-only and isn't involved in the real build at all (per CLAUDE.md).

So: pure logic moves into `Sources/SMKCore/` — a directory, not a new
concept, from the embedded build's point of view. Both `main/CMakeLists.txt`
and `ports/rp2040/CMakeLists.txt` add these files' paths to their existing
flat `swift_srcs` lists, exactly like any other file. No CMake behavior
changes beyond "compile a few more files in the same pass," and firmware
behavior is unchanged (pure code motion).

`Package.swift` gets two new targets, used only for host testing (never by
the real build):
- `SMKCore` — a plain library target, `path: Sources/SMKCore`, no
  Embedded feature flag, no ESP-IDF/pico-sdk include paths.
- `SMKCoreTests` — a Swift Testing target depending on `SMKCore`.

### cJSON for host builds

`Config` and `LayerEngine` parse JSON via cJSON (`cJSON_Parse`,
`cJSON_GetObjectItem`, etc.), currently reachable through
`Sources/smk/Bridging.h`'s `#include "cJSON.h"`. For the host build, add a
small SPM C target wrapping the already-vendored
`managed_components/espressif__cjson/cJSON/cJSON.c`, and have `SMKCore`
depend on it. This keeps tests exercising the *exact same* parser the
firmware ships, not a reimplementation. (Exact SPM C-target wiring —
whether it references the vendored path directly or needs a thin
`include/` shim — is an implementation detail to confirm in the plan; SPM
version quirks here are the main open risk in this design.)

## What moves into `SMKCore/`

| File | Extracted from | What it covers |
|---|---|---|
| `LayerEngine.swift` | moved as-is (already fully pure) | keymap JSON loading, layer state, `getAction` resolution, `KeyCode`/`Modifier`/`KeyAction` |
| `Config.swift` | `Main.swift` | matrix-config JSON parsing (`Config.fromJson`) |
| `HIDReport.swift` | `Main.swift` | report byte-building (`reset`/`addKey`/`addModifier`) |
| `ConnectionMode.swift` | `Main.swift` | wired/bluetooth `toggle()` |
| `Debounce.swift` | `KeyMatrix.swift` | `DebouncedMatrix`'s counter-based debounce (threshold=5) |
| `LEDChainMapping.swift` | `RGBLighting.swift` | `ledChainIndex` serpentine row/col → chain-position mapping |
| `KeyEventProcessing.swift` | new, extracted from `app_main_swift`'s `while true` loop | see below |

`Modifier`'s `rawValue` bit-mask enum currently lives in `KeyMatrix.swift`
outside `DebouncedMatrix`/`KeyMatrix` — it moves to `SMKCore` too (it's
pure, and `HIDReport.addModifier` already depends on it).

After extraction, `Sources/smk/Main.swift`, `KeyMatrix.swift`, and
`RGBLighting.swift` shrink to just their hardware-touching parts
(`@_extern` declarations, the scan loop's I/O calls, `app_main_swift`'s
wiring), calling into the `SMKCore` types for everything else. This is a
real code-quality improvement independent of testing — `Main.swift` is
currently 420 lines mixing entry-point wiring with business logic.

### `KeyEventProcessing.swift` — the important one

Today, `app_main_swift`'s loop (Main.swift:339-419) inlines: edge detection
between `cleanScan`/`lastScan`, `engine.getAction()` resolution on press,
layer toggle/momentary-add on press and momentary-remove on release,
connection-mode toggle decision on `toggle_conn`, and `HIDReport` assembly
from currently-held keys — the actual "what happens when you press a key"
behavior, currently with no test coverage because it's trapped inside the
hardware loop alongside `matrix.scan()` and `rgb?.setKey()` calls.

This extracts into a pure unit taking the debounced scan state, previous
scan state, and mutable `LayerEngine`/`ConnectionMode`/`pressedActions`
state as input, and producing the resolved `HIDReport` plus updated state
as output — no hardware calls inside it. `app_main_swift`'s loop keeps
`matrix.scan()` (input) and `send_keyboard_report`/`send_wired_report`/
`rgb?.setKey()` (output) around a call into this unit. Exact
function/type signature is an implementation-plan detail, not fixed here.

## Explicitly out of scope

- `GPIOInit.swift` / `SmkConfig.swift` — compile-time Kconfig selection
  (`#if SMK_HAS_RGB_BACKLIGHT` etc.), no runtime branches to unit test.
- `KeyMatrix`'s scan struct, `RGBLighting`'s hardware struct,
  `GPIORegisters.swift` — real hardware I/O, no mock seam introduced.
- All C: `ble_helper.c`, `uart_init.c`, `led_strip_driver.c`,
  `cyw43439_patchram.c`, `ble_hid_kbd_uart.c`, and the keymap
  store/protocol framing (`smk_keymap_store.c`, `smk_keymap_protocol.c`).
  Testing these would mean a materially different toolchain (ESP-IDF's
  Unity C test framework, likely on-device) — worth its own initiative if
  wanted later, not folded into this one.

## CI

A GitHub Actions workflow (`.github/workflows/`) running `swift test` for
`SMKCoreTests` on `macos-latest` (needs a recent Xcode/Swift toolchain for
Swift Testing support — pin a runner image known to have it), triggered on
push and pull_request. No coverage threshold/reporting — out of scope per
the scope decision above.

## Testing/verification

The suite tests itself by existing: each extracted file gets a
corresponding `SMKCoreTests` file covering its public behavior (JSON
parsing edge cases for `Config`/`LayerEngine`, debounce threshold
boundaries, HID report key-rollover/reset, `ledChainIndex` even/odd row
serpentine math, `KeyEventProcessing`'s press/release/layer-toggle/
momentary-layer/connection-toggle paths). After extraction, all six
existing build targets (ESP32-C6, Pico, Pico W, Pico 2, Pico 2 W,
smk_kbd_rp2040) must still build clean — this is the regression check that
the code motion didn't change embedded behavior.

## Open risks

- SPM C-target wiring for vendored cJSON on host — needs a quick spike
  early in the implementation plan to confirm the exact target shape
  before writing tests against it.
- `KeyEventProcessing`'s extraction touches the most behaviorally dense
  part of `Main.swift`; needs care to keep runtime behavior byte-identical
  (verified via the six-target build check above, plus manual read-through
  since there's no hardware-in-loop check in this pass).
