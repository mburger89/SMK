#include "esp_hidd.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "services/gap/ble_svc_gap.h"
#include <string.h>

// This file is a trimmed remainder of the former ble_helper.c — see
// Sources/smk/BleHelper.swift's header comment for the full rationale.
// Everything left here needed either a struct type that's genuinely
// bitfield-heavy (struct ble_hs_adv_fields, struct ble_hs_cfg — both
// verified against real ESP-IDF v6.0.1 headers, not assumed) or the
// static esp_hid_device_config_t/esp_hid_raw_report_map_t construction
// those depend on. ble_hidd_event_callback, send_keyboard_report,
// smk_ble_set_battery_level, kb_log, and ble_hid_host_task all moved to
// BleHelper.swift.

static const char *TAG = "SMK_BLE";

// HID Report Map: a standard keyboard (Report ID 1) plus a 32-byte
// vendor-defined channel (Report ID 2) used only for keymap upload — see
// Sources/SMKCore/KeymapProtocol.swift for what rides over it.
static const uint8_t hid_report_map[] = {
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xc0,
    // Keymap upload channel — Usage Page (Vendor Defined 0xFF00), Report ID 2
    0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x02,
    0x75, 0x08, 0x95, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00,
    0x09, 0x01, 0x81, 0x02,
    0x09, 0x01, 0x91, 0x02,
    0xC0
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

// Constructs struct ble_hs_adv_fields (host/ble_hs_adv.h), which packs
// many optional fields behind 1-bit presence flags
// (uuids16_is_complete:1, name_is_complete:1, tx_pwr_lvl_is_present:1,
// sm_tk_value_is_present:1, sm_oob_flag_is_present:1, ...) alongside
// pointer/uint8_t fields with no documented packing pragma — kept in C
// per this task's Step 2 finding rather than hand-rolled in Swift.
//
// Not `static` anymore: Sources/smk/BleHelper.swift's
// ble_hidd_event_callback (@_cdecl) calls this via
// @_extern(c, "start_advertising") on the START/DISCONNECT events, so it
// needs external linkage now that its only caller moved out of this
// translation unit.
void start_advertising(void) {
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

// Defined in Sources/smk/BleHelper.swift as @_cdecl("ble_hidd_event_callback")
// / @_cdecl("ble_hid_host_task") — forward-declared here so they can be
// handed to esp_hidd_dev_init()/esp_nimble_enable() by address, same
// "vtable-adjacent" pattern as any other C API that takes a raw function
// pointer.
extern void ble_hidd_event_callback(void *handler_args, esp_event_base_t base, int32_t id, void *event_data);
extern void ble_hid_host_task(void *param);

// Defined in Sources/smk/BleHelper.swift. Hands the esp_hidd_dev_init()
// out-param to Swift exactly once — see BleHelper.swift's header comment
// on s_hid_dev ownership. Swift's `hidDev` is the single source of truth
// from that point on; this file keeps no persistent copy.
extern void smk_ble_set_hid_dev(void *dev);

void init_ble_hid(void) {
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Must run before esp_hidd_dev_init(): esp_hidd_dev_init() synchronously
    // registers GATT services (GAP/GATT/DIS/BAS/HID) via NimBLE's
    // ble_gatts_count_cfg(), which — under CONFIG_BT_NIMBLE_STATIC_TO_DYNAMIC
    // (enabled in sdkconfig) — dereferences the host's dynamically-allocated
    // ble_hs_state_ctx (see ble_hs_priv.h's ble_hs_max_services/max_attrs/
    // max_client_configs macros). That allocation only happens inside
    // ble_hs_init(), called from nimble_port_init(). Calling
    // esp_hidd_dev_init() first (as this function used to) dereferences a
    // still-NULL ble_hs_state_ctx and crashes — found via real hardware
    // testing (Guru Meditation Error, Load access fault at address 0x4,
    // inside ble_gatts_count_cfg <- ble_svc_gap_init <- esp_hidd_dev_init).
    nimble_port_init();

    // Initialize the HID device stack. s_hid_dev is local now (not a
    // persistent file-static) — its address is only needed transiently
    // as esp_hidd_dev_init's out-param; the resulting pointer is handed
    // to Swift immediately below and not touched here again.
    esp_hidd_dev_t *s_hid_dev = NULL;
    ESP_ERROR_CHECK(esp_hidd_dev_init(&ble_hid_config, ESP_HID_TRANSPORT_BLE, ble_hidd_event_callback, &s_hid_dev));
    smk_ble_set_hid_dev(s_hid_dev);

    // Make the advertised/GATT device name match what we broadcast in
    // start_advertising() (esp_hidd_dev_init leaves the GAP service with the
    // Kconfig default name, e.g. "nimble").
    ble_svc_gap_device_name_set(ble_hid_config.device_name);

    // Security: require encryption + bonding so macOS (and other hosts)
    // remember this keyboard and auto-reconnect after the first pairing,
    // instead of treating every reconnect as a brand-new device.
    //  - sm_io_cap = NO_IO: the board has no display/keypad for a passkey,
    //    so pairing is "Just Works" (no MITM protection).
    //  - sm_bonding = 1: actually persist the pairing instead of only
    //    encrypting for the current connection.
    //  - sm_our_key_dist / sm_their_key_dist include ID: exchanges the
    //    Identity Resolving Key, which is what lets the host resolve our
    //    address on later advertisements and reconnect silently rather than
    //    showing up as an unknown device each time.
    // (CONFIG_BT_NIMBLE_SM_LVL and CONFIG_BT_NIMBLE_NVS_PERSIST in sdkconfig
    // must also be enabled — see sdkconfig.defaults — for this to actually
    // take effect and survive a reboot.)
    //
    // ble_hs_cfg (extern struct ble_hs_cfg, host/ble_hs.h) packs
    // sm_oob_data_flag:1/sm_bonding:1/sm_mitm:1/sm_sc:1/... as adjacent
    // 1-bit bitfields — the same kind of struct this task's Step 2 finding
    // says to leave in C rather than hand-roll in Swift.
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

    // Enable the NimBLE stack (nimble_port_init() already ran above, before
    // esp_hidd_dev_init())
    esp_nimble_enable(ble_hid_host_task);
}
