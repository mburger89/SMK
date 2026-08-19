// TinyUSB configuration for the SMK SAMD21 USB HID keyboard (device mode).
// Modeled directly on ports/stm32f4/platform/tusb_config.h; only the MCU
// identifier differs (OPT_MCU_SAMD21 selects TinyUSB's
// portable/microchip/samd driver; the SAMD21's USB peripheral is
// full-speed-only, which is that driver's default).

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// --- Common ---
#ifndef CFG_TUSB_MCU
#define CFG_TUSB_MCU OPT_MCU_SAMD21
#endif

#ifndef CFG_TUSB_OS
#define CFG_TUSB_OS OPT_OS_NONE
#endif

#ifndef CFG_TUSB_DEBUG
#define CFG_TUSB_DEBUG 0
#endif

#define CFG_TUD_ENABLED 1
// Required: this is what defines TUD_OPT_RHPORT, which gates
// tusb_rhport_init(0, NULL)'s backward-compat path — without it the NULL
// rh_init gets dereferenced (found on hardware: silent USB init failure).
#define CFG_TUSB_RHPORT0_MODE (OPT_MODE_DEVICE | OPT_MODE_FULL_SPEED)

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
