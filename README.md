# SMK (Swift Matrix Keyboard)

📖 **[Read the docs and see the full feature list](https://mburger89.github.io/SMK/)**

A keyboard firmware written in **Embedded Swift**, targeting the **ESP32-C6**, **Raspberry Pi Pico / Pico W (RP2040)**, **Raspberry Pi Pico 2 / Pico 2 W (RP2350)**, **Nordic nRF52840**, **STM32F4**, and **STM32WB**. SMK provides a modern development experience for keyboard enthusiasts, featuring Bluetooth (BLE) and Wired (USB/UART) connectivity, and a flexible JSON-based keymap system.

## Features
- **Embedded Swift**: Leverages Swift's safety and modern syntax on bare-metal hardware.
- **Multi-target**: Supports ESP32-C6 (RISC-V via ESP-IDF), RP2040/RP2350 (ARM via pico-sdk), nRF52840 (ARM via a vendored nRF5 SDK + CMake), STM32F4 (ARM via vendored CMSIS + CMake), and STM32WB (ARM via vendored CMSIS + CMake + BTstack + a vendored IPCC transport layer). See [`CLAUDE.md`'s Supported Targets table](CLAUDE.md#supported-targets) for the full matrix of what's working vs. build-only-so-far per target.
- **Dual Mode**: Switch between Bluetooth and Wired (USB HID / CH9350 bridge) modes.
- **Dynamic Matrix**: Configurable GPIO pins for rows and columns.
- **Layer Engine**: Supports momentary layers, toggled layers, and transparent keys (similar to QMK).
- **JSON Configuration**: Keymaps and hardware settings defined via JSON.
- **Per-Key RGB (opt-in)**: SK6812MINI-E/WS2812 backlight driver (ESP32-C6 only), off by default.
- **Battery-Level Reporting (ESP32-C6/smk_kbd only)**: reads the board's VBAT divider and reports an estimated percentage via the BLE HID Battery Service — approximate (uncalibrated ADC + linear voltage curve), not yet checked against real hardware.
- **Kconfig Board Options**: `idf.py menuconfig` toggles wired-bridge presence, default connection mode, and RGB backlight per board without touching source.
- **Runtime Keymap Upload**: a transport-agnostic BEGIN/CHUNK/COMMIT/ERASE protocol (`Sources/SMKCore/KeymapProtocol.swift`) lets a keymap be uploaded over USB HID without reflashing, persisted to NVS on ESP32-C6 or flash on RP2040/RP2350 (nRF52840/STM32WB currently stub the write).

## Prerequisites

Before building, ensure you have the following installed:

1.  **ESP-IDF v6.0.1**: The official Espressif IoT Development Framework.
2.  **Swift 6.3.1 (Experimental Embedded RISC-V)**:
    - Download the appropriate toolchain from the Swift.org snapshots or use a compatible pre-built toolchain for RISC-V.
    - Ensure it is installed in `~/Library/Developer/Toolchains/`.
3.  **Python 3.11+**: Required by ESP-IDF.

## Getting Started

### 1. Configure the Environment
Ensure your ESP-IDF environment is sourced. The standard installer puts the real export script at
`~/.espressif/v6.0.1/esp-idf/export.sh` (adjust the version if you installed a different one):
```bash
. ~/.espressif/v6.0.1/esp-idf/export.sh  # or your own export-esp-idf.sh alias, if you have one
```

### 2. Configure Hardware & Keymap
Currently, the hardware configuration and keymap are defined in `Sources/smk/Main.swift`. You can modify the `configJson` string to match your keyboard's matrix and desired layers.

The checked-in `configJson` targets the **smk_kbd** board (ESP32-C6-MINI-1, 59-key 5×12, BLE + battery) — see `CLAUDE.md` for its full GPIO map. If you're building different hardware, update the pin lists and `colsAreDriven` flag to match your wiring.

**JSON Schema:**
- `matrix`: Defines the `rows` and `cols` GPIO pins, plus `colsAreDriven` (0/1) — whether columns are the strobed/output side (1) or rows are (0, default). This depends on your diode orientation; see `CLAUDE.md`'s "Matrix scan loop" section.
- `layers`: An array of layers, where each layer is a 2D array of strings.
  - `key:<char>`: Standard keycode (e.g., `key:a`, `key:enter`).
  - `mod:<name>`: Modifier keys (e.g., `mod:leftShift`).
  - `mo:<index>`: Momentary layer switch.
  - `tg:<index>`: Toggle layer.
  - `trans`: Transparent key (falls through to lower layer).
  - `toggle_conn`: Switches between Wired and Bluetooth modes.

### 3. Board Configuration (Kconfig)
Run `idf.py menuconfig` → **SMK Keyboard Configuration** to set board-specific options without editing source:

| Option | Default | Purpose |
|---|---|---|
| `SMK_HAS_WIRED_BRIDGE` | off | Enable only if your board has a CH9350 UART-to-HID bridge chip. |
| `SMK_DEFAULT_CONNECTION_MODE` | Bluetooth | Boot-time default (Bluetooth/Wired). Forced to Bluetooth if `SMK_HAS_WIRED_BRIDGE` is off. |
| `SMK_HAS_RGB_BACKLIGHT` | off | Enable if you've wired an SK6812MINI-E/WS2812 per-key RGB chain. |
| `SMK_RGB_GPIO` | 16 | GPIO for the RGB data line (shown only when RGB is enabled). Checked against matrix pins at boot; a collision disables the chain with a log warning instead of corrupting the scan. |

The stock **smk_kbd** board has neither a wired bridge nor an RGB chain, so all of these default off.

### 4. Build the Project
Set the target to ESP32-C6 and build:
```bash
idf.py set-target esp32c6
idf.py build
```

### 5. Flash and Monitor
Connect your ESP32-C6 via USB and run:
```bash
idf.py flash monitor
```

## Project Structure

- `Sources/smk/`: Swift sources shared by every target, plus the ESP32-C6-only Swift files (`GPIOInit.swift`, `SmkConfig.swift`, `BatteryMonitor.swift`, `BleHelper.swift`, `WiredHidUart.swift`, `KeymapStoreNVS.swift`, `LedStripDriverRMT.swift`, `RGBLighting.swift`).
  - `Main.swift`: Entry point, board config JSON, main scan loop.
  - `KeyMatrix.swift`: GPIO matrix scanning.
  - `GPIORegisters.swift`: ESP32-C6 GPIO register access.
- `Sources/SMKCore/`: hardware-independent, host-testable logic shared across all targets — `LayerEngine.swift`, `KeyEventProcessing.swift`, `Debounce.swift`, `HIDReport.swift`, `Config.swift`, `ConnectionMode.swift`, `Modifier.swift`, `LEDChainMapping.swift`, `KeymapFrame.swift`, `KeymapProtocol.swift`, etc.
- `Sources/components/`: remaining ESP32-C6 C sources — `ble_helper.c`, `kb_main.c`, `battery_adc.c`, `led_strip_encoder.c`.
- `Tests/SMKCoreTests/`: Swift Testing suite for `Sources/SMKCore/` (host-only, no embedded toolchain required).
- `main/`: ESP-IDF component configuration and bridging (`CMakeLists.txt`, `Bridging.h`, `Kconfig.projbuild`).
- `ports/`: per-target platform layers (`rp2040/`, `nrf52840/`, `stm32f4/`, `stm32wb/`), each with its own `GPIORegisters.swift`, GPIO/USB/BLE glue, and build config — see `CLAUDE.md` for the full per-file breakdown.
- `managed_components/`: External dependencies handled by the ESP-IDF component manager (e.g., `cJSON`).
- `site/`: source for the [docs site](https://mburger89.github.io/SMK/) (built via `site/build.py`, deployed by `.github/workflows/`).

## Scripts & Environment Variables

- `idf.py`: Standard ESP-IDF build script.
- `IDF_PATH`: Should point to your local ESP-IDF installation (required by `CMakeLists.txt`).

## RP2040 / RP2350 (Pico / Pico W / Pico 2 / Pico 2 W) Support

SMK also targets the **Raspberry Pi Pico** (USB HID), **Pico W** (USB HID + BLE scaffolded), and
their RP2350-based successors **Pico 2** / **Pico 2 W** (build-only for now — not yet verified on
real hardware), plus a dedicated chip-down board, **smk_kbd_rp2040** (RP2040 QFN-56 + CYW43439,
`SMK_TARGET_BOARD=smk_kbd_rp2040` — USB HID + per-key RGB, working; BLE over a dedicated UART to the
CYW43439, not yet hardware-confirmed). The keyboard logic (`Sources/smk/`) is shared single-source
across all of these targets; only the hardware platform layer differs.

### Prerequisites (RP2040)
```bash
# pico-sdk with submodules
git clone https://github.com/raspberrypi/pico-sdk ~/pico-sdk
git -C ~/pico-sdk submodule update --init

# ARM cross-compiler (full toolchain with newlib)
brew tap osx-cross/arm && brew install osx-cross/arm/arm-gcc-bin@14

# Build tools (if not already present)
brew install cmake ninja picotool
```

RP2350 (`pico2`/`pico2_w`) additionally requires a Swift development-snapshot toolchain (confirmed:
`swift-DEVELOPMENT-SNAPSHOT-2026-05-27-a` or later) that ships a real Embedded-Swift stdlib for
`armv8m.main-none-none-eabi` (RP2350's Cortex-M33 target). Released `swift-6.3.x` toolchains report
support for that triple via `-print-target-info` but fail an actual compile — they don't ship the
stdlib.

### Build (RP2040 / RP2350)
```bash
export PICO_SDK_PATH=~/pico-sdk

./build_rp2040.sh pico      # plain Pico (RP2040)   — USB HID only
./build_rp2040.sh pico_w    # Pico W (RP2040)       — USB HID + BLE
./build_rp2040.sh pico2     # Pico 2 (RP2350)       — USB HID only
./build_rp2040.sh pico2_w   # Pico 2 W (RP2350)     — USB HID + BLE
```

Flash by holding **BOOTSEL**, connecting USB, then:
```bash
picotool load -f build_rp2040_pico/smk_rp2040.uf2
```

See [`ports/rp2040/README.md`](ports/rp2040/README.md) for full details.

## nRF52840 Support

SMK also targets the **Nordic nRF52840** (Arm Cortex-M4F) — USB HID (TinyUSB) + BLE HID (Nordic's
SoftDevice Controller over BTstack), build-only for now, not yet verified on real hardware. As with
RP2040/RP2350, the keyboard logic (`Sources/smk/`) is shared single-source; only the hardware
platform layer (`ports/nrf52840/`) differs.

```bash
export NRF5_SDK_PATH=~/nRF5_SDK
export NRFXLIB_PATH=~/sdk-nrfxlib
export TINYUSB_PATH=~/tinyusb
export BTSTACK_PATH=~/btstack

./build_nrf52840.sh
```

See [`CLAUDE.md`'s nRF52840 Prerequisites subsection](CLAUDE.md#nrf52840) for how to obtain and
place the four vendored dependencies these env vars point at.

SMK also targets the **STM32F4** (WeAct Black Pill, STM32F411CEU6, Arm Cortex-M4F) — USB HID
(TinyUSB's `dwc2` driver) only this pass, no BLE (a future STM32WB cycle covers that), build-only,
not yet verified on real hardware. As with the other ports, the keyboard logic (`Sources/smk/`) is
shared single-source; only the hardware platform layer (`ports/stm32f4/`) differs — including a
hand-written linker script, since ST's `cmsis-device-f4` ships device headers and startup assembly
but no GCC linker script.

```bash
export CMSIS_F4_PATH=~/cmsis-device-f4
export CMSIS_CORE_PATH=~/CMSIS_6
export TINYUSB_PATH=~/tinyusb

./build_stm32f4.sh
```

See [`CLAUDE.md`'s STM32F4 Prerequisites subsection](CLAUDE.md#stm32f4) for how to obtain and
place the three vendored dependencies these env vars point at.

SMK also targets the **STM32WB** (NUCLEO-WB55RG, Arm Cortex-M4 + an on-chip Cortex-M0+ radio
coprocessor) — USB HID (TinyUSB's `fsdev` driver) + BLE HID (ST's HCI-Layer wireless coprocessor
firmware over a vendored IPCC transport layer, bridged into BTstack), build-only, not yet verified
on real hardware. As with the other ports, the keyboard logic (`Sources/smk/`) is shared
single-source; only the hardware platform layer (`ports/stm32wb/`) differs.

**Read [`CLAUDE.md`'s STM32WB board section](CLAUDE.md#stm32wb-board-nucleo-wb55rg--read-before-flashing-real-hardware-and-before-distributing-a-build)
before flashing real hardware or distributing a build of this port** — it covers an unresolved
license conflict between this repo's GPL-3.0 license and the vendored SLA0044-licensed IPCC
transport files, plus hardware bring-up caveats (placeholder GPIO map, unapplied HSE trim, and the
separate manual CPU2 firmware flashing step).

```bash
export CMSIS_WB_PATH=~/cmsis-device-wb
export CMSIS_CORE_PATH=~/CMSIS_6
export TINYUSB_PATH=~/tinyusb
export BTSTACK_PATH=~/btstack
export STM32CUBEWB_PATH=~/STM32CubeWB

./build_stm32wb.sh
```

See [`CLAUDE.md`'s STM32WB Prerequisites subsection](CLAUDE.md#stm32wb) for how to obtain and
place the five vendored dependencies these env vars point at.

## Tests

The hardware-independent logic (`Sources/SMKCore/`: layer resolution, key-event/debounce
processing, HID report building, JSON config/keymap parsing, LED chain mapping) has a host-side
Swift Testing suite that runs without any embedded toolchain — no ESP-IDF, pico-sdk, or nRF5 SDK
required:

```bash
SMK_HOST_TESTS_ONLY=1 swift test
```

`SMK_HOST_TESTS_ONLY=1` drops `Package.swift`'s hardware-only dependencies (e.g. `swift-mmio`)
entirely, so this resolves and runs on a plain host Swift toolchain. Runs automatically on every
push/PR to `main` via [`.github/workflows/host-tests.yml`](.github/workflows/host-tests.yml).

Everything outside `Sources/SMKCore/` — GPIO register pokes, USB/BLE stack glue, vendor SDK calls —
is hardware-dependent by nature and isn't unit-testable; it's verified by a clean build/link per
target (see each target's build command above) plus code review against the real vendored source,
not by an automated test suite. None of these targets have been exercised on real hardware in
this repo's CI.

## Known Issues / TODOs
- **Battery-level reporting is unverified on real hardware**: the smk_kbd board's VBAT divider (IO4/ADC1_CH4) is now read and reported via the BLE HID Battery Service. The ADC reading itself is calibrated (ESP-IDF's `adc_cali_*` curve-fitting scheme, using the chip's factory eFuse constants), but the voltage-to-percentage curve is still a rough linear approximation, not a real Li-ion discharge curve — that needs charge/discharge data logged from a physical board. See `CLAUDE.md`'s smk_kbd board section for details.
- **nRF52840 port is build-only**: no hardware verification yet, and the board's GPIO pin map in `Sources/smk/Main.swift` is an explicit placeholder that must be replaced before flashing a real board. See [`CLAUDE.md`'s nRF52840 section](CLAUDE.md#nrf52840) (Prerequisites through the "read before flashing real hardware" caveat) for the full list of known gaps (no LE bonding persistence, keymap upload accepted but not yet persisted, uncalibrated software timers).
- **STM32F4 port is build-only, USB HID only, and its bring-up matrix isn't a real keyboard**: no WeAct Black Pill hardware verification yet, and `Sources/smk/Main.swift`'s STM32F4 board branch is a placeholder 5x5 test matrix on GPIOB, not a real layout — no board schematic exists yet (this targets the bare dev board). BLE is out of scope for this pass (a future STM32WB cycle), and the matrix is single-GPIO-port-only for now (`ports/stm32f4/GPIORegisters.swift`'s own header comment explains why). See `CLAUDE.md`'s STM32F4 Prerequisites subsection and `docs/superpowers/specs/2026-08-10-stm32f4-support-design.md`'s Future Work section.
- **STM32WB port has an unresolved license conflict — do not distribute a build.** This repo is GPL-3.0, but the vendored IPCC transport-layer files in `ports/stm32wb/platform/` (`tl_mbox.c`, `shci.c`, `shci_tl.c`, etc., sourced from STM32CubeWB) are licensed under ST's SLA0044, which forbids GPL redistribution. This was flagged during the port and deliberately deferred rather than resolved — see `CLAUDE.md`'s STM32WB board section. The port is also build-only (no NUCLEO-WB55RG hardware verification yet), and its GPIO pin map is a placeholder 5x5 test matrix. Factory HSE capacitor trim is now read from OTP and applied (see `CLAUDE.md`), though unverified against a real board's RF accuracy; CPU2 still requires a separate manual flash of ST's "HCI Layer" wireless-coprocessor firmware that this project's build does not perform.

## IDE Support
To enable code completion and syntax highlighting in VS Code or Xcode:
1. Ensure `Package.swift` is present in the root.
2. The `Package.swift` is configured to point to your local ESP-IDF headers.
3. Restart your Swift Language Server (SourceKit-LSP) after making changes to dependencies.

## License
This project is licensed under the GNU General Public License v3.0 (GPL-3.0).
