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
