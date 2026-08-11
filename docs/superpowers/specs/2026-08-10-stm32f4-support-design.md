# STM32F4 Support

Date: 2026-08-10
Status: Approved, pending implementation plan

## Problem

SMK currently targets ESP32-C6 (RISC-V, ESP-IDF), RP2040/RP2350 (Arm
Cortex-M0+/M33, pico-sdk), and nRF52840 (Arm Cortex-M4F, vendored nRF5
SDK). STM32F4 is one of the most common MCU families in mechanical
keyboard firmware (QMK/ZMK/VIA target it heavily) but has no port here.
This spec adds `ports/stm32f4/`, targeting the WeAct Black Pill (F411 or
F401 variant) as the bring-up board — a bare dev board, not a keyboard
PCB.

Two chip families were requested: STM32F4 and STM32WB. They are sequenced
as separate projects — this spec covers F4 only. STM32WB (adds BLE) is a
later brainstorming cycle once F4's USB HID path is proven, mirroring how
this project sequenced RP2040 (USB HID) before Pico W (adds BLE) and
`smk_kbd_rp2040`.

Out of scope for this pass, deferred to follow-on work (see Future Work):
STM32WB/BLE, a custom STM32F4 keyboard PCB, per-key RGB backlight, wired
HID bridge.

## Feasibility checks already done

- **Swift stdlib for the target triple**: `armv7em-none-none-eabi`
  (soft-float Cortex-M4/M4F) typechecks cleanly against the real Embedded
  Swift stdlib shipped in `swift-6.3.1-RELEASE.xctoolchain` (verified
  directly against that toolchain's `swiftc`, not `-print-target-info`
  alone, which RP2350's spec showed can report false positives). This is
  the same triple already verified working for the nRF52840 port (also
  Cortex-M4F) — no new toolchain risk, this is a re-confirmation on the
  same hardware class.
- **`armv7em-none-none-eabihf` (hard-float) has no shipped stdlib** —
  confirmed by the same probe (`could not find module 'Swift' for target
  'armv7em-none-none-eabihf'`). Same conclusion nRF52840 reached: only the
  soft-float variant is usable, so C-side code must be built
  `-mfloat-abi=soft` to match — no ABI mismatch risk since both sides
  agree on soft-float.
- **ARM toolchain**: `arm-gcc-bin@14` already installed for
  RP2040/nRF52840 supports Cortex-M4: `arm-none-eabi-gcc -mcpu=cortex-m4
  -mthumb -mfloat-abi=soft -print-multi-directory` resolves to a real
  multilib (same one nRF52840 uses, since both are Cortex-M4/M4F
  soft-float). No new ARM toolchain install needed.
- **CMSIS device header + startup/linker script**: STMicroelectronics
  publishes `cmsis_device_f4` (CMSIS-Core device headers, ARM CMSIS
  startup `.s` files, and reference linker scripts for every STM32F4
  variant including F401/F411) as a standalone public GitHub repo,
  separate from the full STM32CubeF4 HAL/LL tree — directly analogous to
  how the nRF52840 port takes only `modules/nrfx/mdk/` from the nRF5 SDK
  and ignores the rest. This is the minimal vendored piece for this port;
  exact repo URL and pinned commit to be confirmed at implementation time.
- **USB peripheral**: F401/F411 (including the Black Pill) expose USB via
  the `OTG_FS` peripheral — a Synopsys DesignWare USB2 OTG core, not the
  simpler `USB_FS` device-only peripheral some smaller STM32 parts have.
  TinyUSB's `dwc2` portable driver (`src/portable/synopsys/dwc2/`) already
  supports STM32F4's OTG_FS/OTG_HS, is mature (also used for ESP32-S2/S3
  in other projects), and is the same TinyUSB dependency already vendored
  for RP2040/nRF52840 — no new USB stack.
- **GPIO register layout**: STM32F4 GPIO is a simple per-port memory-mapped
  block (`MODER`/`OTYPER`/`OSPEEDR`/`PUPDR`/`IDR`/`ODR`/`BSRR`), directly
  analogous in complexity to the existing `GPIORegisters.swift` files —
  `BSRR` (atomic set/reset via a single write, high half-word = reset,
  low half-word = set) maps cleanly onto the established `outSet`/
  `outClear`/`input` API.
- **Clock tree**: F401/F411 boot on the internal 16MHz HSI by default; the
  Black Pill's external HSE crystal (25MHz on most WeAct revisions) plus
  the main PLL must be configured to reach the parts' max core clock
  (84MHz F401 / 100MHz F411) and, critically, to derive a USB-spec-exact
  48MHz for `OTG_FS`. This RCC/PLL sequencing is the highest-risk new
  code in this port — no existing port in this repo has PLL math this
  involved (RP2040/RP2350's clocks are pico-sdk-managed; nRF52840 doesn't
  need a PLL for its USB peripheral). Exact PLL divider values (`PLLM`/
  `PLLN`/`PLLP`/`PLLQ`) depend on the confirmed HSE crystal frequency and
  are deferred to the implementation plan.

## Design

### Chip/core and Swift target triple

Arm Cortex-M4F (F411) or Cortex-M4 (F401), soft-float ABI either way since
that's the only stdlib variant available. Swift target triple:
`armv7em-none-none-eabi`, same as nRF52840. C-side peripheral code compiled
`-mfloat-abi=soft` to match.

### New port directory: `ports/stm32f4/`

Mirrors `ports/nrf52840/`'s shape (hand-rolled `CMakeLists.txt`, no
vendor-SDK CMake integration to piggyback on, unlike RP2040's pico-sdk):

| File | Responsibility |
|---|---|
| `CMakeLists.txt` | Swift toolchain discovery (same real-stdlib-typecheck probe pattern as the other two hand-rolled ports), links against vendored `cmsis_device_f4` |
| `GPIORegisters.swift` | STM32F4 GPIOA–GPIOx port register blocks, same `outSet`/`outClear`/`input` API as the other three targets, backed by `BSRR` |
| `ClockInit.swift` | RCC/PLL bring-up: HSE→PLL→SYSCLK, plus the USB-clock (48MHz) derivation via `PLLQ`. Highest-risk new Swift in this port — see Feasibility checks above |
| `GPIOInit.swift` | `init_keyboard_pins()` — matrix row/column pin config via direct register writes, same responsibility as the other ports' equivalents |
| `UsbHid.swift` | TinyUSB `dwc2` driver init + `send_wired_report()`, same role as `ports/rp2040/UsbHid.swift` |
| `PlatformConfig.swift` | board/connection-mode config, `kb_log`, delay loop — same role as `ports/rp2040/PlatformConfig.swift` |
| `BridgingHeader.h` | C declarations for Swift, same role as the other ports' |
| `platform/usb_descriptors.c` | TinyUSB HID descriptors, same shape as RP2040's |
| `platform/platform_glue.c` | `main()`, Swift stdlib stubs, `posix_memalign` — the non-portable remainder, same split as RP2040/nRF52840 |
| Vendored (C, minimal) | `cmsis_device_f4` device header, CMSIS startup `.s`, linker script — the only vendored C, matching this project's established minimal-vendoring pattern |

### Build system

`build_stm32f4.sh` (new, sibling to `build_rp2040.sh`/pattern established
by nRF52840's `build_nrf52840.sh`): takes a `CMSIS_F4_PATH` env var
(mirroring `NRFX_PATH`'s pattern) pointing at a plain git checkout of
`cmsis_device_f4`. `CMakeLists.txt` compiles the vendored startup/linker
files directly — no ST-provided build system (no CubeMX/CubeIDE project,
no `west`) to integrate with.

### Board

WeAct Black Pill only for this pass — F411 or F401 variant (exact variant
and HSE crystal frequency to confirm at implementation time from the
board's actual silkscreen/revision, since WeAct has shipped both 25MHz and
8MHz HSE crystal revisions historically). No keyboard matrix — this is a
bring-up target, same role `pico` played before `smk_kbd_rp2040` existed:
verify clock bring-up, GPIO, and USB HID enumeration on a minimal test
setup (a handful of GPIO-wired switches), not a real keyboard.

### Explicitly unchanged / reused

`Sources/SMKCore/` (all of it — pure logic, chip-agnostic),
`Sources/smk/Main.swift`'s board-selection `#if` pattern (extends with a
new `SMK_BOARD_STM32F4_BLACKPILL`-style flag), TinyUSB's shared
descriptor/report-building conventions, the `outSet`/`outClear`/`input`
GPIO API shape.

### Docs

- Add an STM32F4 row to the target table in `CLAUDE.md`, alongside the
  Prerequisites section documenting `CMSIS_F4_PATH`.
- Mention `./build_stm32f4.sh` in `README.md`.

## Future Work (deferred from this cycle)

1. **STM32WB BLE support** — separate future brainstorming cycle (agreed
   sequencing: F4 first, WB second). BTstack-based; likely mirrors the
   RP2040 Pico W / `smk_kbd_rp2040` dual-transport pattern once F4's
   USB-only path is proven on hardware.
2. **Custom STM32F4 keyboard PCB** — this cycle targets the bare Black
   Pill dev board with a minimal test matrix; a real keyboard PCB
   (schematic, GPIO map, `SMK_TARGET_BOARD`-style board config) is a
   follow-on once USB HID + matrix scan are verified on hardware.
3. **Per-key RGB backlight** — SK6812MINI-E chain driver would need an
   STM32 timer/DMA-based bit-timing driver (this project's precedent: RMT
   on ESP32-C6, PIO on RP2040) — no STM32 timer/DMA approach chosen yet.
4. **Wired-HID bridge** (CH9350-style) — only relevant if a future
   STM32-based board design includes one; no current board target needs
   it.

## Testing

Build-only: `./build_stm32f4.sh` needs to produce a clean `.elf`/`.bin`
for the USB HID path. No flash, no hardware verification in this pass —
no Black Pill hardware confirmed on hand yet. The clock-tree bring-up
(`ClockInit.swift`) is the least-proven piece of this design: PLL divider
math can be checked arithmetically against the datasheet's constraints
(VCO input 1–2MHz, VCO output 100–432MHz, USB output must be exactly
48MHz) at build-review time, but only real hardware confirms the chip
actually reaches lock and produces spec-accurate USB timing. Flash/HID
verification deferred to a future session once hardware is available.
