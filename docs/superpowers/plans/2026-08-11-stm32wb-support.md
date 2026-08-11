# STM32WB Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ports/stm32wb/` as a new SMK build target for ST's NUCLEO-WB55RG (Arm Cortex-M4 application core; the on-chip Cortex-M0+ runs ST's own prebuilt wireless firmware, not our code), covering USB HID and BLE HID, build-only (no hardware on hand).

**Architecture:** New port directory mirroring `ports/stm32f4/`'s shape for the non-BLE pieces (GPIO, clock, USB HID via TinyUSB's `fsdev` driver — WB55's USB peripheral is the classic device-only type, not F4's `dwc2` OTG core). BLE is the novel piece, architecturally unlike every existing port: CPU2 (the on-chip M0+) is flashed with ST's prebuilt "HCI Layer" wireless-coprocessor firmware (link-layer/controller only, no host), and CPU1 (where all our code runs) hosts the full BLE stack via BTstack — same shape as RP2040/nRF52840's BLE ports. The CPU1↔CPU2 link uses ST's own IPCC (Inter-Processor Communication Controller) mailbox protocol, which has no ready-made BTstack transport; rather than hand-roll it, this plan vendors and adapts ST's own transport-layer files (`tl_mbox.c`, `shci.c`, `hci_tl.c`, and their supporting files) from a pinned STM32CubeWB release, the same "vendor the fiddly protocol dispatcher, Swift wraps the edges" move already used for nRF52840's `hci_internal.c`.

**Tech Stack:** Embedded Swift (`armv7em-none-none-eabi`), `arm-gcc-bin@14`, CMake/Ninja, STMicroelectronics' `cmsis-device-wb` (device headers + startup assembly — no GCC linker script, same gap as `cmsis-device-f4`), ARM's `CMSIS_6` (reused from the STM32F4 port), TinyUSB (`fsdev` device-controller driver), BTstack (reused from RP2040/nRF52840), and STM32CubeWB's IPCC/mailbox transport-layer sources (vendored at a pinned release, not the whole SDK).

## Global Constraints

- **Build-only**: no NUCLEO-WB55RG hardware confirmed on hand. No flash/HID/BLE verification — every task's regression check is "does it build and link cleanly." CPU2's wireless-coprocessor firmware is ST's own prebuilt binary, flashed to CPU2's flash region separately from this project's CPU1 build — this plan does not build or flash it, only documents where to get it.
- **Board**: NUCLEO-WB55RG only, this pass. HSE = 32MHz (confirmed: this board's crystal, and the STM32WB55's default SYSCLK source is HSE directly at 32MHz — no PLL is required to reach a usable CPU1 clock, unlike STM32F4's port, which needed the PLL specifically to also derive a USB-accurate 48MHz. WB55's USB clock instead comes from the internal HSI48 oscillator, trimmed by the CRS (Clock Recovery System) peripheral — a different mechanism from F4's PLLQ tap, confirmed via `cmsis-device-wb`'s `RCC_TypeDef` (real `CRRCR`/`CFGR` register fields exist for this) during this plan's research.
- **Chip/ABI**: Arm Cortex-M4 (CPU1 only — CPU2 runs ST's own firmware image, never user Swift/C code), soft-float, `armv7em-none-none-eabi` — same triple already verified working for STM32F4/nRF52840 on this session's toolchain, re-used without re-verification since it's the identical core family.
- **Vendor dependencies**, five plain git-clonable/downloadable directories referenced by env vars (same pattern as the other ports):
  - `CMSIS_WB_PATH` → `git clone https://github.com/STMicroelectronics/cmsis-device-wb`. Only `Include/` (device headers) and the GCC startup assembly under `Source/Templates/gcc/` are used. Same no-linker-script gap as `cmsis-device-f4` (this plan hand-writes one).
  - `CMSIS_CORE_PATH` → already required by the STM32F4 port (`~/CMSIS_6`), reused unmodified.
  - `TINYUSB_PATH` → already required by every other port, reused unmodified.
  - `BTSTACK_PATH` → already required by RP2040/nRF52840, reused unmodified.
  - `STM32CUBEWB_PATH` → `git clone --branch v1.24.0 https://github.com/STMicroelectronics/STM32CubeWB` (a specific pinned tag — the `master` branch has since migrated `Middlewares/ST/STM32_WPAN` to a git submodule pointing at `STMicroelectronics/stm32-mw-wpan`, whose current content targets the newer, architecturally different single-core STM32WBA family and no longer contains the dual-core WB55 transport-layer files this plan needs — confirmed by inspecting that submodule's tree during this plan's research and finding no `tl_mbox`/`shci`/`hci_tl` files anywhere in it. `v1.24.0` is the pinned tag where `Middlewares/ST/STM32_WPAN/interface/patterns/ble_thread/{tl,shci}/` still exists directly in-repo, confirmed by directory listing during this plan's research). Only that one subdirectory (plus, for reference during Task 7, the `Projects/P-NUCLEO-WB55.Nucleo/Applications/BLE/BLE_Hid/` example) is used — not the whole SDK.
- **CPU2 firmware mode**: ST's "HCI Layer" wireless-coprocessor binary (`stm32wb5x_BLE_HCILayer_extended_fw.bin`, from `STM32CUBEWB_PATH/Projects/STM32WB_Copro_Wireless_Binaries/STM32WB5x/`) — CPU2 runs only the BLE link-layer/controller; the full host (GAP/GATT/SM) runs on CPU1 via BTstack. This is the one architectural decision this plan does not revisit — see the design spec's Feasibility checks for why "Full Stack" firmware (CPU2 running the complete host too) was rejected (would introduce a third BLE host stack into this project).
- **Mailbox tables must live in SRAM2A** (`0x2003_0000`, 32KB — confirmed via `cmsis-device-wb`'s `SRAM2A_BASE` `#define` during this plan's research), the region both CPU1 and CPU2 can access. This plan's linker script places a dedicated section there via a `MAILBOX_RAM` memory region; Task 6 wires the vendored `tl_mbox.c`'s buffer declarations into it via `__attribute__((section(...)))`, matching how STM32CubeWB's own example projects place them.
- **Bare-metal cross-compile CMake boilerplate**: `CMAKE_SYSTEM_NAME Generic`/`CMAKE_SYSTEM_PROCESSOR arm`/`CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY` before `project()` — same fix already required by the nRF52840 and STM32F4 ports.
- **Matrix bring-up is single-port only**, same reasoning and same GPIOB choice as the STM32F4 port (`Sources/smk/KeyMatrix.swift`'s shared scan loop assumes one flat 32-bit GPIO bank). Revisit when a real STM32WB keyboard PCB is designed.
- **`--specs=nosys.specs` + `posix_memalign`/`_init` stubs are needed from Task 1 onward**, same real finding already hit and fixed during the STM32F4 port's Task 1 — apply it from the start here instead of rediscovering it.
- **TinyUSB symbol names**: use the real exported symbols (`tusb_rhport_init`, `tud_task_ext`, `tud_hid_n_ready`, `tud_hid_n_keyboard_report`), not the macro/`static inline` names — same trap already documented and fixed in the nRF52840 and STM32F4 ports.
- **`Main.swift`'s `init_wired_link`/`send_wired_report` have no `@_extern` fallback anywhere in the project** — every board now backs them natively in Swift. Task 4 must create `UsbHid.swift` (even as a stub) in the SAME task that wires up `Sources/smk`, or that task's build will fail to compile, not just "link but not work" — a real finding from executing the STM32F4 port's Task 4 that applies identically here.
- **`Sources/SMKCore/KeymapProtocol.swift`'s `smk_keymap_dispatch_packet` `@_cdecl` wrapper is behind a per-target `#if` guard** that must include `SMK_TARGET_STM32WB` — same real finding from the STM32F4 port's Task 5; add this board's flag to that guard as part of Task 5 here (USB HID), not left for BLE's Task 7, since USB's `usb_descriptors.c` calls it too.
- **`Sources/SMKCore/` is reused unmodified.**
- **New project code favors Swift over C wherever the C calling convention allows it** — same precedent as every other port. This does **not** extend to: the C `main()` stub, the CMSIS startup assembly, `usb_descriptors.c` (macro-computed TinyUSB descriptor tables), or the vendored/adapted IPCC mailbox transport files (Task 6) — porting ST's own timing-sensitive protocol dispatcher to Swift would defeat the point of reusing it, same reasoning nRF52840's `hci_internal.c` exception already established. The CPU2 boot sequence and `hci_transport_t` glue *around* those vendored files (Task 7) stay C only where they call directly into the vendored API; the BTstack GATT/HID callback bodies inside that glue port to Swift `@_cdecl` functions where the calling convention allows it, same split as `ports/nrf52840/platform/ble_hid_sdc.c`.

---

### Task 1: Vendor CMSIS-WB + hand-written linker script + toolchain discovery + minimal smoke test

**Files:**
- Create: `ports/stm32wb/CMakeLists.txt`
- Create: `ports/stm32wb/linker/STM32WB55RGVx_FLASH.ld`
- Create: `ports/stm32wb/smoke_test.swift`
- Create: `ports/stm32wb/platform/platform_glue.c` (minimal stub — Task 4 replaces it)
- Create: `build_stm32wb.sh` (minimal — Task 8 finalizes it)
- Modify: `CLAUDE.md` (Prerequisites section — document the five env vars)

**Interfaces:**
- Produces: a working `ports/stm32wb/CMakeLists.txt` that discovers a Swift toolchain, compiles the vendored CMSIS-WB startup assembly, links against a hand-written linker script reserving SRAM2A for the mailbox tables, and produces a `.bin` from a trivial Swift `@_cdecl` entry point.

- [ ] **Step 1: Vendor the five dependencies**

Add a `### STM32WB` subsection to `CLAUDE.md`'s Prerequisites, matching the existing subsections' style:

```markdown
### STM32WB
- **cmsis-device-wb** (CMSIS device headers + Cortex-M4 startup assembly for the STM32WB series — no GCC linker script shipped, same gap as cmsis-device-f4) at `~/cmsis-device-wb`: `git clone https://github.com/STMicroelectronics/cmsis-device-wb ~/cmsis-device-wb`
- **CMSIS_6** (reused from the STM32F4 port — `~/CMSIS_6`, no new clone needed if you have one).
- **TinyUSB** at `~/tinyusb` (reused — no new clone needed if you have one).
- **BTstack** at `~/btstack` (reused from RP2040/nRF52840 — no new clone needed if you have one).
- **STM32CubeWB** (pinned at v1.24.0 — the IPCC mailbox transport-layer source this port vendors from, plus the prebuilt CPU2 "HCI Layer" wireless-coprocessor firmware binary; later tags moved this content to a submodule that no longer covers dual-core WB55) at `~/STM32CubeWB`: `git clone --branch v1.24.0 https://github.com/STMicroelectronics/STM32CubeWB ~/STM32CubeWB`
- **ARM toolchain with newlib**: same `arm-gcc-bin@14` already required for RP2040/nRF52840/STM32F4 — no new install.
- **Swift Embedded ARM toolchain**: same one already required for the other ARM ports — `armv7em-none-none-eabi` has a real stdlib, no dev-snapshot requirement.
```

- [ ] **Step 2: Write the linker script**

Create `ports/stm32wb/linker/STM32WB55RGVx_FLASH.ld`. Memory map from `cmsis-device-wb`'s `Include/stm32wb55xx.h` (verified during this plan's research): flash base `0x08000000` (up to 1MB, but **CPU1's usable region is smaller than the full 1MB** — CPU2's wireless-coprocessor firmware occupies the top portion of flash, at an offset controlled by the SFSA/SBRSA option bytes, which this build-only pass does not program; use a conservative `448K` for CPU1's flash region, matching STM32CubeWB's own BLE example projects' typical linker scripts for this firmware combination — confirm against the real SFSA value once hardware is available), SRAM1 base `0x20000000` (up to 192KB, `192K` for CPU1's stack/heap/`.data`/`.bss`), and a **separate `MAILBOX_RAM` region** at SRAM2A (`0x20030000`, 32KB) reserved for Task 6's mailbox tables — CPU2 can only see SRAM2A/SRAM2B, so these buffers cannot live in ordinary `.bss`.

```ld
MEMORY
{
  FLASH (rx)      : ORIGIN = 0x08000000, LENGTH = 448K
  RAM (xrw)       : ORIGIN = 0x20000000, LENGTH = 192K
  MAILBOX_RAM (xrw) : ORIGIN = 0x20030000, LENGTH = 32K
}

_estack = ORIGIN(RAM) + LENGTH(RAM);
_Min_Heap_Size = 0x400;
_Min_Stack_Size = 0x400;

ENTRY(Reset_Handler)

SECTIONS
{
  .isr_vector :
  {
    . = ALIGN(4);
    KEEP(*(.isr_vector))
    . = ALIGN(4);
  } >FLASH

  .text :
  {
    . = ALIGN(4);
    *(.text)
    *(.text*)
    *(.rodata)
    *(.rodata*)
    *(.glue_7)
    *(.glue_7t)
    *(.eh_frame)
    KEEP (*(.init))
    KEEP (*(.fini))
    . = ALIGN(4);
    _etext = .;
  } >FLASH

  _sidata = LOADADDR(.data);

  .data :
  {
    . = ALIGN(4);
    _sdata = .;
    *(.data)
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } >RAM AT> FLASH

  .bss :
  {
    . = ALIGN(4);
    _sbss = .;
    *(.bss)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } >RAM

  ._user_heap_stack :
  {
    . = ALIGN(8);
    PROVIDE ( end = . );
    PROVIDE ( _end = . );
    . = . + _Min_Heap_Size;
    . = . + _Min_Stack_Size;
    . = ALIGN(8);
  } >RAM

  /* Task 6 places the IPCC mailbox tables here via
     __attribute__((section(".mailbox_ram"))) — CPU2 can only access
     SRAM2A/SRAM2B, so these buffers must not land in ordinary .bss (RAM,
     above). NOLOAD: zero-initialized by hardware reset state, not the C
     runtime's .bss zero-fill loop (this region is outside RAM above, so
     Reset_Handler's zero-fill loop never touches it). */
  .mailbox_ram (NOLOAD) :
  {
    . = ALIGN(4);
    *(.mailbox_ram)
    . = ALIGN(4);
  } >MAILBOX_RAM

  /DISCARD/ :
  {
    libc.a ( * )
    libm.a ( * )
    libgcc.a ( * )
  }
}
```

- [ ] **Step 3: Write `ports/stm32wb/CMakeLists.txt`**

Read `ports/stm32f4/CMakeLists.txt` first — this file is nearly identical to it. Create `ports/stm32wb/CMakeLists.txt` with the same shape: vendor-path env var checks (`CMSIS_WB_PATH`, `CMSIS_CORE_PATH`, `TINYUSB_PATH`, `BTSTACK_PATH`, `STM32CUBEWB_PATH`), the same `CMAKE_SYSTEM_NAME Generic`/`CMAKE_SYSTEM_PROCESSOR arm`/`CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY` boilerplate before `project()`, the same Swift-toolchain-discovery probe (`SMK_SWIFT_TARGET "armv7em-none-none-eabi"`), and the same `-E -Wp,-v` trick for finding newlib's system include path for ClangImporter. Differences from F4's file:

```cmake
set(CMSIS_WB_PATH "$ENV{CMSIS_WB_PATH}")
set(CMSIS_WB_INCLUDE "${CMSIS_WB_PATH}/Include")
set(CMSIS_WB_GCC "${CMSIS_WB_PATH}/Source/Templates/gcc")
set(CMSIS_WB_TEMPLATES "${CMSIS_WB_PATH}/Source/Templates")
set(LINKER_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/linker/STM32WB55RGVx_FLASH.ld")

set(C_ASM_FLAGS
    -mcpu=cortex-m4
    -mthumb
    -mfloat-abi=soft
    -DSTM32WB55xx
    -DHSE_VALUE=32000000U
)
add_compile_options(${C_ASM_FLAGS})
# --specs=nosys.specs: same real finding from the STM32F4 port's Task 1 —
# apply it from the start here.
add_link_options(${C_ASM_FLAGS} --specs=nosys.specs -nostartfiles -Wl,--gc-sections)
```

(Find the exact startup-assembly filename by listing `${CMSIS_WB_GCC}` — expected to follow `cmsis-device-wb`'s naming convention, most likely `startup_stm32wb55xx_cm4.s` given WB55's dual-core split names CPU1's startup file distinctly from any CPU2-side template; confirm the exact name against the real checkout rather than assuming, since this plan's research did not fetch that specific directory listing.)

`platform_glue.c`'s `posix_memalign`/`_init` stubs are needed **from this task onward** (real finding from the STM32F4 port — Swift's Embedded runtime needs `posix_memalign` even for a trivial smoke test, and CMSIS startup's `Reset_Handler` unconditionally calls `__libc_init_array` → `_init`, undefined once `-nostartfiles` excludes `crti.o`/`crtn.o`). Create `ports/stm32wb/platform/platform_glue.c` with the same content STM32F4's Task 1 platform_glue.c ended up needing (read that file — its current, real content, not its own task's original draft — for the exact shape):

```c
#include <errno.h>
#include <malloc.h>
#include <stddef.h>

extern void app_main_swift(void);

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) return EINVAL;
    if (size == 0) { *memptr = NULL; return 0; }
    void *p = memalign(alignment, size);
    if (p == NULL) return ENOMEM;
    *memptr = p;
    return 0;
}

void _init(void) {}

int main(void) {
    app_main_swift();
    return 0;
}
```

- [ ] **Step 4: Write the Swift smoke-test file**

Create `ports/stm32wb/smoke_test.swift`:

```swift
// Task 1 smoke test only — proves the Swift/C/ASM/linker pipeline works.
// Replaced by real Main.swift/SMKCore wiring in Task 4.
@_cdecl("app_main_swift")
func app_main_swift() {
    while true {}
}
```

- [ ] **Step 5: Write the minimal `build_stm32wb.sh`**

Create `build_stm32wb.sh` at the repo root, modeled on `build_stm32f4.sh` (read that file first — same shape: env var checks with `:?` error messages **without any apostrophe in the message text**, since this project's default `bash` (3.2, macOS's stock version) breaks on a literal `'` inside a double-quoted `${VAR:?message}` even though the quoting is syntactically valid — a real finding from the STM32F4 port's Task 1, confirmed via `bash -n` reproduction there):

```bash
#!/usr/bin/env bash
# Build SMK firmware for STM32WB (NUCLEO-WB55RG only, this pass).
# Usage: ./build_stm32wb.sh

set -euo pipefail

: "${CMSIS_WB_PATH:?Set CMSIS_WB_PATH — see CLAUDE.md, STM32WB Prerequisites section}"
: "${CMSIS_CORE_PATH:?Set CMSIS_CORE_PATH — see CLAUDE.md, STM32WB Prerequisites section}"
: "${TINYUSB_PATH:?Set TINYUSB_PATH — see CLAUDE.md, STM32WB Prerequisites section}"
: "${BTSTACK_PATH:?Set BTSTACK_PATH — see CLAUDE.md, STM32WB Prerequisites section}"
: "${STM32CUBEWB_PATH:?Set STM32CUBEWB_PATH — see CLAUDE.md, STM32WB Prerequisites section}"
export CMSIS_WB_PATH CMSIS_CORE_PATH TINYUSB_PATH BTSTACK_PATH STM32CUBEWB_PATH

BUILD_DIR="build_stm32wb"

OX_ARM="/opt/homebrew/opt/arm-gcc-bin@14/bin"
if [ -d "${OX_ARM}" ]; then
    export PATH="${OX_ARM}:$PATH"
fi

echo "==> cmsis-device-wb: ${CMSIS_WB_PATH}"
echo "==> CMSIS_6:         ${CMSIS_CORE_PATH}"
echo "==> TinyUSB:         ${TINYUSB_PATH}"
echo "==> BTstack:         ${BTSTACK_PATH}"
echo "==> STM32CubeWB:     ${STM32CUBEWB_PATH}"
echo "==> Build dir:       ${BUILD_DIR}"

cmake -G Ninja -B "${BUILD_DIR}" -S ports/stm32wb
ninja -C "${BUILD_DIR}"

echo
echo "==> Build complete. Artifacts:"
ls -lh "${BUILD_DIR}/smk_stm32wb.bin" 2>/dev/null || true
ls -lh "${BUILD_DIR}/smk_stm32wb" 2>/dev/null || true
```

```bash
chmod +x build_stm32wb.sh
```

- [ ] **Step 6: Build and verify**

Run:
```bash
export CMSIS_WB_PATH=~/cmsis-device-wb
export CMSIS_CORE_PATH=~/CMSIS_6
export TINYUSB_PATH=~/tinyusb
export BTSTACK_PATH=~/btstack
export STM32CUBEWB_PATH=~/STM32CubeWB
./build_stm32wb.sh
```
Expected: succeeds, produces `build_stm32wb/smk_stm32wb.bin`.

- [ ] **Step 7: Commit**

```bash
git add ports/stm32wb/CMakeLists.txt ports/stm32wb/linker/STM32WB55RGVx_FLASH.ld ports/stm32wb/smoke_test.swift ports/stm32wb/platform/platform_glue.c build_stm32wb.sh CLAUDE.md
git commit -m "Add STM32WB toolchain discovery, hand-written linker script, and minimal linking smoke test"
```

---

### Task 2: Clock bring-up — `ClockInit.swift`

**Files:**
- Create: `ports/stm32wb/ClockInit.swift`
- Modify: `ports/stm32wb/platform/platform_glue.c` (call `smk_clock_init()` before `app_main_swift()`)
- Modify: `ports/stm32wb/CMakeLists.txt`

**Interfaces:**
- Produces: `smk_clock_init()` — brings SYSCLK up to 32MHz directly from HSE (no PLL needed — confirmed during this plan's research: NUCLEO-WB55RG's default configuration runs SYSCLK from HSE directly at its native 32MHz, well within CPU1's clock limits, so this is simpler than STM32F4's PLL-based bring-up), and separately enables HSI48 + CRS (Clock Recovery System) for the USB peripheral's dedicated 48MHz clock — a different mechanism from F4's PLLQ-derived USB clock.

Register offsets verified against `cmsis-device-wb`'s `RCC_TypeDef`/`FLASH_TypeDef` (`Include/stm32wb55xx.h`) during this plan's research: RCC base `0x58000000` (`AHB4PERIPH_BASE`, itself `PERIPH_BASE + 0x18000000` — note this differs from STM32F4, where RCC lives on `AHB1PERIPH_BASE`; WB55's bus mapping is genuinely different, do not assume F4's offsets transfer). Within RCC: `CR` at `+0x00`, `CFGR` at `+0x08`, `CRRCR` at `+0x98` (HSI48 control — confirmed present in the real header), `AHB2ENR` at `+0x4C` (GPIO clocks live here on WB, not `AHB1ENR` as on F4 — confirmed via the real header, WB's GPIO ports are on `AHB2PERIPH_BASE`).

**Real detail this plan's research did not fully pin down — implementer must verify against the real header/reference manual before writing this file:** the exact `CRRCR`/`CRSCR` bit layout for enabling HSI48 and configuring CRS to trim it against a reference (LSE if present, or USB SOF once the device enumerates), and the exact `CFGR`/`SW` bit encoding for selecting HSE (not HSI) as the SYSCLK source on WB55 (expected to follow the same "write SW bits, poll SWS bits until they match" pattern as every other STM32F4xx-family chip already implemented in this project, but confirm the exact encoding values against `cmsis-device-wb`'s header rather than assuming F4's `RCC_CFGR_SW`/`SWS` bit *positions* are identical — the register offset itself already differs).

- [ ] **Step 1: Write `ClockInit.swift`**

Create `ports/stm32wb/ClockInit.swift` following the exact structural pattern of `ports/stm32f4/ClockInit.swift` (read that file first to match its style: `private let` register-pointer constants, named bit-mask constants, a busy-wait-with-no-timeout bring-up routine, `@_cdecl("smk_clock_init")`). Steps, in order:
1. Enable HSE (`RCC_CR` bit — confirm exact bit position against the real header; on every other STM32F4-family chip this project has touched it has been `HSEON`/`HSERDY` at consistent bit positions, but WB55's `CR` register has additional CPU2-related fields interleaved per the real header's field list — do not assume the bit positions carry over from F4 without checking) and wait for ready.
2. Switch SYSCLK to HSE via `RCC_CFGR`'s `SW` field, poll `SWS` until it reflects HSE selected.
3. Enable HSI48 (`RCC_CRRCR`) for USB, wait for ready.
4. Enable and configure CRS to trim HSI48 (exact source — LSE vs USB SOF — and bit layout deferred to real header/reference-manual verification per the note above; a `while true {}` fatal-hang placeholder is acceptable if this step's exact bits cannot be confirmed synchronously during this task, flagged clearly as a TODO comment for a follow-up fix-loop round, not silently guessed).

- [ ] **Step 2: Wire into `platform_glue.c` and CMake**

Same mechanical wiring as the STM32F4 port's Task 2 Step 2 (add the `extern void smk_clock_init(void);` declaration, call it first in `main()`, add `ClockInit.swift` to `swift_srcs` in `CMakeLists.txt`).

- [ ] **Step 3: Build and verify**

Run: `./build_stm32wb.sh`. Expected: links cleanly.

- [ ] **Step 4: Commit**

```bash
git add ports/stm32wb/ClockInit.swift ports/stm32wb/platform/platform_glue.c ports/stm32wb/CMakeLists.txt
git commit -m "Add STM32WB HSE/HSI48/CRS clock bring-up in Swift"
```

---

### Task 3: GPIO — `GPIORegisters.swift` + `GPIOInit.swift`

**Files:**
- Create: `ports/stm32wb/GPIORegisters.swift`
- Create: `ports/stm32wb/GPIOInit.swift`
- Modify: `Sources/smk/KeyMatrix.swift` (extend the extern-declaration guard to also exclude this board)
- Modify: `ports/stm32wb/CMakeLists.txt`

**Interfaces:**
- Produces: same `outSet`/`outClear`/`input` API as every other port, `init_keyboard_pins(...)` as a plain Swift function. Single-port constraint (GPIOB) — same reasoning as the STM32F4 port.

Read `ports/stm32f4/GPIORegisters.swift`/`GPIOInit.swift` first — the register-level logic (`MODER`/`PUPDR`/`ODR`/`BSRR`/`IDR` field layout, the `BSRR` atomic-set/reset split, `setTwoBitField` helper) is **identical** to F4's, since STM32's GPIO peripheral register layout is consistent across the F4/WB families (confirmed: WB55's `GPIO_TypeDef` struct field order/offsets in `cmsis-device-wb`'s header match F4's exactly — only the peripheral *base addresses* and the *RCC enable register* differ). Create `ports/stm32wb/GPIORegisters.swift` and `ports/stm32wb/GPIOInit.swift` as near-verbatim copies of the F4 versions, with these substitutions:

- `GPIORegisters.base`: `0x48000400` (GPIOB on WB55 — `IOPORT_BASE` is `AHB2PERIPH_BASE + 0`, itself `PERIPH_BASE + 0x08000000` = `0x48000000`; GPIOB is `+0x400` — confirmed via `cmsis-device-wb`'s header during this plan's research. **Note this differs from F4's GPIOB base (`0x40020400`)** — WB puts GPIO on AHB2 at a different base than F4's AHB1-relative address; do not reuse F4's literal constant.
- The RCC GPIO-clock-enable register is `RCC_AHB2ENR` (offset `+0x4C` from RCC base `0x58000000`, per Task 2's research), **not** `RCC_AHB1ENR` as on F4 — bit 1 = `GPIOBEN`, same bit position as F4's `AHB1ENR` (confirmed consistent across the family), just a different register.

- [ ] **Step 1: Write `GPIORegisters.swift`** (copy F4's structure, substitute the base address above)

- [ ] **Step 2: Write `GPIOInit.swift`** (copy F4's structure, substitute the RCC register: `rccAhb2Enr` at `0x58000000 + 0x4C`, `rccAhb2EnrGpiobEn: UInt32 = 1 << 1`)

- [ ] **Step 3: Guard `KeyMatrix.swift`'s extern declaration**

Extend the guard (already covers `ESP32C6`/`RP2040`/`NRF52840`/`STM32F4`) to add `&& !SMK_TARGET_STM32WB`.

- [ ] **Step 4: Wire into CMake**

Add both files to `swift_srcs`, add `-DSMK_TARGET_STM32WB` to the swiftc invocation.

Run: `./build_stm32wb.sh`. Also re-run `./build_rp2040.sh pico` to confirm the `KeyMatrix.swift` guard extension is inert for that target (same regression check the STM32F4 port's Task 3 already established the need for).

- [ ] **Step 5: Commit**

```bash
git add ports/stm32wb/GPIORegisters.swift ports/stm32wb/GPIOInit.swift ports/stm32wb/CMakeLists.txt Sources/smk/KeyMatrix.swift
git commit -m "Add STM32WB GPIOB register access and matrix pin configuration in Swift"
```

---

### Task 4: Wire up `Sources/smk`/`Sources/SMKCore` — `BridgingHeader.h`, real `platform_glue.c`, board selection, keymap stub, `UsbHid.swift` stub

**Files:**
- Create: `ports/stm32wb/BridgingHeader.h`
- Create: `ports/stm32wb/KeymapStoreStub.swift`
- Create: `ports/stm32wb/UsbHid.swift` (minimal stub only — Task 5 replaces its content, same two-step pattern the STM32F4 port's Tasks 4→5 already established)
- Modify: `ports/stm32wb/platform/platform_glue.c` (replace Task 1's stub with the real version)
- Modify: `ports/stm32wb/CMakeLists.txt`
- Modify: `Sources/smk/Main.swift` (add board pin map under `#if SMK_BOARD_STM32WB_NUCLEO`)
- Delete: `ports/stm32wb/smoke_test.swift`

**Interfaces:**
- Consumes: `Sources/SMKCore/*.swift` (unmodified), `Sources/smk/Main.swift`, `Sources/smk/KeyMatrix.swift`.
- Produces: a linking full application build proving the shared Swift application layer compiles for this fifth independent Embedded Swift target.

This task's shape is a near-exact repeat of the STM32F4 port's Task 4 — read that task's own text (in `docs/superpowers/plans/2026-08-10-stm32f4-support.md`) and its real, merged output files (`ports/stm32f4/BridgingHeader.h`, `ports/stm32f4/platform/platform_glue.c`, `ports/stm32f4/KeymapStoreStub.swift`, `ports/stm32f4/UsbHid.swift`'s stub-only initial version — check git log for that file's first commit if its current content already has Task 5's real implementation) as the direct template, substituting board/target names (`STM32WB`/`STM32WB_NUCLEO` for `STM32F4`/`STM32F4_BLACKPILL`) and dropping the BLE-stub content from `platform_glue.c` (this port's `init_ble_hid`/`send_keyboard_report` get **real** implementations in Task 7, not stubs, since BLE is in scope this cycle — but Task 4 still needs *some* definition of them to link, since `Main.swift` calls them unconditionally; stub them here exactly as F4 did, and let Task 7 replace `platform_glue.c`'s stub bodies with `#ifndef SMK_HAS_REAL_BLE_HID_WB` guards around them, matching `ports/nrf52840/platform/platform_glue.c`'s own `SMK_HAS_REAL_BLE_HID_SDC` pattern for the identical "task N stubs it, task N+1 provides the real definition, must not both compile in" problem).

- [ ] **Step 1: Write `BridgingHeader.h`** (copy F4's structure; keep `init_ble_hid`/`send_keyboard_report` declared as extern C functions, same as every other port, since this board WILL back them with C — `platform/ble_hid_wb.c`, Task 7)

- [ ] **Step 2: Write `KeymapStoreStub.swift`** (identical shape to F4's — no flash layout designed yet for this bring-up board)

- [ ] **Step 3: Write the `UsbHid.swift` stub** (identical shape to F4's Task 4 stub: `init_wired_link()`/`send_wired_report()` as no-ops, `kb_usb_task()` as an empty `@_cdecl`)

- [ ] **Step 4: Write the real `platform_glue.c`**

Same shape as F4's real `platform_glue.c` (`kb_log` no-op, `vTaskDelay` busy-loop calling `kb_usb_task()`, `smk_has_wired_bridge()`/`smk_default_mode_is_wired()` both `1`), but with `init_ble_hid`/`send_keyboard_report` stubs wrapped in `#ifndef SMK_HAS_REAL_BLE_HID_WB` (per this task's own introduction above) instead of being permanent no-ops:

```c
#ifndef SMK_HAS_REAL_BLE_HID_WB
void init_ble_hid(void) {
    // Stub — Task 7 (ble_hid_wb.c) provides the real implementation.
}

void send_keyboard_report(uint8_t modifier, uint8_t *keycodes) {
    (void)modifier;
    (void)keycodes;
}
#endif
```

- [ ] **Step 5: Add the board pin map to `Main.swift`**

Same bring-up-only placeholder shape as the STM32F4 branch (5x5 matrix, GPIOB pins 0-9) — copy that branch, rename the `#if` flag to `SMK_BOARD_STM32WB_NUCLEO`, insert as a new `#elseif` branch in the existing chain.

- [ ] **Step 6: Rewrite `ports/stm32wb/CMakeLists.txt`'s source lists**

Same shape as F4's Task 4 Step 5 (full `swift_srcs` list including `Sources/smk/Main.swift`/`KeyMatrix.swift`, all of `Sources/SMKCore/`, this port's own `ClockInit.swift`/`GPIORegisters.swift`/`GPIOInit.swift`/`KeymapStoreStub.swift`/`UsbHid.swift`; cJSON `c_srcs` entry; `-import-objc-header`; `-DSMK_TARGET_STM32WB -DSMK_BOARD_STM32WB_NUCLEO`).

- [ ] **Step 7: Build and verify**

Run: `./build_stm32wb.sh`. Expected: links cleanly — this is the biggest regression check in this plan, proving `Sources/SMKCore` compiles for a fifth independent Embedded Swift target.

- [ ] **Step 8: Commit**

```bash
git rm ports/stm32wb/smoke_test.swift
git add ports/stm32wb/BridgingHeader.h ports/stm32wb/KeymapStoreStub.swift ports/stm32wb/UsbHid.swift ports/stm32wb/platform/platform_glue.c ports/stm32wb/CMakeLists.txt Sources/smk/Main.swift
git commit -m "Wire STM32WB port into Sources/smk and Sources/SMKCore"
```

---

### Task 5: USB HID via TinyUSB (`fsdev` driver)

**Files:**
- Create: `ports/stm32wb/platform/tusb_config.h`
- Modify: `ports/stm32wb/UsbHid.swift` (replace Task 4's stub with the real implementation)
- Create: `ports/stm32wb/platform/usb_descriptors.c` (unmodified copy)
- Modify: `ports/stm32wb/CMakeLists.txt`
- Modify: `Sources/SMKCore/KeymapProtocol.swift` (extend `smk_keymap_dispatch_packet`'s target guard to add `SMK_TARGET_STM32WB` — same real finding already hit in the STM32F4 port's Task 5)

**Interfaces:**
- Produces: `init_wired_link()`, `send_wired_report()`, `kb_usb_task()` — same contract as every other port.

`tusb_config.h`: `CFG_TUSB_MCU OPT_MCU_STM32WB` (WB55's USB peripheral is the classic device-only `USB_FS` type shared with F0/F1/F3/L0/G0/G4 — TinyUSB's `dcd_stm32_fsdev.c` driver covers it, **not** the `dwc2` driver STM32F4 used). No `CFG_TUSB_RHPORT0_MODE` full-speed disambiguation needed (unlike F4's dwc2, which is dual FS/HS-capable on some parts) — `fsdev` is FS-only, matching RP2040/nRF52840's simpler config.

`UsbHid.swift`: same real TinyUSB symbol names already established (`tusb_rhport_init`/`tud_task_ext`/`tud_hid_n_ready`/`tud_hid_n_keyboard_report`/`tusb_int_handler`/`tusb_time_millis_api`) and the same `OTG_FS_IRQHandler`-style forwarder pattern, but for WB55's actual USB interrupt vector name (expected `USB_LP_IRQHandler` on WB55, per this family's convention of a single "USB low-priority" interrupt for `fsdev` — **confirm the exact vector name against the vendored `cmsis-device-wb` startup assembly's weak-symbol list during implementation**, the same way the STM32F4 port confirmed `OTG_FS_IRQHandler` directly from its startup file rather than assuming it).

Unlike F4's `dwc2_clock_init()` (a documented no-op requiring the application to manually enable the OTG_FS peripheral clock), TinyUSB's `fsdev` driver family conventionally expects the application to enable the USB peripheral clock and the HSI48/CRS clock (Task 2) before calling `tusb_rhport_init` — **confirm the exact RCC enable bit against the vendored `dcd_stm32_fsdev.c`'s own comments/`dwc2_clock_init`-equivalent during implementation**, mirroring how the STM32F4 port discovered its own equivalent requirement empirically rather than assuming.

`usb_descriptors.c`: unmodified copy of `ports/stm32f4/platform/usb_descriptors.c` (board-independent).

- [ ] **Step 1: Write `tusb_config.h`**
- [ ] **Step 2: Write the real `UsbHid.swift`**
- [ ] **Step 3: Write `usb_descriptors.c`** (straight copy)
- [ ] **Step 4: Wire TinyUSB's `fsdev` sources into CMake**

```cmake
target_sources(smk_stm32wb PRIVATE
    "${TINYUSB_PATH}/src/tusb.c"
    "${TINYUSB_PATH}/src/common/tusb_fifo.c"
    "${TINYUSB_PATH}/src/device/usbd.c"
    "${TINYUSB_PATH}/src/class/hid/hid_device.c"
    "${TINYUSB_PATH}/src/portable/st/stm32_fsdev/dcd_stm32_fsdev.c"
)
```

(Confirm this exact path against the vendored TinyUSB checkout — `portable/st/stm32_fsdev/` is this driver's conventional location, following the same `portable/<vendor>/<driver>/` layout STM32F4's `portable/synopsys/dwc2/` already confirmed.)

- [ ] **Step 5: Extend `KeymapProtocol.swift`'s guard**

```swift
#if SMK_TARGET_ESP32C6 || SMK_TARGET_RP2040 || SMK_TARGET_NRF52840 || SMK_TARGET_STM32F4 || SMK_TARGET_STM32WB
```

- [ ] **Step 6: Build and verify**

Run: `./build_stm32wb.sh`. Also re-verify STM32F4/RP2040/nRF52840 build cleanly after the `KeymapProtocol.swift` guard change (same regression check the STM32F4 port's Task 5 already established the need for).

- [ ] **Step 7: Commit**

```bash
git add ports/stm32wb/platform/tusb_config.h ports/stm32wb/UsbHid.swift ports/stm32wb/platform/usb_descriptors.c ports/stm32wb/CMakeLists.txt Sources/SMKCore/KeymapProtocol.swift
git commit -m "Add STM32WB USB HID via TinyUSB's fsdev driver (Swift glue, C descriptor tables)"
```

---

### Task 6: Vendor and adapt the IPCC mailbox transport layer

**Files:**
- Create: `ports/stm32wb/platform/tl_mbox.c`, `ports/stm32wb/platform/mbox_def.h`, `ports/stm32wb/platform/tl.h`, `ports/stm32wb/platform/shci.c`, `ports/stm32wb/platform/shci.h`, `ports/stm32wb/platform/shci_tl.c`, `ports/stm32wb/platform/shci_tl.h`, `ports/stm32wb/platform/hci_tl.c`, `ports/stm32wb/platform/hci_tl.h` (vendored, adapted)
- Create: `ports/stm32wb/platform/hw_ipcc.c` (new — not vendored, see below)
- Modify: `ports/stm32wb/CMakeLists.txt`

**Interfaces:**
- Produces: `TL_Init()`, `TL_BLE_Init(void *pConf)`, `shci_init(void (*UserEvtRx)(void *), void *pConf)`, `SHCI_C2_BLE_Init(SHCI_C2_Ble_Init_Cmd_Packet_t *pCmdPacket)` — ST's own real API surface (confirmed via direct inspection of the pinned `v1.24.0` headers during this plan's research: `tl.h`'s `void TL_Init( void );` / `int32_t TL_BLE_Init( void* pConf );`, `shci_tl.h`'s `void shci_init(void(* UserEvtRx)(void* pData), void* pConf);`, `shci.h`'s `SHCI_CmdStatus_t SHCI_C2_BLE_Init( SHCI_C2_Ble_Init_Cmd_Packet_t *pCmdPacket );`). Task 7 calls these directly; this task only proves they compile and link standalone (nothing calls them yet).

- [ ] **Step 1: Copy the vendored files**

From `${STM32CUBEWB_PATH}/Middlewares/ST/STM32_WPAN/interface/patterns/ble_thread/tl/`: `tl.h`, `tl_mbox.c`, `mbox_def.h`, `hci_tl.c`, `hci_tl.h`, `hci_tl_if.c`, `shci_tl.c`, `shci_tl.h`, `shci_tl_if.c` (confirmed present at these exact paths in the pinned `v1.24.0` tag via directory listing during this plan's research — do **not** copy `tl_mac_802_15_4.h`/`tl_thread_hci.*`/`tl_zigbee_hci.*` from the same directory, this project uses none of those protocols).

From `${STM32CUBEWB_PATH}/Middlewares/ST/STM32_WPAN/interface/patterns/ble_thread/shci/`: `shci.c`, `shci.h`.

```bash
cp "${STM32CUBEWB_PATH}/Middlewares/ST/STM32_WPAN/interface/patterns/ble_thread/tl/"{tl.h,tl_mbox.c,mbox_def.h,hci_tl.c,hci_tl.h,hci_tl_if.c,shci_tl.c,shci_tl.h,shci_tl_if.c} ports/stm32wb/platform/
cp "${STM32CUBEWB_PATH}/Middlewares/ST/STM32_WPAN/interface/patterns/ble_thread/shci/"{shci.c,shci.h} ports/stm32wb/platform/
```

Preserve ST's copyright headers in every copied file, per this project's established precedent for vendored third-party source (matching the nRF52840 port's `LicenseRef-Nordic-5-Clause` handling — confirm STM32CubeWB's actual license terms permit this redistribution shape before finalizing; ST's software is typically under a permissive "Ultimate Liberty" or Apache-2.0-style license for this class of middleware, but verify against the real `LICENSE.md`/file headers in the checkout rather than assuming).

- [ ] **Step 2: Adapt the vendored files for this project's build**

These files `#include` a handful of ST HAL/CMSIS headers and project-local config headers (`app_conf.h`, `hw.h`, `stm32_wpan_common.h`) that assume the full STM32CubeWB project template's directory layout. Read each vendored file's `#include` list and, for each header not already provided by this project (`cmsis-device-wb`'s own headers, already on the include path from Task 1), either:
  - vendor the specific small config header too if it's genuinely just constants (e.g. `stm32_wpan_common.h` is a small standalone typedef/macro header, safe to vendor unmodified), or
  - write a minimal project-local replacement (e.g. `app_conf.h` in the real SDK is a large project-specific config file defining IPCC channel-number constants, task-priority constants, and memory-pool sizes for every possible WPAN protocol this project doesn't use — do **not** vendor it wholesale; write a minimal `ports/stm32wb/platform/app_conf.h` defining only the constants the vendored files in this task's Step 1 actually reference, discovered by attempting the compile and resolving each undefined-macro error one at a time, not by guessing the full set upfront).

This adaptation step is the least-precedented part of this whole plan — closer in spirit to nRF52840's Task 6 (`hci_internal.c` adaptation, replacing Zephyr-specific includes with `sdc_bt_compat.h`) than to any exact template, since this plan's own research did not fetch and diff every vendored file's `#include` list line by line. Expect this step to take real iteration (attempt compile, read the error, fix, repeat) — that is expected here, not a sign the plan is wrong.

- [ ] **Step 3: Write `hw_ipcc.c`**

Unlike the vendored files above, the IPCC *hardware* glue (raw `IPCC_TypeDef` register pokes — enabling the IPCC peripheral clock, unmasking channel interrupts, the `HW_IPCC_*` function family the vendored `tl_mbox.c` calls into) is genuinely a thin per-project file in ST's own example projects (confirmed: it lives under each example's own `STM32_WPAN/Target/hw_ipcc.c`, not the shared middleware — meaning it's meant to be reimplemented per-integration, not vendored verbatim). Per this project's Swift-first preference, prefer writing this as Swift where the vendored C's calling convention allows a `@_extern(c, ...)`/`@_cdecl` boundary — but IPCC's interrupt-handler registration (the STM32WB `IPCC_C1_RX_IRQHandler`/`IPCC_C1_TX_IRQHandler` vector-table entries) follows the exact same `@_cdecl`-named-weak-symbol-override pattern already used for every other port's interrupt forwarders, so this can very likely be `ports/stm32wb/HwIpcc.swift` instead of a `.c` file — **make this call once the real `HW_IPCC_*` function signatures the vendored `tl_mbox.c` expects are known** (from Step 2's adaptation work), rather than committing to Swift-vs-C here before that's confirmed.

- [ ] **Step 4: Wire into CMake as a standalone compile check**

Add the vendored + new files to `c_srcs`, include the vendored directory, but call nothing from `app_main_swift` yet (same "prove it compiles standalone" scoping as nRF52840's Task 6).

Run: `./build_stm32wb.sh`. Expected: links cleanly (unused-but-compiled, matching Task 6's own scope — Task 7 calls these functions for real).

- [ ] **Step 5: Commit**

```bash
git add ports/stm32wb/platform/tl_mbox.c ports/stm32wb/platform/mbox_def.h ports/stm32wb/platform/tl.h ports/stm32wb/platform/shci.c ports/stm32wb/platform/shci.h ports/stm32wb/platform/shci_tl.c ports/stm32wb/platform/shci_tl.h ports/stm32wb/platform/hci_tl.c ports/stm32wb/platform/hci_tl.h ports/stm32wb/platform/hci_tl_if.c ports/stm32wb/platform/shci_tl_if.c ports/stm32wb/platform/hw_ipcc.c ports/stm32wb/platform/app_conf.h ports/stm32wb/CMakeLists.txt
git commit -m "Vendor and adapt STM32WB's IPCC mailbox transport layer (ST's tl_mbox.c/shci.c/hci_tl.c)"
```

---

### Task 7: CPU2 boot sequence + `hci_transport_t` + BTstack GATT HID wiring

**Files:**
- Create: `ports/stm32wb/platform/ble_hid_wb.c`
- Modify: `ports/stm32wb/platform/platform_glue.c` (remove the `#ifndef SMK_HAS_REAL_BLE_HID_WB` stubs' guard-disable — define `SMK_HAS_REAL_BLE_HID_WB` in CMake instead)
- Modify: `ports/stm32wb/CMakeLists.txt` (BTstack sources, GATT header generation, `SMK_HAS_REAL_BLE_HID_WB` define)

**Interfaces:**
- Produces: real `init_ble_hid()`/`send_keyboard_report()` — CPU2 release, `TL_Init()`/`shci_init()`/`SHCI_C2_BLE_Init()` boot sequence, an `hci_transport_t` bridging the vendored mailbox layer's HCI byte stream into BTstack, then BTstack's HID-over-GATT service (same `smk_hid.gatt` already shared by RP2040/nRF52840).

This task is the highest-risk, least-precedented piece of this entire plan. Read `ports/nrf52840/platform/ble_hid_sdc.c` first as the closest structural analog (SDC init → `hci_transport_t` → BTstack run loop → HID-over-GATT) — the *shape* transfers, but the specific transport calls do not: nRF52840's SDC exposes generic HCI command/event bytes directly (`hci_internal_cmd_put`/`hci_internal_msg_get`); STM32WB's vendored `hci_tl.c`/`shci_tl.c` (Task 6) expose ST's own packet-typed API instead (`hci_tl_if.c`'s I/O callbacks, `TL_BLE_SendCmd`-style entry points — exact names confirmed only by reading Task 6's actually-vendored `hci_tl.h`/`tl.h` directly, not assumed here).

- [ ] **Step 1: CPU2 boot**

Enable CPU2 (`HAL_PWREx_ReleaseCore`-equivalent — a `PWR` register bit release, direct-register Swift or C per this project's Swift-first preference, confirm exact bit against `cmsis-device-wb`'s `PWR_TypeDef` during implementation) then call the vendored `TL_Init()` → `shci_init(userEvtCallback, &shciConfig)` → `SHCI_C2_BLE_Init(&bleCmdPacket)` sequence, waiting for the ready event per `shci.h`'s documented contract (`SHCI_SUB_EVT_CODE_READY`, confirmed referenced in this plan's research but not fully traced to its exact wait mechanism — implementer must read `shci_tl.c`'s real event-wait implementation, vendored in Task 6, to get this right rather than guessing a busy-wait shape).

- [ ] **Step 2: `hci_transport_t` bridge**

Bridge the vendored mailbox layer's I/O into BTstack's generic `hci_transport_t`, same shape nRF52840's Task 7 already established for SDC — but expect the exact function-pointer signatures ST's `hci_tl_if.c` expects for its callback registration to differ from SDC's, confirmed only by reading that vendored file directly (Task 6).

- [ ] **Step 3: BTstack HID-over-GATT**

Reuse `smk_hid.gatt`/the generated `smk_hid.h` unchanged (same GATT profile RP2040/nRF52840 already share — HID-over-GATT doesn't depend on the transport underneath it), and the same BTstack source-file list nRF52840's `CMakeLists.txt` already established (`hci.c`, `l2cap.c`, `att_db.c`/`att_server.c`, `sm.c`, `gatt-service/hids_device.c`, etc.) — copy that list as a starting point, not gospel; resolve any undefined-symbol link error by adding the specific missing source file, same instruction nRF52840's own plan gave (which found `btstack_hid_parser.c` this way, not anticipated by that plan's own draft).

- [ ] **Step 4: Build and verify**

Run: `./build_stm32wb.sh`. Expected: links cleanly with real BLE symbols present (`SHCI_C2_BLE_Init`, `hci_power_control`, `hids_device_init` or equivalent).

- [ ] **Step 5: Commit**

```bash
git add ports/stm32wb/platform/ble_hid_wb.c ports/stm32wb/platform/platform_glue.c ports/stm32wb/CMakeLists.txt
git commit -m "Add STM32WB CPU2 boot + IPCC transport bridge + BTstack HID-over-GATT"
```

---

### Task 8: Final assembly, docs

**Files:**
- Modify: `CLAUDE.md` (Supported Targets table + Prerequisites cross-check)
- Modify: `README.md`

- [ ] **Step 1: Add the STM32WB row to `CLAUDE.md`'s Supported Targets table**

```markdown
| STM32WB (NUCLEO-WB55RG) | Arm Cortex-M4 (+ on-chip Cortex-M0+ radio coprocessor running ST's own firmware) | CMake / Ninja (hand-rolled — vendored cmsis-device-wb + CMSIS_6 + TinyUSB + BTstack + STM32CubeWB's IPCC transport layer) | USB HID (TinyUSB's `fsdev` driver) + BLE HID (ST's HCI-Layer wireless coprocessor over BTstack); build-only, not yet hardware-verified |
```

- [ ] **Step 2: Mention `./build_stm32wb.sh` in `README.md`**, modeled on the STM32F4 section added there.

- [ ] **Step 3: Full clean-build verification of every target**

```bash
rm -rf build_stm32wb
./build_stm32wb.sh
./build_stm32f4.sh
./build_rp2040.sh pico
./build_nrf52840.sh   # if that toolchain is available in this environment
# idf.py build         # if the ESP-IDF toolchain is available (source its export.sh first)
SMK_HOST_TESTS_ONLY=1 swift test
```

Expected: all succeed. This confirms none of this plan's shared-file changes (`KeyMatrix.swift`, `KeymapProtocol.swift`) regressed any other target.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "Document STM32WB support in CLAUDE.md and README.md"
```
