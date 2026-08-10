// BLE HID glue for Pico W — Swift port of the former
// ports/rp2040/platform/ble_hid.c's SMK_ENABLE_BLE branch. Close relative
// of ports/nrf52840/platform/ble_hid_sdc.c's GATT-setup half — read that
// file alongside this one; the HID-over-GATT logic is nearly identical,
// only the transport bring-up differs (cyw43_arch_init() here vs. SDC
// there). No hci_transport_t-equivalent vtable struct exists in this file
// at all — cyw43_arch owns BTstack's transport setup internally.
//
// Compiled for every non-smk_kbd_rp2040 RP2040 board (plain Pico, Pico W,
// Pico 2, Pico 2 W) — always included in ports/rp2040/CMakeLists.txt's
// Swift source list, exactly like the deleted ble_hid.c was always
// included in the C source list for those boards. The real-vs-stub split
// below (#if SMK_ENABLE_BLE) mirrors that file's own #ifdef SMK_ENABLE_BLE
// / #else, driven by the same -DSMK_ENABLE_BLE define (set only for
// pico_w/pico2_w), now also passed to swiftc as a bare -D so this file's
// #if sees it too (see ports/rp2040/CMakeLists.txt's _smk_swift_defs).
//
// Every numeric constant below was cross-checked against pico-sdk's
// BUNDLED BTstack tree (~/pico-sdk/lib/btstack/src/*.h) — NOT the
// standalone ~/btstack checkout the nRF52840 port uses; the two are not
// guaranteed to be the same version. Several of this task's planned
// placeholder values turned out wrong against the real headers — see the
// inline "verified" comments below for each one (task-12-report.md has
// the full list).

#if SMK_ENABLE_BLE

@_extern(c, "cyw43_arch_init")
func cyw43_arch_init() -> Int32

@_extern(c, "l2cap_init")
func l2cap_init()

@_extern(c, "sm_init")
func sm_init()

// sm_set_io_capabilities takes io_capability_t (a C enum). This whole
// project's RP2040 Swift target passes -Xcc -fshort-enums to keep the
// Clang importer in sync with real GCC codegen, and arm-none-eabi-gcc's
// own default (verified empirically against the exact toolchain this
// project uses) already sizes small enums to 1 byte with no flag needed
// — so the real ABI parameter width here is UInt8, not the plan's Int32.
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

// gap.h's real signature takes a non-const `uint8_t *`, not `const
// uint8_t *` — BTstack doesn't actually mutate it (the deleted C file
// cast away const at the call site: `(uint8_t *)adv_data`), but the
// extern here matches the header, so advData below is `var` and passed
// via withUnsafeMutableBufferPointer.
@_extern(c, "gap_advertisements_set_data")
func gap_advertisements_set_data(_ advDataLen: UInt8, _ advData: UnsafeMutablePointer<UInt8>)

// gap_advertisements_enable's real parameter is plain C `int` (not an
// enum, so -fshort-enums doesn't apply) — 4 bytes, Int32. The plan's
// UInt8 was wrong.
@_extern(c, "gap_advertisements_enable")
func gap_advertisements_enable(_ enabled: Int32)

// UnsafeMutablePointer<BtstackPacketCallbackRegistration> doesn't
// typecheck across an @_extern(c,...) boundary here ("cannot be
// represented in C") because the struct has an optional @convention(c)
// closure field — Swift's C-representability check for @_extern(c,...)
// parameters doesn't look through nested struct fields the way
// ClangImporter would for a real header. UnsafeMutableRawPointer (-> C
// `void *`) sidesteps that check; the byte layout at the address is
// unaffected, so BTstack still reads/writes the real struct correctly.
@_extern(c, "hci_add_event_handler")
func hci_add_event_handler(_ registration: UnsafeMutableRawPointer)

@_extern(c, "sm_add_event_handler")
func sm_add_event_handler(_ registration: UnsafeMutableRawPointer)

@_extern(c, "hids_device_register_packet_handler")
func hids_device_register_packet_handler(_ handler: @convention(c) (UInt8, UInt16, UnsafeMutablePointer<UInt8>?, UInt16) -> Void)

// hci_power_control's real parameter is HCI_POWER_MODE (enum, 1 byte
// under -fshort-enums — matches the plan's UInt8) but its real return
// type is `int` (Int32), not void as the plan implied by omission.
@_extern(c, "hci_power_control")
func hci_power_control(_ mode: UInt8) -> Int32

// hids_device_send_input_report / hids_device_request_can_send_now_event
// both actually return uint8_t (a status code) per hids_device.h, not
// void as the plan declared — fixed below even though this file (like
// the deleted C file) discards the result.
@_extern(c, "hids_device_send_input_report")
func hids_device_send_input_report(_ conHandle: UInt16, _ report: UnsafePointer<UInt8>, _ reportLen: UInt16) -> UInt8

@_extern(c, "hids_device_request_can_send_now_event")
func hids_device_request_can_send_now_event(_ conHandle: UInt16) -> UInt8

// btstack_packet_callback_registration_t — verified against
// btstack_defines.h. NOT the one-field struct the plan guessed: the real
// layout is { btstack_linked_item_t item; btstack_packet_handler_t
// callback; }, where btstack_linked_item_t itself is a single `next`
// pointer BTstack's linked-list bookkeeping writes through when the
// registration is added via hci_add_event_handler/sm_add_event_handler.
// Omitting that first field would undersize the struct and let BTstack
// write past the real Swift storage / read garbage as the `next` link.
struct BtstackLinkedItem {
    var next: UnsafeMutableRawPointer?
}

struct BtstackPacketCallbackRegistration {
    var item = BtstackLinkedItem()
    var callback: (@convention(c) (UInt8, UInt16, UnsafeMutablePointer<UInt8>?, UInt16) -> Void)?
}

// profile_data — generated by pico_btstack_make_gatt_header() from
// smk_hid.gatt into the build directory's smk_hid.h as
// `const uint8_t profile_data[] = {...}` (compile_gatt.py's template has
// no `static`, so it's a genuine external symbol in C). Embedded Swift
// has no ClangImporter path to pull in a generated header here, so this
// binds directly to the linker symbol as a scalar extern var and
// recovers the array's base address via its own storage address — this
// pattern (extern C array -> Swift `@_extern(c,...) var` of the element
// type -> address-of) was verified end-to-end with a standalone host
// probe (matching {1,2,3,4,5} test data read back correctly through the
// resulting pointer) before relying on it here. The plan's placeholder
// `nil` first argument to att_server_init was flagged as "almost
// certainly wrong" and confirmed so: the deleted ble_hid.c's real call
// is `att_server_init(profile_data, NULL, NULL)`.
@_extern(c, "profile_data")
var profile_data: UInt8

// HCI_CON_HANDLE_INVALID (btstack_defines.h) — verified 0xffffu, matches plan.
private let hciConHandleInvalid: UInt16 = 0xFFFF

private let hidDescriptorKeyboard: [UInt8] = [
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xc0
]

// Advertisement: flags, appearance (keyboard), 16-bit HID service UUID,
// name. All BLUETOOTH_DATA_TYPE_* type bytes verified against
// bluetooth_data_types.h. `var`, not `let`: gap_advertisements_set_data
// takes a non-const pointer (see above).
private var advData: [UInt8] = [
    0x02, 0x01, 0x06,       // len=2, BLUETOOTH_DATA_TYPE_FLAGS(0x01) — verified, matches plan; General Discoverable + BR/EDR Not Supported
    0x03, 0x19, 0xC1, 0x03, // len=3, BLUETOOTH_DATA_TYPE_APPEARANCE(0x19) — verified, matches plan; 0x03C1 = Keyboard
    0x03, 0x02, 0x12, 0x18, // len=3, BLUETOOTH_DATA_TYPE_INCOMPLETE_LIST_OF_16_BIT_SERVICE_CLASS_UUIDS — verified 0x02, plan's 0x03 was wrong (0x03 is the *complete*-list type, a different AD type); HID service UUID 0x1812
    0x0d, 0x09, 0x53, 0x4D, 0x4B, 0x20, 0x4B, 0x65, 0x79, 0x62, 0x6F, 0x61, 0x72, 0x64, // len=13, BLUETOOTH_DATA_TYPE_COMPLETE_LOCAL_NAME(0x09) — verified, matches plan; "SMK Keyboard"
]

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
// symbol to bind an @_extern(c,...) to (established pattern from Tasks
// 8-11: the plan's suggested @_extern targets sometimes turn out to be
// static inline/macro-only). Reimplemented below as direct byte reads,
// copied exactly from those inline bodies.
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
    guard packetType == 0x04, let packet = packet else { return } // HCI_EVENT_PACKET (bluetooth.h) — verified 0x04, matches plan
    let eventType = hciEventPacketGetType(packet)
    if eventType == 0x05 { // HCI_EVENT_DISCONNECTION_COMPLETE (btstack_defines.h) — verified 0x05u, matches plan
        conHandle = hciConHandleInvalid
    } else if eventType == 0xF1 { // HCI_EVENT_HIDS_META (btstack_defines.h) — verified 0xF1u; plan's 0xFF placeholder was WRONG
        let subevent = hciEventHidsMetaGetSubeventCode(packet)
        switch subevent {
        case 0x05: // HIDS_SUBEVENT_INPUT_REPORT_ENABLE (btstack_defines.h) — verified 0x05u; plan's 0x01 placeholder was WRONG
            conHandle = hidsSubeventInputReportEnableGetConHandle(packet)
        case 0x02: // HIDS_SUBEVENT_PROTOCOL_MODE — verified 0x02u, matches plan
            protocolMode = hidsSubeventProtocolModeGetProtocolMode(packet)
        case 0x01: // HIDS_SUBEVENT_CAN_SEND_NOW — verified 0x01u; plan's 0x03 placeholder was WRONG
            if reportDirty { sendPending() }
        default:
            break
        }
    }
}

func init_ble_hid() {
    guard cyw43_arch_init() == 0 else { return } // wireless init failed; USB path still works

    l2cap_init()
    sm_init()
    sm_set_io_capabilities(3) // IO_CAPABILITY_NO_INPUT_NO_OUTPUT (bluetooth.h io_capability_t) — verified 3 (4th enumerator after DISPLAY_ONLY=0, DISPLAY_YES_NO=1, KEYBOARD_ONLY=2); plan's 0 placeholder was WRONG (0 is IO_CAPABILITY_DISPLAY_ONLY)
    sm_set_authentication_requirements(0x09) // SM_AUTHREQ_BONDING(0x01) | SM_AUTHREQ_SECURE_CONNECTION(0x08) — verified 0x09; plan's 0x03 placeholder was WRONG

    withUnsafePointer(to: &profile_data) {
        att_server_init($0, nil, nil)
    }

    battery_service_server_init(battery)
    device_information_service_server_init()
    hidDescriptorKeyboard.withUnsafeBufferPointer { hids_device_init(0, $0.baseAddress!, UInt16($0.count)) }

    let nullAddr = [UInt8](repeating: 0, count: 6)
    nullAddr.withUnsafeBufferPointer { addrPtr in
        gap_advertisements_set_params(0x0030, 0x0030, 0, 0, addrPtr.baseAddress!, 0x07, 0x00)
    }
    advData.withUnsafeMutableBufferPointer { gap_advertisements_set_data(UInt8($0.count), $0.baseAddress!) }
    gap_advertisements_enable(1)

    hciEventCallbackRegistration.callback = packetHandler
    withUnsafeMutablePointer(to: &hciEventCallbackRegistration) { hci_add_event_handler(UnsafeMutableRawPointer($0)) }
    smEventCallbackRegistration.callback = packetHandler
    withUnsafeMutablePointer(to: &smEventCallbackRegistration) { sm_add_event_handler(UnsafeMutableRawPointer($0)) }
    hids_device_register_packet_handler(packetHandler)

    _ = hci_power_control(1) // HCI_POWER_ON (hci_cmd.h HCI_POWER_MODE: HCI_POWER_OFF=0, HCI_POWER_ON=1, HCI_POWER_SLEEP=2) — verified 1, matches plan
}

func send_keyboard_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    pendingReport[0] = modifier
    pendingReport[1] = 0
    for i in 0..<6 { pendingReport[2 + i] = keys[i] }
    reportDirty = true
    if conHandle != hciConHandleInvalid {
        _ = hids_device_request_can_send_now_event(conHandle)
    }
}

#else // !SMK_ENABLE_BLE — plain Pico / Pico 2 (no CYW43 radio): no-op
      // stubs, matching the deleted ble_hid.c's own #else branch so the
      // shared scan loop (Main.swift) links and runs USB-only.

func init_ble_hid() {}

func send_keyboard_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    _ = modifier
    _ = keys
}

#endif // SMK_ENABLE_BLE
