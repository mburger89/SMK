// BLE HID glue for nrf52840dk — same SMK BLE contract as
// ble_hid_kbd_uart.c's RP2040 smk_kbd_rp2040 branch, but talking to
// Nordic's SoftDevice Controller (running in this same firmware image,
// not a physically separate chip) via the adapted HCI dispatcher in
// sdc_hci_dispatch.c instead of a UART H4 link.
//
// *** STATUS as of this pass: build-only, no hardware verification. The
// transport wiring below (SDC init, hci_transport_t implementation,
// BTstack GATT/HID setup) is real and follows this plan's research
// (docs/superpowers/plans/2026-08-09-nrf52840-support.md, Tasks 5-7), but
// nothing has been exercised on real silicon. ***

#include <stdint.h>
#include <string.h>

#include <sdc.h>
#include <sdc_hci.h>
#include <sdc_soc.h>
#include <mpsl.h>
#include <nrf.h> // NRF_RNG — see sdc_rand_poll() below

#include "btstack.h"
#include "hci_transport.h"
#include "ble/gatt-service/hids_device.h"
#include "ble/gatt-service/battery_service_server.h"
#include "ble/gatt-service/device_information_service_server.h"
#include "smk_hid.h" // generated from smk_hid.gatt, same as the RP2040 BLE build

#include "sdc_hci_dispatch.h"

// --- SDC resource buffer -----------------------------------------------
// Peripheral-role-only, single connection (MAX_NR_HCI_CONNECTIONS in
// btstack_config.h) — matches this project's needs, no Central role.
//
// The plan's original draft assumed a compile-time sizing macro
// (`SDC_MEM_PERIPHERAL_COUNT(n)`) analogous to sdc.h's other
// `SDC_MEM_PER_*`/`SDC_MEM_*_SHARED` helpers. Verified against the real
// vendored header (~/sdk-nrfxlib/softdevice_controller/include/sdc.h) while
// implementing this file: no such macro exists in this SDC release. The
// header's actual documented pattern (see sdc_cfg_set()'s doc comment) is
// to query the required size at *runtime*: call
// `sdc_cfg_set(tag, SDC_CFG_TYPE_NONE, NULL)` after configuring the desired
// role support, which returns the byte count needed for the memory pool
// sdc_enable() then consumes. Since this build has no heap-backed
// allocator wired up this early in boot, the buffer below is a static
// array sized generously for a single-peripheral/no-central/default-adv
// configuration, and init_ble_hid() below verifies at startup (via the
// same sdc_cfg_set() query) that the real requirement actually fits,
// halting via sdc_fault_handler() if it doesn't rather than silently
// overrunning the buffer.
#define SDC_MEM_BUFFER_SIZE 3600
static uint8_t sdc_mem_buffer[SDC_MEM_BUFFER_SIZE] __attribute__((aligned(8)));

static void sdc_fault_handler(const char *file, uint32_t line) {
    (void)file; (void)line;
    while (1) { }
}

// --- Entropy source -----------------------------------------------------
// sdc_enable()'s doc comment (sdc.h) states it returns -NRF_EPERM ("The
// entropy source is not configured") unless sdc_rand_source_register() has
// been called first — a real functional gap the plan's original draft
// didn't account for (only sdc_init/sdc_enable/sdc_support_* were listed).
// Without this, init_ble_hid() below would halt forever on the sdc_enable()
// error check the first time it runs, on real hardware or not. Backed by
// the nRF52840's onboard hardware RNG peripheral (product spec: TASKS_START
// starts sampling, EVENTS_VALRDY pulses once per byte, VALUE holds the
// latest byte; CONFIG.DERCEN enables the peripheral's own digital bias
// correction — worth having on since this randomness feeds LE Secure
// Connections pairing, not just non-cryptographic use). Blocking/polling
// implementation matches this file's other synchronous, no-RTOS style.
static void sdc_rand_poll(uint8_t *p_buff, uint8_t length) {
    NRF_RNG->CONFIG = (RNG_CONFIG_DERCEN_Enabled << RNG_CONFIG_DERCEN_Pos);
    NRF_RNG->TASKS_START = 1;
    for (uint8_t i = 0; i < length; i++) {
        NRF_RNG->EVENTS_VALRDY = 0;
        while (NRF_RNG->EVENTS_VALRDY == 0) { }
        p_buff[i] = (uint8_t)NRF_RNG->VALUE;
    }
    NRF_RNG->TASKS_STOP = 1;
}

static const sdc_rand_source_t sdc_rand_source = {
    .rand_poll = sdc_rand_poll,
};

// hci_transport_t implementation — feeds BTstack's HCI host through the
// Task 6 dispatcher into SDC, instead of a UART H4 byte stream. Exact
// struct field list verified against btstack/src/hci_transport.h while
// implementing this file (name/init/open/close/register_packet_handler/
// can_send_packet_now/send_packet/set_baudrate/reset_link/
// set_sco_config) — only the fields this project actually uses are
// implemented; the rest are UART/USB-extension fields BTstack calls
// conditionally and are safe to leave NULL.
static void (*s_packet_handler)(uint8_t packet_type, uint8_t *packet, uint16_t size) = NULL;

static void sdc_transport_init(const void *transport_config) { (void)transport_config; }
static int sdc_transport_open(void) { return 0; }
static int sdc_transport_close(void) { return 0; }

static void sdc_transport_register_packet_handler(void (*handler)(uint8_t packet_type, uint8_t *packet, uint16_t size)) {
    s_packet_handler = handler;
}

static int sdc_transport_can_send_packet_now(uint8_t packet_type) {
    (void)packet_type;
    return 1; // SDC's sdc_hci_data_put/hci_internal_cmd_put are synchronous from this call site
}

static int sdc_transport_send_packet(uint8_t packet_type, uint8_t *packet, int size) {
    (void)size;
    int32_t err;
    switch (packet_type) {
        case HCI_COMMAND_DATA_PACKET:
            err = hci_internal_cmd_put(packet);
            break;
        case HCI_ACL_DATA_PACKET:
            err = sdc_hci_data_put(packet);
            break;
        default:
            return -1;
    }
    return (err == 0) ? 0 : -1;
}

static const hci_transport_t sdc_transport = {
    .name = "sdc",
    .init = &sdc_transport_init,
    .open = &sdc_transport_open,
    .close = &sdc_transport_close,
    .register_packet_handler = &sdc_transport_register_packet_handler,
    .can_send_packet_now = &sdc_transport_can_send_packet_now,
    .send_packet = &sdc_transport_send_packet,
    .set_baudrate = NULL,
    .reset_link = NULL,
    .set_sco_config = NULL,
};

// Drains any pending event/data from SDC and forwards it to BTstack — the
// "read" half of this transport (send_packet above is the "write" half).
// Called every scan tick from platform_glue.c's vTaskDelay, same
// cooperative-polling style as mpsl_glue_poll()/kb_usb_task().
//
// Uses sdc_hci_get() (sdc_hci.h) directly rather than Task 6's
// hci_internal_msg_get() — the two are not interchangeable: sdc_hci_get()
// is SDC's own raw event/data retrieval API (uint8_t * msg_type_out, the
// signature this function is written against), while
// hci_internal_msg_get() (sdc_hci_dispatch.h) additionally consults the
// dispatcher's own user-command-handler bookkeeping and expects a
// sdc_hci_msg_type_t * out-param, a different type. Verified both
// signatures against their real vendored headers while implementing this
// file.
void sdc_transport_poll(void) {
    static uint8_t msg_buf[HCI_MSG_BUFFER_MAX_SIZE];
    uint8_t msg_type;
    while (sdc_hci_get(msg_buf, &msg_type) == 0) {
        if (!s_packet_handler) continue;
        switch (msg_type) {
            case SDC_HCI_MSG_TYPE_EVT:
                s_packet_handler(HCI_EVENT_PACKET, msg_buf, msg_buf[1] + 2); // BT_HCI_EVT_HDR_SIZE + param length
                break;
            case SDC_HCI_MSG_TYPE_DATA:
                s_packet_handler(HCI_ACL_DATA_PACKET, msg_buf, (msg_buf[2] | (msg_buf[3] << 8)) + 4); // HCI_DATA_HEADER_SIZE
                break;
            default:
                break;
        }
    }
}

// --- HID-over-GATT (identical shape to ble_hid_kbd_uart.c's) -----------

static const uint8_t hid_descriptor_keyboard[] = {
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xc0
};

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

static uint8_t pending_report[8];
static int report_dirty = 0;

static void send_pending(void) {
    if (con_handle == HCI_CON_HANDLE_INVALID) return;
    report_dirty = 0;
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
    int32_t err = sdc_init(sdc_fault_handler);
    if (err != 0) { while (1) { } }

    // Legacy (non-extended) advertising only — matches gap_advertisements_
    // set_params()/set_data() below, BTstack's legacy GAP advertising API,
    // not its separate extended-advertising API. sdc.h's own doc comment
    // says to call *either* sdc_support_adv() *or* sdc_support_ext_adv(),
    // never both — and verified against the real prebuilt libs while
    // implementing this file: libsoftdevice_controller_peripheral.a (the
    // single-role, peripheral-only variant this target links, matching
    // this file's "no Central role" design) doesn't even export
    // sdc_support_ext_adv() — only libsoftdevice_controller_multirole.a
    // does. The plan's original draft called both; that would have been
    // both redundant and a link failure on this library variant.
    sdc_support_adv();
    sdc_support_peripheral();

    err = sdc_rand_source_register(&sdc_rand_source);
    if (err != 0) { while (1) { } }

    // Query the real memory requirement for the role/feature configuration
    // just set up above (see the sdc_mem_buffer comment for why this can't
    // be a compile-time macro) and fault rather than silently overrun the
    // static buffer if it doesn't fit.
    int32_t required_mem = sdc_cfg_set(SDC_DEFAULT_RESOURCE_CFG_TAG, SDC_CFG_TYPE_NONE, NULL);
    if (required_mem < 0 || (uint32_t)required_mem > sizeof(sdc_mem_buffer)) {
        sdc_fault_handler(__FILE__, __LINE__);
    }

    err = sdc_enable(NULL, sdc_mem_buffer);
    if (err != 0) { while (1) { } }

    hci_init(&sdc_transport, NULL);

    l2cap_init();
    sm_init();
    sm_set_io_capabilities(IO_CAPABILITY_NO_INPUT_NO_OUTPUT);
    sm_set_authentication_requirements(SM_AUTHREQ_BONDING | SM_AUTHREQ_SECURE_CONNECTION);

    att_server_init(profile_data, NULL, NULL);

    battery_service_server_init(battery);
    device_information_service_server_init();
    hids_device_init(0, hid_descriptor_keyboard, sizeof(hid_descriptor_keyboard));

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
    pending_report[1] = 0;
    memcpy(&pending_report[2], keys, 6);
    report_dirty = 1;
    if (con_handle != HCI_CON_HANDLE_INVALID) {
        hids_device_request_can_send_now_event(con_handle);
    }
}
