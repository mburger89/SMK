// TinyUSB configuration for the SMK STM32F4 USB HID keyboard (device mode).
// Modeled directly on ports/nrf52840/platform/tusb_config.h; STM32F411's
// OTG_FS is full-speed only (no OTG_HS on this chip). Only the MCU
// identifier and CFG_TUSB_RHPORT0_MODE differ (OPT_MCU_STM32F4 selects
// TinyUSB's dwc2 driver's STM32 glue; the explicit OPT_MODE_FULL_SPEED is
// needed here since dwc2 is dual FS/HS-capable on other STM32F4 parts,
// unlike RP2040/nRF52840's FS-only USB peripherals).

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// --- Common ---
#ifndef CFG_TUSB_MCU
#define CFG_TUSB_MCU OPT_MCU_STM32F4
#endif

#ifndef CFG_TUSB_OS
#define CFG_TUSB_OS OPT_OS_NONE
#endif

#ifndef CFG_TUSB_DEBUG
#define CFG_TUSB_DEBUG 0
#endif

#define CFG_TUD_ENABLED 1
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
