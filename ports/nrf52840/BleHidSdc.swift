// BLE HID transport bring-up for nrf52840dk — Swift port of the former C
// transport half of platform/ble_hid_sdc.c. Talks to Nordic's SoftDevice
// Controller (running in this same firmware image) through the adapted HCI
// dispatcher in platform/sdc_hci_dispatch.c. The HID-over-GATT half is the
// shared ports/common/BleHidGatt.swift; what remains in the C file is only
// what Swift can't express: the CMSIS-intrinsic hal_cpu_* wrappers, the
// NRF_RNG register-polling entropy source (naturally volatile in C), and
// the spin-forever fault handler this file reuses as its hang primitive.
//
// *** STATUS: build-only, no hardware verification — carried over from the
// C original, see its header for the full history of review findings
// (Critical #1-#4) whose fixes this port preserves. ***

// --- BTstack core ------------------------------------------------------------

@_extern(c, "btstack_memory_init")
func btstack_memory_init()

@_extern(c, "btstack_run_loop_embedded_get_instance")
func btstack_run_loop_embedded_get_instance() -> UnsafeMutableRawPointer?

@_extern(c, "btstack_run_loop_init")
func btstack_run_loop_init(_ runLoop: UnsafeMutableRawPointer?)

@_extern(c, "hci_init")
func hci_init(_ transport: UnsafeRawPointer?, _ transportConfig: UnsafeRawPointer?)

// --- SoftDevice Controller (sdc.h / sdc_soc.h / sdc_hci.h) -------------------
// Signatures verified against the real vendored headers
// (~/sdk-nrfxlib/softdevice_controller/include).

@_extern(c, "sdc_init")
func sdc_init(_ faultHandler: (@convention(c) (UnsafePointer<CChar>?, UInt32) -> Void)?) -> Int32

@_extern(c, "sdc_support_adv")
func sdc_support_adv() -> Int32

@_extern(c, "sdc_support_peripheral")
func sdc_support_peripheral() -> Int32

@_extern(c, "sdc_rand_source_register")
func sdc_rand_source_register(_ randSource: UnsafeRawPointer) -> Int32

@_extern(c, "sdc_cfg_set")
func sdc_cfg_set(_ configTag: UInt8, _ configType: UInt8, _ resourceCfg: UnsafeRawPointer?) -> Int32

@_extern(c, "sdc_enable")
func sdc_enable(_ callback: UnsafeRawPointer?, _ memBuffer: UnsafeMutablePointer<UInt8>) -> Int32

// Task 6's dispatcher (platform/sdc_hci_dispatch.c). The msg-type out-param
// is sdc_hci_msg_type_t — verified 1 byte on this toolchain (see the C
// file's enum-width probe note), so UnsafeMutablePointer<UInt8> matches the
// real ABI.
@_extern(c, "hci_internal_cmd_put")
func hci_internal_cmd_put(_ cmd: UnsafeMutablePointer<UInt8>?) -> Int32

@_extern(c, "sdc_hci_data_put")
func sdc_hci_data_put(_ data: UnsafePointer<UInt8>?) -> Int32

@_extern(c, "hci_internal_msg_get")
func hci_internal_msg_get(_ msgOut: UnsafeMutablePointer<UInt8>, _ msgTypeOut: UnsafeMutablePointer<UInt8>) -> Int32

// --- C remainder (platform/ble_hid_sdc.c) ------------------------------------

// Spins forever — used both as SDC's registered fault handler and as this
// file's own hang-on-unrecoverable-error primitive (the C original's
// `while (1) { }`), keeping the infinite loop in C where its semantics are
// unambiguous.
@_extern(c, "smk_sdc_fault_handler")
func smk_sdc_fault_handler(_ file: UnsafePointer<CChar>?, _ line: UInt32)

// NRF_RNG register-polling entropy source — stays C (naturally-volatile
// hardware register access; feeding LE Secure Connections pairing).
@_extern(c, "smk_sdc_rand_poll")
func smk_sdc_rand_poll(_ buffer: UnsafeMutablePointer<UInt8>?, _ length: UInt8)

// --- Struct mirrors ----------------------------------------------------------

// sdc_rand_source_t (sdc_soc.h): exactly one function pointer.
struct SdcRandSource {
    var randPoll: (@convention(c) (UnsafeMutablePointer<UInt8>?, UInt8) -> Void)?
}

// hci_transport_t (btstack/src/hci_transport.h) — name pointer + 9 function
// pointers in declaration order: init, open, close,
// register_packet_handler, can_send_packet_now, send_packet, set_baudrate,
// reset_link, set_sco_config. Ten same-size pointer fields — the same
// verified mirror class as BtstackUartVtable (ports/rp2040) and
// BtstackPacketCallbackRegistration (ports/common/BleHidGatt.swift). The
// unused UART/USB-extension tail fields are untyped nil pointers.
struct HciTransportVtable {
    var name: UnsafePointer<CChar>?
    var initFn: (@convention(c) (UnsafeRawPointer?) -> Void)?
    var open: (@convention(c) () -> Int32)?
    var close: (@convention(c) () -> Int32)?
    var registerPacketHandler: (@convention(c) ((@convention(c) (UInt8, UnsafeMutablePointer<UInt8>?, UInt16) -> Void)?) -> Void)?
    // Deliberately nil — Critical #4: BTstack decides sync-vs-async purely
    // by this field's NULL-ness (hci_transport_synchronous()). This
    // transport IS synchronous (hci_internal_cmd_put/sdc_hci_data_put
    // return before send_packet returns); a non-NULL always-1 stub here
    // told BTstack to wait for an HCI_EVENT_TRANSPORT_PACKET_SENT that
    // never came, wedging after exactly one packet.
    var canSendPacketNow: UnsafeRawPointer? = nil
    var sendPacket: (@convention(c) (UInt8, UnsafeMutablePointer<UInt8>?, Int32) -> Int32)?
    var setBaudrate: UnsafeRawPointer? = nil
    var resetLink: UnsafeRawPointer? = nil
    var setScoConfig: UnsafeRawPointer? = nil
}

// --- Transport implementation ------------------------------------------------

// HCI packet-type bytes (Bluetooth Core Spec Vol 4 Part A; same values
// BTstack's bluetooth.h defines).
private let hciCommandDataPacket: UInt8 = 0x01
private let hciAclDataPacket: UInt8 = 0x02
private let hciEventPacket: UInt8 = 0x04

// sdc_hci_msg_type_t values (sdc_hci.h): NONE=0x00, DATA=0x02, EVT=0x04.
private let sdcHciMsgTypeData: UInt8 = 0x02
private let sdcHciMsgTypeEvt: UInt8 = 0x04

private var sdcPacketHandler: (@convention(c) (UInt8, UnsafeMutablePointer<UInt8>?, UInt16) -> Void)? = nil

private func sdcTransportInit(_ transportConfig: UnsafeRawPointer?) {}
private func sdcTransportOpen() -> Int32 { 0 }
private func sdcTransportClose() -> Int32 { 0 }

private func sdcTransportRegisterPacketHandler(_ handler: (@convention(c) (UInt8, UnsafeMutablePointer<UInt8>?, UInt16) -> Void)?) {
    sdcPacketHandler = handler
}

private func sdcTransportSendPacket(_ packetType: UInt8, _ packet: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    let err: Int32
    switch packetType {
    case hciCommandDataPacket:
        err = hci_internal_cmd_put(packet)
    case hciAclDataPacket:
        err = sdc_hci_data_put(packet)
    default:
        return -1
    }
    return err == 0 ? 0 : -1
}

private let sdcTransportNameBytes: [UInt8] = Array("sdc".utf8) + [0]

private var sdcTransport = HciTransportVtable(
    name: nil, // permanent copy installed by init (see below)
    initFn: sdcTransportInit,
    open: sdcTransportOpen,
    close: sdcTransportClose,
    registerPacketHandler: sdcTransportRegisterPacketHandler,
    sendPacket: sdcTransportSendPacket
)

private var sdcRandSource = SdcRandSource(randPoll: smk_sdc_rand_poll)

// HCI_MSG_BUFFER_MAX_SIZE (sdc_hci.h): HCI_CMD_MAX_SIZE(255) +
// HCI_CMD_HEADER_SIZE(3) = 258.
private var sdcMsgBuf = [UInt8](repeating: 0, count: 258)

// Drains any pending event/data from SDC and forwards it to BTstack — the
// "read" half of this transport (send_packet above is the "write" half).
// Called every scan tick from platform_glue.c's vTaskDelay (hence @_cdecl),
// same cooperative-polling style as mpsl_glue_poll()/kb_usb_task().
//
// hci_internal_msg_get (NOT bare sdc_hci_get) is load-bearing — Critical #1:
// the dispatcher synthesizes Command Complete/Status events into its own
// latch, and only hci_internal_msg_get drains that latch before falling
// through to sdc_hci_get; bare sdc_hci_get would stall BTstack's init state
// machine forever and wedge hci_internal_cmd_put with -NRF_EPERM. See the C
// original's git history for the full analysis.
@_cdecl("sdc_transport_poll")
func sdc_transport_poll() {
    sdcMsgBuf.withUnsafeMutableBufferPointer { buf in
        let base = buf.baseAddress!
        var msgType: UInt8 = 0 // zero-init: cheap insurance for the enum-width hazard
        while hci_internal_msg_get(base, &msgType) == 0 {
            guard let handler = sdcPacketHandler else { continue }
            switch msgType {
            case sdcHciMsgTypeEvt:
                handler(hciEventPacket, base, UInt16(base[1]) + 2) // event header + param length
            case sdcHciMsgTypeData:
                handler(hciAclDataPacket, base, (UInt16(base[2]) | (UInt16(base[3]) << 8)) + 4) // ACL header + payload
            default:
                break
            }
        }
    }
}

// Peripheral-role-only, single connection (MAX_NR_HCI_CONNECTIONS in
// btstack_config.h) — no compile-time sizing macro exists in this SDC
// release (see the C original's research note), so the pool is sized
// generously and the real requirement is queried at runtime via
// sdc_cfg_set(tag, SDC_CFG_TYPE_NONE, NULL), faulting rather than silently
// overrunning if it doesn't fit.
private let sdcMemBufferSize = 3600
private var sdcMemBuffer: UnsafeMutableRawPointer? = nil

@_cdecl("init_ble_hid")
func initBleHidSdc() {
    // Critical #3: BTstack's memory pools stay NULL forever unless this is
    // called — first, before anything else touches BTstack.
    btstack_memory_init()

    // Critical #2: hci.c registers timers/data sources against whatever run
    // loop btstack_run_loop_init() configured — must precede hci_init().
    // btstack_run_loop_embedded_execute_once() is pumped every tick from
    // platform_glue.c's vTaskDelay, alongside sdc_transport_poll() above.
    btstack_run_loop_init(btstack_run_loop_embedded_get_instance())

    guard sdc_init(smk_sdc_fault_handler) == 0 else {
        smk_sdc_fault_handler(nil, 0) // spins forever
        return
    }

    // Legacy (non-extended) advertising only — matches the shared GATT
    // file's gap_advertisements_* calls, and
    // libsoftdevice_controller_peripheral.a (the single-role variant this
    // target links) doesn't even export sdc_support_ext_adv().
    _ = sdc_support_adv()
    _ = sdc_support_peripheral()

    guard withUnsafePointer(to: &sdcRandSource, { sdc_rand_source_register(UnsafeRawPointer($0)) }) == 0 else {
        smk_sdc_fault_handler(nil, 0)
        return
    }

    // Query the real memory requirement for the role/feature configuration
    // just set up (SDC_DEFAULT_RESOURCE_CFG_TAG=0, SDC_CFG_TYPE_NONE=0) and
    // fault rather than silently overrun the pool if it doesn't fit.
    let requiredMem = sdc_cfg_set(0, 0, nil)
    guard requiredMem >= 0, requiredMem <= Int32(sdcMemBufferSize) else {
        smk_sdc_fault_handler(nil, 0)
        return
    }

    let memBuffer = UnsafeMutableRawPointer.allocate(byteCount: sdcMemBufferSize, alignment: 8)
    sdcMemBuffer = memBuffer // permanent — SDC owns it from here on
    guard sdc_enable(nil, memBuffer.assumingMemoryBound(to: UInt8.self)) == 0 else {
        smk_sdc_fault_handler(nil, 0)
        return
    }

    // Give the transport its name (a permanent copy — BTstack keeps the
    // pointer), then hand the vtable to BTstack.
    let nameStorage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: sdcTransportNameBytes.count)
    _ = nameStorage.initialize(from: sdcTransportNameBytes)
    sdcTransport.name = UnsafeRawPointer(nameStorage.baseAddress!).assumingMemoryBound(to: CChar.self)

    withUnsafePointer(to: &sdcTransport) { hci_init(UnsafeRawPointer($0), nil) }

    // GATT/SM/advertising setup + hci_power_control(HCI_POWER_ON) — the
    // shared ports/common/BleHidGatt.swift, same-module call.
    smk_ble_hid_gatt_setup()
}
