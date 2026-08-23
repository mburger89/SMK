// Shared BTstack HID-over-GATT logic — the keyboard's BLE HID service setup,
// advertising, event handling, and report sending, identical for every
// BTstack-based target. Compiled into four builds (see each CMakeLists):
//   - pico_w / pico2_w  (ports/rp2040, transport: cyw43_arch — BleHidPicoW.swift)
//   - smk_kbd_rp2040    (ports/rp2040, transport: CYW43439 over UART — BleHidKbdUart.swift)
//   - nrf52840          (transport: SoftDevice Controller — platform/ble_hid_sdc.c)
//   - stm32wb           (transport: CPU2 over IPCC — platform/ble_hid_wb.c)
// The ESP32-C6 build is NOT one of them — its BLE HID is NimBLE-based
// (Sources/smk/BleHelper.swift + Sources/components/ble_helper.c).
//
// This file used to exist as four near-verbatim copies: the HID-over-GATT
// halves of BleHidPicoW.swift (where the layout/constant verification notes
// below were first established — see that file's git history for the full
// story), BleHidKbdUart.swift, ble_hid_sdc.c, and ble_hid_wb.c. Each port
// keeps only its transport bring-up and calls smk_ble_hid_gatt_setup() once
// its HCI transport is registered (after hci_init(); this function ends
// with hci_power_control(HCI_POWER_ON)).
//
// Every numeric constant below was cross-checked against the real BTstack
// headers when the RP2040 ports were written — pico-sdk's bundled BTstack
// tree for those boards, the standalone ~/btstack checkout for
// nrf52840/stm32wb. The two trees agree on all of these values (they're
// wire-protocol constants and public-API enums, stable across versions).

// --- BTstack externs --------------------------------------------------------

@_extern(c, "l2cap_init")
func l2cap_init()

@_extern(c, "sm_init")
func sm_init()

// sm_set_io_capabilities takes io_capability_t (a C enum). Every ARM target
// here sizes small C enums to 1 byte (arm-none-eabi-gcc's default, and the
// RP2040 build passes -Xcc -fshort-enums to keep the Clang importer in
// sync) — so the real ABI parameter width is UInt8, not Int32.
@_extern(c, "sm_set_io_capabilities")
func sm_set_io_capabilities(_ ioCapability: UInt8)

@_extern(c, "sm_set_authentication_requirements")
func sm_set_authentication_requirements(_ authReq: UInt8)

@_extern(c, "att_server_init")
func att_server_init(_ dbData: UnsafePointer<UInt8>?, _ readCallback: UnsafeRawPointer?, _ writeCallback: UnsafeRawPointer?)

@_extern(c, "battery_service_server_init")
func battery_service_server_init(_ battery: UInt8)

@_extern(c, "device_information_service_server_init")
func device_information_service_server_init()

@_extern(c, "hids_device_init")
func hids_device_init(_ hidCountryCode: UInt8, _ descriptor: UnsafePointer<UInt8>, _ descriptorSize: UInt16)

@_extern(c, "gap_advertisements_set_params")
func gap_advertisements_set_params(_ advIntMin: UInt16, _ advIntMax: UInt16, _ advType: UInt8, _ ownAddrType: UInt8, _ directAddr: UnsafePointer<UInt8>, _ channelMap: UInt8, _ filterPolicy: UInt8)

// gap.h's real signature takes a non-const `uint8_t *` — BTstack doesn't
// actually mutate it, but the extern here matches the header. Called with
// the permanently-allocated advDataStorage below, not a scoped closure
// pointer — see the comment on advDataBytes for why.
@_extern(c, "gap_advertisements_set_data")
func gap_advertisements_set_data(_ advDataLen: UInt8, _ advData: UnsafeMutablePointer<UInt8>)

// gap_advertisements_enable's real parameter is plain C `int` (not an
// enum, so short-enums sizing doesn't apply) — 4 bytes, Int32.
@_extern(c, "gap_advertisements_enable")
func gap_advertisements_enable(_ enabled: Int32)

// UnsafeMutablePointer<BtstackPacketCallbackRegistration> doesn't typecheck
// across an @_extern(c,...) boundary ("cannot be represented in C") because
// the struct has an optional @convention(c) closure field.
// UnsafeMutableRawPointer (-> C `void *`) sidesteps that check; the byte
// layout at the address is unaffected.
@_extern(c, "hci_add_event_handler")
func hci_add_event_handler(_ registration: UnsafeMutableRawPointer)

@_extern(c, "sm_add_event_handler")
func sm_add_event_handler(_ registration: UnsafeMutableRawPointer)

@_extern(c, "hids_device_register_packet_handler")
func hids_device_register_packet_handler(_ handler: @convention(c) (UInt8, UInt16, UnsafeMutablePointer<UInt8>?, UInt16) -> Void)

// hci_power_control's real parameter is HCI_POWER_MODE (enum, 1 byte) and
// its real return type is `int` (Int32), not void.
@_extern(c, "hci_power_control")
func hci_power_control(_ mode: UInt8) -> Int32

// hids_device_send_input_report / hids_device_request_can_send_now_event
// both return uint8_t (a status code) per hids_device.h; discarded below,
// matching every one of the four former copies.
@_extern(c, "hids_device_send_input_report")
func hids_device_send_input_report(_ conHandle: UInt16, _ report: UnsafePointer<UInt8>, _ reportLen: UInt16) -> UInt8

@_extern(c, "hids_device_request_can_send_now_event")
func hids_device_request_can_send_now_event(_ conHandle: UInt16) -> UInt8

// btstack_packet_callback_registration_t — verified against
// btstack_defines.h. The real layout is { btstack_linked_item_t item;
// btstack_packet_handler_t callback; }, where btstack_linked_item_t is a
// single `next` pointer BTstack's linked-list bookkeeping writes through
// when the registration is added. Omitting that first field would undersize
// the struct and let BTstack write past the real Swift storage.
struct BtstackLinkedItem {
    var next: UnsafeMutableRawPointer?
}

struct BtstackPacketCallbackRegistration {
    var item = BtstackLinkedItem()
    var callback: (@convention(c) (UInt8, UInt16, UnsafeMutablePointer<UInt8>?, UInt16) -> Void)?
}

// smk_profile_data() — accessor for the GATT database generated from each
// port's smk_hid.gatt (byte-identical across ports; HID-over-GATT doesn't
// depend on the transport under it) into the build directory's smk_hid.h,
// instantiated by ports/common/smk_hid_gatt_data.c. An accessor function
// rather than a direct `@_extern(c, "profile_data")` array binding because
// the standalone BTstack checkout's compile_gatt.py declares the array
// `static` — no external symbol to bind — while pico-sdk's bundled version
// doesn't; the accessor works identically against both (see that C file's
// header comment).
@_extern(c, "smk_profile_data")
func smk_profile_data() -> UnsafePointer<UInt8>

// HCI_CON_HANDLE_INVALID (btstack_defines.h) — verified 0xffffu.
private let hciConHandleInvalid: UInt16 = 0xFFFF

// hidDescriptorKeyboard / advData are handed to BTstack calls that store
// the raw pointer LONG-TERM, not just for the duration of the call —
// verified against the real vendored source:
//   - hids_device_init() -> ble/gatt-service/hids_device.c:420 stores
//     `instance->hid_descriptor = hid_descriptor` and reads it again on
//     every future protocol-mode/report-map GATT read.
//   - gap_advertisements_set_data() -> hci.c stores
//     `hci_stack->le_advertisements_data = advertising_data`, read again
//     later inside hci_run(), not synchronously during the call.
// A withUnsafeBufferPointer closure's pointer is only contractually valid
// inside the closure — so each is copied once into permanently allocated,
// intentionally-never-freed storage in smk_ble_hid_gatt_setup() below,
// matching the process-lifetime storage a C `static const uint8_t[]` array
// guaranteed in the former C copies.
// Hoisted to Sources/SMKCore/HIDReportMap.swift: Sources/smk/BleHelper.swift
// held a byte-identical copy, and the usage-range widening had to land in both
// identically or one transport would silently drop keys the other sends.
// hids_device_init below takes the length from .count, so the map growing by
// two bytes needs no change here.
private let hidDescriptorKeyboardBytes: [UInt8] = hidKeyboardReportMap

// Advertisement: flags, appearance (keyboard), 16-bit HID service UUID,
// name. All BLUETOOTH_DATA_TYPE_* type bytes verified against
// bluetooth_data_types.h.
private let advDataBytes: [UInt8] = [
    0x02, 0x01, 0x06,       // len=2, BLUETOOTH_DATA_TYPE_FLAGS(0x01); General Discoverable + BR/EDR Not Supported
    0x03, 0x19, 0xC1, 0x03, // len=3, BLUETOOTH_DATA_TYPE_APPEARANCE(0x19); 0x03C1 = Keyboard
    0x03, 0x02, 0x12, 0x18, // len=3, BLUETOOTH_DATA_TYPE_INCOMPLETE_LIST_OF_16_BIT_SERVICE_CLASS_UUIDS(0x02); HID service UUID 0x1812
    0x0d, 0x09, 0x53, 0x4D, 0x4B, 0x20, 0x4B, 0x65, 0x79, 0x62, 0x6F, 0x61, 0x72, 0x64, // len=13, BLUETOOTH_DATA_TYPE_COMPLETE_LOCAL_NAME(0x09); "SMK Keyboard"
]

// Permanent copies of the two buffers above, allocated once in
// smk_ble_hid_gatt_setup() and intentionally never deallocated (deliberate
// leak, matching a C `static` array's process-lifetime storage — this
// firmware never exits).
private var hidDescriptorKeyboardStorage: UnsafeMutableBufferPointer<UInt8>?
private var advDataStorage: UnsafeMutableBufferPointer<UInt8>?

private func permanentCopy(_ bytes: [UInt8]) -> UnsafeMutableBufferPointer<UInt8> {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
    _ = storage.initialize(from: bytes)
    return storage
}

private var hciEventCallbackRegistration = BtstackPacketCallbackRegistration()
private var smEventCallbackRegistration = BtstackPacketCallbackRegistration()
private let battery: UInt8 = 100
private var conHandle: UInt16 = hciConHandleInvalid
private var protocolMode: UInt8 = 1
private var pendingReport = [UInt8](repeating: 0, count: 8)
private var reportDirty = false

private func sendPending() {
    guard conHandle != hciConHandleInvalid else { return }
    reportDirty = false
    pendingReport.withUnsafeBufferPointer { _ = hids_device_send_input_report(conHandle, $0.baseAddress!, 8) }
}

// hci_event_packet_get_type / hci_event_hids_meta_get_subevent_code /
// hids_subevent_protocol_mode_get_protocol_mode /
// hids_subevent_input_report_enable_get_con_handle are all declared
// `static inline` in btstack_event.h — real code, but with no linkable
// symbol to bind an @_extern(c,...) to. Reimplemented as direct byte
// reads, copied exactly from those inline bodies.
private func hciEventPacketGetType(_ event: UnsafePointer<UInt8>) -> UInt8 {
    event[0]
}

private func hciEventHidsMetaGetSubeventCode(_ event: UnsafePointer<UInt8>) -> UInt8 {
    event[2]
}

private func hidsSubeventProtocolModeGetProtocolMode(_ event: UnsafePointer<UInt8>) -> UInt8 {
    event[5]
}

private func hidsSubeventInputReportEnableGetConHandle(_ event: UnsafePointer<UInt8>) -> UInt16 {
    UInt16(event[3]) | (UInt16(event[4]) << 8) // little_endian_read_16(event, 3)
}

@_cdecl("smk_ble_hid_packet_handler")
private func packetHandler(_ packetType: UInt8, _ channel: UInt16, _ packet: UnsafeMutablePointer<UInt8>?, _ size: UInt16) {
    guard packetType == 0x04, let packet = packet else { return } // HCI_EVENT_PACKET (bluetooth.h) — verified 0x04
    let eventType = hciEventPacketGetType(packet)
    if eventType == 0x05 { // HCI_EVENT_DISCONNECTION_COMPLETE (btstack_defines.h) — verified 0x05u
        conHandle = hciConHandleInvalid
    } else if eventType == 0xF1 { // HCI_EVENT_HIDS_META (btstack_defines.h) — verified 0xF1u
        let subevent = hciEventHidsMetaGetSubeventCode(packet)
        switch subevent {
        case 0x05: // HIDS_SUBEVENT_INPUT_REPORT_ENABLE (btstack_defines.h) — verified 0x05u
            conHandle = hidsSubeventInputReportEnableGetConHandle(packet)
        case 0x02: // HIDS_SUBEVENT_PROTOCOL_MODE — verified 0x02u
            protocolMode = hidsSubeventProtocolModeGetProtocolMode(packet)
        case 0x01: // HIDS_SUBEVENT_CAN_SEND_NOW — verified 0x01u
            if reportDirty { sendPending() }
        default:
            break
        }
    }
}

// The whole HID-over-GATT setup: L2CAP, Security Manager, ATT server (the
// generated GATT database), Battery + Device Information + HID services,
// advertising, event-handler registration, then HCI power-on. Call exactly
// once, after the port's HCI transport is fully registered (hci_init() has
// run) — hci_power_control(HCI_POWER_ON) at the end is what triggers the
// transport's own init/boot sequence. @_cdecl so the C transport files
// (ble_hid_sdc.c, ble_hid_wb.c) can call it; the RP2040 Swift transports
// call it same-module.
@_cdecl("smk_ble_hid_gatt_setup")
func smk_ble_hid_gatt_setup() {
    l2cap_init()
    sm_init()
    sm_set_io_capabilities(3) // IO_CAPABILITY_NO_INPUT_NO_OUTPUT (bluetooth.h io_capability_t) — verified 3
    sm_set_authentication_requirements(0x09) // SM_AUTHREQ_BONDING(0x01) | SM_AUTHREQ_SECURE_CONNECTION(0x08) — verified 0x09

    // Unlike hidDescriptorKeyboardBytes/advDataBytes below, the GATT
    // database doesn't need permanentCopy() even though att_server_init
    // retains this pointer long-term: it's a C `.rodata` global with static
    // storage duration — its address is stable for the life of the process.
    att_server_init(smk_profile_data(), nil, nil)

    battery_service_server_init(battery)
    device_information_service_server_init()
    // hids_device_init stores this pointer long-term (hids_device.c:420) —
    // must be the permanent copy, not a withUnsafeBufferPointer-scoped one.
    let hidDescStorage = permanentCopy(hidDescriptorKeyboardBytes)
    hidDescriptorKeyboardStorage = hidDescStorage
    hids_device_init(0, hidDescStorage.baseAddress!, UInt16(hidDescStorage.count))

    // gap_advertisements_set_params's direct_address is memcpy'd into
    // hci_stack's own storage synchronously — BTstack does NOT retain this
    // pointer, so a withUnsafeBufferPointer-scoped one is fine here.
    let nullAddr = [UInt8](repeating: 0, count: 6)
    nullAddr.withUnsafeBufferPointer { addrPtr in
        gap_advertisements_set_params(0x0030, 0x0030, 0, 0, addrPtr.baseAddress!, 0x07, 0x00)
    }
    // gap_advertisements_set_data stores this pointer long-term too — must
    // be the permanent copy.
    let advStorage = permanentCopy(advDataBytes)
    advDataStorage = advStorage
    gap_advertisements_set_data(UInt8(advStorage.count), advStorage.baseAddress!)
    gap_advertisements_enable(1)

    hciEventCallbackRegistration.callback = packetHandler
    withUnsafeMutablePointer(to: &hciEventCallbackRegistration) { hci_add_event_handler(UnsafeMutableRawPointer($0)) }
    smEventCallbackRegistration.callback = packetHandler
    withUnsafeMutablePointer(to: &smEventCallbackRegistration) { sm_add_event_handler(UnsafeMutableRawPointer($0)) }
    hids_device_register_packet_handler(packetHandler)

    _ = hci_power_control(1) // HCI_POWER_ON (hci_cmd.h HCI_POWER_MODE) — verified 1
}

// Called from the shared scan loop (Sources/smk/Main.swift, same-module
// resolution on every target that compiles this file). Degrades gracefully
// without a connection — the report is latched and sent once a host
// subscribes.
func send_keyboard_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    pendingReport[0] = modifier
    pendingReport[1] = 0
    for i in 0..<6 { pendingReport[2 + i] = keys[i] }
    reportDirty = true
    if conHandle != hciConHandleInvalid {
        _ = hids_device_request_can_send_now_event(conHandle)
    }
}
