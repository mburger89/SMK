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
// The adc_oneshot/adc_cali driver setup is Swift too now (the former
// Sources/components/battery_adc.c is deleted): the driver's config structs
// (adc_oneshot_unit_init_cfg_t, adc_oneshot_chan_cfg_t,
// adc_cali_curve_fitting_config_t) come in through Bridging.h's
// `esp_adc/*.h` includes, so the ClangImporter provides the real types and
// their exact layouts — constructing them here is no more fragile than the
// C designated initializers were. No @_cdecl needed anywhere here: nothing
// outside this Swift module calls these functions, matching
// GPIOInit.swift/SmkConfig.swift's precedent for ESP32-C6-only files.
//
// The mV reading uses ESP-IDF's adc_cali curve-fitting scheme (this chip's
// factory eFuse calibration constants), so it no longer needs a multimeter
// to be roughly trustworthy. The voltage-to-percentage curve below is still
// a rough single-cell Li-ion linear approximation, not a calibrated
// discharge curve — real Li-ion voltage-vs-charge is nonlinear, and getting
// a true discharge curve requires logging real board data over a full
// charge/discharge cycle, not just an accurate instantaneous voltage.
// Revisit the curve once real hardware is available to log that data.

// smk_ble_set_battery_level: a plain same-module Swift-to-Swift call
// (BleHelper.swift).

// VBAT sense channel — IO4/ADC1_CH4 on the smk_kbd board (see CLAUDE.md's
// GPIO map), GPIO0/ADC1_CH0 on the SMK test board, picked by Kconfig's
// SMK_BOARD choice (main/CMakeLists.txt forwards it as this Swift -D).
#if SMK_BOARD_TEST_BOARD
private let batteryAdcChannel = ADC_CHANNEL_0
#else
private let batteryAdcChannel = ADC_CHANNEL_4
#endif
private let batteryAdcAtten = ADC_ATTEN_DB_12
private let batteryAdcBitwidth = ADC_BITWIDTH_DEFAULT

private var adcHandle: adc_oneshot_unit_handle_t? = nil
private var caliHandle: adc_cali_handle_t? = nil

// Returns true on success. Mirrors the former smk_battery_adc_init():
// unit + channel config are required; calibration is best-effort (e.g.
// ESP_ERR_NOT_SUPPORTED on a chip revision without the calibration eFuse
// burnt), with readBatteryPinMv() falling back to a nominal conversion
// when caliHandle stays nil.
private func batteryAdcInit() -> Bool {
    if adcHandle != nil { return true } // already initialized

    var initConfig = adc_oneshot_unit_init_cfg_t()
    initConfig.unit_id = ADC_UNIT_1
    var handle: adc_oneshot_unit_handle_t? = nil
    guard adc_oneshot_new_unit(&initConfig, &handle) == 0, handle != nil else {
        return false
    }

    var chanConfig = adc_oneshot_chan_cfg_t()
    chanConfig.atten = batteryAdcAtten
    chanConfig.bitwidth = batteryAdcBitwidth
    guard adc_oneshot_config_channel(handle, batteryAdcChannel, &chanConfig) == 0 else {
        return false
    }
    adcHandle = handle

    var caliConfig = adc_cali_curve_fitting_config_t()
    caliConfig.unit_id = ADC_UNIT_1
    caliConfig.chan = batteryAdcChannel
    caliConfig.atten = batteryAdcAtten
    caliConfig.bitwidth = batteryAdcBitwidth
    var cali: adc_cali_handle_t? = nil
    if adc_cali_create_scheme_curve_fitting(&caliConfig, &cali) == 0 {
        caliHandle = cali
    }

    return true
}

// The VBAT-pin voltage in mV (calibrated if the eFuse scheme was
// available, otherwise a nominal-full-scale approximation), or nil if the
// read failed. Pin voltage only — the caller applies the board's ÷2
// divider ratio.
private func readBatteryPinMv() -> Int32? {
    guard let handle = adcHandle else { return nil }
    var raw: Int32 = 0
    guard adc_oneshot_read(handle, batteryAdcChannel, &raw) == 0 else { return nil }

    if let cali = caliHandle {
        var mv: Int32 = 0
        if adc_cali_raw_to_voltage(cali, raw, &mv) == 0 {
            return mv
        }
    }

    // Uncalibrated fallback: ADC_ATTEN_DB_12's nominal ~3300mV full-scale
    // at the default 12-bit width.
    return raw * 3300 / 4095
}

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
    batteryMonitorReady = batteryAdcInit()
    if !batteryMonitorReady {
        kb_log("Battery ADC init failed; battery reporting disabled")
    }
}

// Call periodically, not every scan tick — battery voltage changes slowly
// and each ADC conversion has real latency the scan loop shouldn't pay on
// every single iteration. See Main.swift's call site for the interval.
func pollBatteryLevel() {
    guard batteryMonitorReady else { return }
    guard let pinMv = readBatteryPinMv() else { return }

    let vbatMv = pinMv * vbatDividerRatio

    let clampedMv = min(max(vbatMv, batteryEmptyMv), batteryFullMv)
    let percent = (clampedMv - batteryEmptyMv) * 100 / (batteryFullMv - batteryEmptyMv)

    smk_ble_set_battery_level(UInt8(percent))
}
