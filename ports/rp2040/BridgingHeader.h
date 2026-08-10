// Bridging header for the RP2040 / Pico W build of SMK.
//
// The shared Swift sources (Sources/smk/{Main,LayerEngine,KeyMatrix}.swift) need:
//   - cJSON           (config / keymap parsing)
//   - libc            (strcmp / strncmp / atoi used by LayerEngine)
//   - the platform glue prototypes (also declared via @_extern in Swift, listed
//     here for clarity and C-side type checking).
//
// The ESP32 build uses Sources/smk/Bridging.h instead; this file is its RP2040
// counterpart and pulls in portable headers only (no ESP-IDF dependencies).

#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include "cJSON.h"

// --- Platform glue implemented in ports/rp2040/platform/*.c ---

// USB HID — the "wired" path on RP2040 (usb_hid.c)
void init_wired_link(void);
void send_wired_report(uint8_t modifier, uint8_t *keycodes);

// BLE HID — real on Pico W, no-op stub on plain Pico (ble_hid.c)
void init_ble_hid(void);
void send_keyboard_report(uint8_t modifier, uint8_t *keycodes);

// Board/connection-mode config, logging, and the cooperative delay shim are
// now plain Swift — see ports/rp2040/PlatformConfig.swift. No C prototypes
// needed here (same-module Swift-to-Swift calls from Main.swift).

// Runtime keymap store (ports/rp2040/KeymapStoreFlash.swift, flash-backed)
// and its BLE/USB dispatch (Sources/SMKCore/KeymapProtocol.swift) are
// implemented directly in Swift for this target. No C prototypes here for
// smk_keymap_load/erase/begin_write/write_chunk/commit/dispatch_packet:
// these are Swift-owned (dispatch_packet via `@_cdecl`), called from C
// (usb_descriptors.c's smk_keymap_usb_service), not the other way around.
// usb_descriptors.c declares its own local prototype for the one it calls.
// See docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md
// for the protocol this implements. Mirrors Sources/smk/Bridging.h's
// ESP32-C6 precedent (Task 5).

// RGB backlight (ports/rp2040/LedStripDriverPIO.swift, only compiled in for
// SMK_TARGET_BOARD=smk_kbd_rp2040 via SMK_RGB_AVAILABLE in
// ports/rp2040/CMakeLists.txt) is implemented directly in Swift for this
// target. No C prototypes needed here for smk_has_rgb_backlight/
// smk_rgb_gpio/led_strip_driver_init/led_strip_set_pixel/led_strip_refresh/
// led_strip_clear: same-module Swift-to-Swift calls from RGBLighting.swift
// (which reaches them via its own @_extern(c, ...) declarations — see that
// file). Unlike ESP32 (Kconfig-driven, off by default), this board always
// has the hardware, so both config functions are hardcoded true/17 — see
// LedStripDriverPIO.swift. The one remaining C function this board's RGB
// path needs, smk_ws2812_pio_start/smk_ws2812_put_blocking (the PIO
// program's generated-struct-touching remainder), is declared via
// ws2812_pio_shim.c's own header include (hardware/pio.h), not here, and
// called from Swift the same way — see LedStripDriverPIO.swift.
