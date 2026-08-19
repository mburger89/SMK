---
name: target-build
description: Build (and optionally flash) SMK firmware for a specific hardware target — esp32c6, pico, pico_w, pico2, pico2_w, smk_kbd_rp2040, nrf52840, nrf52840_feather, stm32f4, or stm32wb. Use whenever the user asks to build, compile, or flash the firmware for one of these boards, or asks which command builds a given target.
---

# SMK Target Build

This project has one build system per MCU family, not one build system for
the whole repo. Given a target name, run the exact commands below — don't
guess or adapt a different target's commands, since env vars and toolchains
differ per family.

## Step 1: identify the target

Map whatever the user said to one of these exact target names. If it's
ambiguous (e.g. just "pico"), ask which — don't guess between `pico`,
`pico_w`, `pico2`, `pico2_w`, and `smk_kbd_rp2040`.

| User says | Target |
|---|---|
| ESP32-C6, ESP32, esp32c6, smk_kbd | `esp32c6` |
| Pico, plain Pico | `pico` |
| Pico W | `pico_w` |
| Pico 2, RP2350 | `pico2` |
| Pico 2 W | `pico2_w` |
| smk_kbd_rp2040, the custom RP2040 PCB | `smk_kbd_rp2040` |
| nRF52840, nrf52840dk | `nrf52840` |
| Feather nRF52840 Express, Adafruit Feather nRF52840 | `nrf52840_feather` |
| STM32F4, Black Pill, WeAct | `stm32f4` |
| STM32WB, NUCLEO-WB55RG | `stm32wb` |

## Step 2: run the build

### esp32c6

```bash
. ~/.espressif/v6.0.1/esp-idf/export.sh   # or the user's own export-esp-idf.sh alias
idf.py set-target esp32c6   # one-time; skip if already set
idf.py build
```

To flash + monitor after a successful build: `idf.py flash monitor`
(requires the board connected over USB).

If `export.sh` fails or the user hasn't sourced ESP-IDF, tell them to run
it themselves first — don't try to reconstruct the ESP-IDF environment by
hand.

### pico / pico_w / pico2 / pico2_w / smk_kbd_rp2040

```bash
export PICO_SDK_PATH=~/pico-sdk   # skip if already set/exported
./build_rp2040.sh <target>        # e.g. ./build_rp2040.sh pico_w
```

(`./build_rp2040.sh` with no argument builds plain `pico`.)

Produces `build_rp2040_<target>/smk_rp2040.uf2`. `pico2`/`pico2_w` need the
Swift development-snapshot toolchain (see CLAUDE.md's RP2040 Prerequisites)
— a build failure citing a missing stdlib for `armv8m.main-none-none-eabi`
means the installed toolchain doesn't support RP2350 yet, not a bug in the
build script.

To flash: put the board in BOOTSEL mode, then:
```bash
picotool load -f build_rp2040_<target>/smk_rp2040.uf2
picotool reboot
```
`picotool load -f` does **not** auto-reboot — the `picotool reboot` step is
required or the newly flashed firmware never runs.

### nrf52840 / nrf52840_feather

```bash
export NRF5_SDK_PATH=~/nRF5_SDK
export NRFXLIB_PATH=~/sdk-nrfxlib
export TINYUSB_PATH=~/tinyusb
export BTSTACK_PATH=~/btstack
./build_nrf52840.sh              # nrf52840dk (default)
./build_nrf52840.sh feather      # Feather nRF52840 Express
```

Produces `build_nrf52840_nrf52840dk/` or `build_nrf52840_feather_nrf52840/`
depending on which board arg was passed. `nrf52840dk` has no scripted flash
step — build-only per CLAUDE.md (placeholder GPIO map, not yet
hardware-verified).

`feather` additionally produces `smk_nrf52840.uf2` in its build dir, but
**drag-and-drop UF2 has not worked in bring-up so far** (bootloader enters
fine, but no mass-storage drive ever mounts — see CLAUDE.md's "nRF52840
Feather board" section). The flash path that actually worked twice in
that session is `adafruit-nrfutil` DFU-over-serial:
```bash
pip3 install adafruit-nrfutil   # venv if Python is externally-managed
adafruit-nrfutil dfu genpkg --dev-type 0x0052 \
    --application build_nrf52840_feather_nrf52840/smk_nrf52840.hex \
    smk_nrf52840_dfu.zip
adafruit-nrfutil dfu serial -pkg smk_nrf52840_dfu.zip -p /dev/cu.usbmodemXXXX -b 115200
```
Enter the bootloader first (watch for the LED to shift to a slow red
fade — a plain blink is a false positive; if the board is already
enumerating over USB, `stty -f /dev/cu.usbmodemXXXX 1200` is more
reliable than the physical double-tap). **IN PROGRESS, not confirmed
working** — a real missing-`SCB->VTOR`-relocation bug was found and fixed
this session (see CLAUDE.md), but the fix was never hardware-reconfirmed
before the USB connection went unreliable.

### stm32f4

```bash
export CMSIS_F4_PATH=~/cmsis-device-f4
export CMSIS_CORE_PATH=~/CMSIS_6
export TINYUSB_PATH=~/tinyusb
./build_stm32f4.sh
```

Produces `build_stm32f4/smk_stm32f4.bin`. Build-only per CLAUDE.md, not yet
hardware-verified.

### stm32wb

```bash
export CMSIS_WB_PATH=~/cmsis-device-wb
export CMSIS_CORE_PATH=~/CMSIS_6
export TINYUSB_PATH=~/tinyusb
export BTSTACK_PATH=~/btstack
export STM32CUBEWB_PATH=~/STM32CubeWB
./build_stm32wb.sh
```

Produces `build_stm32wb/`. Build-only per CLAUDE.md, not yet
hardware-verified. Do not distribute a build of this port — see CLAUDE.md's
STM32WB license-conflict note before flashing or sharing binaries.

## Step 3: report the result

On success, state the output artifact path and, for targets with a scripted
flash step (`esp32c6`, the RP2040 family), ask whether to flash — don't
flash automatically without being asked, since it requires a physical board
connected and could interrupt something already running on it.

On failure, show the actual build error rather than re-guessing at env
vars — most failures here are a missing/misconfigured prerequisite (wrong
toolchain version, unset path var), and CLAUDE.md's per-target
"Prerequisites" section is the source of truth for what each one needs.
