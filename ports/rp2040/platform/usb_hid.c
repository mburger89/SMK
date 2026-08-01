// USB HID glue for RP2040 — implements the "wired" link of the SMK contract
// using native USB (TinyUSB), replacing the ESP32 CH9350 UART bridge
// (Sources/componets/uart_init.c).
//
//   init_wired_link()              -> bring up the TinyUSB device stack
//   send_wired_report(mod, keys)   -> send a boot-keyboard report
//   kb_usb_task()                  -> pump TinyUSB (called from the delay shim)

#include "tusb.h"
#include "pico/stdlib.h"
#include <stdint.h>

void smk_keymap_usb_service(void); // usb_descriptors.c

void init_wired_link(void) {
    // Initialise TinyUSB device stack on the default root-hub port.
    tusb_init();
}

// Pump TinyUSB. Must be called frequently from the main loop; the vTaskDelay
// shim in platform_glue.c calls this every scan tick.
void kb_usb_task(void) {
    tud_task();
    smk_keymap_usb_service();
}

// Send a standard 8-byte boot-keyboard report: [modifier][reserved][6 keys].
// `keys` points to the 6 active keycodes (matches HIDReport.keys in Main.swift).
void send_wired_report(uint8_t modifier, uint8_t *keys) {
    if (!tud_hid_ready()) {
        return;
    }
    // report_id 0 (single HID report), modifier byte, 6-key array.
    tud_hid_keyboard_report(0, modifier, keys);
}
