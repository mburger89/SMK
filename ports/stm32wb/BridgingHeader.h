// Bridging header for the STM32WB build of SMK (NUCLEO-WB55RG,
// STM32WB55RGVx).
//
// The shared Swift sources (Sources/smk/{Main,KeyMatrix}.swift,
// Sources/SMKCore/*.swift) need:
//   - libc   (strcmp / strncmp / atoi used by LayerEngine)
//
// GPIO matrix init (init_keyboard_pins) and USB HID (init_wired_link/
// send_wired_report) are both implemented directly in Swift here
// (ports/stm32wb/GPIOInit.swift, ports/stm32wb/UsbHid.swift, same module),
// so neither is declared below — same reasoning as ports/stm32f4's own
// bridging header. This board has no RGB chain and no wired-HID bridge, so
// neither of those externs appears here either.
//
// Unlike STM32F4, this board backs BLE HID with C
// (platform/ble_hid_wb.c, Task 7 — BTstack over the IPCC mailbox to CPU2, and
// BTstack's own headers are C-only) — init_ble_hid/send_keyboard_report are
// declared below as real extern C functions, not a permanently-out-of-scope
// stub pair.

#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

// --- Platform glue implemented in ports/stm32wb/platform/platform_glue.c ---

// This board has real native-USB wired HID (Task 5, TinyUSB fsdev) and real
// BLE HID (Task 7); wired is the boot default, same as ports/nrf52840 and
// ports/rp2040.
int smk_has_wired_bridge(void);
int smk_default_mode_is_wired(void);

// Logging + cooperative delay (platform_glue.c)
void kb_log(const char *msg);
void vTaskDelay(uint32_t ticks); // shim: pumps USB then delays ~ticks ms

// BLE HID: Sources/smk/Main.swift calls init_ble_hid()/send_keyboard_report()
// unconditionally regardless of board. platform/ble_hid_wb.c defines the
// transport bring-up (init_ble_hid); send_keyboard_report is deliberately
// NOT declared here anymore — it's backed directly in Swift now (the shared
// ports/common/BleHidGatt.swift, same-module resolution). platform_glue.c
// keeps #ifndef SMK_HAS_REAL_BLE_HID_WB stub bodies that CMakeLists.txt's
// target_compile_definitions now compiles out.
void init_ble_hid(void);

// Runtime keymap store (ports/stm32wb/KeymapStoreStub.swift, build-only
// no-op stub — no flash layout designed yet, same status as
// ports/stm32f4/KeymapStoreStub.swift) is implemented directly in Swift, so
// no C prototypes here — same reasoning as init_keyboard_pins above.
