#!/usr/bin/env bash
# Build SMK firmware for Raspberry Pi Pico/Pico 2 (RP2040/RP2350), Pico W,
# or the custom smk_kbd_rp2040 chip-down PCB (see ~/esp/SMK_Keyboard).
# Usage:
#   ./build_rp2040.sh                  # plain Pico (USB HID only)
#   ./build_rp2040.sh pico_w           # Pico W  (USB HID + BLE scaffolded)
#   ./build_rp2040.sh pico2            # Pico 2  (RP2350, USB HID only)
#   ./build_rp2040.sh pico2_w          # Pico 2 W (RP2350, USB HID + BLE scaffolded)
#   ./build_rp2040.sh smk_kbd_rp2040   # custom PCB (USB HID + RGB + BLE-over-UART)
#   PICO_BOARD=pico_w ./build_rp2040.sh

set -euo pipefail

BOARD="${1:-${PICO_BOARD:-pico}}"
BUILD_DIR="build_rp2040_${BOARD}"

: "${PICO_SDK_PATH:=$HOME/pico-sdk}"
export PICO_SDK_PATH

# smk_kbd_rp2040 is a chip-down RP2040 design, not a Pico/Pico W
# module -- but its external flash (Winbond W25Q16JV) and 12MHz crystal are
# electrically identical to the stock Pico's own (generate_kbd_rp2040.py
# deliberately chose the exact part Raspberry Pi's own Pico uses), so
# PICO_BOARD=pico is still the correct pico-sdk hardware descriptor. The
# real board-specific bits (matrix pins, RGB chain, BLE-over-UART instead of
# Pico W's SPI-wired CYW43) are selected independently via SMK_TARGET_BOARD,
# which CMakeLists.txt branches on for compile definitions/sources.
SMK_TARGET_BOARD="${BOARD}"
if [ "${BOARD}" = "smk_kbd_rp2040" ]; then
    PICO_BOARD_ARG="pico"
else
    PICO_BOARD_ARG="${BOARD}"
fi

# Prefer the osx-cross/arm full toolchain (includes newlib/nosys.specs).
# Falls back to whatever arm-none-eabi-gcc is on PATH.
OX_ARM="/opt/homebrew/opt/arm-gcc-bin@14/bin"
if [ -d "${OX_ARM}" ]; then
    export PATH="${OX_ARM}:$PATH"
    GCC_ARGS=(
        -DCMAKE_C_COMPILER="${OX_ARM}/arm-none-eabi-gcc"
        -DCMAKE_CXX_COMPILER="${OX_ARM}/arm-none-eabi-g++"
        -DCMAKE_ASM_COMPILER="${OX_ARM}/arm-none-eabi-gcc"
    )
else
    GCC_ARGS=()
fi

echo "==> Board:        ${BOARD}  (PICO_BOARD=${PICO_BOARD_ARG}, SMK_TARGET_BOARD=${SMK_TARGET_BOARD})"
echo "==> pico-sdk:     ${PICO_SDK_PATH}"
echo "==> Build dir:    ${BUILD_DIR}"
echo "==> ARM GCC:      $(arm-none-eabi-gcc --version 2>/dev/null | head -1)"

cmake -G Ninja \
      -B "${BUILD_DIR}" \
      -S ports/rp2040 \
      -DPICO_BOARD="${PICO_BOARD_ARG}" \
      -DSMK_TARGET_BOARD="${SMK_TARGET_BOARD}" \
      "${GCC_ARGS[@]}"

ninja -C "${BUILD_DIR}"

echo
echo "==> Build complete. Artifacts:"
ls -lh "${BUILD_DIR}/smk_rp2040.uf2" 2>/dev/null || true
ls -lh "${BUILD_DIR}/smk_rp2040.elf" 2>/dev/null || true

echo
echo "Flash via BOOTSEL (drag-and-drop or picotool):"
echo "  picotool load -f ${BUILD_DIR}/smk_rp2040.uf2"
