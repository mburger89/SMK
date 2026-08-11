#!/usr/bin/env bash
# Build SMK firmware for STM32F4 (WeAct Black Pill, STM32F411CEU6 only, this pass).
# Usage: ./build_stm32f4.sh

set -euo pipefail

: "${CMSIS_F4_PATH:?Set CMSIS_F4_PATH — see CLAUDE.md, STM32F4 Prerequisites section}"
: "${CMSIS_CORE_PATH:?Set CMSIS_CORE_PATH — see CLAUDE.md, STM32F4 Prerequisites section}"
: "${TINYUSB_PATH:?Set TINYUSB_PATH — see CLAUDE.md, STM32F4 Prerequisites section}"
export CMSIS_F4_PATH CMSIS_CORE_PATH TINYUSB_PATH

BUILD_DIR="build_stm32f4"

OX_ARM="/opt/homebrew/opt/arm-gcc-bin@14/bin"
if [ -d "${OX_ARM}" ]; then
    export PATH="${OX_ARM}:$PATH"
fi

echo "==> cmsis-device-f4: ${CMSIS_F4_PATH}"
echo "==> CMSIS_6:         ${CMSIS_CORE_PATH}"
echo "==> TinyUSB:         ${TINYUSB_PATH}"
echo "==> Build dir:       ${BUILD_DIR}"

cmake -G Ninja -B "${BUILD_DIR}" -S ports/stm32f4
ninja -C "${BUILD_DIR}"

echo
echo "==> Build complete. Artifacts:"
ls -lh "${BUILD_DIR}/smk_stm32f4.bin" 2>/dev/null || true
ls -lh "${BUILD_DIR}/smk_stm32f4" 2>/dev/null || true
