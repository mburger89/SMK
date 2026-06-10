# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SMK (Swift Matrix Keyboard) is keyboard firmware written in **Embedded Swift** targeting the **ESP32-C6** (RISC-V). It uses ESP-IDF as its build system with a custom CMake step that invokes `swiftc` directly — `Package.swift` exists only for IDE/LSP support and is **not** the actual build system.

## Prerequisites

- **ESP-IDF v6.0.1** sourced via `. $HOME/export-esp-idf.sh`
- **Swift 6.3.1 Embedded RISC-V toolchain** installed in `~/Library/Developer/Toolchains/`

## Build & Flash Commands

```bash
# Source ESP-IDF environment first
. $HOME/export-esp-idf.sh

idf.py set-target esp32c6   # one-time target selection
idf.py build                 # compile Swift + C and link
idf.py flash monitor         # flash to device and open serial monitor
```

The build compiles Swift via a custom command in `main/CMakeLists.txt` — it auto-discovers the swiftc toolchain from `~/Library/Developer/Toolchains/` or the `SWIFTC_PATH` env var.

## Architecture

### Swift ↔ C Boundary

- `Sources/smk/Bridging.h` — C headers imported into Swift; declares all C functions callable from Swift
- Swift uses `@_extern(c, "fn_name")` to call C functions (BLE init, GPIO init, FreeRTOS delay, logging)
- Swift uses `@_cdecl("app_main_swift")` to expose its entry point to C
- `Sources/componets/kb_main.c` contains `app_main()` which calls `app_main_swift()`

### Swift Sources (`Sources/smk/`)

| File | Responsibility |
|---|---|
| `Main.swift` | Entry point, main scan loop, `Config` JSON parsing, `HIDReport` building, connection mode switching |
| `LayerEngine.swift` | `KeyCode`/`Modifier`/`KeyAction` enums, `LayerEngine` struct (JSON keymap loading, layer state, action resolution) |
| `KeyMatrix.swift` | `Modifier` enum, `KeyMatrix` (GPIO scan), `DebouncedMatrix` (counter-based debounce, threshold=5) |
| `GPIORegisters.swift` | Memory-mapped GPIO at `0x60091000`; `outSet`/`outClear`/`input` registers |

### C Sources (`Sources/componets/`)

| File | Responsibility |
|---|---|
| `ble_helper.c` | NimBLE/esp_hidd BLE HID init and `send_keyboard_report()` |
| `uart_init.c` | UART1 init (TX:21, RX:20) and CH9350 wired HID bridge via `send_wired_report()` |
| `gpio_init.c` | `init_keyboard_pins()` — rows as push-pull outputs, columns as inputs with pull-ups |
| `kb_main.c` | `app_main()` C entry point; Unicode linker stubs for Embedded Swift |

### Key Architectural Patterns

**Matrix scan loop** (in `Main.swift`): pulls each row LOW → reads column input register → restores row HIGH. Column pin reads `0` = key pressed (active-low with pull-up). The `DebouncedMatrix` wraps raw scans and requires 5 consecutive agreeing samples before reporting a state change.

**Layer resolution** (`LayerEngine.getAction`): iterates layers from highest index to 0, skipping inactive layers and transparent keys, returning the first non-transparent action. Layer 0 is always active.

**HID dispatch**: On each tick, a `HIDReport` is built from all currently pressed key/modifier actions, then sent via either `send_keyboard_report` (BLE) or `send_wired_report` (CH9350 UART) based on `ConnectionMode`.

### Keymap Configuration

The active keymap is the `configJson` string literal in `Sources/smk/Main.swift:93`. The `keymap.json` at the repo root is a reference copy — changes there do **not** affect the firmware until copied into `Main.swift`.

**Key action syntax:**
- `key:<char>` — standard keycode (e.g. `key:a`, `key:enter`)
- `mod:<name>` — modifier (e.g. `mod:leftShift`)
- `mo:<n>` — momentary layer (held = active)
- `tg:<n>` — toggle layer
- `trans` — transparent (fall through to lower layer)
- `toggle_conn` — switch between BLE and wired modes
- `none` — no action
