#include "esp_hidd.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "services/gap/ble_svc_gap.h"
#include <string.h>

static const char *TAG = "SMK_BLE";
static esp_hidd_dev_t *s_hid_dev = NULL;

void kb_log(const char *msg) {
    ESP_LOGI(TAG, "%s", msg);
}

// HID Report Map for a standard keyboard
static const uint8_t hid_report_map[] = {
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xc0
};

static esp_hid_raw_report_map_t ble_report_maps[] = {
    { .data = hid_report_map, .len = sizeof(hid_report_map) }
};

static esp_hid_device_config_t ble_hid_config = {
    .vendor_id = 0x16C0,
    .product_id = 0x05DF,
    .version = 0x0100,
    .device_name = "SMK Keyboard",
    .manufacturer_name = "Swift",
    .serial_number = "123456",
    .report_maps = ble_report_maps,
    .report_maps_len = 1
};

static void start_advertising(void) {
    struct ble_gap_adv_params adv_params;
    struct ble_hs_adv_fields fields;
    int rc;

    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)ble_hid_config.device_name;
    fields.name_len = strlen(ble_hid_config.device_name);
    fields.name_is_complete = 1;
    fields.appearance = 0x03C1; // Keyboard
    fields.appearance_is_present = 1;

    rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "error setting advertisement data; rc=%d", rc);
        return;
    }

    memset(&adv_params, 0, sizeof(adv_params));
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    // 0 is BLE_OWN_ADDR_PUBLIC
    rc = ble_gap_adv_start(0, NULL, BLE_HS_FOREVER, &adv_params, NULL, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "error enabling advertisement; rc=%d", rc);
        return;
    }
    ESP_LOGI(TAG, "Advertising started");
}

static void ble_hidd_event_callback(void *handler_args, esp_event_base_t base, int32_t id, void *event_data) {
    (void)handler_args;
    (void)base;
    (void)event_data;
    esp_hidd_event_t event = (esp_hidd_event_t)id;

    switch (event) {
        case ESP_HIDD_START_EVENT:
            ESP_LOGI(TAG, "BLE HID Stack Started");
            start_advertising();
            break;
        case ESP_HIDD_CONNECT_EVENT:
            ESP_LOGI(TAG, "BLE HID Connected");
            break;
        case ESP_HIDD_DISCONNECT_EVENT:
            ESP_LOGI(TAG, "BLE HID Disconnected");
            start_advertising();
            break;
        default:
            break;
    }
}

void ble_hid_host_task(void *param) {
    (void)param;
    ESP_LOGI(TAG, "NimBLE Host Task Started");
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void init_ble_hid(void) {
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Initialize the HID device stack
    ESP_ERROR_CHECK(esp_hidd_dev_init(&ble_hid_config, ESP_HID_TRANSPORT_BLE, ble_hidd_event_callback, &s_hid_dev));

    // Initialize NimBLE port
    nimble_port_init();

    // Enable the NimBLE stack
    esp_nimble_enable(ble_hid_host_task);
}

void send_keyboard_report(uint8_t modifier, uint8_t keycodes[6]) {
    if (s_hid_dev && esp_hidd_dev_connected(s_hid_dev)) {
        uint8_t report[8];
        report[0] = modifier;
        report[1] = 0; // Reserved
        memcpy(&report[2], keycodes, 6);
        // Map index 0, Report ID 1 (matches descriptor)
        esp_hidd_dev_input_set(s_hid_dev, 0, 1, report, 8);
    }
}
