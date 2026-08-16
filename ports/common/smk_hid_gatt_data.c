// Instantiates the `profile_data[]` GATT database literal generated from
// smk_hid.gatt into each build directory's smk_hid.h
// (pico_btstack_make_gatt_header() on RP2040, BTstack's compile_gatt.py
// driven directly on nrf52840/stm32wb — same generator underneath, and the
// .gatt inputs are byte-identical), and exposes its address through a real
// external function.
//
// The accessor exists because the two generator versions in play disagree
// about linkage: pico-sdk's bundled compile_gatt.py emits
// `const uint8_t profile_data[]` (external), the standalone ~/btstack
// checkout's emits `static const uint8_t profile_data[]` (internal, no
// linkable symbol at all). The shared ports/common/BleHidGatt.swift used to
// bind the array directly via `@_extern(c, "profile_data")`, which links on
// RP2040 and fails on nrf52840/stm32wb; calling this accessor instead works
// identically against both. Compiled into every BTstack BLE build:
// pico_w/pico2_w and smk_kbd_rp2040 (ports/rp2040/CMakeLists.txt),
// nrf52840, and stm32wb.
#include <stdint.h>
#include "smk_hid.h"

const uint8_t *smk_profile_data(void) {
    return profile_data;
}
