// USB descriptors for the SMK HID keyboard — shared by every TinyUSB port
// (rp2040 family, nrf52840, stm32f4, stm32wb). Nothing here is
// target-specific: pure TinyUSB descriptor tables/macros plus HID callbacks
// operating on smk_keymap_dispatch_packet, a cross-platform Swift function
// (Sources/SMKCore/KeymapProtocol.swift). This file used to exist as four
// byte-identical per-port copies under ports/*/platform/.
//
// Reuses the same VID/PID and product name as the ESP32 BLE config
// (Sources/components/ble_helper.c) so the device presents consistently:
//   VID 0x16C0, PID 0x05DF, "SMK Keyboard" by "Swift".

#include "tusb.h"
#include <string.h>
#include <stdbool.h>

void smk_keymap_dispatch_packet(const uint8_t *packet, uint8_t *response);

// ---------------------------------------------------------------------------
// Device Descriptor
// ---------------------------------------------------------------------------
tusb_desc_device_t const desc_device = {
    .bLength            = sizeof(tusb_desc_device_t),
    .bDescriptorType    = TUSB_DESC_DEVICE,
    .bcdUSB             = 0x0200,
    .bDeviceClass       = 0x00, // defined at interface level
    .bDeviceSubClass    = 0x00,
    .bDeviceProtocol    = 0x00,
    .bMaxPacketSize0    = CFG_TUD_ENDPOINT0_SIZE,

    .idVendor           = 0x16C0,
    .idProduct          = 0x05DF,
    .bcdDevice          = 0x0100,

    .iManufacturer      = 0x01,
    .iProduct           = 0x02,
    .iSerialNumber      = 0x03,

    .bNumConfigurations = 0x01,
};

uint8_t const *tud_descriptor_device_cb(void) {
    return (uint8_t const *)&desc_device;
}

// ---------------------------------------------------------------------------
// HID Report Descriptor — standard boot keyboard (8-byte report).
// ---------------------------------------------------------------------------
uint8_t const desc_hid_report[] = {
    TUD_HID_REPORT_DESC_KEYBOARD()
};

// ---------------------------------------------------------------------------
// HID Report Descriptor — 32-byte vendor-defined raw channel, used only for
// keymap upload (see Sources/SMKCore/KeymapProtocol.swift). Its own interface, so no
// Report ID is needed (unlike the BLE side, which multiplexes this onto the
// same GATT report characteristic as the keyboard and needs one).
// ---------------------------------------------------------------------------
uint8_t const desc_hid_report_raw[] = {
    0x06, 0x00, 0xFF,        // Usage Page (Vendor Defined 0xFF00)
    0x09, 0x01,              // Usage (0x01)
    0xA1, 0x01,              // Collection (Application)
    0x15, 0x00,              //   Logical Minimum (0)
    0x26, 0xFF, 0x00,        //   Logical Maximum (255)
    0x75, 0x08,              //   Report Size (8)
    0x95, 0x20,              //   Report Count (32)
    0x09, 0x01,              //   Usage (0x01)
    0x81, 0x02,              //   Input (Data,Var,Abs)
    0x95, 0x20,              //   Report Count (32)
    0x09, 0x01,              //   Usage (0x01)
    0x91, 0x02,              //   Output (Data,Var,Abs)
    0xC0                     // End Collection
};

uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance) {
    // instance 0 = keyboard (desc_hid_report), instance 1 = raw upload
    // channel (desc_hid_report_raw) — TinyUSB numbers HID instances in
    // declaration order within desc_configuration below.
    return (instance == 1) ? desc_hid_report_raw : desc_hid_report;
}

// ---------------------------------------------------------------------------
// Configuration Descriptor
// ---------------------------------------------------------------------------
enum { ITF_NUM_HID, ITF_NUM_RAWHID, ITF_NUM_TOTAL };

#define EPNUM_HID 0x81
#define EPNUM_RAWHID_OUT 0x02
#define EPNUM_RAWHID_IN  0x82

#define CONFIG_TOTAL_LEN (TUD_CONFIG_DESC_LEN + TUD_HID_DESC_LEN + TUD_HID_INOUT_DESC_LEN)

uint8_t const desc_configuration[] = {
    // Config: number, interface count, string index, total length, attribute, power (mA)
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, CONFIG_TOTAL_LEN,
                          TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP, 100),

    // Keyboard HID: string index, boot protocol, report descriptor len,
    //               EP In address, EP size, polling interval (ms)
    TUD_HID_DESCRIPTOR(ITF_NUM_HID, 0, HID_ITF_PROTOCOL_KEYBOARD,
                       sizeof(desc_hid_report), EPNUM_HID, CFG_TUD_HID_EP_BUFSIZE, 5),

    // Raw HID (keymap upload channel): vendor-defined, IN+OUT.
    TUD_HID_INOUT_DESCRIPTOR(ITF_NUM_RAWHID, 0, HID_ITF_PROTOCOL_NONE,
                             sizeof(desc_hid_report_raw), EPNUM_RAWHID_OUT, EPNUM_RAWHID_IN,
                             CFG_TUD_HID_EP_BUFSIZE, 5),
};

uint8_t const *tud_descriptor_configuration_cb(uint8_t index) {
    (void)index;
    return desc_configuration;
}

// ---------------------------------------------------------------------------
// String Descriptors
// ---------------------------------------------------------------------------
char const *string_desc_arr[] = {
    (const char[]){0x09, 0x04}, // 0: supported language = English (0x0409)
    "Swift",                    // 1: Manufacturer
    "SMK Keyboard",             // 2: Product
    "123456",                   // 3: Serial
};

static uint16_t _desc_str[32];

uint16_t const *tud_descriptor_string_cb(uint8_t index, uint16_t langid) {
    (void)langid;
    uint8_t chr_count;

    if (index == 0) {
        memcpy(&_desc_str[1], string_desc_arr[0], 2);
        chr_count = 1;
    } else {
        if (index >= sizeof(string_desc_arr) / sizeof(string_desc_arr[0])) {
            return NULL;
        }
        const char *str = string_desc_arr[index];
        chr_count = (uint8_t)strlen(str);
        if (chr_count > 31) chr_count = 31;
        for (uint8_t i = 0; i < chr_count; i++) {
            _desc_str[1 + i] = str[i];
        }
    }

    // First byte: length (in bytes), second byte: string type.
    _desc_str[0] = (uint16_t)((TUSB_DESC_STRING << 8) | (2 * chr_count + 2));
    return _desc_str;
}

// ---------------------------------------------------------------------------
// HID class callbacks (required by TinyUSB; we are output-only).
// ---------------------------------------------------------------------------
uint16_t tud_hid_get_report_cb(uint8_t instance, uint8_t report_id,
                               hid_report_type_t report_type, uint8_t *buffer,
                               uint16_t reqlen) {
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)reqlen;
    return 0;
}

static uint8_t s_pending_packet[32];
static volatile bool s_packet_pending = false;

void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id,
                           hid_report_type_t report_type, uint8_t const *buffer,
                           uint16_t bufsize) {
    if (instance == 1 && bufsize >= 32) {
        memcpy(s_pending_packet, buffer, sizeof(s_pending_packet));
        s_packet_pending = true;
        return;
    }
    (void)report_id; (void)report_type;
}

// Services a keymap-upload packet received by tud_hid_set_report_cb, called
// from the main loop (kb_usb_task, @_cdecl'd Swift in each port's
// UsbHid.swift) rather than from inside the USB callback itself --
// smk_keymap_dispatch_packet can trigger a multi-ms flash erase+program
// (e.g. smk_keymap_commit in the RP2040 KeymapStoreFlash.swift), which must
// not block the USB stack's own callback context.
void smk_keymap_usb_service(void) {
    if (!s_packet_pending) {
        return;
    }
    s_packet_pending = false;
    uint8_t response[32];
    smk_keymap_dispatch_packet(s_pending_packet, response);
    tud_hid_n_report(1, 0, response, sizeof(response));
}
