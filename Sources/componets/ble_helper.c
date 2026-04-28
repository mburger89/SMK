#include "esp_hidd.h"
#include "esp_log.h"

static const char *TAG = "SMK";

void kb_log(const char *msg) {
    ESP_LOGI(TAG, "%s", msg);
}

// This helper is called by Swift to send a standard 8-byte HID report
void send_keyboard_report(uint8_t modifier, uint8_t keycodes[6]) {
    esp_hidd_send_keyboard_value(modifier, keycodes, 6);
}
