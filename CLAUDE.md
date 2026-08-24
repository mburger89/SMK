# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SMK (Swift Matrix Keyboard) is keyboard firmware written in **Embedded Swift** targeting the **ESP32-C6** (RISC-V). It uses ESP-IDF as its build system with a custom CMake step that invokes `swiftc` directly — `Package.swift` exists only for IDE/LSP support and is **not** the actual build system.

## Supported Targets

| Target | MCU | Build system | HID transport |
|---|---|---|---|
| ESP32-C6 | RISC-V | ESP-IDF / idf.py | BLE (NimBLE) + Wired (CH9350 UART); BLE HID boot + advertising hardware-verified on a real smk_kbd board after fixing 3 real bugs found via that testing — see `Sources/smk/BleHelper.swift` (BLE is fully Swift now) and `Sources/components/kb_main.c` |
| Pico | RP2040 ARM | CMake / Ninja + pico-sdk | USB HID (TinyUSB); boot + USB HID enumeration hardware-verified on a third-party RP2040 board (2026-08-16, on the post-`ports/common` refactor build) — enumerated as "SMK Keyboard" with both HID interfaces (boot keyboard + vendor keymap-upload channel) registered; matrix scan not yet verified against real switches (no matrix wired on that board) |
| Pico W | RP2040 ARM | CMake / Ninja + pico-sdk | USB HID + BLE (BTstack, scaffolded) |
| Pico 2 | RP2350 ARM (Cortex-M33) | CMake / Ninja + pico-sdk (`SMK_TARGET_BOARD=pico2`) | USB HID (TinyUSB); boot + USB HID enumeration hardware-verified on a Seeed XIAO RP2350 (same RP2350 chip, built with `PICO_BOARD=pico2`) — re-verified 2026-08-16 on the post-`ports/common` refactor build, enumerated as "SMK Keyboard" with both HID interfaces registered; matrix scan not yet verified against real switches (no matrix wired on that board) |
| Pico 2 W | RP2350 ARM (Cortex-M33) | CMake / Ninja + pico-sdk (`SMK_TARGET_BOARD=pico2_w`) | USB HID + BLE (BTstack, scaffolded); build-only, not yet hardware-verified |
| smk_kbd_rp2040 | RP2040 ARM (chip-down + CYW43439) | CMake / Ninja + pico-sdk (`SMK_TARGET_BOARD=smk_kbd_rp2040`) | USB HID + per-key RGB (working) + BLE (BTstack over dedicated UART; PatchRAM firmware data embedded in `ports/rp2040/platform/cyw43439_patchram.c`, sourced from Murata's public `cyw-bt-patch` repo per their CYW43439→"1YN" module mapping — matched by part number, not yet hardware-confirmed via `lmp_subversion` since the board is still at fab) |
| nRF52840 | Arm Cortex-M4F | CMake / Ninja (no pico-sdk equivalent — vendored nRF5 SDK + sdk-nrfxlib + TinyUSB + BTstack) | USB HID + BLE HID (SoftDevice Controller over BTstack); build-only, not yet hardware-verified |
| nRF52840 Feather (`SMK_TARGET_BOARD=feather_nrf52840`) | Arm Cortex-M4F, same chip as nrf52840dk | CMake / Ninja, same source tree as nRF52840 above (`./build_nrf52840.sh feather`) | USB HID only for this bring-up pass (BLE init call skipped — see `Sources/smk/Main.swift`'s `SMK_BOARD_FEATHER_NRF52840` branch); **IN PROGRESS, not working yet** — the physical board used for this bring-up session enumerates over USB as "Feather nRF52840 Express" when running its (prior, unrelated) application firmware, but its **bootloader identifies itself as `nice!nano`** (confirmed via its USB product string once actually entered — see below), meaning the real board is most likely a nice!nano or compatible clone, not a genuine Adafruit board — the board/file naming here is aspirational, kept as-is because the bootloader/flash-layout conventions matched regardless. A real bug was found and fixed this session: flashed firmware never enumerated any USB device at all, traced by reading the vendored nRF5 SDK's startup code (`gcc_startup_nrf52840.S`/`system_nrf52.c`) to a missing `SCB->VTOR` relocation — the SDK's startup assumes VTOR stays at its power-on default (0x0), correct for `nrf52840dk`'s flash-origin-0x0 build but wrong once the app is linked at `0x27000` for bootloader coexistence; any interrupt (MPSL's, in particular) dispatched through the stale table at 0x0 instead of the real one, causing total silence. Fixed in `ports/nrf52840/platform/platform_glue.c` (`smk_relocate_vector_table()`, called first thing in `main()`) — rebuilt and reflashed via `adafruit-nrfutil` DFU-over-serial (the empirically-proven-working flash path on this board; drag-and-drop UF2 never got a mass-storage volume to mount, a known unresolved class of issue per nice!nano's own troubleshooting docs), but hardware re-confirmation of the fix is still pending as of this writing — the USB connection became unreliable partway through this session (stopped enumerating at all, even across a port change) before the post-fix build could be verified booting |
| STM32F4 (WeAct Black Pill) | Arm Cortex-M4F | CMake / Ninja (hand-rolled — vendored cmsis-device-f4 + CMSIS_6 + TinyUSB, hand-written linker script) | USB HID (TinyUSB's `dwc2` driver); build-only, not yet hardware-verified |
| STM32WB (NUCLEO-WB55RG) | Arm Cortex-M4 (+ on-chip Cortex-M0+ radio coprocessor running ST's own firmware) | CMake / Ninja (hand-rolled — vendored cmsis-device-wb + CMSIS_6 + TinyUSB + BTstack + STM32CubeWB's IPCC transport layer) | USB HID (TinyUSB's `fsdev` driver) + BLE HID (ST's HCI-Layer wireless coprocessor over BTstack); build-only, not yet hardware-verified |
| SAMD21 (Seeed XIAO M0) | Arm Cortex-M0+ (armv6m, no LDREX/STREX — `ports/samd21/platform/armv6m_atomics.c` supplies `__atomic_*` via PRIMASK critical sections) | CMake / Ninja (hand-rolled — vendored TinyUSB `hw/mcu/microchip/samd21` DFP + linker script) | USB HID (TinyUSB's `dcd_samd` driver); **IN PROGRESS, not working yet** — DFLL48M clock bring-up and `tusb_rhport_init` both confirmed correct on real hardware (worked around a bootloader-locked GCLK2 USB clock channel — see `ports/samd21/ClockInit.swift`), but the device still never completes USB enumeration with a host. A UART debug channel (`ports/samd21/UartDebug.swift`, PA06/SERCOM0, 115200 8N1 TX-only) was added after LED-blink bit-decoding of the USB INTFLAG/EPINTFLAG registers proved unreliable; reading it needs a USB-to-TTL serial adapter (RX → XIAO D6, GND → GND), not yet available during this bring-up session |

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
- **Feather nRF52840 Express variant**: no extra prerequisites beyond the above — `ports/nrf52840/tools/uf2conv.py`/`uf2families.json` (vendored byte-identical from microsoft/uf2, MIT-licensed) are checked into the repo, not a separate install.

### STM32F4
- **cmsis-device-f4** (CMSIS device headers + Cortex-M4 startup assembly for the STM32F4 series — no GCC linker script is shipped here, this project hand-writes its own) at `~/cmsis-device-f4`: `git clone https://github.com/STMicroelectronics/cmsis-device-f4 ~/cmsis-device-f4`
- **CMSIS_6** (ARM's own Cortex-M4 core headers — `cmsis-device-f4` depends on this separately, per that repo's own README) at `~/CMSIS_6`: `git clone https://github.com/ARM-software/CMSIS_6 ~/CMSIS_6`
- **TinyUSB** at `~/tinyusb` (same checkout already required for RP2040/nRF52840 — no new clone needed if you have one).
- **ARM toolchain with newlib**: same `arm-gcc-bin@14` already required for RP2040/nRF52840 — no new install.
- **Swift Embedded ARM toolchain**: same one already required for RP2040/nRF52840/ESP32-C6 — `armv7em-none-none-eabi` has a real stdlib on every currently-installed toolchain (re-verified during this port's planning), no dev-snapshot requirement.

### STM32WB
- **cmsis-device-wb** (CMSIS device headers + Cortex-M4 startup assembly for the STM32WB series — no GCC linker script shipped, same gap as cmsis-device-f4) at `~/cmsis-device-wb`: `git clone https://github.com/STMicroelectronics/cmsis-device-wb ~/cmsis-device-wb`
- **CMSIS_6** (reused from the STM32F4 port — `~/CMSIS_6`, no new clone needed if you have one).
- **TinyUSB** at `~/tinyusb` (reused — no new clone needed if you have one).
- **BTstack** at `~/btstack` (reused from RP2040/nRF52840 — no new clone needed if you have one).
- **STM32CubeWB** (pinned at v1.24.0 — the IPCC mailbox transport-layer source this port vendors from, plus the prebuilt CPU2 "HCI Layer" wireless-coprocessor firmware binary; later tags moved this content to a submodule that no longer covers dual-core WB55) at `~/STM32CubeWB`: `git clone --branch v1.24.0 https://github.com/STMicroelectronics/STM32CubeWB ~/STM32CubeWB`
- **ARM toolchain with newlib**: same `arm-gcc-bin@14` already required for RP2040/nRF52840/STM32F4 — no new install.
- **Swift Embedded ARM toolchain**: same one already required for the other ARM ports — `armv7em-none-none-eabi` has a real stdlib, no dev-snapshot requirement.

### SAMD21 (Seeed XIAO M0) — IN PROGRESS, not hardware-verified yet (see Supported Targets)
- **TinyUSB** at `~/tinyusb`, with the SAMD21 DFP fetched: `cd ~/tinyusb && python3 tools/get_deps.py samd2x_l2x` (reused checkout if you have one from RP2040/nRF52840/STM32F4/STM32WB — just needs this extra `get_deps.py` step for the `hw/mcu/microchip/samd21` device headers).
- **CMSIS_6** (reused from the STM32 ports — `~/CMSIS_6`, no new clone needed if you have one).
- **ARM toolchain with newlib**: same `arm-gcc-bin@14` already required for the other ARM ports — no new install.
- **Swift Embedded ARM toolchain**: same one already required for the other ARM ports — `armv6m-none-none-eabi` (Cortex-M0+, no LDREX/STREX) has a real stdlib on every currently-installed toolchain.

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

### SAMD21 (Seeed XIAO M0) — IN PROGRESS
```bash
export TINYUSB_PATH=~/tinyusb
export CMSIS_CORE_PATH=~/CMSIS_6

./build_samd21.sh
```

Produces `build_samd21/smk_samd21.uf2`. Flash by double-tapping the XIAO M0's reset pads (mounts an `Arduino` UF2-bootloader volume) and copying the `.uf2` onto it. USB enumeration does not yet work on this target — see Supported Targets above.

## Architecture

### Swift ↔ C Boundary

- `Sources/smk/Bridging.h` — C headers imported into Swift; declares all C functions callable from Swift
- Swift uses `@_extern(c, "fn_name")` to call C functions (BLE init, GPIO init, FreeRTOS delay, logging)
- Swift uses `@_cdecl("app_main_swift")` to expose its entry point to C
- `Sources/components/kb_main.c` contains `app_main()` which calls `app_main_swift()`

**Register-polling loops written in Swift MUST call an opaque C function inside the loop body** (e.g. `smk_cpu_nop()` in `ports/stm32wb/platform/cortex_m_intrinsics.c` / `ports/stm32f4/platform/cortex_m_intrinsics.c`), because `UnsafeMutablePointer.pointee` is **not** a volatile access in Swift — LLVM treats an empty-bodied `while (reg.pointee & bit) == 0 {}` as loop-invariant and deletes it outright under the forward-progress rule, silently turning a hardware wait into no wait at all. This was a real bug found by disassembling both STM32 ports' `smk_clock_init`; any future port doing direct MMIO polling from Swift will hit it again.

### Shared Swift Sources (`Sources/smk/`) — compiled for ALL targets

| File | Responsibility |
|---|---|
| `Main.swift` | Entry point, main scan loop, board config JSON literals, boot/keymap-store wiring, `app_main_swift` — calls into SMKCore for the actual scan-cycle logic |
| `KeyMatrix.swift` | `KeyMatrix` (GPIO scan) |

### Hardware-Independent Sources (`Sources/SMKCore/`) — compiled for ALL targets, host-testable

Same flat-file-compilation treatment as `Sources/smk/` — no module boundary in the real build. These files have zero hardware/`@_extern` calls, so `Package.swift` also exposes them as a real `SMKCore` library target for host-side testing (`swift test`, no ESP-IDF/pico-sdk needed). See `docs/superpowers/specs/2026-08-09-host-unit-tests-design.md`.

**A new file here is invisible to the embedded builds until it is listed in all six build files that enumerate SMKCore sources explicitly** — `main/CMakeLists.txt` plus `ports/{rp2040,nrf52840,samd21,stm32f4,stm32wb}/CMakeLists.txt`. `Package.swift` needs no change, since its `SMKCore` target globs the directory — which is exactly the trap: a missing CMake entry still passes `swift test` and only surfaces as a link failure on real hardware. `KeymapBinary.swift`, `AsciiKeycodes.swift`, `MacroPlayer.swift`, and `DefaultKeymapGenerated.swift` (see below) are the four files the binary-keymap-format work added to all six lists together — a template for what "new SMKCore file" actually means in practice.

| File | Responsibility |
|---|---|
| `Modifier.swift` | Modifier-key bit-flag enum |
| `Debounce.swift` | `DebouncedMatrix` — counter-based debounce (threshold=5) |
| `ConnectionMode.swift` | wired/bluetooth toggle |
| `HIDReport.swift` | HID report byte-building |
| `Config.swift` | the board's GPIO matrix, built from a decoded payload header (`Config(payload:)`) |
| `LayerEngine.swift` | keymap loading (binary payloads only), layer state, action resolution. Holds `KeyAction`/`Modifier` `fromCString` — the token *grammar*. The key *vocabulary* it dispatches into lives in `KeyCodesGenerated.swift` |
| `KeymapBinary.swift` | **the binary keymap decoder.** `decodeKeymapPayload` turns a version-2 binary payload (see "Binary Keymap Payload Format" below) into a `KeymapPayload` of layers/macros; `encodeCell`/`decodeCell` are the two-byte cell codec. One of three implementations of this format that must be kept in lockstep — see below |
| `KeyCodesGenerated.swift` | **GENERATED — do not edit.** `KeyCode` enum, its HID-usage `rawValue`, and `fromCString`. Produced by `./generate_keycodes.sh` from `keycodes.json`, which is the single source of the key vocabulary for this repo *and* smk_configurator. Adding a key means editing the manifest and re-running the script, then committing the regenerated file in **both** repos (same pattern as `generate_ble_uuids.sh`). The configurator's `KeyVocabularyTests` pins the agreement by HID usage |
| `DefaultKeymapGenerated.swift` | **GENERATED — do not edit.** `defaultKeymapBytes: [UInt8]`, the compiled-in default keymap pre-encoded in the version-2 binary payload format (`KeymapBinary.swift`'s `decodeKeymapPayload`). Produced by `./generate_default_keymap.sh` from `keymap.json` and `keycodes.json` (HID usages come from the same manifest `generate_keycodes.sh` reads — not hardcoded). `KeymapBinaryTests`' `compiledDefaultKeymapRoundTrips` pins the generator against the decoder |
| `AsciiKeycodes.swift` | maps a printable-ASCII byte to the HID keystroke (usage + shift) that types it, for a macro's "type this text" step. Assumes US QWERTY on the host — see "Binary Keymap Payload Format" below for why it can't be generated from `keycodes.json` |
| `HIDReportMap.swift` | BLE HID-over-GATT keyboard report map, shared by `Sources/smk/BleHelper.swift` (esp_hidd) and `ports/common/BleHidGatt.swift` (BTstack). Hoisted out of those two files, which held byte-identical copies. Declares the keycode array's Logical/Usage Maximum as 255 — it was 101 (`application`), which silently excluded every usage above it |
| `LEDChainMapping.swift` | serpentine row/col -> RGB chain-position mapping |
| `KeyEventProcessing.swift` | press/release edge detection, layer toggle/momentary add-remove, connection-toggle decision, HID report assembly — the scan loop calls this once per cycle |
| `MacroPlayer.swift` | plays one macro back as HID reports, advanced once per scan tick by the same main loop that calls `KeyEventProcessing.swift` — see "Binary Keymap Payload Format" below for its timing/ownership rules |
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
| `BatteryMonitor.swift` | `initBatteryMonitor()` / `pollBatteryLevel()` — VBAT percentage estimate from the IO4/ADC1_CH4 divider, reported via `smk_ble_set_battery_level()` (in `BleHelper.swift`, see below). Fully Swift including the `adc_oneshot`/`adc_cali` driver setup (the former `battery_adc.c` is deleted): the driver's config structs come in through Bridging.h's `esp_adc/*.h` imports, so the ClangImporter provides the real layouts. |
| `BleHelper.swift` | **full** Swift port of the former `ble_helper.c` (deleted): event callback, host task, `send_keyboard_report()`, `smk_ble_set_battery_level()`, `kb_log`, and now also `init_ble_hid()`/advertising — NimBLE's bitfield-heavy `ble_hs_adv_fields`/`ble_hs_cfg` come in through Bridging.h's NimBLE header imports, so their 1-bit flags are ClangImporter computed properties with header-derived packing (no hand-mirrored layouts). |
| `WiredHidUart.swift` | Swift port of the former `uart_init.c` — UART1 init (TX:16, TX-only) and the CH9350L wired HID bridge via `send_wired_report()` |
| `KeymapStoreNVS.swift` | runtime keymap store (ESP32-C6, NVS-backed) — Swift port of the former `Sources/components/smk_keymap_store.c`; frame/CRC logic itself lives in `KeymapFrame.swift`, shared with RP2040 |
| `LedStripDriverRMT.swift` | SK6812MINI-E per-key RGB chain driver (RMT-based) — Swift port of the former `led_strip_driver.c` AND the former `led_strip_encoder.c` (both deleted): the custom RMT encoder's 3-function-pointer vtable is a verified Swift mirror, its ISR-context encode/reset callbacks are `@_section(".iram1.*")`-placed to match `CONFIG_RMT_ENCODER_FUNC_IN_IRAM` (SymbolLinkageMarkers feature, see main/CMakeLists.txt) |

### smk_kbd board (ESP32-C6-MINI-1)

`boards/smk_kbd.json` — the `#else` board of the generated keymap, and the one every build without an `SMK_BOARD_*` flag gets — targets this specific board (59-key, 5×12, BLE + Li-ion + USB-C charging, no wired-HID bridge, no per-key RGB). GPIO map, straight from the PCB project's README (source of truth for pin assignments):

| Function | GPIO |
|---|---|
| ROW0–ROW3 (sense, pull-down) | IO0–IO3 |
| ROW4 (sense, pull-down) | IO5 |
| COL0–COL11 (strobe, push-pull) | IO6, IO7, IO8, IO14, IO15, IO18, IO19, IO20, IO21, IO22, IO23, IO17 |
| VBAT sense (÷2 divider) | IO4 / ADC1_CH4 — read by `BatteryMonitor.swift` via `adc_oneshot` (see below) |
| USB D−/D+ (native, flashing only) | IO12/IO13 |
| BOOT / RESET | IO9 / EN |

Row 4 is irregular: 5 keys (cols 0–4), one 2U key (col 5), no switch at col 6, then 5 more keys (cols 7–11) — 59 physical keys over the 60-position matrix.

Battery-voltage ADC reading is polled roughly every 20 seconds from the main scan loop and reported via the BLE HID Battery Service (`esp_hidd_dev_init()` creates this GATT service internally — `smk_ble_set_battery_level()` in `BleHelper.swift` just feeds it data). The ADC reading itself is calibrated via `adc_cali_*` (curve-fitting scheme, using this chip's factory eFuse-burnt constants — falls back to a nominal raw/4095×3300mV conversion if that scheme isn't available on a given chip revision), so the mV reading is trustworthy without a per-board multimeter check. The mV→percentage conversion is still a rough single-cell Li-ion linear approximation (4200mV=100%, 3300mV=0%), not a calibrated discharge curve — that would need real charge/discharge logging from a physical board, not just an accurate instantaneous voltage. Not yet verified against a real board.

### C Sources (`Sources/components/`) — ESP32-C6 only

| File | Responsibility |
|---|---|
| `kb_main.c` | `app_main()` C entry point; Unicode linker stubs for Embedded Swift — **the only C file left in the ESP32-C6 target** |

Everything else that used to live here — GPIO pin configuration, Kconfig-backed board config, the UART wired-HID bridge, the RGB LED strip driver + its RMT encoder, the keymap store, the battery ADC setup, and the entire NimBLE BLE HID glue (`gpio_init.c`, `smk_config.c`, `uart_init.c`, `led_strip_driver.c`, `led_strip_encoder.c`, `smk_keymap_store.c`, `battery_adc.c`, `ble_helper.c`) — is now plain Swift; see "ESP32-C6-only Swift Sources" above.

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

### Shared Port Sources (`ports/common/`) — every ARM port

Files identical across ports live once here instead of as per-port copies:

| File | Responsibility | Compiled into |
|---|---|---|
| `BleHidGatt.swift` | **the shared BTstack HID-over-GATT logic**: GATT/SM/advertising setup (`smk_ble_hid_gatt_setup()`, ends with `hci_power_control(HCI_POWER_ON)`), the HID event packet handler, and `send_keyboard_report()`. Each BTstack port keeps only its transport bring-up and calls `smk_ble_hid_gatt_setup()` after `hci_init()` — this file replaced four near-verbatim copies (BleHidPicoW.swift/BleHidKbdUart.swift's GATT halves, and the C tails of the former `ble_hid_sdc.c` transport (now `ports/nrf52840/BleHidSdc.swift`)/`ble_hid_wb.c`) | pico_w, pico2_w, smk_kbd_rp2040, nrf52840, stm32wb (NOT plain pico/pico2 — its `@_cdecl` entry points reference BTstack symbols unconditionally, so it's only listed for boards that link BTstack) |
| `smk_hid_gatt_data.c` | `#include`s the build-generated `smk_hid.h` and exposes the GATT database via `smk_profile_data()` — an accessor function rather than a direct symbol binding because the standalone BTstack checkout's `compile_gatt.py` declares `profile_data[]` `static` (no external symbol) while pico-sdk's bundled version doesn't | same five builds as `BleHidGatt.swift` |
| `usb_descriptors.c` | TinyUSB device + HID keyboard report descriptors (formerly four byte-identical per-port copies) | all rp2040-family boards, nrf52840, stm32f4, stm32wb |
| `embedded_swift_glue.c` | `posix_memalign` + the Embedded-Swift Unicode linker stubs (formerly duplicated at the bottom of each ARM port's `platform_glue.c`; ESP32-C6 keeps its own stubs in `kb_main.c`) | all rp2040-family boards, nrf52840, stm32f4, stm32wb |

### RP2040 Platform Sources (`ports/rp2040/`)

| File | Responsibility |
|---|---|
| `GPIORegisters.swift` | RP2040 SIO registers (`0xD0000000`) — same API as ESP32 version |
| `BridgingHeader.h` | RP2040 bridging header: libc + platform glue prototypes (mostly comment blocks now — see file; the real glue is same-module Swift) |
| `CMakeLists.txt` | pico-sdk + native CMake Swift integration; auto-discovers swiftc |
| `GPIOInit.swift` | `init_keyboard_pins()` — Swift port of the former `platform/gpio_init.c`; rows driven / columns sensed by default (`colsAreDriven: false`) |
| `UsbHid.swift` | `init_wired_link()` / `send_wired_report()` via TinyUSB — Swift port of the former `platform/usb_hid.c` |
| `PlatformConfig.swift` | board/connection-mode config and `kb_log` — Swift port of the portable half of the former `platform/platform_glue.c` (`main()`, `posix_memalign`, and the Unicode-stdlib linker stubs stay in C — see that file) |
| `KeymapStoreFlash.swift` | runtime keymap store (RP2040, flash-backed, last flash sector reserved) — Swift port of the former `platform/smk_keymap_store.c`; frame/CRC logic lives in `Sources/SMKCore/KeymapFrame.swift` |
| `LedStripDriverPIO.swift` | SK6812MINI-E per-key RGB chain driver (PIO-based), `smk_kbd_rp2040` board only — Swift port of the former `platform/led_strip_driver.c`; PIO state-machine claiming/program-loading stays in `platform/ws2812_pio_shim.c` |
| `BleHidPicoW.swift` | Pico W BLE transport bring-up (`cyw43_arch_init()` + the shared GATT setup call); plain-Pico no-op stubs in its `#else` branch — the HID-over-GATT logic itself is `ports/common/BleHidGatt.swift` |
| `BleHidKbdUart.swift` | `smk_kbd_rp2040` BLE transport bring-up — CYW43439 over the board's dedicated Bluetooth UART (H4 + btstack_chipset_bcm PatchRAM wiring) instead of Pico W's SPI/PIO link; GATT logic shared via `ports/common/BleHidGatt.swift` |
| `platform/tusb_config.h` | TinyUSB device config (descriptors themselves are `ports/common/usb_descriptors.c`) |
| `platform/platform_glue.c` | `main()` — the non-portable remainder of the former full file, see `PlatformConfig.swift` above (`posix_memalign`/stdlib stubs now in `ports/common/embedded_swift_glue.c`) |
| `platform/btstack_config.h` | BTstack config (Pico W / smk_kbd_rp2040 only) |
| `platform/smk_hid.gatt` | GATT database for BLE HID (compiled to `smk_hid.h` at build time) |
| `platform/gpio_init_wrappers.c` | non-inline wrapper entry points for pico-sdk's `static inline` `hardware/gpio.h` functions, so `GPIOInit.swift` can bind them via `@_extern(c, ...)` |
| `platform/flash_irq_wrappers.c` | non-inline wrappers for pico-sdk's `static inline`/`__force_inline` `hardware/sync.h` interrupt-disable functions, plus a runtime accessor for `PICO_FLASH_SIZE_BYTES` — both needed by `KeymapStoreFlash.swift` |
| `platform/ws2812_pio_shim.c` | narrow C remainder for the RGB driver: instantiates the build-generated `ws2812_program` PIO program struct and claims/loads the PIO state machine, since hand-replicating that generated struct layout in Swift would be fragile for no benefit — see `LedStripDriverPIO.swift` |
| `platform/uart_driver_vtable.c` | narrow C remainder for `smk_kbd_rp2040`'s BLE UART transport: the `async_context_poll_t` state (vendor-internal, version-fragile layout — the documented mirror-fallback case), the `uart1` macro accessor, and the `static inline` UART wrappers. The `btstack_uart_block_t` vtable that used to live here is now a verified Swift mirror in `BleHidKbdUart.swift` (`BtstackUartVtable`) |

### nRF52840 board (nrf52840dk / PCA10056) — read before flashing real hardware

**The GPIO pin map for this board (`boards/nrf52840dk.json`'s `matrix`) is a placeholder, not a verified pin assignment.** No board schematic was consulted when choosing it — see that file's own `comment` ("GPIO map deferred to hardware bring-up... Placeholder pin numbers here MUST be replaced before this board is ever flashed"). It MUST be replaced with real, schematic-verified pin assignments before this board is ever flashed to physical hardware — using the placeholder numbers as-is risks driving pins that aren't wired the way the firmware assumes.

Other known gaps on this port, briefly (this is a build-only pass — see `docs/superpowers/specs/2026-08-09-nrf52840-support-design.md`):
- **Runtime keymap store is a no-op stub** (`ports/nrf52840/KeymapStoreStub.swift`) — a keymap upload over USB HID is accepted and dispatched, but every write silently fails; nothing persists across reboots yet.
- **LE bonding does not survive a reboot** (Task 7's known gap — no persistent bonding-info storage wired up yet).
- **No real clock**: `hal_time_ms()` (`ports/nrf52840/platform/ble_hid_sdc.c` — now a slim C remainder; the SDC transport itself is `ports/nrf52840/BleHidSdc.swift`, including a verified Swift `hci_transport_t` mirror), `tusb_time_millis_api()` (`ports/nrf52840/UsbHid.swift`), and the `vTaskDelay` busy-loop (`ports/nrf52840/platform/platform_glue.c`) are all uncalibrated per-call/per-loop counters, not real millisecond clocks, until a real hardware timer (`NRF_RTC`, once MPSL claims it) is wired up.

### nRF52840 Feather board (`SMK_TARGET_BOARD=feather_nrf52840`) — IN PROGRESS, read before flashing real hardware

This is a separate board variant of the same nRF52840 target above (`./build_nrf52840.sh feather`), still bring-up-in-progress, not confirmed working yet — see the Supported Targets table entry for the full story (board identity turned out to be a nice!nano/clone rather than a genuine Adafruit Feather, and a real missing-`SCB->VTOR`-relocation bug was found and fixed but not yet hardware-reconfirmed). It exists as a USB-enumeration bring-up test only — no matrix is wired, and `Sources/smk/Main.swift`'s `SMK_BOARD_FEATHER_NRF52840` branch uses an empty `rows`/`cols` matrix config specifically so no GPIO pin is ever touched, since this board's fixed-function pins (P0.00/P0.01 are the 32.768kHz crystal XL1/XL2, P0.16 drives the onboard NeoPixel, per the Adafruit Feather Express pinout — not reconfirmed against the actual nice!nano-identified board) directly collide with the `nrf52840dk` placeholder matrix above. BLE init (`init_ble_hid()`) and MPSL init (`mpsl_glue_init()`) are both skipped for this board, keeping the bring-up scope to USB HID only.

**A second, independent reason this board cannot enumerate USB, found 2026-08-23 and NOT yet fixed.** `Sources/smk/Main.swift`'s `app_main_swift` rejects an empty matrix (`cfg.rowPins.isEmpty || cfg.colPins.isEmpty`) by logging `Critical Error` and **returning** — and this board's config declares exactly that, deliberately, so no GPIO is touched. That early return happens *before* `init_wired_link()`, so TinyUSB is never initialised on the one board whose entire bring-up goal is USB enumeration. This is orthogonal to the `SCB->VTOR` fix above and predates it; both would have to be right for the board to enumerate. It is annotated in place at that check in `Main.swift`. Fixing it means letting a zero-key board proceed past the matrix check (or exempting this board), which is a behaviour change nobody has made yet.

**Flashing this board — drag-and-drop UF2 did not work in the one bring-up session so far** (the bootloader enters fine — confirmed via USB re-enumeration and a breathing red LED once the timing/technique was right — but no mass-storage volume ever mounted on macOS, a known unresolved class of issue per nice!nano's own troubleshooting docs, which point to a host driver/OS-level cause rather than the board). **`adafruit-nrfutil` DFU-over-serial is the flash path that actually worked**, twice, end to end:
```bash
pip3 install adafruit-nrfutil   # in a venv if your Python is externally-managed (PEP 668)
adafruit-nrfutil dfu genpkg --dev-type 0x0052 \
    --application build_nrf52840_feather_nrf52840/smk_nrf52840.hex \
    smk_nrf52840_dfu.zip
# Enter the bootloader first — see below — then, while it's still active:
adafruit-nrfutil dfu serial -pkg smk_nrf52840_dfu.zip -p /dev/cu.usbmodemXXXX -b 115200
```
- **Entering the bootloader**: the documented double-tap-reset trick is unreliable by feel alone — watch specifically for the LED to shift into a **slow, smooth red fade**, distinct from whatever blink pattern the current application firmware shows; a false-positive read of "the LED did something" wastes a flash cycle. If the board is currently enumerating over USB (i.e. some application is running), the **1200-baud serial touch is more reliable than the physical button**: `stty -f /dev/cu.usbmodemXXXX 1200`, then check `ioreg`/`/dev/cu.*` for a new device a couple seconds later — this is the same mechanism Arduino/`bossac` use to trigger bootloader entry programmatically.
- The app-start flash offset baked into `ports/nrf52840/linker/feather_nrf52840.ld` (`FLASH ORIGIN = 0x27000`) assumes an S140 v7 SoftDevice; a v6 board (app region starting at `0x26000`) is still safe to flash with this build (just wastes 4KB). Real confirmation of the actual SoftDevice version on this specific board is still outstanding (its `INFO_UF2.TXT` was never actually read — the drive that would contain it never mounted).
- This board has no SWD/J-Link recovery path in this project's tooling — the linker script was deliberately chosen to coexist with the factory bootloader/SoftDevice rather than overwrite them, so DFU-over-serial (or UF2, if it ever mounts) stays the recovery path if something goes wrong, rather than needing external debug hardware.
- **Known-fixed-but-unconfirmed bug**: `ports/nrf52840/platform/platform_glue.c`'s `smk_relocate_vector_table()` (called first in `main()` for this board) sets `SCB->VTOR` to the app's real vector table address — without it, the flashed firmware enumerated no USB device at all, silently, because interrupts dispatched through the stale table at flash address 0x0 (the SoftDevice's reserved region) instead of the app's own handlers at 0x27000. This was diagnosed by reading the vendored nRF5 SDK's startup code, not by guessing. The fix was rebuilt and reflashed once, but the USB connection went unreliable (stopped enumerating anything at all, even across a port change) before booting could be reconfirmed — pick this back up by re-attempting the flash-and-observe cycle once the physical connection is solid again.

### STM32WB Platform Sources (`ports/stm32wb/`)

| File | Responsibility |
|---|---|
| `GPIORegisters.swift` | GPIOB register access — same `outSet`/`outClear`/`input` API as the other ports |
| `ClockInit.swift` | HSE/HSI48/CRS clock bring-up (Swift port of the equivalent STM32F4 init, adapted for the WB55's clock tree), plus `smk_enable_lse_and_rf_wakeup_clock()` — the LSE + RF-wakeup-clock bring-up CPU2's link layer needs, called from `ble_hid_wb.c`'s `init_ble_hid()` (ported from that file's former C implementation). Reads that need to be guaranteed-issued/ordered (post-clock-enable read-backs) go through the opaque `smk_mmio_read32()` C helper — `.pointee` reads get store-forwarded or hoisted, a distinct hazard from the deleted-poll-loop one (both found by disassembly, see the file) |
| `GPIOInit.swift` | `init_keyboard_pins()` — matrix pin configuration on GPIOB |
| `UsbHid.swift` | `init_wired_link()` / `send_wired_report()` via TinyUSB's `fsdev` driver |
| `HwIpcc.swift` | IPCC (Inter-Processor Communication Controller) **hardware layer only** — the `HW_IPCC_*` entry points ST's vendored `tl_mbox.c` calls down into: enabling the IPCC peripheral clock, releasing CPU2 from reset (PWR_CR4's C2BOOT), per-channel TX/RX mask manipulation, both IPCC NVIC IRQ handlers dispatching to the transport layer's channel callbacks, and `smk_ipcc_reset()` (pre-`TL_Init()` channel-flag/mask reset, ported from `ble_hid_wb.c`'s former C). It knows nothing about BTstack, HCI, or the CPU2 boot/SHCI handshake — those live in `platform/ble_hid_wb.c` |
| `KeymapStoreStub.swift` | runtime keymap store stub — same no-op-write pattern as the nRF52840 port; nothing persists across reboots yet |
| `BridgingHeader.h` | STM32WB bridging header |
| `CMakeLists.txt` | hand-rolled CMake + Ninja build, no vendor SDK CMake integration — auto-discovers swiftc |
| `linker/` | hand-written GCC linker script (cmsis-device-wb ships no linker script, same gap as cmsis-device-f4) |
| `platform/tl_mbox.c`, `platform/shci.c`, `platform/shci_tl.c`, `platform/shci_tl_if.c`, `platform/stm_list.c`, and related headers | **vendored byte-for-byte** (not edited — see below) from STM32CubeWB v1.24.0's IPCC transport layer: ST's mailbox protocol for talking to CPU2's HCI-Layer firmware. See the license note immediately below before distributing anything built from this port. |
| `platform/hci_tl.c`, `platform/hci_tl_if.c` | vendored on disk but **deliberately NOT compiled** — see the "`hci_tl.c` is excluded on purpose" note below before adding them to the build |
| `platform/ble_hid_wb.c` | **the BLE transport implementation for this port**: the CPU2 boot sequence (`TL_Init`/`TL_MM_Init`/`TL_Enable`/`shci_init`/`SHCI_C2_BLE_Init` — LSE/RF-wakeup-clock and IPCC reset are now Swift, see `ClockInit.swift`/`HwIpcc.swift` above), the `hci_transport_t` bridge that carries BTstack's HCI traffic over the vendored mailbox layer (including the BTstack run-loop data source and the main-context event delivery queue), and the SysTick 1ms time base and `hal_*` hooks BTstack needs. The HID-over-GATT setup, advertising/security-manager configuration, and `send_keyboard_report()` are the shared `ports/common/BleHidGatt.swift`; `init_ble_hid()` here ends by calling its `smk_ble_hid_gatt_setup()` |
| `platform/tusb_config.h` | TinyUSB device config (descriptors themselves are `ports/common/usb_descriptors.c`) |
| `platform/smk_hid.gatt` | GATT database for BLE HID (compiled to a header at build time) |
| `platform/platform_glue.c`, `platform/cortex_m_intrinsics.c` | `main()`/`_init` and the compiler-intrinsic shims non-portable enough to stay C — including `smk_mmio_read32()`, the guaranteed-issued/ordered MMIO read `ClockInit.swift`/`HwIpcc.swift` use for read-backs (stdlib stubs/`posix_memalign` now in `ports/common/embedded_swift_glue.c`) |

**Vendored files are byte-identical to upstream — adapt via stand-in headers, not by editing them.** Every `.c`/`.h` taken from STM32CubeWB was copied verbatim, ST copyright headers intact, with not one line modified. The adaptations this project needed (replacements for CubeMX-generated headers the vendored sources `#include`) live instead in four small project-local stand-ins: `platform/tl_dbg_conf.h`, `platform/utilities_common.h`, `platform/ble_common.h`, `platform/ble_const.h`. Keep it that way — re-syncing against a newer CubeWB should be a straight file copy. (Include-path ordering matters here: BTstack's checkout vendors its own ST HAL tree containing real headers with those same four filenames, so `ports/stm32wb/CMakeLists.txt` deliberately adds only `${BTSTACK_PATH}/src`, `/platform/embedded` and `/3rd-party/*` — never anything under BTstack's `port/` subtree.)

**`hci_tl.c` is excluded from the build on purpose — do not "helpfully" re-add it.** It is vendored on disk (`platform/hci_tl.c`, `platform/hci_tl_if.c`) as part of the CubeWB vendoring record, but is not in `CMakeLists.txt`'s `stm32wb_ipcc_srcs`, for two independent hard reasons:
1. `hci_tl.c` defines `void hci_init(void (*)(void *), void *)`, which collides at link time with BTstack's `src/hci.c` `void hci_init(const hci_transport_t *, const void *)` — both are unconditionally in the link, so building it is a duplicate-symbol error.
2. `hci_tl.c` routes HCI Command Complete/Status events into a private queue drained only by ST's own blocking `hci_send_req()` API, which BTstack never calls. BTstack **is** the HCI host in this port and needs to see every event.

BTstack's own reference port for this exact chip makes the same call (`~/btstack/port/stm32-wb55xx-nucleo-freertos/Makefile` builds `shci_tl.c`, `shci_tl_if.c`, `tl_mbox.c`, `shci.c`, `stm_list.c` — and no `hci_tl.c`). Consequence: of the transport layer's two application-level callbacks, only `shci_notify_asynch_evt()` still has a caller, and it is implemented in `platform/ble_hid_wb.c`. `platform/ble_common.h`/`ble_const.h` existed solely to satisfy `hci_tl.c`'s `#include`s and are now unused.

### STM32WB board (NUCLEO-WB55RG) — read before flashing real hardware, and before distributing a build

**License conflict — unresolved by deliberate decision.** This repository is licensed GPL-3.0 (see root `LICENSE`). The IPCC transport-layer files vendored into `ports/stm32wb/platform/` from STM32CubeWB (`tl_mbox.c`, `shci.c`, `shci_tl.c`, and related headers) are distributed by ST under the SLA0044 license, whose clause 5 explicitly forbids redistributing SLA0044-licensed software under GPL terms. This is a real, currently-unresolved conflict between this repo's license and its vendored dependencies — it was flagged during this port's implementation, and the decision (made explicitly, not by omission) was to continue the port and defer resolution rather than pause or restructure now. **Do not release or otherwise distribute a build of this port** until the maintainer has reviewed and resolved this — via a carve-out, re-licensing, replacing the vendored files, or another approach not yet decided.

Other known gaps on this port, briefly (build-only pass):
- **The GPIO pin map is an explicit bring-up placeholder, not a real keyboard layout** — `boards/stm32wb_nucleo.json` is a 5×5 test matrix on GPIOB pins 0–9, same placeholder-until-schematic-verified pattern as the nRF52840 and STM32F4 ports.
- ~~HSE capacitor tuning from factory OTP is not applied.~~ **Fixed.** `ClockInit.swift`'s `smk_clock_init()` now reads the per-die HSE trim from the WB55's OTP area (record id 0, byte offset 6 — same layout ST's own `Config_HSE()`/`LL_RCC_HSE_SetCapacitorTuning()` reads, independently re-derived from public register/memory-map facts rather than copied from ST's SLA0044-licensed `otp.c`) and applies it to `RCC.HSECR` right after HSE stabilizes. Still unverified against a real board's actual RF frequency accuracy — the register-level logic is confirmed against `stm32wb55xx.h`, but nothing here can confirm the *result* without a real crystal and a frequency counter.
- **CPU2 firmware is a separate, manual flashing step this project does not automate.** The WB55's on-chip Cortex-M0+ radio coprocessor (CPU2) must be flashed with ST's **"HCI Layer"** wireless-coprocessor firmware specifically — e.g. `stm32wb5x_BLE_HCILayer_extended_fw.bin` from `STM32CubeWB/Projects/STM32WB_Copro_Wireless_Binaries/STM32WB5x/` in the vendored `STM32CubeWB` checkout. The "Full Stack" firmware variant will **not** work with this port's BTstack-based host (this port supplies its own BLE host stack over IPCC/HCI, whereas "Full Stack" runs the host on CPU2 itself). Flash CPU2 with ST's own tooling (e.g. STM32CubeProgrammer) before expecting BLE HID to come up — this repo's build only produces the CPU1 (application) image.

### Keymap Configuration

Every board's keymap — its GPIO matrix *and* its layers — lives in `boards/<name>.json` and is compiled at build time by `./generate_default_keymap.sh` into `Sources/SMKCore/DefaultKeymapGenerated.swift`'s `defaultKeymapBytes`. Edit the board file (or `keymap.json`) and re-run the script, then commit the regenerated file — the same generated-file pattern as `KeyCodesGenerated.swift`. `Main.swift` gets the layers via `LayerEngine.loadKeymap(binary:count:)` and the matrix via `Config(payload:)`, both from that one payload, so the two cannot disagree about how many rows and columns a board has.

The generated file is a `#if` chain over the same `SMK_BOARD_*` flags that used to select a board's string literal, with **smk_kbd as the `#else` fallback** — which is what the ESP32-C6 reference board takes (its `main/CMakeLists.txt` defines `SMK_BOARD_TEST_BOARD` only when Kconfig selects the test board) and what the host `swift test` build takes (no board flag is defined there). `hostBuildFallsBackToTheSmkKbdBoard` in `Tests/SMKCoreTests/BoardPayloadRoundTripTests.swift` pins that.

**Adding a board** means two edits, in this order: write `boards/<name>.json` (keys: `comment`, `board`, `define`, `matrix`, and either `layers` or `layersFrom`), then add its name to `BOARDS` in `generate_default_keymap.sh`. The list is ordered and the board with `"define": null` must be last — the generator refuses otherwise, since that entry becomes the `#else`.

`nrf52840dk`, `kbd_rp2040` and `smk_kbd` share one layout: their board files carry `"layersFrom": "keymap.json"` instead of a `layers` array, so the repo has one copy of that layout rather than three that can drift. Only their matrices differ.

`feather_nrf52840` compiles to a bare six-byte header with `layerCount == 0`. That is correct, not data loss: no matrix is wired to that board, so its JSON declared a 0x0 matrix, and `decodeKeymapPayload` deliberately refuses a *declared* layer over a 0x0 matrix (a six-byte payload claiming 200 empty layers would otherwise blank a working keyboard — see `KeymapBinary.swift`'s guard). `LayerEngine` then leaves `keymaps` empty, which for a board with no pins to scan is behaviourally identical to the `[[[]]]` the JSON used to declare.

**The matrix always comes from the compiled-in payload, never a stored one.** An uploaded keymap carries its own `rows`/`cols` header, and honouring it would let a configurator bug leave a board unable to scan even the keys needed to recover it. A stored keymap contributes layers and macros only.

**cJSON is gone from the firmware** as of the change that introduced `boards/`. There is no JSON parser on any target: `Config.fromJson` and `LayerEngine.loadKeymap(json:)`/`loadKeymap(cJsonStr:)` are deleted, `Sources/CJSON/` is deleted, and the dependency is out of `Package.swift`, `main/idf_component.yml` and all six port CMakeLists. Removing it saved **16–93 KB of `.text` per target** (measured before and after on all eleven builds — see `docs/superpowers/notes/2026-08-23-cjson-flash-sizes.md`). cJSON's own symbols were only 7.8 KB of that; the rest was newlib's floating-point conversion machinery, which cJSON dragged in transitively via `strtod`/`sprintf("%g")`. That is why the hand-rolled-CMake ports (STM32F4 −59%, SAMD21 −40%) saved far more than the RP2040 family (−18 KB, already on newlib-nano without float printf). Tests keep their readability through a **test-only** token→payload builder (`Tests/SMKCoreTests/PayloadBuilder.swift`), which is pinned byte-for-byte against the shell generator by `builderMatchesShellGenerator` — it is a fourth implementation of the payload format and would otherwise drift.

### Binary Keymap Payload Format

The runtime keymap store and the compiled-in default both hold a **version-2 binary payload**, not JSON. Full design rationale (the JSON-vs-binary size measurement, the decision to compile the whole keymap rather than enlarge storage, etc.) is in `docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md` — what follows is the byte contract itself, reproduced in full rather than summarized, since a paraphrase is exactly what drifts out of sync silently. The configurator's own binary compiler does not exist yet (as of this writing) and its `CLAUDE.md` does not document this contract yet either — do not assume that document carries it; this is the authoritative copy until that changes.

```
header    rowCount(1) colCount(1) colsAreDriven(1)
          layerCount(1) macroCount(1) reserved(1)
          rows[rowCount](1 each)   GPIO numbers
          cols[colCount](1 each)
layers    layerCount * rowCount * colCount * 2 bytes
macros    macroCount entries
```

A cell is two bytes: an action tag, then its parameter.

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

A compiled macro is `id(1) + nameLength(1) + name + stepCount(1) + steps`:

| step | opcode | layout |
|---|---|---|
| keystroke | `0x01` | `opcode(1) + mods(1) + keycode(1) + holdMs(2)` = 5 |
| delay | `0x02` | `opcode(1) + ms(2)` = 3 |
| layer | `0x03` | `opcode(1) + op(1) + index(1)` = 3 |
| text | `0x04` | `opcode(1) + delivery(1) + msPerChar(1) + length(1) + payload` = 4 + n |
| repeat | `0x05` | `opcode(1) + count(1) + bodyLength(2) + body` = 4 + body |

All multi-byte fields (`holdMs`, `ms`, `bodyLength`) are little-endian. `mods` bits 0–7 are `Modifier`'s declaration order (`leftCtrl, leftShift, leftAlt, leftGUI, rightCtrl, rightShift, rightAlt, rightGUI`) — the same bit order as a standard USB HID keyboard report, so a `mods` byte ORs straight into a report. `op` is `0x00` momentary (`"mo"`) / `0x01` toggle (`"tg"`). `delivery` is `0x00` keystrokes / `0x01` paste — paste is unimplementable board-side and the editor already refuses to save it, but the byte stays in the stride rather than churning a layout three implementations share.

**Three implementations of this format now exist, and nothing but tests keeps them agreeing** — a change to the tag table, the header layout, or the macro-step layout has to land in all three:
- `Sources/SMKCore/KeymapBinary.swift` — the decoder (`decodeKeymapPayload`)
- `generate_default_keymap.sh` — the build-time generator of the compiled-in default
- the configurator's compiler (`KeymapDocument` → binary payload) — not yet written; lives in `~/esp/smk_configurator`

**The `init?(rawValue:)` landmine — read this before writing any decoder for this format.** `KeyCode` and `Modifier` both override their synthesized `rawValue` *getter* to return real HID usages / bit masks (`KeyCodesGenerated.swift:178`'s own warning comment; `Modifier.swift`), but the compiler still synthesizes `init?(rawValue:)` against **ordinal case position**, not the overridden value. `KeyCode(rawValue: 0x04)` returns whichever case sits fifth in declaration order (ordinal 4, zero-based), not `.a` — whose HID usage just happens to *be* `0x04`. Code that calls `KeyCode(rawValue: wireByte)` to decode a wire byte compiles cleanly and decodes every key wrong, with nothing to catch it short of hardware. `KeymapBinary.swift`'s private `keyCode(fromHIDUsage:)` / `modifier(fromBit:)` are the correct pattern instead: walk `T(rawValue: 0)`, `T(rawValue: 1)`, ... (a valid use of the synthesized initializer as a pure ordinal enumerator) and compare each candidate's real `.rawValue` against the wire byte, rather than ever passing a wire byte to `T(rawValue:)` directly.

**Frame version 2.** The 11-byte store frame (magic/version/length/CRC32, layout unchanged — see `KeymapFrame.swift`) bumps its version byte from 1 (JSON) to 2 (this binary payload). A version-1 frame — written by pre-this-change firmware — fails the version check and is rejected outright, falling back to the compiled-in default, the same safe path an already-corrupt frame takes. This *is* the whole migration story: the frame stays at the same offset and size, so an old frame fails a clean version check instead of being misread as garbage at a shifted offset.

**16 layers now fit.** The previously documented 16-layer ceiling (`LayerEngine` sizes `toggledLayers`/`momentaryCounts` at 16, and the configurator enforces `maxLayerCount = 16`) was never actually reachable at JSON's ~11.9 bytes/cell — real capacity topped out around five layers, and nothing reported the shortfall; a user just failed to upload. At two bytes/cell, for the smk_kbd board's 5×12 matrix: `6 (header) + 5 (rows) + 12 (cols) + (16 layers × 5 rows × 12 cols × 2 bytes) = 1,943 bytes`, against the existing 4,085-byte store (`smkKeymapMaxLen`) — all 16 layers fit with roughly 2 KB left over for macros.

**`AsciiKeycodes.swift` assumes US QWERTY** on the host — the board has no way to detect the host's actual keyboard layout, so a macro's "type this text" step types the wrong characters on a non-QWERTY host; this is the standard assumption boot-protocol keyboards make. It cannot be generated from `keycodes.json` the way `KeyCodesGenerated.swift` is: that manifest maps key *names* to HID usages and carries no shift state, so `'A'` vs `'a'` or `'!'` vs `'1'` have no entry there. It is hand-written and pinned by `AsciiKeycodesTests` against `KeyCode` so it can't silently drift from the generated vocabulary.

**`MacroPlayer.swift`** plays one macro back as HID reports, advanced once per scan tick from `Main.swift`'s main loop. Timing quantizes to the 10 ms scan tick (`macroTicks(forMs:)`, matching `CONFIG_FREERTOS_HZ=100`) and **rounds milliseconds up**, so a sub-tick duration (e.g. 5 ms) still takes one tick rather than silently becoming zero. A playing macro **owns the HID report** for every tick it plays — the scan loop substitutes `macroPlayer.tick()`'s report for the normal per-key report while a macro is active (`report = r` in the `.report` case), rather than merging the two. A macro runs **once per press, not repeatedly while the trigger key is held**: playback starts on the press edge (`KeyEventProcessing.swift`'s `macroEvents`), `MacroPlayer.start(_:)` is a no-op while one is already playing, and no `lastScan` reset happens when playback finishes — so a still-held macro key is already reflected in `lastScan` and does not look like a fresh press once the macro ends (this was tried the other way and reverted; see the comment at the `.finished` case in `Main.swift`).

**`CAPS` opcode `0x05`** (`smkKeymapOpCaps` in `KeymapProtocol.swift`) is a new upload-protocol packet type alongside BEGIN/CHUNK/COMMIT/ERASE that reports real per-port capacity — `macroBytes`, `macroSlots`, `keymapMaxLen` — so the configurator's capacity meter can show real numbers instead of a conservative floor estimate. Two of the reported values look like bugs but aren't:
- **`macroBytes` equals `keymapMaxLen`** — not a copy-paste error. Macros and layers share one budget inside the keymap payload rather than having a separate flash region, so there is no macro-only allowance to report; the board reports the shared ceiling and only the editor, which compiles the layers, knows how much of it is left for macros.
- **`macroSlots` is `255` (`UInt8.max`), not `256`**, even though a macro id is a full byte (0–255, 256 distinct values) — because the `macroSlots` field on the wire is itself one byte, which cannot represent 256. Understating by one is the safe direction (the editor refuses a 256th macro that would in fact have fit, rather than accepting one that doesn't exist), and 255 macros exhausts the shared byte budget many times over before the slot count would matter for any real keymap.

### RGB Backlight (opt-in, off by default)

`RGBLighting.swift` and `LedStripDriverRMT.swift` implement an SK6812MINI-E per-key RGB chain, but the stock smk_kbd board has no such chain (its only LED is a fixed charge-status indicator wired straight to the charger IC). Enable via `SMK_HAS_RGB_BACKLIGHT` in `idf.py menuconfig` if you wire one up yourself.

Gated two ways: compiled in only for the ESP32-C6 build (`-DSMK_RGB_AVAILABLE` in `main/CMakeLists.txt`; RP2040 doesn't include `RGBLighting.swift` at all, so the `#if SMK_RGB_AVAILABLE` block in `Main.swift` compiles out there instead of failing a type lookup), and instantiated at runtime only if the Kconfig option is on. `SMK_RGB_GPIO` (default IO16, the PCB's documented spare pad) is checked against the matrix pins at boot; a collision (e.g. the old hardcoded GPIO0, which is ROW0) disables the chain with a log warning instead of corrupting the scan.

**Key action syntax:**
- `key:<char>` — standard keycode (e.g. `key:a`, `key:enter`)
- `mod:<name>` — modifier (e.g. `mod:leftShift`)
- `mo:<n>` — momentary layer (held = active)
- `tg:<n>` — toggle layer
- `trans` — transparent (fall through to lower layer)
- `toggle_conn` — switch between BLE and wired modes
- `none` — no action
