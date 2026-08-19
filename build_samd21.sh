#!/bin/bash
# Build SMK for the SAMD21 (Seeed XIAO M0). Mirrors build_stm32f4.sh.
#
# Required env vars (see CLAUDE.md's SAMD21 Prerequisites):
#   TINYUSB_PATH     — TinyUSB checkout with the samd2x_l2x deps fetched
#                      (cd $TINYUSB_PATH && python3 tools/get_deps.py samd2x_l2x)
#   CMSIS_CORE_PATH  — ARM CMSIS_6 checkout (core_cm0plus.h)
set -euo pipefail

: "${TINYUSB_PATH:?TINYUSB_PATH not set (see CLAUDE.md's SAMD21 Prerequisites)}"
: "${CMSIS_CORE_PATH:?CMSIS_CORE_PATH not set (see CLAUDE.md's SAMD21 Prerequisites)}"

BUILD_DIR="build_samd21"

# Prefer the arm-gcc-bin@14 toolchain (full newlib) over any other
# arm-none-eabi-gcc on PATH — same pinning as build_stm32f4.sh.
OX_ARM="/opt/homebrew/opt/arm-gcc-bin@14/bin"
if [ -d "${OX_ARM}" ]; then
    export PATH="${OX_ARM}:$PATH"
fi

echo "==> TinyUSB:   ${TINYUSB_PATH}"
echo "==> CMSIS_6:   ${CMSIS_CORE_PATH}"
echo "==> Build dir: ${BUILD_DIR}"

cmake -G Ninja -S ports/samd21 -B "${BUILD_DIR}"
ninja -C "${BUILD_DIR}"

echo
echo "==> Build complete. Artifacts:"
ls -lh "${BUILD_DIR}/smk_samd21" "${BUILD_DIR}"/smk_samd21.bin "${BUILD_DIR}"/smk_samd21.uf2 2>/dev/null || true
echo
echo "Flash: double-tap the XIAO M0's reset pads to enter the UF2 bootloader"
echo "(an 'Arduino'/'XIAO-SENSE' drive mounts), then copy smk_samd21.uf2 onto it."
