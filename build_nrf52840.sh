#!/usr/bin/env bash
# Build SMK firmware for Nordic nRF52840 (nrf52840dk board only, this pass).
# Usage: ./build_nrf52840.sh

set -euo pipefail

: "${NRF5_SDK_PATH:?Set NRF5_SDK_PATH — see CLAUDE.md's nRF52840 Prerequisites section}"
: "${NRFXLIB_PATH:?Set NRFXLIB_PATH — see CLAUDE.md's nRF52840 Prerequisites section}"
: "${TINYUSB_PATH:?Set TINYUSB_PATH — see CLAUDE.md's nRF52840 Prerequisites section}"
: "${BTSTACK_PATH:?Set BTSTACK_PATH — see CLAUDE.md's nRF52840 Prerequisites section}"
export NRF5_SDK_PATH NRFXLIB_PATH TINYUSB_PATH BTSTACK_PATH

BUILD_DIR="build_nrf52840"

OX_ARM="/opt/homebrew/opt/arm-gcc-bin@14/bin"
if [ -d "${OX_ARM}" ]; then
    export PATH="${OX_ARM}:$PATH"
fi

echo "==> nRF5 SDK:     ${NRF5_SDK_PATH}"
echo "==> sdk-nrfxlib:  ${NRFXLIB_PATH}"
echo "==> TinyUSB:      ${TINYUSB_PATH}"
echo "==> BTstack:      ${BTSTACK_PATH}"
echo "==> Build dir:    ${BUILD_DIR}"

cmake -G Ninja -B "${BUILD_DIR}" -S ports/nrf52840
ninja -C "${BUILD_DIR}"

echo
echo "==> Build complete. Artifacts:"
ls -lh "${BUILD_DIR}/smk_nrf52840.hex" 2>/dev/null || true
ls -lh "${BUILD_DIR}/smk_nrf52840" 2>/dev/null || true
