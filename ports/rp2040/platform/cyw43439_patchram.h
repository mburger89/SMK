// Declarations for the PatchRAM data in cyw43439_patchram.c — see that file
// for how to populate it with real firmware data.
//
// Named to match what <pico-sdk>/lib/btstack/chipset/bcm/btstack_chipset_bcm.c's
// embedded (non-POSIX) build expects as extern symbols -- that driver reads
// these three globals directly (see its `#else` branch of
// `#ifdef HAVE_POSIX_FILE_IO`); there is no setter function to call, unlike
// the POSIX branch's btstack_chipset_bcm_set_hcd_file_path().
#pragma once

#include <stdint.h>

extern const uint8_t brcm_patchram_buf[];
extern const int brcm_patch_ram_length;
extern const char brcm_patch_version[];
