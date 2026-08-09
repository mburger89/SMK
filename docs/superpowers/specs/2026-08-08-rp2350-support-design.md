# RP2350 (Pico 2 / Pico 2 W) Support

Date: 2026-08-08
Status: Approved, pending implementation plan

## Problem

`ports/rp2040/` currently only builds for RP2040-based boards (`pico`,
`pico_w`, `smk_kbd_rp2040`). Raspberry Pi's newer RP2350 chip (used on
Pico 2 / Pico 2 W) is a different core architecture — Arm Cortex-M33
(Armv8-M Mainline) instead of RP2040's Cortex-M0+ (Armv6-M) — so it needs
its own Swift target triple and compiler flags, even though it shares
pico-sdk, TinyUSB, and (for the W variant) the same CYW43/BTstack BLE
stack as the existing RP2040 boards.

Out of scope: a future RP2350 chip-down board analogous to
`smk_kbd_rp2040` — deferred until such a board exists, same as
`smk_kbd_rp2040` itself was deferred until that PCB existed. This spec
covers only the stock `pico2` / `pico2_w` boards, build-only (no RP2350
hardware on hand yet, so no flash/HID verification).

## Feasibility checks already done

- The installed Swift toolchain (`swift-6.3.2-RELEASE`) accepts the
  `armv8m.main-none-none-eabi` target triple via
  `swiftc -target armv8m.main-none-none-eabi -enable-experimental-feature
  Embedded -print-target-info` (exits 0, produces a valid target-info JSON
  with its own `runtimeLibraryPaths`).
- `arm-gcc-bin@14` (`/opt/homebrew/opt/arm-gcc-bin@14/bin/arm-none-eabi-gcc`)
  already supports the `v8-m.main` multilib family, including
  `march=armv8-m.main+fp / mfloat-abi=softfp` — the exact combination
  pico-sdk's own Cortex-M33 toolchain preset
  (`cmake/preload/toolchains/pico_arm_cortex_m33_gcc.cmake`) requests. No
  new/separate ARM toolchain install is needed.
- pico-sdk (`~/pico-sdk`, checked out version already has RP2350 support)
  ships `pico2.h` / `pico2_w.h` board headers and
  `cmake/preload/platforms/rp2350-arm-s.cmake`, defaulting
  `PICO_PLATFORM=rp2350` → auto-converted to `rp2350-arm-s` (secure-only
  Arm build, no TrustZone partitioning) — matches the Cortex-M33 choice
  made below.
- The SIO GPIO register block (`GPIO_IN` / `GPIO_OUT` / `GPIO_OUT_SET` /
  `GPIO_OUT_CLR`) is byte-for-byte identical between
  `src/rp2040/hardware_regs/.../sio.h` and
  `src/rp2350/hardware_regs/.../sio.h` — same base address `0xD0000000`,
  same offsets. Confirmed by diff.
- `picotool v2.3.0` is already installed and RP2350-aware.

## Design

### Core/architecture choice

Arm Cortex-M33, not RISC-V Hazard3 — RP2350 can run either core, but
Cortex-M33 keeps the same toolchain family (`arm-gcc-bin@14`) and overall
build shape as the existing RP2040 port, minimizing new moving parts.

pico-sdk's Cortex-M33 preset defaults to:

```
-mcpu=cortex-m33 -mthumb -march=armv8-m.main+fp+dsp -mfloat-abi=softfp -mcmse
```

Two deliberate deviations:

1. **`PICO_NO_CMSE=1`** (set before `pico_sdk_init()` when targeting an
   RP2350 board) — disables `-mcmse` (TrustZone secure-gateway codegen).
   This project does no secure/non-secure partitioning, so CMSE is pure
   risk (untested interaction with Swift-emitted code) with no payoff.
2. **Swift's `-Xcc` flags mirror the real C-side arch/float flags**
   (`-march=armv8-m.main+fp+dsp -mfloat-abi=softfp -mfpu=fpv5-sp-d16`)
   instead of forcing soft-float the way the RP2040/Armv6-M path does.
   Armv6-M has no FPU at all, so soft-float there is the only option;
   RP2350's Cortex-M33 has a real single-precision FPU and pico-sdk's
   prebuilt/vendored objects are compiled expecting `softfp`. Diverging
   would risk ABI mismatches (float-argument-passing convention) at the
   Swift/C boundary.

Swift target triple: `armv8m.main-none-none-eabi`.

### GPIO — no new file needed

`ports/rp2040/GPIORegisters.swift` is reused unchanged for RP2350 (same
SIO base address and offsets, confirmed above). Add a comment noting it's
shared across both chips rather than RP2040-specific.

### `ports/rp2040/CMakeLists.txt` changes

- Add an arch-selection block keyed off `SMK_TARGET_BOARD`: `pico2` /
  `pico2_w` select the RP2350/Cortex-M33 Swift `-target` and `-Xcc` flag
  set described above; every other value (`pico`, `pico_w`,
  `smk_kbd_rp2040`) keeps today's `armv6m-none-none-eabi` /
  `-Xcc -mfloat-abi=soft` path unchanged. This replaces the current
  hardcoded `armv6m-none-none-eabi` block in the final
  `target_compile_options(smk_rp2040 PRIVATE "$<$<COMPILE_LANGUAGE:Swift>...`
  section.
- The existing Pico W BLE/BTstack branch
  (`if(PICO_BOARD STREQUAL "pico_w" AND NOT SMK_IS_KBD_RP2040)`) extends
  to also match `pico2_w` — both boards wire CYW43 the same way
  (pico-sdk's `pico_cyw43_arch_none` + `pico_btstack_*` abstract the
  electrical difference), so the same GATT/BTstack linkage should apply
  unchanged.
- `set(PICO_NO_CMSE 1)` before `pico_sdk_init()` when
  `SMK_TARGET_BOARD` is `pico2` or `pico2_w`.

### `build_rp2040.sh` changes

Accept `pico2` / `pico2_w` as valid `BOARD` arguments. Unlike
`smk_kbd_rp2040` (which needs `PICO_BOARD` and `SMK_TARGET_BOARD` to
diverge because it's an electrically-different custom PCB reusing the
Pico's flash/crystal descriptor), `pico2`/`pico2_w` map straight through
as both `PICO_BOARD` and `SMK_TARGET_BOARD` — same pattern as today's
plain `pico`/`pico_w`.

### Explicitly unchanged

`platform/gpio_init.c`, `platform/usb_hid.c`,
`platform/usb_descriptors.c`, `platform/platform_glue.c`,
`platform/ble_hid.c`, `BridgingHeader.h` — all pico-sdk-API-level and
chip-agnostic already; expected to compile unchanged for RP2350.

### Docs

- Add an RP2350 / Pico 2 / Pico 2 W row to the target table in
  `CLAUDE.md`.
- Mention `./build_rp2040.sh pico2` / `pico2_w` in `README.md` alongside
  the existing `pico`/`pico_w` build commands.

## Testing

Build-only: `./build_rp2040.sh pico2` and `./build_rp2040.sh pico2_w`
both need to produce a `.uf2`/`.elf` cleanly. No flash or hardware HID/BLE
verification — no RP2350 hardware on hand. Flash/HID verification is
deferred to a future session once hardware is available.
