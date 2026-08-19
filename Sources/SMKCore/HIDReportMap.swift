// The BLE HID-over-GATT keyboard report map, shared by every BLE transport:
// Sources/smk/BleHelper.swift (ESP32-C6 / esp_hidd) and
// ports/common/BleHidGatt.swift (BTstack -- pico_w, pico2_w, nrf52840,
// stm32wb). These held byte-identical copies until the usage range widened
// below, which has to land in both identically or one transport silently drops
// keys the other sends -- exactly the drift keycodes.json exists to prevent.
//
// Standard boot keyboard, Report ID 1: 8-bit modifier bitmap, 1 reserved byte,
// 5-bit LED output + 3-bit padding, 6-byte keycode array.
//
// The keycode array declares Logical/Usage Maximum 255 (two-byte form,
// 0x26/0x2A) rather than the 101 (0x65) it carried before. 101 is
// `application`, the highest usage the firmware knew at the time; every keycode
// above it -- keypadEqual 0x67, F13-F24, the 0x74-0x7E editing block,
// International/Language, the 0x99-0xA4 legacy block -- falls outside a
// 101-capped range and may be discarded by the host.
//
// USB needs no equivalent change: TUD_HID_REPORT_DESC_KEYBOARD() already
// declares HID_USAGE_MAX_N(255,2) and HID_LOGICAL_MAX_N(255,2).
let hidKeyboardReportMap: [UInt8] = [
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x06,        // Usage (Keyboard)
    0xa1, 0x01,        // Collection (Application)
    0x85, 0x01,        //   Report ID (1)
    0x05, 0x07,        //   Usage Page (Keyboard/Keypad)
    0x19, 0xe0,        //   Usage Minimum (LeftControl)
    0x29, 0xe7,        //   Usage Maximum (Right GUI)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x08,        //   Report Count (8)
    0x81, 0x02,        //   Input (Data, Variable, Absolute) -- modifier byte
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x03,        //   Input (Constant) -- reserved byte
    0x95, 0x05,        //   Report Count (5)
    0x75, 0x01,        //   Report Size (1)
    0x05, 0x08,        //   Usage Page (LEDs)
    0x19, 0x01,        //   Usage Minimum (Num Lock)
    0x29, 0x05,        //   Usage Maximum (Kana)
    0x91, 0x02,        //   Output (Data, Variable, Absolute) -- LED report
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x03,        //   Report Size (3)
    0x91, 0x03,        //   Output (Constant) -- LED padding
    0x95, 0x06,        //   Report Count (6)
    0x75, 0x08,        //   Report Size (8)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)   <- was 0x25, 0x65
    0x05, 0x07,        //   Usage Page (Keyboard/Keypad)
    0x19, 0x00,        //   Usage Minimum (0)
    0x2A, 0xFF, 0x00,  //   Usage Maximum (255)     <- was 0x29, 0x65
    0x81, 0x00,        //   Input (Data, Array) -- 6-byte keycode array
    0xc0,              // End Collection
]
