// BLE HID glue for the Pico W — implements the SMK BLE contract:
//   init_ble_hid()                 -> bring up CYW43 + BTstack HID-over-GATT
//   send_keyboard_report(mod,keys) -> send an 8-byte boot-keyboard report
//
// SCAFFOLD: This is the higher-risk part of the port (pairing/bonding,
// reconnection, host quirks). It is built only when SMK_ENABLE_BLE is defined
// (i.e. PICO_BOARD=pico_w). On a plain Pico the no-op stub at the bottom is
// compiled instead, so the shared Main.swift — which always calls these — links
// and runs USB-only. Modeled on BTstack's hog_keyboard_demo.

#include <stdint.h>
#include <string.h>

#ifdef SMK_ENABLE_BLE

#include "btstack.h"
#include "pico/cyw43_arch.h"
#include "ble/gatt-service/hids_device.h"
#include "ble/gatt-service/battery_service_server.h"
#include "ble/gatt-service/device_information_service_server.h"
#include "smk_hid.h" // generated from smk_hid.gatt by pico_btstack_make_gatt_header()

// Standard boot-keyboard HID report descriptor (matches usb_descriptors.c).
static const uint8_t hid_descriptor_keyboard[] = {
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xc0
};

// Advertisement: flags, appearance (keyboard), 16-bit HID service UUID, name.
static const uint8_t adv_data[] = {
    0x02, BLUETOOTH_DATA_TYPE_FLAGS, 0x06,
    0x03, BLUETOOTH_DATA_TYPE_APPEARANCE, 0xC1, 0x03,
    0x03, BLUETOOTH_DATA_TYPE_INCOMPLETE_LIST_OF_16_BIT_SERVICE_CLASS_UUIDS, 0x12, 0x18,
    0x0d, BLUETOOTH_DATA_TYPE_COMPLETE_LOCAL_NAME,
        'S','M','K',' ','K','e','y','b','o','a','r','d',
};

static btstack_packet_callback_registration_t hci_event_callback_registration;
static btstack_packet_callback_registration_t sm_event_callback_registration;
static uint8_t battery = 100;
static hci_con_handle_t con_handle = HCI_CON_HANDLE_INVALID;
static uint8_t protocol_mode = 1;

// Latest report staged for sending (8-byte boot report).
static uint8_t pending_report[8];
static int     report_dirty = 0;

static void send_pending(void) {
    if (con_handle == HCI_CON_HANDLE_INVALID) return;
    report_dirty = 0;
    // input report value is the 6-key array preceded by modifier+reserved.
    hids_device_send_input_report(con_handle, pending_report, sizeof(pending_report));
}

static void packet_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size) {
    (void)channel; (void)size;
    if (packet_type != HCI_EVENT_PACKET) return;

    switch (hci_event_packet_get_type(packet)) {
        case HCI_EVENT_DISCONNECTION_COMPLETE:
            con_handle = HCI_CON_HANDLE_INVALID;
            break;
        case HCI_EVENT_HIDS_META:
            switch (hci_event_hids_meta_get_subevent_code(packet)) {
                case HIDS_SUBEVENT_INPUT_REPORT_ENABLE:
                    con_handle = hids_subevent_input_report_enable_get_con_handle(packet);
                    break;
                case HIDS_SUBEVENT_PROTOCOL_MODE:
                    protocol_mode = hids_subevent_protocol_mode_get_protocol_mode(packet);
                    break;
                case HIDS_SUBEVENT_CAN_SEND_NOW:
                    if (report_dirty) send_pending();
                    break;
                default:
                    break;
            }
            break;
        default:
            break;
    }
}

void init_ble_hid(void) {
    if (cyw43_arch_init()) {
        return; // wireless init failed; USB path still works
    }

    l2cap_init();
    sm_init();
    sm_set_io_capabilities(IO_CAPABILITY_NO_INPUT_NO_OUTPUT);
    sm_set_authentication_requirements(SM_AUTHREQ_BONDING | SM_AUTHREQ_SECURE_CONNECTION);

    att_server_init(profile_data, NULL, NULL);

    battery_service_server_init(battery);
    device_information_service_server_init();
    hids_device_init(0, hid_descriptor_keyboard, sizeof(hid_descriptor_keyboard));

    // Advertise as a connectable, undirected keyboard.
    uint16_t adv_int_min = 0x0030, adv_int_max = 0x0030;
    bd_addr_t null_addr; memset(null_addr, 0, sizeof(null_addr));
    gap_advertisements_set_params(adv_int_min, adv_int_max, 0, 0, null_addr, 0x07, 0x00);
    gap_advertisements_set_data(sizeof(adv_data), (uint8_t *)adv_data);
    gap_advertisements_enable(1);

    hci_event_callback_registration.callback = &packet_handler;
    hci_add_event_handler(&hci_event_callback_registration);
    sm_event_callback_registration.callback = &packet_handler;
    sm_add_event_handler(&sm_event_callback_registration);
    hids_device_register_packet_handler(packet_handler);

    hci_power_control(HCI_POWER_ON);
}

void send_keyboard_report(uint8_t modifier, uint8_t *keys) {
    pending_report[0] = modifier;
    pending_report[1] = 0; // reserved
    memcpy(&pending_report[2], keys, 6);
    report_dirty = 1;
    if (con_handle != HCI_CON_HANDLE_INVALID) {
        hids_device_request_can_send_now_event(con_handle);
    }
}

#else // !SMK_ENABLE_BLE  — plain Pico: no radio, link no-op stubs.

void init_ble_hid(void) {}
void send_keyboard_report(uint8_t modifier, uint8_t *keys) {
    (void)modifier; (void)keys;
}

#endif // SMK_ENABLE_BLE
