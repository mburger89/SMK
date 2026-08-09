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
| Pico 2 | RP2350 ARM (Cortex-M33) | CMake / Ninja + pico-sdk (`SMK_TARGET_BOARD=pico2`) | USB HID (TinyUSB); build-only, not yet hardware-verified |
| Pico 2 W | RP2350 ARM (Cortex-M33) | CMake / Ninja + pico-sdk (`SMK_TARGET_BOARD=pico2_w`) | USB HID + BLE (BTstack, scaffolded); build-only, not yet hardware-verified |
| smk_kbd_rp2040 | RP2040 ARM (chip-down + CYW43439) | CMake / Ninja + pico-sdk (`SMK_TARGET_BOARD=smk_kbd_rp2040`) | USB HID + per-key RGB (working) + BLE (BTstack over dedicated UART; PatchRAM firmware data embedded in `ports/rp2040/platform/cyw43439_patchram.c`, sourced from Murata's public `cyw-bt-patch` repo per their CYW43439→"1YN" module mapping — matched by part number, not yet hardware-confirmed via `lmp_subversion` since the board is still at fab) |

## Prerequisites

### ESP32-C6
- **ESP-IDF v6.0.1** sourced via `. $HOME/export-esp-idf.sh`
- **Swift 6.3.1 Embedded RISC-V toolchain** installed in `~/Library/Developer/Toolchains/`

### RP2040 / Pico
- **pico-sdk** at `~/pico-sdk` with submodules initialized (`git -C ~/pico-sdk submodule update --init`)
- **ARM toolchain with newlib**: `brew tap osx-cross/arm && brew install osx-cross/arm/arm-gcc-bin@14`
- **cmake ≥ 3.29, ninja, picotool**: `brew install cmake ninja picotool`
- **Swift ≥ 6.3 Embedded ARM toolchain** installed in `~/Library/Developer/Toolchains/`
- **RP2350 (`pico2`/`pico2_w`) additionally requires a Swift development-snapshot toolchain** (confirmed: `swift-DEVELOPMENT-SNAPSHOT-2026-05-27-a` or later) that ships a real Embedded-Swift stdlib for `armv8m.main-none-none-eabi` (RP2350's Cortex-M33 target). Released `swift-6.3.x` toolchains report support for that triple via `-print-target-info` but fail an actual compile — they don't ship the stdlib.

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
| RP2040 / RP2350 | `ports/rp2040/GPIORegisters.swift` | `0xD0000000` (SIO — identical register layout on both chips) |

### smk_kbd board (ESP32-C6-MINI-1)

The active `configJson` in `Main.swift` targets this specific board (59-key, 5×12, BLE + Li-ion + USB-C charging, no wired-HID bridge, no per-key RGB). GPIO map, straight from the PCB project's README (source of truth for pin assignments):

| Function | GPIO |
|---|---|
| ROW0–ROW3 (sense, pull-down) | IO0–IO3 |
| ROW4 (sense, pull-down) | IO5 |
| COL0–COL11 (strobe, push-pull) | IO6, IO7, IO8, IO14, IO15, IO18, IO19, IO20, IO21, IO22, IO23, IO17 |
| VBAT sense (÷2 divider) | IO4 / ADC1_CH4 — **not used by firmware yet** |
| USB D−/D+ (native, flashing only) | IO12/IO13 |
| BOOT / RESET | IO9 / EN |

Row 4 is irregular: 5 keys (cols 0–4), one 2U key (col 5), no switch at col 6, then 5 more keys (cols 7–11) — 59 physical keys over the 60-position matrix. Battery-voltage ADC reading (fuel gauge) is not yet implemented in firmware despite the hardware supporting it.

### C Sources (`Sources/componets/`) — ESP32-C6 only

| File | Responsibility |
|---|---|
| `ble_helper.c` | NimBLE/esp_hidd BLE HID init and `send_keyboard_report()` |
| `uart_init.c` | UART1 init (TX:16, TX-only) and CH9350L wired HID bridge via `send_wired_report()` — only safe to enable via `SMK_HAS_WIRED_BRIDGE` (see below). IO16 is smk_kbd's one documented spare pad, so a wired-bridge revision and `SMK_HAS_RGB_BACKLIGHT` (which also defaults to IO16) are mutually exclusive unless RGB is moved to a different pin — Kconfig does not currently guard against enabling both. |
| `gpio_init.c` | `init_keyboard_pins()` — configures rows/columns as push-pull output vs. pull-up/pull-down input depending on the `colsAreDriven` flag passed in from the JSON config (see Matrix scan loop below) |
| `kb_main.c` | `app_main()` C entry point; Unicode linker stubs for Embedded Swift |
| `smk_config.c` | `smk_has_wired_bridge()` / `smk_default_mode_is_wired()`, backed by `main/Kconfig.projbuild` — lets `idf.py menuconfig` pick the boot-default connection mode and whether wired HID hardware exists on the board |

### Board Configuration (Kconfig)

`main/Kconfig.projbuild` adds a "SMK Keyboard Configuration" menu (`idf.py menuconfig`):
- `SMK_HAS_WIRED_BRIDGE` (default **off**) — only enable if the board actually has a CH9350 bridge chip.
- `SMK_DEFAULT_CONNECTION_MODE` (Bluetooth / Wired, default **Bluetooth**) — boot-time default; forced to Bluetooth regardless of this setting if `SMK_HAS_WIRED_BRIDGE` is off.
- `SMK_HAS_RGB_BACKLIGHT` (default **off**) — opt-in per-key RGB backlight; enable only if you've wired an SK6812MINI-E/WS2812 chain yourself (the stock board hasn't got one).
- `SMK_RGB_GPIO` (default **16**, the PCB's one documented spare pad) — only shown when RGB is enabled; firmware checks it against the matrix pins at boot and disables the chain (with a log warning) rather than silently breaking scanning if they collide.

### Key Architectural Patterns

**Matrix scan loop** (in `Main.swift`/`KeyMatrix.swift`): direction depends on `matrix.colsAreDriven` in the JSON config, since different boards wire the diodes/strobe direction oppositely:
- `colsAreDriven: false` (RP2040 boards): rows are strobed LOW one at a time (push-pull outputs, idle HIGH), columns are read as inputs with pull-ups (idle HIGH, reads `0` = pressed).
- `colsAreDriven: true` (ESP32-C6 **smk_kbd** board — its matrix is COL2ROW, diode anode at the column/switch side): columns are strobed HIGH one at a time (push-pull outputs, idle LOW), rows are read as inputs with pull-downs (idle LOW, reads `1` = pressed).

The `DebouncedMatrix` wraps raw scans and requires 5 consecutive agreeing samples before reporting a state change.

**Layer resolution** (`LayerEngine.getAction`): iterates layers from highest index to 0, skipping inactive layers and transparent keys, returning the first non-transparent action. Layer 0 is always active.

**HID dispatch**: On each tick, a `HIDReport` is built from all currently pressed key/modifier actions, then sent via either `send_keyboard_report` (BLE) or `send_wired_report` (CH9350 UART) based on `ConnectionMode`.

### RP2040 Platform Sources (`ports/rp2040/`)

| File | Responsibility |
|---|---|
| `GPIORegisters.swift` | RP2040 SIO registers (`0xD0000000`) — same API as ESP32 version |
| `BridgingHeader.h` | RP2040 bridging header: cJSON + libc + platform glue prototypes |
| `CMakeLists.txt` | pico-sdk + native CMake Swift integration; auto-discovers swiftc |
| `platform/gpio_init.c` | `init_keyboard_pins()` via `hardware/gpio.h`; rows driven / columns sensed by default (`colsAreDriven: false`) |
| `platform/usb_hid.c` | `init_wired_link()` / `send_wired_report()` via TinyUSB |
| `platform/usb_descriptors.c` | TinyUSB device + HID keyboard report descriptors |
| `platform/tusb_config.h` | TinyUSB device config |
| `platform/platform_glue.c` | `kb_log`, `vTaskDelay` shim, `main()`, Swift stdlib stubs, `posix_memalign` |
| `platform/ble_hid.c` | Pico W: CYW43 + BTstack HID-over-GATT; plain Pico: no-op stubs |
| `platform/btstack_config.h` | BTstack config (Pico W only) |
| `platform/smk_hid.gatt` | GATT database for BLE HID (compiled to `smk_hid.h` at build time) |

### Keymap Configuration

The active keymap is the `configJson` string literal in `Sources/smk/Main.swift`. The `keymap.json` at the repo root is a reference copy — changes there do **not** affect the firmware until copied into `Main.swift`.

### RGB Backlight (opt-in, off by default)

`RGBLighting.swift` and `led_strip_driver.c`/`led_strip_encoder.c` implement an SK6812MINI-E per-key RGB chain, but the stock smk_kbd board has no such chain (its only LED is a fixed charge-status indicator wired straight to the charger IC). Enable via `SMK_HAS_RGB_BACKLIGHT` in `idf.py menuconfig` if you wire one up yourself.

Gated two ways: compiled in only for the ESP32-C6 build (`-DSMK_RGB_AVAILABLE` in `main/CMakeLists.txt`; RP2040 doesn't include `RGBLighting.swift` at all, so the `#if SMK_RGB_AVAILABLE` block in `Main.swift` compiles out there instead of failing a type lookup), and instantiated at runtime only if the Kconfig option is on. `SMK_RGB_GPIO` (default IO16, the PCB's documented spare pad) is checked against the matrix pins at boot; a collision (e.g. the old hardcoded GPIO0, which is ROW0) disables the chain with a log warning instead of corrupting the scan.

**Key action syntax:**
- `key:<char>` — standard keycode (e.g. `key:a`, `key:enter`)
- `mod:<name>` — modifier (e.g. `mod:leftShift`)
- `mo:<n>` — momentary layer (held = active)
- `tg:<n>` — toggle layer
- `trans` — transparent (fall through to lower layer)
- `toggle_conn` — switch between BLE and wired modes
- `none` — no action
