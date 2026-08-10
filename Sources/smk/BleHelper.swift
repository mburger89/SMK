// ESP32-C6 BLE HID glue — partial Swift port of the former
// Sources/components/ble_helper.c.
//
// What moved to Swift here (all scalar/pointer logic, no struct
// construction — verified against real vendored ESP-IDF v6.0.1 source,
// not guessed, per this task's brief):
//   - kb_log
//   - ble_hidd_event_callback (@_cdecl — registered as esp_hidd_dev_init's
//     `esp_event_handler_t callback` param, a raw C function pointer, from
//     ble_helper.c's init_ble_hid — same "vtable-adjacent" pattern as any
//     other @_cdecl handed to a C registration API by address)
//   - send_keyboard_report
//   - smk_ble_set_battery_level
//   - ble_hid_host_task (@_cdecl — handed to esp_nimble_enable() by
//     address, same pattern)
//
// What stayed in Sources/components/ble_helper.c (trimmed remainder) and
// why — resolved from Step 1/2's real findings, not guessed:
//   - hid_report_map / ble_report_maps / ble_hid_config: the static report
//     descriptor bytes plus esp_hid_raw_report_map_t/
//     esp_hid_device_config_t construction. These are flat, non-bitfield
//     structs and would have been tractable to hand-roll, but there's no
//     benefit to doing so in isolation — see init_ble_hid below.
//   - start_advertising(): constructs `struct ble_hs_adv_fields`
//     (components/bt/.../host/ble_hs_adv.h), which is genuinely
//     bitfield-heavy — uuids16_is_complete:1, uuids32_is_complete:1,
//     uuids128_is_complete:1, name_is_complete:1, tx_pwr_lvl_is_present:1,
//     sm_tk_value_is_present:1, sm_oob_flag_is_present:1, and more, packed
//     alongside pointer/uint8_t fields with no #pragma pack documenting
//     the packing rules. This is exactly the case the design spec
//     anticipated as not worth hand-rolling — verified by reading the
//     real struct (Step 2), not assumed from the brief's warning alone.
//   - init_ble_hid(): mutates the global `extern struct ble_hs_cfg
//     ble_hs_cfg;` (host/ble_hs.h), which is *also* bitfield-heavy
//     (sm_oob_data_flag:1/sm_bonding:1/sm_mitm:1/sm_sc:1/... packed
//     together) for the same reason, and needs the address of
//     ble_hid_config (above) for esp_hidd_dev_init. Kept together with its
//     C-only dependencies rather than split mid-function.
//
// s_hid_dev ownership: C's init_ble_hid() still makes the
// esp_hidd_dev_init() call (it owns the struct-heavy config), but no
// longer keeps s_hid_dev as a persistent file-static — it's now a local
// that receives the out-param and is handed to Swift exactly once via
// smk_ble_set_hid_dev() below, right after esp_hidd_dev_init() succeeds.
// From that point on, `hidDev` in this file is the single source of
// truth: every other former reader of s_hid_dev
// (ble_hidd_event_callback/send_keyboard_report/smk_ble_set_battery_level)
// is now Swift and reads this same variable — there is no separate,
// potentially-stale C-side copy after init.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Reuses the exact fixed-2-arg @_extern(c, "printf") binding
// ports/rp2040/PlatformConfig.swift's kb_log already established for
// Task 3, rather than inventing a second variadic-printf approach for
// this target. ESP32-C6's kb_log predates any Swift version (it lived
// only in ble_helper.c as an ESP_LOGI wrapper), so this task is the one
// that ports it — nothing upstream already claimed it.
@_extern(c, "printf")
func printf(_ format: UnsafePointer<CChar>, _ arg: UnsafePointer<CChar>) -> Int32

func kb_log(_ msg: UnsafePointer<CChar>) {
    _ = printf("[SMK] %s\n", msg)
}

@_extern(c, "esp_hidd_dev_connected")
func esp_hidd_dev_connected(_ dev: UnsafeMutableRawPointer?) -> Bool

// esp_hidd_dev_input_set's real signature (esp_hid/include/esp_hidd.h):
//   esp_err_t esp_hidd_dev_input_set(esp_hidd_dev_t *dev, size_t map_index,
//                                     size_t report_id, uint8_t *data,
//                                     size_t length);
// size_t on this 32-bit RISC-V target is 4 bytes, matching Swift's `UInt`
// (word-sized) here — not Int32, which the brief's draft used as a
// placeholder.
@_extern(c, "esp_hidd_dev_input_set")
func esp_hidd_dev_input_set(_ dev: UnsafeMutableRawPointer?, _ mapIndex: UInt, _ reportID: UInt, _ data: UnsafePointer<UInt8>, _ length: UInt) -> Int32

@_extern(c, "esp_hidd_dev_battery_set")
func esp_hidd_dev_battery_set(_ dev: UnsafeMutableRawPointer?, _ level: UInt8) -> Int32

// start_advertising() stays defined in ble_helper.c — see file header
// comment above (ble_hs_adv_fields' bitfields).
@_extern(c, "start_advertising")
func start_advertising()

// nimble_port_run/nimble_port_freertos_deinit (nimble/nimble_port.h,
// nimble/nimble_port_freertos.h) — both plain `void (void)`, ported into
// ble_hid_host_task below.
@_extern(c, "nimble_port_run")
func nimble_port_run()

@_extern(c, "nimble_port_freertos_deinit")
func nimble_port_freertos_deinit()

// smk_keymap_dispatch_packet is @_cdecl'd Swift
// (Sources/SMKCore/KeymapProtocol.swift, part of this same module/build —
// Task 4 already landed per this plan's task ordering) — no @_extern
// needed here, this is a same-module Swift-to-Swift call.

// Single source of truth for the HID device handle — see file header
// comment. Populated exactly once by smk_ble_set_hid_dev(), called from
// ble_helper.c's init_ble_hid() right after esp_hidd_dev_init() succeeds.
private var hidDev: UnsafeMutableRawPointer? = nil

@_cdecl("smk_ble_set_hid_dev")
func smk_ble_set_hid_dev(_ dev: UnsafeMutableRawPointer?) {
    hidDev = dev
}

// esp_hidd_event_t real values — verified against
// ~/.espressif/v6.0.1/esp-idf/components/esp_hid/include/esp_hidd.h,
// NOT the brief's placeholder values (which happened to get START/CONNECT/
// DISCONNECT right but guessed OUTPUT as 2 — it's actually 4, since
// PROTOCOL_MODE_EVENT and CONTROL_EVENT sit between CONNECT and OUTPUT in
// the real enum):
//   ESP_HIDD_START_EVENT          = 0
//   ESP_HIDD_CONNECT_EVENT        = 1
//   ESP_HIDD_PROTOCOL_MODE_EVENT  = 2
//   ESP_HIDD_CONTROL_EVENT        = 3
//   ESP_HIDD_OUTPUT_EVENT         = 4
//   ESP_HIDD_FEATURE_EVENT        = 5
//   ESP_HIDD_DISCONNECT_EVENT     = 6
//   ESP_HIDD_STOP_EVENT           = 7
let espHiddStartEvent: Int32 = 0
let espHiddConnectEvent: Int32 = 1
let espHiddOutputEvent: Int32 = 4
let espHiddDisconnectEvent: Int32 = 6

@_cdecl("ble_hidd_event_callback")
func ble_hidd_event_callback(_ handlerArgs: UnsafeMutableRawPointer?, _ base: UnsafeRawPointer?, _ id: Int32, _ eventData: UnsafeMutableRawPointer?) {
    switch id {
    case espHiddStartEvent:
        kb_log("BLE HID Stack Started")
        start_advertising()
    case espHiddConnectEvent:
        kb_log("BLE HID Connected")
    case espHiddOutputEvent:
        // esp_hidd_event_data_t's `output` variant (esp_hidd.h), the
        // single highest-risk read in this task:
        //   struct {
        //       esp_hidd_dev_t *dev;      // offset 0,  4 bytes (32-bit ptr)
        //       esp_hid_usage_t usage;    // offset 4,  4 bytes (plain C enum -> int)
        //       uint16_t report_id;       // offset 8,  2 bytes
        //       uint16_t length;          // offset 10, 2 bytes
        //       uint8_t *data;            // offset 12, 4 bytes (already 4-aligned)
        //       uint8_t map_index;        // offset 16, 1 byte
        //   } output;                     // struct padded to 20 bytes (align 4)
        // Grepped esp_hidd.h/esp_hid_common.h for `pragma pack`/`packed`:
        // none found, so standard alignment rules apply deterministically
        // (each field aligned to its own size, no reordering) — this
        // doesn't depend on a scratch-compile the way a struct with
        // ambiguous packing would.
        //
        // Read via raw byte-offset loads on the raw event_data pointer
        // rather than a hand-rolled Swift struct mirroring the C layout:
        // this sidesteps any question of whether Swift's stored-property
        // layout would preserve declaration order for this specific
        // struct (this project's WiredHidUart.swift precedent verified
        // that Swift *does* preserve it for a pointer-free struct, but
        // this struct has two pointers whose size is architecture-
        // dependent — offset-based loads avoid relying on that at all).
        guard let eventData = eventData else { break }
        let reportID = eventData.load(fromByteOffset: 8, as: UInt16.self)
        let length = eventData.load(fromByteOffset: 10, as: UInt16.self)
        if reportID == 2 && length >= 32 {
            let dataPtr = eventData.load(fromByteOffset: 12, as: UnsafeMutablePointer<UInt8>?.self)
            if let dataPtr = dataPtr, let dev = hidDev {
                var response = [UInt8](repeating: 0, count: 32)
                response.withUnsafeMutableBufferPointer { respBuf in
                    smk_keymap_dispatch_packet(dataPtr, respBuf.baseAddress!)
                }
                _ = response.withUnsafeMutableBufferPointer {
                    esp_hidd_dev_input_set(dev, 0, 2, $0.baseAddress!, 32)
                }
            }
        }
    case espHiddDisconnectEvent:
        kb_log("BLE HID Disconnected")
        start_advertising()
    default:
        break
    }
}

func send_keyboard_report(_ modifier: UInt8, _ keycodes: UnsafePointer<UInt8>) {
    guard let dev = hidDev, esp_hidd_dev_connected(dev) else { return }
    var report = [UInt8](repeating: 0, count: 8)
    report[0] = modifier
    // report[1] stays 0 (Reserved byte).
    for i in 0..<6 { report[2 + i] = keycodes[i] }
    // Map index 0, Report ID 1 (matches the descriptor in ble_helper.c's
    // hid_report_map).
    _ = report.withUnsafeBufferPointer { esp_hidd_dev_input_set(dev, 0, 1, $0.baseAddress!, 8) }
}

// Reports a 0-100 battery level via the standard BLE Battery Service —
// esp_hidd_dev_init() already creates this GATT service internally as
// part of the HID-over-GATT profile, so this is the one call needed to
// feed it real data. Called from BatteryMonitor.swift, which owns the
// ADC-to-percentage math.
func smk_ble_set_battery_level(_ level: UInt8) {
    guard let dev = hidDev else { return }
    _ = esp_hidd_dev_battery_set(dev, level)
}

// Handed to esp_nimble_enable() by address from ble_helper.c's
// init_ble_hid() (esp_nimble_enable(void *host_task) — the FreeRTOS task
// entry point convention, hence the UnsafeMutableRawPointer? param even
// though it's unused, matching void(*)(void*)).
@_cdecl("ble_hid_host_task")
func ble_hid_host_task(_ param: UnsafeMutableRawPointer?) {
    kb_log("NimBLE Host Task Started")
    nimble_port_run()
    nimble_port_freertos_deinit()
}
