# STM32WB Support

Date: 2026-08-11
Status: Approved, pending implementation plan

## Problem

SMK currently targets ESP32-C6, RP2040/RP2350, nRF52840, and STM32F4
(USB HID only, no BLE). STM32WB is the second half of the two-part STM32
addition agreed when STM32F4 was scoped (`docs/superpowers/specs/2026-08-10-stm32f4-support-design.md`'s
Future Work #1) — it adds BLE, which F4's cycle deliberately deferred. This
spec adds `ports/stm32wb/`, targeting ST's official NUCLEO-WB55RG dev
board — a bare bring-up board, not a keyboard PCB, same role the Black
Pill played for F4.

Out of scope for this pass, deferred to follow-on work (see Future Work):
a custom STM32WB keyboard PCB, per-key RGB backlight, LE bonding
persistence across reboots.

## Feasibility checks already done

- **Chip architecture**: STM32WB55 is a dual-core MCU — an Arm Cortex-M4
  application processor (CPU1, where all of this project's code runs,
  64MHz) and a separate Arm Cortex-M0+ network/radio processor (CPU2,
  32MHz) that runs ST's own wireless-protocol firmware. This is a materially
  different shape from every existing BLE-capable port in this project:
  nRF52840's SoftDevice Controller and RP2040's CYW43439 are both
  single-purpose radio *controllers* the application core drives directly
  or over UART; STM32WB's CPU2 is a full second application processor
  running ST's own firmware image, talked to over an on-chip IPCC
  (Inter-Processor Communication Controller) mailbox rather than a simple
  function-call or UART interface.
- **CPU2 firmware mode — the central architecture decision**: CPU2 must be
  flashed with one of two ST-provided prebuilt wireless-coprocessor
  binaries (confirmed via STM32CubeWB's own release notes and community
  documentation):
  1. **"Full Stack"** (`stm32wb5x_BLE_Stack_full_fw.bin`) — CPU2 runs the
     complete BLE host (GAP/GATT/SM) *and* controller; CPU1 talks to it via
     ST's own high-level host-command API. Would introduce a **third** BLE
     host stack into this project (alongside NimBLE on ESP32-C6 and BTstack
     everywhere else) and pull in more of ST's STM32CubeWB middleware
     directly — a bigger step away from this project's minimal-vendoring
     pattern.
  2. **"HCI Layer"** (`stm32wb5x_BLE_HCILayer_extended_fw.bin`) — CPU2 runs
     only the link-layer/controller; the full BLE host runs on CPU1. **Chosen
     approach** — keeps this project on one BLE host stack (BTstack) across
     every ARM port, matching RP2040 and nRF52840's precedent exactly.
- **Transport layer**: unlike nRF52840's SoftDevice Controller (which
  exposes generic HCI bytes BTstack's existing transport abstraction binds
  to directly, needing only a thin `hci_transport_t` glue struct), STM32WB's
  CPU1↔CPU2 link uses ST's own IPCC mailbox protocol — a shared-RAM table
  structure (`TL_CmdPacket_t`/`TL_PacketHeader_t`) with its own boot
  handshake (`SHCI_C2_Init` → `SHCI_C2_BLE_Init` → wait for a
  `SHCI_SUB_EVT_CODE_READY` event) and per-channel IPCC interrupt signaling.
  No ready-made BTstack IPCC transport exists (confirmed: an open BTstack
  GitHub feature request for exactly this, still unresolved as of this
  spec). Rather than hand-roll this fiddly, timing-sensitive protocol from
  scratch, this design **vendors and adapts ST's own transport-layer files**
  (`tl_mbox.c`, `shci.c`, `hci_tl.c`, from STM32CubeWB's
  `Middlewares/ST/STM32_WPAN/interface/patterns/ble_thread/`) — the same
  move this project already made for nRF52840's `hci_internal.c` (vendor
  the fiddly protocol dispatcher, Swift wraps the edges around it). This
  keeps the risk profile close to nRF52840's already-proven approach rather
  than inventing a new transport layer from zero.
- **USB**: STM32WB55 has a USB 2.0 FS **device-only** peripheral (`USB_FS`,
  8 endpoints, integrated FS PHY) — confirmed via ST's own USB hardware
  guidelines. This is the simpler classic STM32 USB peripheral type (shared
  across F0/F1/F3/L0/G0/G4), **not** F4's `dwc2` OTG core — TinyUSB's
  `dcd_stm32_fsdev` driver covers it. This means the port can offer wired
  USB HID as a baseline alongside BLE, matching every other port's pattern,
  rather than being BLE-only.
- **Swift toolchain / clock tree**: same Cortex-M4 core family as
  nRF52840/F4 (`armv7em-none-none-eabi`, soft-float, already re-verified
  twice this project). WB55's clock tree needs its own PLL math (HSE is
  typically 32MHz on NUCLEO-WB55RG, and a dedicated 48MHz USB clock source
  exists separately from the main SYSCLK PLL, unlike F4 which derives both
  from the same PLL via PLLQ) — exact values deferred to the implementation
  plan's own research pass, following F4's precedent of confirming register
  offsets against the real CMSIS headers rather than assuming them here.
- **CMSIS device support**: STMicroelectronics publishes a
  `cmsis-device-wb` repo (device headers + startup assembly), the same
  split as F4's `cmsis-device-f4` — paired with the same `CMSIS_6` (ARM
  core headers) dependency already vendored for F4. No new linker-script
  source either: same as F4, this will need a hand-written GCC linker
  script (confirmed pattern: ST's CMSIS device repos don't ship one).

## Design

### Chip/core and Swift target triple

Arm Cortex-M4 (CPU1 only — CPU2 runs ST's own firmware, not user code),
soft-float ABI. Swift target triple: `armv7em-none-none-eabi`, same as
nRF52840 and STM32F4.

### New port directory: `ports/stm32wb/`

Mirrors `ports/stm32f4/`'s shape, with the CPU2/mailbox pieces added:

| File | Responsibility |
|---|---|
| `CMakeLists.txt` | Swift toolchain discovery (same pattern as F4/nRF52840), links against vendored `cmsis-device-wb` + `CMSIS_6` |
| `linker/*.ld` | Hand-written GCC linker script for WB55's flash/RAM map (no vendor-shipped one, same as F4) |
| `GPIORegisters.swift`, `GPIOInit.swift`, `ClockInit.swift` | Same shape as the F4 port's equivalents — direct-register Swift |
| `UsbHid.swift` | TinyUSB `fsdev` driver glue, mirrors F4's `UsbHid.swift` shape (different underlying TinyUSB driver, same Swift-glue pattern) |
| `platform/tl_mbox.c`, `platform/shci.c`, `platform/hci_tl.c` | **Vendored + adapted** from STM32CubeWB's `Middlewares/ST/STM32_WPAN/interface/patterns/ble_thread/` — the IPCC mailbox transport layer and CPU2 boot/system-command protocol. Kept in C per this project's "vendored/adapted third-party protocol machinery stays C" precedent (nRF52840's `hci_internal.c`). |
| `platform/ble_hid_wb.c` + `BleHidWb.swift` | CPU2 release + `SHCI_C2_Init`/`SHCI_C2_BLE_Init` boot sequence, `hci_transport_t` bridging the vendored mailbox layer into BTstack, then BTstack HID-over-GATT — same shape as `ports/nrf52840/platform/ble_hid_sdc.c` |
| `platform/tusb_config.h`, `platform/usb_descriptors.c` | Same role as every other port's — `usb_descriptors.c` is board-independent, likely an unmodified copy |

### Build system

`build_stm32wb.sh` (new, sibling to `build_stm32f4.sh`): takes
`CMSIS_WB_PATH`, `CMSIS_CORE_PATH` (reused from F4), `TINYUSB_PATH`
(reused), `BTSTACK_PATH` (reused from nRF52840), and a new
`STM32WB_COPRO_FW_PATH` pointing at STM32CubeWB's
`Projects/STM32WB_Copro_Wireless_Binaries/STM32WB5x/` directory — the
prebuilt CPU2 "HCI Layer" firmware image gets flashed to CPU2's own flash
region separately from CPU1's application build (a real two-image flashing
step, not something `build_stm32wb.sh` alone produces — documented in the
implementation plan's own flashing instructions, deferred since this pass
is build-only).

### Board

ST NUCLEO-WB55RG only for this pass — the official, best-documented WB55
dev board, same bring-up role the Black Pill played before any real F4
keyboard PCB existed. No keyboard matrix — bring-up target only (minimal
test matrix, GPIO port TBD in the implementation plan, following F4's
single-GPIO-port precedent unless `KeyMatrix.swift` gains multi-port
support first).

### Explicitly unchanged / reused

`Sources/SMKCore/` (all of it), `Sources/smk/Main.swift`'s board-selection
`#if` pattern (new `SMK_BOARD_STM32WB_NUCLEO`-style flag), BTstack's
existing HID-over-GATT service definitions (`smk_hid.gatt`, already shared
across RP2040/nRF52840 — reused verbatim), TinyUSB's shared
descriptor/report-building conventions.

### Docs

- Add an STM32WB row to the target table in `CLAUDE.md`, alongside the
  Prerequisites section documenting the four vendor env vars.
- Mention `./build_stm32wb.sh` in `README.md`.

## Future Work (deferred from this cycle)

1. **Custom STM32WB keyboard PCB** — this cycle targets the bare
   NUCLEO-WB55RG with a minimal test matrix; a real keyboard PCB is a
   follow-on once USB HID + BLE + matrix scan are verified on hardware.
2. **Per-key RGB backlight** — same status as F4's: no STM32 timer/DMA
   bit-timing driver chosen yet.
3. **LE bonding persistence across reboots** — no persistent bonding-info
   storage design chosen yet; same class of gap nRF52840's BLE port
   already has.

## Testing

Build-only: `./build_stm32wb.sh` needs to produce a clean CPU1 application
image. CPU2's wireless-coprocessor firmware is ST's own prebuilt binary
(not built by this project), flashed separately — no hardware on hand to
verify the two-image flash + CPU2 boot handshake actually completes. The
IPCC mailbox transport layer (`tl_mbox.c`/`shci.c`/`hci_tl.c` adaptation)
is the least-proven piece of this design, by a wide margin — none of it has
been exercised even at a "does it link" level yet, and unlike F4's clock
math (checkable by arithmetic alone) or nRF52840's SDC (a simpler generic-HCI
transport), this is genuinely novel, timing-sensitive protocol code for
this project. Flash/HID/BLE verification deferred to a future session once
hardware is available.
