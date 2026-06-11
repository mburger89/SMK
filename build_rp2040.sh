#!/usr/bin/env bash
# Build SMK firmware for Raspberry Pi Pico (RP2040) or Pico W.
# Usage:
#   ./build_rp2040.sh             # plain Pico (USB HID only)
#   ./build_rp2040.sh pico_w      # Pico W  (USB HID + BLE scaffolded)
#   PICO_BOARD=pico_w ./build_rp2040.sh

set -euo pipefail

BOARD="${1:-${PICO_BOARD:-pico}}"
BUILD_DIR="build_rp2040_${BOARD}"

: "${PICO_SDK_PATH:=$HOME/pico-sdk}"
export PICO_SDK_PATH

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

echo "==> Board:        ${BOARD}"
echo "==> pico-sdk:     ${PICO_SDK_PATH}"
echo "==> Build dir:    ${BUILD_DIR}"
echo "==> ARM GCC:      $(arm-none-eabi-gcc --version 2>/dev/null | head -1)"

cmake -G Ninja \
      -B "${BUILD_DIR}" \
      -S ports/rp2040 \
      -DPICO_BOARD="${BOARD}" \
      "${GCC_ARGS[@]}"

ninja -C "${BUILD_DIR}"

echo
echo "==> Build complete. Artifacts:"
ls -lh "${BUILD_DIR}/smk_rp2040.uf2" 2>/dev/null || true
ls -lh "${BUILD_DIR}/smk_rp2040.elf" 2>/dev/null || true

echo
echo "Flash via BOOTSEL (drag-and-drop or picotool):"
echo "  picotool load -f ${BUILD_DIR}/smk_rp2040.uf2"
