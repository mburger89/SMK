// Bridging header for the SAMD21 build of SMK (Seeed XIAO M0, SAMD21G18A).
//
// The shared Swift sources (Sources/smk/{Main,KeyMatrix}.swift,
// Sources/SMKCore/*.swift) need:
//   - cJSON  (config / keymap parsing)
//   - libc   (strcmp / strncmp / atoi used by LayerEngine)
//
// GPIO matrix init (init_keyboard_pins), the clock bring-up, and USB HID
// (init_wired_link/send_wired_report) are all implemented directly in Swift
// here (ports/samd21/{GPIOInit,ClockInit,UsbHid}.swift, same module), so
// none are declared below — same reasoning as ports/stm32f4/BridgingHeader.h.
// This board has no BLE, no RGB chain, and no wired-HID bridge.

#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include "cJSON.h"

// --- Platform glue implemented in ports/samd21/platform/platform_glue.c ---

// This board always has real native-USB wired HID, no wired-HID bridge, no
// BLE, so wired is always available and stays the boot default.
int smk_has_wired_bridge(void);
int smk_default_mode_is_wired(void);

// Logging + cooperative delay (platform_glue.c)
void kb_log(const char *msg);
void vTaskDelay(uint32_t ticks); // shim: pumps USB then delays ~ticks ms

// BLE HID is permanently out of scope (no radio on a XIAO M0) —
// Sources/smk/Main.swift calls init_ble_hid()/send_keyboard_report()
// unconditionally regardless of board, so platform_glue.c provides no-op
// stubs for both.
void init_ble_hid(void);
void send_keyboard_report(uint8_t modifier, uint8_t *keycodes);

// Runtime keymap store (ports/samd21/KeymapStoreStub.swift, build-only
// no-op stub) is implemented directly in Swift — no C prototypes here.
