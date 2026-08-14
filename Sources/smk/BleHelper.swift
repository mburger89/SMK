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

// esp_hidd_dev_connected/esp_hidd_dev_input_set/esp_hidd_dev_battery_set:
// no @_extern redeclarations here — Bridging.h already `#include`s
// esp_hidd.h, so these are called via their real, ClangImporter-imported
// declarations instead. A hand-copied @_extern redeclaration would shadow
// those (same hazard Bridging.h itself already calls out for
// init_wired_link/send_wired_report elsewhere) and could silently drift
// out of sync with the real signature on a future ESP-IDF upgrade. The
// opaque `esp_hidd_dev_t *` C type imports as `OpaquePointer` — see
// `hidDev` below — and `size_t` params import as `Int`.

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
// Typed OpaquePointer (not UnsafeMutableRawPointer) to match how
// ClangImporter imports `esp_hidd_dev_t *` (an opaque, forward-declared C
// struct) — see esp_hidd_dev_connected/input_set/battery_set's real
// imported signatures, called directly below with no @_extern
// redeclaration.
private var hidDev: OpaquePointer? = nil

// smk_ble_set_hid_dev's own param stays a raw pointer (matching
// ble_helper.c's `extern void smk_ble_set_hid_dev(void *dev);` forward
// declaration byte-for-byte at the ABI level); converted to OpaquePointer
// once here, on the way into the single source of truth above.
@_cdecl("smk_ble_set_hid_dev")
func smk_ble_set_hid_dev(_ dev: UnsafeMutableRawPointer?) {
    hidDev = dev.map { OpaquePointer($0) }
}

// esp_hidd_event_t values — pulled directly from the real,
// ClangImporter-imported enum (Bridging.h already `#include`s esp_hidd.h,
// so esp_hidd.h's declarations are visible to Swift as real types/values,
// not just C prototypes) rather than hand-copied integer literals. This
// gets header-derived values for free: if a future ESP-IDF upgrade
// reorders esp_hidd_event_t's cases, this recompiles to the new values
// automatically instead of silently keeping stale ones.
//
// (For the record, verified once against
// ~/.espressif/v6.0.1/esp-idf/components/esp_hid/include/esp_hidd.h
// during this task: START=0, CONNECT=1, PROTOCOL_MODE=2, CONTROL=3,
// OUTPUT=4, FEATURE=5, DISCONNECT=6, STOP=7 — notably NOT the task
// brief's draft placeholders of OUTPUT=2/DISCONNECT=3, which would have
// silently broken keymap-upload detection and the reconnect-advertising
// path had they gone unverified.)
let espHiddStartEvent = ESP_HIDD_START_EVENT.rawValue
let espHiddConnectEvent = ESP_HIDD_CONNECT_EVENT.rawValue
let espHiddOutputEvent = ESP_HIDD_OUTPUT_EVENT.rawValue
let espHiddDisconnectEvent = ESP_HIDD_DISCONNECT_EVENT.rawValue

// Keymap-upload packet handoff from the NimBLE host task (this callback's
// caller) to the main scan loop's smk_keymap_ble_service() poll — mirrors
// ports/rp2040/platform/usb_descriptors.c's tud_hid_set_report_cb ->
// s_pending_packet/s_packet_pending -> smk_keymap_usb_service() split
// (also used as-is by the nRF52840/STM32F4/STM32WB USB targets), which
// exists for exactly this reason: smk_keymap_dispatch_packet's COMMIT
// opcode can trigger a multi-ms flash/NVS erase+program
// (KeymapStoreNVS.swift's smk_keymap_commit), and calling that directly
// from inside a BLE stack callback blocks the NimBLE host task from
// servicing any other BLE event (connection-interval housekeeping, other
// GATT traffic, disconnects) for that whole duration — a real starvation
// risk, not just a style preference. This was flagged as a known gap when
// the runtime-keymap-updates feature shipped (the RP2040/USB path got this
// fix during that feature's final review; the BLE path did not) and is
// fixed here the same way: the callback only copies the packet and sets a
// flag; the actual dispatch (and the flash/NVS write it may trigger) moves
// to the main loop, which has no BLE-timing obligations to violate.
//
// Plain (non-atomic) Swift globals, matching the C sides' own
// `static volatile bool` — not a stronger guarantee, deliberately: ESP32-C6
// is single-core RISC-V, so there's no cross-core visibility hazard, only
// a single-word write/read pair between two FreeRTOS tasks (NimBLE host
// task, main scan-loop task) that never runs concurrently with itself on
// one core. This is the same level of rigor the existing C ports already
// rely on for the identical problem, not a weaker one.
private var pendingKeymapPacket = [UInt8](repeating: 0, count: 32)
private var keymapPacketPending = false

@_cdecl("ble_hidd_event_callback")
func ble_hidd_event_callback(_ handlerArgs: UnsafeMutableRawPointer?, _ base: UnsafeRawPointer?, _ id: Int32, _ eventData: UnsafeMutableRawPointer?) {
    switch id {
    case espHiddStartEvent:
        kb_log("BLE HID Stack Started")
        start_advertising()
    case espHiddConnectEvent:
        kb_log("BLE HID Connected")
    case espHiddOutputEvent:
        // esp_hidd_event_data_t is a real C union (esp_hidd.h), imported
        // by ClangImporter (Bridging.h already `#include`s esp_hidd.h) as
        // a Swift type with a computed `.output` property backed by the
        // same underlying storage — reading `.report_id`/`.length`/`.data`
        // through it uses the header-derived field offsets directly,
        // rather than hand-copied byte offsets that would silently go
        // stale if a future ESP-IDF upgrade reordered `output`'s fields.
        // rebind via assumingMemoryBound since event_data arrives as an
        // untyped `void *` from the C callback signature.
        guard let eventData = eventData else { break }
        let output = eventData.assumingMemoryBound(to: esp_hidd_event_data_t.self).pointee.output
        if output.report_id == 2 && output.length >= 32 {
            if let dataPtr = output.data {
                // Fast path only: copy the 32 bytes and set the flag.
                // smk_keymap_ble_service() (called from the main scan
                // loop) does the actual dispatch — see the comment above
                // pendingKeymapPacket for why this can't happen here.
                for i in 0..<32 {
                    pendingKeymapPacket[i] = dataPtr[i]
                }
                keymapPacketPending = true
            }
        }
    case espHiddDisconnectEvent:
        kb_log("BLE HID Disconnected")
        start_advertising()
    default:
        break
    }
}

// Services a pending keymap-upload packet — called every iteration of the
// main scan loop (Main.swift), never from ble_hidd_event_callback itself.
// See pendingKeymapPacket's comment above for why this split exists.
func smk_keymap_ble_service() {
    guard keymapPacketPending, let dev = hidDev else { return }
    keymapPacketPending = false
    var response = [UInt8](repeating: 0, count: 32)
    pendingKeymapPacket.withUnsafeBufferPointer { pktBuf in
        response.withUnsafeMutableBufferPointer { respBuf in
            smk_keymap_dispatch_packet(pktBuf.baseAddress!, respBuf.baseAddress!)
        }
    }
    _ = response.withUnsafeMutableBufferPointer {
        esp_hidd_dev_input_set(dev, 0, 2, $0.baseAddress!, 32)
    }
}

func send_keyboard_report(_ modifier: UInt8, _ keycodes: UnsafePointer<UInt8>) {
    guard let dev = hidDev, esp_hidd_dev_connected(dev) else { return }
    var report = [UInt8](repeating: 0, count: 8)
    report[0] = modifier
    // report[1] stays 0 (Reserved byte).
    for i in 0..<6 { report[2 + i] = keycodes[i] }
    // Map index 0, Report ID 1 (matches the descriptor in ble_helper.c's
    // hid_report_map). Mutable buffer pointer: esp_hidd_dev_input_set's
    // real imported signature takes non-const `uint8_t *data`.
    _ = report.withUnsafeMutableBufferPointer { esp_hidd_dev_input_set(dev, 0, 1, $0.baseAddress!, 8) }
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
