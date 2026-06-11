# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SMK (Swift Matrix Keyboard) is keyboard firmware written in **Embedded Swift** targeting the **ESP32-C6** (RISC-V). It uses ESP-IDF as its build system with a custom CMake step that invokes `swiftc` directly — `Package.swift` exists only for IDE/LSP support and is **not** the actual build system.

## Supported Targets

| Target | MCU | Build system | HID transport |
|---|---|---|---|
| ESP32-C6 | RISC-V | ESP-IDF / idf.py | BLE (NimBLE) + Wired (CH9350 UART) |
| Pico | RP2040 ARM | CMake / Ninja + pico-sdk | USB HID (TinyUSB) |
| Pico W | RP2040 ARM | CMake / Ninja + pico-sdk | USB HID + BLE (BTstack, scaffolded) |

## Prerequisites

### ESP32-C6
- **ESP-IDF v6.0.1** sourced via `. $HOME/export-esp-idf.sh`
- **Swift 6.3.1 Embedded RISC-V toolchain** installed in `~/Library/Developer/Toolchains/`

### RP2040 / Pico
- **pico-sdk** at `~/pico-sdk` with submodules initialized (`git -C ~/pico-sdk submodule update --init`)
- **ARM toolchain with newlib**: `brew tap osx-cross/arm && brew install osx-cross/arm/arm-gcc-bin@14`
- **cmake ≥ 3.29, ninja, picotool**: `brew install cmake ninja picotool`
- **Swift ≥ 6.3 Embedded ARM toolchain** installed in `~/Library/Developer/Toolchains/`

## Build & Flash Commands

### ESP32-C6
```bash
# Source ESP-IDF environment first
. $HOME/export-esp-idf.sh

idf.py set-target esp32c6   # one-time target selection
idf.py build                 # compile Swift + C and link
idf.py flash monitor         # flash to device and open serial monitor
```

The build compiles Swift via a custom command in `main/CMakeLists.txt` — it auto-discovers the swiftc toolchain from `~/Library/Developer/Toolchains/` or the `SWIFTC_PATH` env var.

### RP2040 / Pico
```bash
export PICO_SDK_PATH=~/pico-sdk

./build_rp2040.sh pico      # plain Pico (USB HID)
./build_rp2040.sh pico_w    # Pico W (USB HID + BLE)
```

Produces `build_rp2040_<board>/smk_rp2040.uf2`. Flash via BOOTSEL + `picotool load -f ...`

The RP2040 build uses CMake's native Swift support (`enable_language(Swift)`) with the pico-sdk CMake toolchain, auto-discovering swiftc from `~/Library/Developer/Toolchains/` or `SWIFTC_PATH`.

## Architecture

### Swift ↔ C Boundary

- `Sources/smk/Bridging.h` — C headers imported into Swift; declares all C functions callable from Swift
- Swift uses `@_extern(c, "fn_name")` to call C functions (BLE init, GPIO init, FreeRTOS delay, logging)
- Swift uses `@_cdecl("app_main_swift")` to expose its entry point to C
- `Sources/componets/kb_main.c` contains `app_main()` which calls `app_main_swift()`

### Shared Swift Sources (`Sources/smk/`) — compiled for ALL targets

| File | Responsibility |
|---|---|
| `Main.swift` | Entry point, main scan loop, `Config` JSON parsing, `HIDReport` building, connection mode switching |
| `LayerEngine.swift` | `KeyCode`/`Modifier`/`KeyAction` enums, `LayerEngine` struct (JSON keymap loading, layer state, action resolution) |
| `KeyMatrix.swift` | `Modifier` enum, `KeyMatrix` (GPIO scan), `DebouncedMatrix` (counter-based debounce, threshold=5) |

### Platform-specific GPIO (`GPIORegisters.swift`)

Each target provides its own `GPIORegisters.swift` with the **same** `outSet`/`outClear`/`input` API (bit = GPIO number):

| Target | File | Base address |
|---|---|---|
| ESP32-C6 | `Sources/smk/GPIORegisters.swift` | `0x60091000` |
| RP2040 | `ports/rp2040/GPIORegisters.swift` | `0xD0000000` (SIO) |

### C Sources (`Sources/componets/`) — ESP32-C6 only

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

### RP2040 Platform Sources (`ports/rp2040/`)

| File | Responsibility |
|---|---|
| `GPIORegisters.swift` | RP2040 SIO registers (`0xD0000000`) — same API as ESP32 version |
| `BridgingHeader.h` | RP2040 bridging header: cJSON + libc + platform glue prototypes |
| `CMakeLists.txt` | pico-sdk + native CMake Swift integration; auto-discovers swiftc |
| `platform/gpio_init.c` | `init_keyboard_pins()` via `hardware/gpio.h` |
| `platform/usb_hid.c` | `init_wired_link()` / `send_wired_report()` via TinyUSB |
| `platform/usb_descriptors.c` | TinyUSB device + HID keyboard report descriptors |
| `platform/tusb_config.h` | TinyUSB device config |
| `platform/platform_glue.c` | `kb_log`, `vTaskDelay` shim, `main()`, Swift stdlib stubs, `posix_memalign` |
| `platform/ble_hid.c` | Pico W: CYW43 + BTstack HID-over-GATT; plain Pico: no-op stubs |
| `platform/btstack_config.h` | BTstack config (Pico W only) |
| `platform/smk_hid.gatt` | GATT database for BLE HID (compiled to `smk_hid.h` at build time) |

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
