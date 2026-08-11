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
| nRF52840 | Arm Cortex-M4F | CMake / Ninja (no pico-sdk equivalent — vendored nRF5 SDK + sdk-nrfxlib + TinyUSB + BTstack) | USB HID + BLE HID (SoftDevice Controller over BTstack); build-only, not yet hardware-verified |

## Prerequisites

### ESP32-C6
- **ESP-IDF v6.0.1** installed via the standard installer (`~/.espressif/v6.0.1/esp-idf`) and sourced via `. ~/.espressif/v6.0.1/esp-idf/export.sh` — the real export script; a top-level `~/export-esp-idf.sh` (as a personal alias/symlink to the above) also works if you've set one up, but isn't created by ESP-IDF's installer itself
- **Swift 6.3.1 Embedded RISC-V toolchain** installed in `~/Library/Developer/Toolchains/`

### RP2040 / Pico
- **pico-sdk** at `~/pico-sdk` with submodules initialized (`git -C ~/pico-sdk submodule update --init`)
- **ARM toolchain with newlib**: `brew tap osx-cross/arm && brew install osx-cross/arm/arm-gcc-bin@14`
- **cmake ≥ 3.29, ninja, picotool**: `brew install cmake ninja picotool`
- **Swift ≥ 6.3 Embedded ARM toolchain** installed in `~/Library/Developer/Toolchains/`
- **RP2350 (`pico2`/`pico2_w`) additionally requires a Swift development-snapshot toolchain** (confirmed: `swift-DEVELOPMENT-SNAPSHOT-2026-05-27-a` or later) that ships a real Embedded-Swift stdlib for `armv8m.main-none-none-eabi` (RP2350's Cortex-M33 target). Released `swift-6.3.x` toolchains report support for that triple via `-print-target-info` but fail an actual compile — they don't ship the stdlib.

### nRF52840
- **nRF5 SDK** (CMSIS device header + Cortex-M4 startup/linker script — modern `nrfx` no longer bundles these) at `~/nRF5_SDK` — download from Nordic's nRF5 SDK page (v17.1.0 or later) and unzip. Only `modules/nrfx/mdk/` is used.
- **sdk-nrfxlib** (prebuilt SoftDevice Controller + MPSL libraries) at `~/sdk-nrfxlib`: `git clone https://github.com/nrfconnect/sdk-nrfxlib ~/sdk-nrfxlib`
- **TinyUSB** at `~/tinyusb`: `git clone https://github.com/hathach/tinyusb ~/tinyusb`
- **BTstack** at `~/btstack`: `git clone https://github.com/bluekitchen/btstack ~/btstack`
- **ARM toolchain with newlib**: same `arm-gcc-bin@14` already required for RP2040 — no new install.
- **Swift Embedded ARM toolchain**: same one already required for RP2040/ESP32-C6 — `armv7em-none-none-eabi` has a real stdlib on every currently-installed toolchain (verified during this port's feasibility spike), no dev-snapshot requirement.

## Build & Flash Commands

### ESP32-C6
```bash
# Source ESP-IDF environment first
. ~/.espressif/v6.0.1/esp-idf/export.sh   # or your own export-esp-idf.sh alias, if you have one

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
- `Sources/components/kb_main.c` contains `app_main()` which calls `app_main_swift()`

### Shared Swift Sources (`Sources/smk/`) — compiled for ALL targets

| File | Responsibility |
|---|---|
| `Main.swift` | Entry point, main scan loop, board config JSON literals, boot/keymap-store wiring, `app_main_swift` — calls into SMKCore for the actual scan-cycle logic |
| `KeyMatrix.swift` | `KeyMatrix` (GPIO scan) |

### Hardware-Independent Sources (`Sources/SMKCore/`) — compiled for ALL targets, host-testable

Same flat-file-compilation treatment as `Sources/smk/` (added to `main/CMakeLists.txt`'s, `ports/rp2040/CMakeLists.txt`'s, and `ports/nrf52840/CMakeLists.txt`'s `swift_srcs` lists, no module boundary in the real build) — but these files have zero hardware/`@_extern` calls, so `Package.swift` also exposes them as a real `SMKCore` library target for host-side testing (`swift test`, no ESP-IDF/pico-sdk needed). See `docs/superpowers/specs/2026-08-09-host-unit-tests-design.md`.

| File | Responsibility |
|---|---|
| `Modifier.swift` | Modifier-key bit-flag enum |
| `Debounce.swift` | `DebouncedMatrix` — counter-based debounce (threshold=5) |
| `ConnectionMode.swift` | wired/bluetooth toggle |
| `HIDReport.swift` | HID report byte-building |
| `Config.swift` | matrix-config JSON parsing |
| `LayerEngine.swift` | keymap JSON loading, layer state, action resolution |
| `LEDChainMapping.swift` | serpentine row/col -> RGB chain-position mapping |
| `KeyEventProcessing.swift` | press/release edge detection, layer toggle/momentary add-remove, connection-toggle decision, HID report assembly — the scan loop calls this once per cycle |
| `Logging.swift` | host-only `kb_log` no-op shim (not compiled into the embedded build) |
| `KeymapFrame.swift` | shared keymap-store frame format: CRC32 + 11-byte header pack/unpack, extracted from what were three duplicated per-target copies |
| `KeymapProtocol.swift` | shared BEGIN/CHUNK/COMMIT/ERASE packet dispatch for the runtime keymap upload protocol, transport-agnostic; storage operations are injected so this is host-testable |

Run the test suite: `SMK_HOST_TESTS_ONLY=1 swift test`. `Package.resolved` is intentionally untracked (`.gitignore`'d): with `SMK_HOST_TESTS_ONLY=1`, `swift-mmio` isn't a dependency at all (see `Package.swift`), so a host-only resolve pins nothing meaningful and would just churn the file on every run.

### Platform-specific GPIO (`GPIORegisters.swift`)

Each target provides its own `GPIORegisters.swift` with the **same** `outSet`/`outClear`/`input` API (bit = GPIO number):

| Target | File | Base address |
|---|---|---|
| ESP32-C6 | `Sources/smk/GPIORegisters.swift` | `0x60091000` |
| RP2040 / RP2350 | `ports/rp2040/GPIORegisters.swift` | `0xD0000000` (SIO — identical register layout on both chips) |
| nRF52840 | `ports/nrf52840/GPIORegisters.swift` | `0x50000000` (P0 GPIO port only — pins 0–31; P1/pins 32–47 unused, this board's matrix fits within P0) |

### ESP32-C6-only Swift Sources (`Sources/smk/`)

Compiled only into the ESP32-C6 build (`main/CMakeLists.txt`'s `swift_srcs`) — RP2040 backs the same function names with its own C, linked in via the `@_extern(c, ...)` declarations these files' `#if !SMK_TARGET_ESP32C6` guards leave in place in `KeyMatrix.swift`/`Main.swift`:

| File | Responsibility |
|---|---|
| `GPIOInit.swift` | `init_keyboard_pins()` — configures rows/columns as push-pull output vs. pull-up/pull-down input depending on the `colsAreDriven` flag, by calling straight into the ESP-IDF gpio driver (`gpio_reset_pin`/`gpio_set_direction`/etc. via `@_extern(c, ...)`) |
| `SmkConfig.swift` | `smk_has_wired_bridge()` / `smk_default_mode_is_wired()` / `smk_has_rgb_backlight()` / `smk_rgb_gpio()`, backed by `main/Kconfig.projbuild` via Swift-level `#if SMK_HAS_WIRED_BRIDGE`/etc. flags that `main/CMakeLists.txt` derives from the matching `CONFIG_SMK_*` CMake variables — lets `idf.py menuconfig` pick the boot-default connection mode and whether wired HID/RGB hardware exists on the board |
| `BatteryMonitor.swift` | `initBatteryMonitor()` / `pollBatteryLevel()` — VBAT percentage estimate from the IO4/ADC1_CH4 divider, reported via `smk_ble_set_battery_level()` (now in `BleHelper.swift`, see below). ADC unit/channel setup itself stays in C (`battery_adc.c`, struct-heavy `adc_oneshot` driver config — same "constructing C-ABI structs" exception as BTstack's `hci_transport_t` in the nRF52840 port); the mV/percentage math and polling schedule are Swift. |
| `BleHelper.swift` | partial Swift port of the former `ble_helper.c`: `ble_hidd_event_callback`/`ble_hid_host_task` (`@_cdecl`, handed to the NimBLE/esp_hidd C APIs by address), `send_keyboard_report()`, `smk_ble_set_battery_level()`, and `kb_log`. The struct-heavy remainder (`ble_hs_adv_fields`/`ble_hs_cfg` construction, `start_advertising`, `init_ble_hid`) stays in the trimmed `ble_helper.c`. |
| `WiredHidUart.swift` | Swift port of the former `uart_init.c` — UART1 init (TX:16, TX-only) and the CH9350L wired HID bridge via `send_wired_report()` |
| `KeymapStoreNVS.swift` | runtime keymap store (ESP32-C6, NVS-backed) — Swift port of the former `Sources/components/smk_keymap_store.c`; frame/CRC logic itself lives in `KeymapFrame.swift`, shared with RP2040 |
| `LedStripDriverRMT.swift` | SK6812MINI-E per-key RGB chain driver (RMT-based) — Swift port of the former `led_strip_driver.c`; `rmt_new_led_strip_encoder` stays C (`led_strip_encoder.c`, struct/vtable idiom) |

### smk_kbd board (ESP32-C6-MINI-1)

The active `configJson` in `Main.swift` targets this specific board (59-key, 5×12, BLE + Li-ion + USB-C charging, no wired-HID bridge, no per-key RGB). GPIO map, straight from the PCB project's README (source of truth for pin assignments):

| Function | GPIO |
|---|---|
| ROW0–ROW3 (sense, pull-down) | IO0–IO3 |
| ROW4 (sense, pull-down) | IO5 |
| COL0–COL11 (strobe, push-pull) | IO6, IO7, IO8, IO14, IO15, IO18, IO19, IO20, IO21, IO22, IO23, IO17 |
| VBAT sense (÷2 divider) | IO4 / ADC1_CH4 — read by `BatteryMonitor.swift` via `adc_oneshot` (see below) |
| USB D−/D+ (native, flashing only) | IO12/IO13 |
| BOOT / RESET | IO9 / EN |

Row 4 is irregular: 5 keys (cols 0–4), one 2U key (col 5), no switch at col 6, then 5 more keys (cols 7–11) — 59 physical keys over the 60-position matrix.

Battery-voltage ADC reading is polled roughly every 20 seconds from the main scan loop and reported via the BLE HID Battery Service (`esp_hidd_dev_init()` creates this GATT service internally — `smk_ble_set_battery_level()` in `BleHelper.swift` just feeds it data). The mV→percentage conversion is a rough single-cell Li-ion linear approximation (4200mV=100%, 3300mV=0%), not a calibrated discharge curve, and the ADC reading itself isn't calibrated via `adc_cali_*` either — good enough for a rough battery icon, not fuel-gauge accuracy. Not yet verified against a real board with a multimeter.

### C Sources (`Sources/components/`) — ESP32-C6 only

| File | Responsibility |
|---|---|
| `ble_helper.c` | trimmed remainder of the former `ble_helper.c`: `start_advertising()`/`init_ble_hid()` and the struct-heavy config (`ble_hs_adv_fields`, `ble_hs_cfg`, `esp_hid_device_config_t`) they build — `send_keyboard_report()`/`smk_ble_set_battery_level()`/`kb_log` moved to `BleHelper.swift` (see above) |
| `kb_main.c` | `app_main()` C entry point; Unicode linker stubs for Embedded Swift |
| `battery_adc.c` | `smk_battery_adc_init()` / `smk_battery_adc_read_raw()` — `adc_oneshot` driver setup for the IO4/ADC1_CH4 VBAT divider; kept in C because the driver's init/config calls take structs by pointer (see `BatteryMonitor.swift`) |

GPIO pin configuration, Kconfig-backed board config, the UART wired-HID bridge, the RGB LED strip driver, and the keymap store used to live here too (`gpio_init.c`, `smk_config.c`, `uart_init.c`, `led_strip_driver.c`, `smk_keymap_store.c`) but are now plain Swift — see "ESP32-C6-only Swift Sources" above (`GPIOInit.swift`, `SmkConfig.swift`, `WiredHidUart.swift`, `LedStripDriverRMT.swift`, `KeymapStoreNVS.swift`).

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
| `BridgingHeader.h` | RP2040 bridging header: cJSON + libc + platform glue prototypes (mostly comment blocks now — see file; the real glue is same-module Swift) |
| `CMakeLists.txt` | pico-sdk + native CMake Swift integration; auto-discovers swiftc |
| `GPIOInit.swift` | `init_keyboard_pins()` — Swift port of the former `platform/gpio_init.c`; rows driven / columns sensed by default (`colsAreDriven: false`) |
| `UsbHid.swift` | `init_wired_link()` / `send_wired_report()` via TinyUSB — Swift port of the former `platform/usb_hid.c` |
| `PlatformConfig.swift` | board/connection-mode config and `kb_log` — Swift port of the portable half of the former `platform/platform_glue.c` (`main()`, `posix_memalign`, and the Unicode-stdlib linker stubs stay in C — see that file) |
| `KeymapStoreFlash.swift` | runtime keymap store (RP2040, flash-backed, last flash sector reserved) — Swift port of the former `platform/smk_keymap_store.c`; frame/CRC logic lives in `Sources/SMKCore/KeymapFrame.swift` |
| `LedStripDriverPIO.swift` | SK6812MINI-E per-key RGB chain driver (PIO-based), `smk_kbd_rp2040` board only — Swift port of the former `platform/led_strip_driver.c`; PIO state-machine claiming/program-loading stays in `platform/ws2812_pio_shim.c` |
| `BleHidPicoW.swift` | BLE HID glue for Pico W — Swift port of the former `platform/ble_hid.c`'s `SMK_ENABLE_BLE` branch (CYW43 + BTstack HID-over-GATT); no-op on plain Pico |
| `BleHidKbdUart.swift` | BLE HID glue for `smk_kbd_rp2040` — Swift port of the former `platform/ble_hid_kbd_uart.c`; talks to the onboard CYW43439 over the board's dedicated Bluetooth UART instead of Pico W's SPI/PIO link |
| `platform/usb_descriptors.c` | TinyUSB device + HID keyboard report descriptors |
| `platform/tusb_config.h` | TinyUSB device config |
| `platform/platform_glue.c` | `main()`, Swift stdlib stubs, `posix_memalign` — the non-portable remainder of the former full file, see `PlatformConfig.swift` above |
| `platform/btstack_config.h` | BTstack config (Pico W / smk_kbd_rp2040 only) |
| `platform/smk_hid.gatt` | GATT database for BLE HID (compiled to `smk_hid.h` at build time) |
| `platform/gpio_init_wrappers.c` | non-inline wrapper entry points for pico-sdk's `static inline` `hardware/gpio.h` functions, so `GPIOInit.swift` can bind them via `@_extern(c, ...)` |
| `platform/flash_irq_wrappers.c` | non-inline wrappers for pico-sdk's `static inline`/`__force_inline` `hardware/sync.h` interrupt-disable functions, plus a runtime accessor for `PICO_FLASH_SIZE_BYTES` — both needed by `KeymapStoreFlash.swift` |
| `platform/ws2812_pio_shim.c` | narrow C remainder for the RGB driver: instantiates the build-generated `ws2812_program` PIO program struct and claims/loads the PIO state machine, since hand-replicating that generated struct layout in Swift would be fragile for no benefit — see `LedStripDriverPIO.swift` |
| `platform/uart_driver_vtable.c` | narrow C remainder for `smk_kbd_rp2040`'s BLE UART transport: the pieces pico-sdk/BTstack expose only as struct literals, `static inline` functions, or macros that Swift can't bind to directly — see `BleHidKbdUart.swift` |
| `platform/smk_hid_gatt_data.c` | `#include`s the generated `smk_hid.h` to instantiate `const uint8_t profile_data[]` as a real linkable symbol (the header only declares its contents as C source text) |

### nRF52840 board (nrf52840dk / PCA10056) — read before flashing real hardware

**The GPIO pin map for this board (the `SMK_BOARD_NRF52840DK` branch of `Sources/smk/Main.swift`'s `configJson`) is a placeholder, not a verified pin assignment.** No board schematic was consulted when choosing it — see that branch's own comment ("GPIO map deferred to hardware bring-up... Placeholder pin numbers below MUST be replaced before this board is ever flashed"). It MUST be replaced with real, schematic-verified pin assignments before this board is ever flashed to physical hardware — using the placeholder numbers as-is risks driving pins that aren't wired the way the firmware assumes.

Other known gaps on this port, briefly (this is a build-only pass — see `docs/superpowers/specs/2026-08-09-nrf52840-support-design.md`):
- **Runtime keymap store is a no-op stub** (`ports/nrf52840/KeymapStoreStub.swift`) — a keymap upload over USB HID is accepted and dispatched, but every write silently fails; nothing persists across reboots yet.
- **LE bonding does not survive a reboot** (Task 7's known gap — no persistent bonding-info storage wired up yet).
- **No real clock**: `hal_time_ms()` (`ports/nrf52840/platform/ble_hid_sdc.c`), `tusb_time_millis_api()` (`ports/nrf52840/UsbHid.swift`), and the `vTaskDelay` busy-loop (`ports/nrf52840/platform/platform_glue.c`) are all uncalibrated per-call/per-loop counters, not real millisecond clocks, until a real hardware timer (`NRF_RTC`, once MPSL claims it) is wired up.

### Keymap Configuration

The active keymap is the `configJson` string literal in `Sources/smk/Main.swift`. The `keymap.json` at the repo root is a reference copy — changes there do **not** affect the firmware until copied into `Main.swift`.

### RGB Backlight (opt-in, off by default)

`RGBLighting.swift` and `LedStripDriverRMT.swift`/`led_strip_encoder.c` implement an SK6812MINI-E per-key RGB chain, but the stock smk_kbd board has no such chain (its only LED is a fixed charge-status indicator wired straight to the charger IC). Enable via `SMK_HAS_RGB_BACKLIGHT` in `idf.py menuconfig` if you wire one up yourself.

Gated two ways: compiled in only for the ESP32-C6 build (`-DSMK_RGB_AVAILABLE` in `main/CMakeLists.txt`; RP2040 doesn't include `RGBLighting.swift` at all, so the `#if SMK_RGB_AVAILABLE` block in `Main.swift` compiles out there instead of failing a type lookup), and instantiated at runtime only if the Kconfig option is on. `SMK_RGB_GPIO` (default IO16, the PCB's documented spare pad) is checked against the matrix pins at boot; a collision (e.g. the old hardcoded GPIO0, which is ROW0) disables the chain with a log warning instead of corrupting the scan.

**Key action syntax:**
- `key:<char>` — standard keycode (e.g. `key:a`, `key:enter`)
- `mod:<name>` — modifier (e.g. `mod:leftShift`)
- `mo:<n>` — momentary layer (held = active)
- `tg:<n>` — toggle layer
- `trans` — transparent (fall through to lower layer)
- `toggle_conn` — switch between BLE and wired modes
- `none` — no action
