// TinyUSB configuration for the SMK STM32WB USB HID keyboard (device mode).
// Modeled directly on ports/stm32f4/platform/tusb_config.h; WB55's USB
// peripheral is the classic device-only "USB_FS"/fsdev type shared with
// F0/F1/F3/L0/G0/G4 (TinyUSB's dcd_stm32_fsdev.c driver), NOT F4's dual
// FS/HS-capable dwc2 core. fsdev is FS-only on every MCU that has it, so
// (unlike F4) no CFG_TUSB_RHPORT0_MODE full-speed disambiguation is
// needed here — matches RP2040/nRF52840's simpler config, confirmed by
// dcd_stm32_fsdev.c never consulting CFG_TUSB_RHPORT0_MODE.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// --- Common ---
#ifndef CFG_TUSB_MCU
#define CFG_TUSB_MCU OPT_MCU_STM32WB
#endif

#ifndef CFG_TUSB_OS
#define CFG_TUSB_OS OPT_OS_NONE
#endif

#ifndef CFG_TUSB_DEBUG
#define CFG_TUSB_DEBUG 0
#endif

#define CFG_TUD_ENABLED 1

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
