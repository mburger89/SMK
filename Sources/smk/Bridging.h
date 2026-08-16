#include "sdkconfig.h"
#include "esp_log.h"
#include "esp_hidd.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "cJSON.h"

// BLE HID Functions
//
// init_ble_hid stays a real C prototype: init_ble_hid() itself stays
// implemented in Sources/components/ble_helper.c (it mutates
// struct ble_hs_cfg, a bitfield-heavy NimBLE global — see
// Sources/smk/BleHelper.swift's header comment for the full rationale).
//
// send_keyboard_report/smk_ble_set_battery_level are NOT declared here
// anymore: both are now implemented directly in Swift (BleHelper.swift).
// A C prototype here would conflict with that same-module Swift
// definition — same reasoning as init_wired_link/send_wired_report below.
void init_ble_hid(void);

// VBAT battery ADC (Sources/components/battery_adc.c, ESP32-C6 only —
// IO4/ADC1_CH4 on the smk_kbd board (see CLAUDE.md's GPIO map),
// GPIO0/ADC1_CH0 on the SMK test board, picked at compile time by Kconfig's
// SMK_BOARD choice). Returns 0/negative esp_err_t and a raw 0-4095 reading
// respectively; see BatteryMonitor.swift for the mV/percentage conversion.
int smk_battery_adc_init(void);
int smk_battery_adc_read_raw(void);

// Wired HID (UART1 -> CH9350L bridge, smk_kbd board) is implemented
// directly in Swift for this target — see WiredHidUart.swift. No C
// prototypes here for init_wired_link/send_wired_report: nothing outside
// the Swift module calls them, and a stale prototype here would silently
// shadow the real same-module Swift definition (Swift's own top-level
// function takes precedence with no build error) rather than fail loudly.

// Logging: kb_log is NOT declared here anymore — it's now implemented
// directly in Swift for this target too (BleHelper.swift, alongside the
// rest of the former ble_helper.c). A C prototype here would conflict
// with that same-module Swift definition.

// GPIO Matrix pin configuration (init_keyboard_pins) and board/
// connection-mode config (smk_has_wired_bridge / smk_default_mode_is_wired
// / smk_has_rgb_backlight / smk_rgb_gpio) are implemented directly in
// Swift for this target — see GPIOInit.swift and SmkConfig.swift. No C
// prototypes here: nothing outside the Swift module calls them.

// RGB LED chain (SK6812MINI-E via RMT) — only referenced from Main.swift
// when compiled with -DSMK_RGB_AVAILABLE (ESP32-C6 build; also the
// smk_kbd_rp2040 RP2040 board variant, which has a real wired chain and
// compiles RGBLighting.swift too — only plain pico/pico_w don't). Chain
// wiring is serpentine, see RGBLighting.swift's ledChainIndex; this driver
// only knows raw chain position, not (row, col).
//
// led_strip_driver_init/led_strip_set_pixel/led_strip_refresh/
// led_strip_clear are implemented directly in Swift for this target — see
// LedStripDriverRMT.swift (RMT-based, formerly
// Sources/components/led_strip_driver.c, deleted). No C prototypes here:
// nothing outside the Swift module calls them, and a stale prototype here
// would silently shadow the real same-module Swift definition (Swift's own
// top-level function takes precedence with no build error) rather than
// fail loudly — same reasoning as init_wired_link/send_wired_report above
// and the GPIO/config block below.

// Runtime keymap store (Sources/smk/KeymapStoreNVS.swift, NVS-backed) and
// its BLE/USB dispatch (Sources/SMKCore/KeymapProtocol.swift) are
// implemented directly in Swift for this target. No C prototypes here for
// smk_keymap_load/erase/begin_write/write_chunk/commit/dispatch_packet:
// these are Swift-owned (dispatch_packet via `@_cdecl`), and the trimmed
// ble_helper.c no longer references any of them at all — the BLE Report
// ID 2 vendor channel that used to call dispatch_packet from C is now
// handled directly in BleHelper.swift (same-module Swift-to-Swift call,
// see that file). See
// docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md.
