# nRF52840 Support

Date: 2026-08-09
Status: Approved, pending implementation plan

## Problem

SMK currently targets ESP32-C6 (RISC-V, ESP-IDF) and RP2040/RP2350 (Arm
Cortex-M0+/M33, pico-sdk). Nordic's nRF52840 (Arm Cortex-M4F) is the most
common chip for BLE keyboards specifically — the CYW43439-over-UART
approach `smk_kbd_rp2040` uses is comparatively unusual — because nRF52840
has much better BLE power efficiency than either existing target's
radio combo. This spec adds it as a new port, `ports/nrf52840/`, alongside
the existing two.

Out of scope: any custom nRF52840 PCB analogous to `smk_kbd_rp2040` —
deferred until such a board exists, same reasoning as RP2350's spec used
for its own future chip-down board. This spec covers only the stock
`nrf52840dk` (Nordic's official PCA10056 dev kit), build-only — no
hardware on hand, so no flash/HID/BLE verification. USB HID is included in
this pass (TinyUSB, low risk per the checks below); BLE HID is included in
scope but is the least-proven piece — see Testing.

## Feasibility checks already done

- `swiftc -target armv7em-none-none-eabi -enable-experimental-feature
  Embedded -parse-as-library -typecheck` (a real stdlib typecheck, not
  just `-print-target-info` — RP2350's spec already established that
  `-print-target-info` alone can report success on a triple with no
  shipped stdlib) succeeds on **every** installed toolchain: both
  `swift-6.3.1-RELEASE` and `swift-6.3.2-RELEASE`, the
  `swift-DEVELOPMENT-SNAPSHOT-2026-05-27-a` snapshot, and `swift-latest`.
  Unlike RP2350 (Cortex-M33, needed the dev snapshot specifically), no
  toolchain gate/probe restriction is needed here — any installed
  toolchain works.
- Only the soft-float variant (`armv7em-none-none-eabi`) has a shipped
  stdlib on any installed toolchain — `armv7em-none-none-eabihf` and
  `thumbv7em-none-none-eabi` both fail with "could not find module
  'Swift' for target". This is not a limitation in practice: Nordic's own
  prebuilt SoftDevice Controller library ships a **soft-float** variant
  too (see below), so there's no ABI mismatch to design around, unlike
  RP2350 where the Cortex-M33 FPU forced a `softfp` C-side convention to
  match pico-sdk's prebuilt objects.
- `arm-gcc-bin@14` already supports the matching multilib:
  `arm-none-eabi-gcc -mcpu=cortex-m4 -mthumb -mfloat-abi=soft
  -print-multi-directory` → `thumb/v7e-m/nofp` (confirmed present via
  `-print-multi-lib`). No new ARM toolchain install needed, same as
  RP2350.
- TinyUSB has a mature `nrf5x` device-controller driver
  (`src/portable/nordic/nrf5x/dcd_nrf5x.c`), actively used across
  Adafruit's nRF52 Arduino core, MicroPython, and others, with USB
  compliance test coverage. Same integration shape as the existing RP2040
  TinyUSB port.
- BLE: three real options exist, researched and compared —
  1. Nordic's classic SoftDevice (S140) — mature, full-featured, what ZMK
     uses — but a closed blob talked to via Nordic's own SVC-call API, an
     entirely different integration shape from NimBLE/BTstack. Nothing
     from the existing ports reuses here.
  2. BTstack's own open-source "Cinnamon" Controller/Link-Layer
     (`port/nrf5-cinnamon` in the BTstack repo) — no Nordic blob at all,
     but its last functional commit is from 2021, and its own README
     states Peripheral-only with **encryption "planned but not supported
     yet."** Not viable for a keyboard: unencrypted keystrokes are a real
     security problem, not just a inconvenience.
  3. **Nordic's SoftDevice Controller (SDC)**, from the public
     `nrfconnect/sdk-nrfxlib` repo — the modern replacement Nordic itself
     recommends over classic SoftDevice, and what current-generation
     firmware (e.g. Rust's RMK, migrated off classic SoftDevice
     specifically for this) uses. A prebuilt static library, but unlike
     classic SoftDevice it exposes **standard HCI** — the same kind of
     interface BTstack already speaks to CYW43439 over UART in
     `smk_kbd_rp2040`. **Chosen approach** — see Design.
- SDC + its required MPSL (Multiprotocol Service Layer) dependency are
  both prebuilt static libraries checked directly into
  `nrfconnect/sdk-nrfxlib` (a plain git repo, no `west`/Zephyr/full nRF
  Connect SDK install needed) — confirmed via the GitHub API:
  `softdevice_controller/lib/nrf52/soft-float/libsoftdevice_controller_peripheral.a`
  (~260KB) and `mpsl/lib/nrf52/soft-float/libmpsl.a` (~85KB) both exist,
  Peripheral-role-only variant (matches this project's needs — a keyboard
  never needs Central role). Both are single-firmware-image libraries
  (unlike CYW43439, there's no separate flash step or physical link — SDC
  runs in the same image, same core, as the application).
- Licensing: `LicenseRef-Nordic-5-Clause` — permits redistribution in
  binary form specifically "as embedded into a Nordic Semiconductor ASA
  integrated circuit in a product," which is exactly this use case.
  Comparable in spirit to how `cyw43439_patchram.c`'s vendor firmware data
  is already embedded in this repo.
- GPIO register layout: nRF52840's GPIO peripheral is a simple
  memory-mapped register block (`OUT`/`OUTSET`/`OUTCLR`/`IN`/`PIN_CNF[]`
  per port), directly analogous in complexity to the existing
  `GPIORegisters.swift` files — low risk, not independently verified
  against real hardware here (build-only pass).

## Design

### Chip/core and Swift target triple

Arm Cortex-M4F, soft-float ABI. Swift target triple:
`armv7em-none-none-eabi`. No FPU codegen on the Swift side (matches the
only stdlib variant that exists); C-side peripheral/SDC code compiled with
`-mfloat-abi=soft` to match — no ABI-mismatch risk since both sides agree
on soft-float, unlike RP2350's situation.

### New port directory: `ports/nrf52840/`

Mirrors `ports/rp2040/`'s shape:

| File | Responsibility |
|---|---|
| `CMakeLists.txt` | Swift toolchain discovery (same real-stdlib-typecheck probe pattern as `ports/rp2040/CMakeLists.txt`, simpler here since no per-board triple branching is needed), links against vendored `nrfx` (GPIO/peripheral register HAL) and `sdk-nrfxlib` (SDC + MPSL) |
| `GPIORegisters.swift` | nRF52840 GPIO0/GPIO1 port register blocks, same `outSet`/`outClear`/`input` API as the other two targets |
| `BridgingHeader.h` | C declarations for Swift, same role as the RP2040 port's |
| `platform/gpio_init.c` | `init_keyboard_pins()` via `nrfx_gpio`/direct register writes |
| `platform/usb_hid.c` | TinyUSB `nrf5x` device driver init + `send_wired_report()` |
| `platform/usb_descriptors.c` | TinyUSB HID descriptors, same shape as RP2040's |
| `platform/ble_hid_sdc.c` | MPSL init → SDC init/enable (Peripheral role) → the new HCI shim below → `init_ble_hid()`/`send_keyboard_report()` |
| `platform/sdc_hci_shim.c` | **New component, no equivalent in the existing ports.** SDC's HCI is callback/function-call based (`sdc_hci_cmd_put`/`sdc_hci_data_put` plus an enable-time callback that fires when HCI event/data bytes are ready), not a physical UART link like CYW43439's. This shim feeds BTstack's HCI transport layer from those calls directly (in-memory), instead of reusing `ble_hid_kbd_uart.c`'s UART H4 transport code. |
| `platform/platform_glue.c` | `kb_log`, `vTaskDelay` shim, `main()`, Swift stdlib stubs — same role as RP2040's |

### Build system

`build_nrf52840.sh` (new, sibling to `build_rp2040.sh`): takes a
`NRFX_PATH` and `NRFXLIB_PATH` env var (mirroring `PICO_SDK_PATH`'s
pattern) pointing at plain git checkouts of `NordicSemiconductor/nrfx` and
`nrfconnect/sdk-nrfxlib`. `CMakeLists.txt` links the soft-float
`libsoftdevice_controller_peripheral.a` and `libmpsl.a` straight from
`sdk-nrfxlib`'s checked-in prebuilt paths — no `west`/Zephyr build step.

### Board

`nrf52840dk` only for this pass (Nordic's PCA10056 reference dev kit) —
the bring-up board, same role `pico` played before `smk_kbd_rp2040`
existed. GPIO pin map deferred to the implementation plan (needs the
DK's schematic, not looked up in this spec).

### Explicitly unchanged / reused

`Sources/SMKCore/` (all of it — pure logic, chip-agnostic),
`Sources/smk/Main.swift`'s board-selection `#if` pattern (extends with a
new `SMK_BOARD_NRF52840DK`-style flag, same shape as
`SMK_BOARD_KBD_RP2040`), TinyUSB's shared descriptor/report-building
conventions.

### Docs

- Add an nRF52840 row to the target table in `CLAUDE.md`, alongside the
  Prerequisites section documenting `NRFX_PATH`/`NRFXLIB_PATH`.
- Mention `./build_nrf52840.sh` in `README.md`.

## Testing

Build-only: `./build_nrf52840.sh` needs to produce a clean `.hex`/`.elf`
for both the USB HID and BLE HID paths. No flash, no hardware HID/BLE
verification — no nRF52840 hardware on hand. The BLE path in particular
(SDC + MPSL + the new HCI shim) is the least-proven piece of this design —
none of it has been exercised even at a "does it link" level yet, unlike
the GPIO/USB pieces which lean on well-trodden TinyUSB/register-block
patterns. Flash/HID/BLE verification deferred to a future session once
hardware is available.
