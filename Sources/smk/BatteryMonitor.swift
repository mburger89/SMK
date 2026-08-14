// VBAT battery-level reporting for the smk_kbd board (ESP32-C6 only —
// gated by SMK_TARGET_ESP32C6 at the Main.swift call sites, since this
// board's IO4/ADC1_CH4 divider and esp_hidd's BLE Battery Service don't
// exist on RP2040/nRF52840). Reads the IO4 ÷2 divider (see CLAUDE.md's
// GPIO map) and reports a rough 0-100% estimate via the BLE HID Battery
// Service — esp_hidd_dev_init() already creates that GATT service
// internally, so smk_ble_set_battery_level() (Sources/components/
// ble_helper.c) just has to call esp_hidd_dev_battery_set() on the
// existing HID device.
//
// ADC unit/channel setup stays in C (Sources/components/battery_adc.c) —
// see that file's header comment for why (struct-heavy driver config,
// same "constructing C-ABI structs" exception as BTstack's hci_transport_t
// elsewhere in this project). Everything downstream — percentage curve,
// periodic scheduling — is plain Swift, per this project's Swift-first
// preference. No @_cdecl needed here: nothing outside this Swift module
// calls these functions, matching GPIOInit.swift/SmkConfig.swift's
// precedent for ESP32-C6-only files.
//
// smk_battery_adc_read_mv() uses ESP-IDF's adc_cali curve-fitting scheme
// (this chip's factory eFuse calibration constants), so the mV reading
// itself no longer needs a multimeter to be roughly trustworthy. The
// voltage-to-percentage curve below is still a rough single-cell Li-ion
// linear approximation, not a calibrated discharge curve — real Li-ion
// voltage-vs-charge is nonlinear, and getting a true discharge curve
// requires logging real board data over a full charge/discharge cycle, not
// just an accurate instantaneous voltage. Revisit the curve once real
// hardware is available to log that data.

@_extern(c, "smk_battery_adc_init")
func smk_battery_adc_init() -> Int32

@_extern(c, "smk_battery_adc_read_mv")
func smk_battery_adc_read_mv() -> Int32

// smk_ble_set_battery_level: no @_extern here anymore — Task 11 ported it
// directly to Swift (BleHelper.swift, same module as this file), so this
// is now a plain same-module Swift-to-Swift call.

private var batteryMonitorReady = false

// The board halves VBAT before it reaches the ADC pin (see CLAUDE.md's
// GPIO map: "VBAT sense (÷2 divider)"), so the true battery voltage is 2x
// the measured pin voltage.
private let vbatDividerRatio: Int32 = 2

// Simple single-cell Li-ion linear approximation, not a real discharge
// curve — real Li-ion voltage-vs-charge is nonlinear, but that requires a
// per-battery-chemistry lookup table this project has no calibration data
// for yet. Good enough for a rough battery icon.
private let batteryFullMv: Int32 = 4200
private let batteryEmptyMv: Int32 = 3300

func initBatteryMonitor() {
    batteryMonitorReady = (smk_battery_adc_init() == 0)
    if !batteryMonitorReady {
        kb_log("Battery ADC init failed; battery reporting disabled")
    }
}

// Call periodically, not every scan tick — battery voltage changes slowly
// and each ADC conversion has real latency the scan loop shouldn't pay on
// every single iteration. See Main.swift's call site for the interval.
func pollBatteryLevel() {
    guard batteryMonitorReady else { return }
    let pinMv = smk_battery_adc_read_mv()
    guard pinMv >= 0 else { return }

    let vbatMv = pinMv * vbatDividerRatio

    let clampedMv = min(max(vbatMv, batteryEmptyMv), batteryFullMv)
    let percent = (clampedMv - batteryEmptyMv) * 100 / (batteryFullMv - batteryEmptyMv)

    smk_ble_set_battery_level(UInt8(percent))
}
