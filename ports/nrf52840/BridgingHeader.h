// Bridging header for the nRF52840 build of SMK (nrf52840dk, PCA10056).
//
// The shared Swift sources (Sources/smk/{Main,KeyMatrix}.swift,
// Sources/SMKCore/*.swift) need:
//   - cJSON           (config / keymap parsing)
//   - libc            (strcmp / strncmp / atoi used by LayerEngine)
//   - the platform glue prototypes (also declared via @_extern in Swift,
//     listed here for clarity and C-side type checking).
//
// Modeled on ports/rp2040/BridgingHeader.h. Unlike RP2040, GPIO matrix init
// (init_keyboard_pins) is implemented directly in Swift here
// (ports/nrf52840/GPIOInit.swift, compiled into the same module) rather than
// as a separate C function, so it is deliberately NOT declared below —
// Sources/smk/KeyMatrix.swift's `#if !SMK_TARGET_ESP32C6 && !SMK_TARGET_NRF52840`
// guard means this build never goes through @_extern(c, "init_keyboard_pins")
// at all. This board has no RGB chain (no board schematic exists yet — see
// Sources/smk/Main.swift's SMK_BOARD_NRF52840DK branch), so the
// SMK_RGB_AVAILABLE-guarded RGB externs in the RP2040 header are omitted
// entirely here, same as plain Pico/Pico W.

#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include "cJSON.h"

// --- Platform glue implemented in ports/nrf52840/platform/*.c ---

// USB HID (init_wired_link/send_wired_report) is deliberately NOT declared
// here, for the same reason init_keyboard_pins above isn't: it's backed
// directly in Swift (ports/nrf52840/UsbHid.swift, same-module resolution),
// so a C declaration here would be redundant with — and could shadow —
// the real one.

// BLE HID transport bring-up (MPSL/SDC, ports/nrf52840/platform/ble_hid_sdc.c).
// send_keyboard_report is deliberately NOT declared here anymore: it's
// backed directly in Swift now (the shared ports/common/BleHidGatt.swift,
// same-module resolution) — same reasoning as init_wired_link above.
void init_ble_hid(void);

// Board/connection-mode config (platform_glue.c). This board always has
// real native-USB wired HID, so this is hardcoded true/wired-default here
// rather than driven by a Kconfig-style option (no menuconfig on this
// build), matching RP2040's pattern.
int smk_has_wired_bridge(void);
int smk_default_mode_is_wired(void);

// Logging + cooperative delay (platform_glue.c)
void kb_log(const char *msg);
void vTaskDelay(uint32_t ticks); // shim: pumps USB then delays ~ticks ms

// Runtime keymap store (ports/nrf52840/KeymapStoreStub.swift, build-only
// no-op stub — see that file's header comment) and its BLE/USB dispatch
// (Sources/SMKCore/KeymapProtocol.swift) are implemented directly in Swift
// for this target. No C prototypes here for smk_keymap_load/erase/
// begin_write/write_chunk/commit/dispatch_packet: these are Swift-owned
// (dispatch_packet via `@_cdecl`), called from C
// (usb_descriptors.c's smk_keymap_usb_service), not the other way around —
// a stale C prototype here would be redundant with, and could shadow, the
// real Swift definitions, same reasoning as init_keyboard_pins/
// init_wired_link above. usb_descriptors.c declares its own local
// prototype for the one it calls.
// See docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md
// for the protocol this implements. Mirrors Sources/smk/Bridging.h's
// ESP32-C6 precedent (Task 5) and ports/rp2040/BridgingHeader.h's (Task 6).
