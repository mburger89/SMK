# SMK — RP2040 / RP2350 (Pico / Pico W / Pico 2 / Pico 2 W) Port

Embedded-Swift keyboard firmware targeting the **Raspberry Pi Pico** (RP2040), **Raspberry Pi Pico W** (RP2040 + CYW43439), and their RP2350-based successors **Pico 2** / **Pico 2 W** (build-only for now — not yet verified on real hardware).

## How it fits the repo

The shared Swift sources (`Sources/smk/`) are reused unchanged. This port provides an RP2040-specific platform layer that satisfies the same Swift↔C contract as the ESP32 build.

| Component | RP2040 implementation |
|---|---|
| GPIO scan | SIO memory-mapped registers (`GPIORegisters.swift`), init via `hardware/gpio.h` |
| "Wired" HID | Native USB HID via TinyUSB (replaces CH9350 UART) |
| BLE HID | BTstack HID-over-GATT on Pico W; no-op stub on plain Pico |
| Logging | `printf` over USB-CDC stdio |
| Delay / yield | `sleep_ms` + `tud_task` pump |

## Prerequisites

| Tool | Install |
|---|---|
| pico-sdk ≥ 2.x | `git clone https://github.com/raspberrypi/pico-sdk ~/pico-sdk && git -C ~/pico-sdk submodule update --init` |
| arm-none-eabi-gcc | `brew install arm-none-eabi-gcc` |
| Swift ≥ 6.3 (Embedded) | Download from swift.org |
| cmake ≥ 3.29, ninja | `brew install cmake ninja` |
| picotool (optional) | `brew install picotool` |

RP2350 (`pico2`/`pico2_w`) additionally requires a Swift development-snapshot toolchain (confirmed:
`swift-DEVELOPMENT-SNAPSHOT-2026-05-27-a` or later) that ships a real Embedded-Swift stdlib for
`armv8m.main-none-none-eabi` (RP2350's Cortex-M33 target). Released `swift-6.3.x` toolchains report
support for that triple via `-print-target-info` but fail an actual compile — they don't ship the
stdlib.

## Build

```bash
# From the repo root:
export PICO_SDK_PATH=~/pico-sdk

# Plain Pico (RP2040) — USB HID only
./build_rp2040.sh pico

# Pico W (RP2040) — USB HID + BLE scaffolded
./build_rp2040.sh pico_w

# Pico 2 (RP2350) — USB HID only
./build_rp2040.sh pico2

# Pico 2 W (RP2350) — USB HID + BLE scaffolded
./build_rp2040.sh pico2_w
```

Or invoke CMake directly:

```bash
cmake -G Ninja -B build_rp2040 -S ports/rp2040 -DPICO_BOARD=pico
ninja -C build_rp2040
```

The build produces `build_rp2040_<board>/smk_rp2040.uf2`.

## Flash

Hold **BOOTSEL**, plug USB, release. The board mounts as a mass-storage device. Then:

```bash
# Drag-and-drop:
cp build_rp2040_pico/smk_rp2040.uf2 /Volumes/RPI-RP2/

# Or via picotool:
picotool load -f build_rp2040_pico/smk_rp2040.uf2
```

## Pico W — Wireless

On Pico W the firmware starts USB HID immediately. `toggle_conn` (the `toggle_conn` keymap action) switches the active transport:

- **Wired** (default) → USB HID reports
- **Bluetooth** → BLE HID-over-GATT; the board advertises as "SMK Keyboard"

BLE bonding credentials are not yet persisted across power cycles (scaffolded — see `BleHidPicoW.swift`).

## Pin assignments

Pin numbers in the keymap JSON map directly to GP (GPIO) numbers on the Pico pinout. The default layout in `Sources/smk/Main.swift` uses GP0–GP23; adjust `rows`/`cols` in `configJson` to match your wiring.

## Differences from the ESP32 build

RP2350 (Pico 2 / Pico 2 W) shares this entire platform layer with RP2040 — same register layout,
same platform C sources, same Swift↔C contract. The only difference is the Swift compile target
(Armv6-M vs. Armv8-M/Cortex-M33) and toolchain requirement noted above.

| | ESP32-C6 | RP2040 / RP2350 |
|---|---|---|
| Build system | ESP-IDF / `idf.py` | CMake / Ninja |
| HID transport | BLE (NimBLE) + wired (CH9350 UART) | USB HID (TinyUSB) + BLE (BTstack, `_w` boards only) |
| GPIO registers | `0x60091000` | SIO `0xD0000000` |
| RTOS | FreeRTOS | none (cooperative) |
| Entry point | `app_main()` → `app_main_swift()` | `main()` → `app_main_swift()` |
