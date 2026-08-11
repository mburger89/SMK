// Bridging header for the STM32WB build of SMK (NUCLEO-WB55RG,
// STM32WB55RGVx).
//
// The shared Swift sources (Sources/smk/{Main,KeyMatrix}.swift,
// Sources/SMKCore/*.swift) need:
//   - cJSON  (config / keymap parsing)
//   - libc   (strcmp / strncmp / atoi used by LayerEngine)
//
// GPIO matrix init (init_keyboard_pins) and USB HID (init_wired_link/
// send_wired_report) are both implemented directly in Swift here
// (ports/stm32wb/GPIOInit.swift, ports/stm32wb/UsbHid.swift, same module),
// so neither is declared below — same reasoning as ports/stm32f4's own
// bridging header. This board has no RGB chain and no wired-HID bridge, so
// neither of those externs appears here either.
//
// Unlike STM32F4, this board WILL back BLE HID with C
// (platform/ble_hid_wb.c, Task 7) — init_ble_hid/send_keyboard_report stay
// declared below as real extern C functions, not a permanently-out-of-scope
// stub pair.

#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include "cJSON.h"

// --- Platform glue implemented in ports/stm32wb/platform/platform_glue.c ---

// This board has real native-USB wired HID (Task 5, TinyUSB fsdev) and, for
// now (until Task 7 lands real BLE HID), defaults to wired at boot — same
// reasoning as ports/stm32f4/BridgingHeader.h.
int smk_has_wired_bridge(void);
int smk_default_mode_is_wired(void);

// Logging + cooperative delay (platform_glue.c)
void kb_log(const char *msg);
void vTaskDelay(uint32_t ticks); // shim: pumps USB then delays ~ticks ms

// BLE HID: Sources/smk/Main.swift calls init_ble_hid()/send_keyboard_report()
// unconditionally regardless of board. This task (Task 4) still needs *some*
// definition of them to link — platform_glue.c provides
// #ifndef SMK_HAS_REAL_BLE_HID_WB stub bodies for both, which Task 7's
// platform/ble_hid_wb.c will supersede by defining that macro.
void init_ble_hid(void);
void send_keyboard_report(uint8_t modifier, uint8_t *keycodes);

// Runtime keymap store (ports/stm32wb/KeymapStoreStub.swift, build-only
// no-op stub — no flash layout designed yet, same status as
// ports/stm32f4/KeymapStoreStub.swift) is implemented directly in Swift, so
// no C prototypes here — same reasoning as init_keyboard_pins above.
