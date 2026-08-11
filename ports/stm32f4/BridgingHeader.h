// Bridging header for the STM32F4 build of SMK (WeAct Black Pill,
// STM32F411CEU6).
//
// The shared Swift sources (Sources/smk/{Main,KeyMatrix}.swift,
// Sources/SMKCore/*.swift) need:
//   - cJSON  (config / keymap parsing)
//   - libc   (strcmp / strncmp / atoi used by LayerEngine)
//
// GPIO matrix init (init_keyboard_pins) and USB HID (init_wired_link/
// send_wired_report) are both implemented directly in Swift here
// (ports/stm32f4/GPIOInit.swift, ports/stm32f4/UsbHid.swift, same module),
// so neither is declared below — same reasoning as
// ports/nrf52840/BridgingHeader.h. This board has no BLE, no RGB chain, and
// no wired-HID bridge, so none of those externs appear here either.

#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include "cJSON.h"

// --- Platform glue implemented in ports/stm32f4/platform/platform_glue.c ---

// This board always has real native-USB wired HID, no wired-HID bridge, no
// BLE, so it's always available and stays the boot default — matching
// RP2040/nRF52840's pattern.
int smk_has_wired_bridge(void);
int smk_default_mode_is_wired(void);

// Logging + cooperative delay (platform_glue.c)
void kb_log(const char *msg);
void vTaskDelay(uint32_t ticks); // shim: pumps USB then delays ~ticks ms

// BLE HID is out of scope for this pass (see the design spec's Future
// Work) — Sources/smk/Main.swift calls init_ble_hid()/send_keyboard_report()
// unconditionally regardless of board, so platform_glue.c provides no-op
// stubs for both (see that file).
void init_ble_hid(void);
void send_keyboard_report(uint8_t modifier, uint8_t *keycodes);

// Runtime keymap store (ports/stm32f4/KeymapStoreStub.swift, build-only
// no-op stub — no flash layout designed yet, same status as
// ports/nrf52840/KeymapStoreStub.swift) is implemented directly in Swift,
// so no C prototypes here — same reasoning as init_keyboard_pins above.
