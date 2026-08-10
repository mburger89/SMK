#include <stdint.h>
#include <stddef.h>
#include "esp_err.h"
#include "esp_log.h"

extern void app_main_swift(void);

// Unicode stubs to satisfy the linker for Embedded Swift String usage
void _swift_stdlib_getNormData(void) {}
void _swift_stdlib_getComposition(void) {}
void _swift_stdlib_getDecompositionEntry(void) {}
uint8_t *_swift_stdlib_nfd_decompositions = NULL;
void _swift_stdlib_isExtendedPictographic(void) {}
void _swift_stdlib_isInCB_Consonant(void) {}
void _swift_stdlib_getGraphemeBreakProperty(void) {}

// Stub for BLE HID if config is inconsistent or linker fails to find it
// Note: This matches the signature in esp_hid
esp_err_t esp_ble_hidd_dev_init(void *dev, const void *config, void *callback) {
    ESP_LOGW("STUB", "esp_ble_hidd_dev_init stub called. Check your NimBLE configuration!");
    return ESP_OK; // Return OK to allow initialization to proceed if it's just a linker glitch
}

void app_main(void) {
    app_main_swift();
}
