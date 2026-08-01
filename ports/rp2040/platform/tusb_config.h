// TinyUSB configuration for the SMK RP2040 USB HID keyboard (device mode).
// Minimal config: full-speed device, one HID interface.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// --- Common ---
#ifndef CFG_TUSB_MCU
#define CFG_TUSB_MCU OPT_MCU_RP2040
#endif

#ifndef CFG_TUSB_OS
#define CFG_TUSB_OS OPT_OS_PICO
#endif

#ifndef CFG_TUSB_DEBUG
#define CFG_TUSB_DEBUG 0
#endif

// RP2040 USB is full-speed.
#define CFG_TUD_ENABLED 1
#define CFG_TUSB_RHPORT0_MODE OPT_MODE_DEVICE

// Memory alignment / section for USB DMA buffers.
#ifndef CFG_TUSB_MEM_SECTION
#define CFG_TUSB_MEM_SECTION
#endif
#ifndef CFG_TUSB_MEM_ALIGN
#define CFG_TUSB_MEM_ALIGN __attribute__((aligned(4)))
#endif

// --- Device class config ---
#ifndef CFG_TUD_ENDPOINT0_SIZE
#define CFG_TUD_ENDPOINT0_SIZE 64
#endif

#define CFG_TUD_HID 2
#define CFG_TUD_CDC 0
#define CFG_TUD_MSC 0
#define CFG_TUD_MIDI 0
#define CFG_TUD_VENDOR 0

// HID buffer size (must be large enough for the report).
#define CFG_TUD_HID_EP_BUFSIZE 32

#ifdef __cplusplus
}
#endif
