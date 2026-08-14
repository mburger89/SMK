// VBAT sense on IO4/ADC1_CH4 (÷2 resistor divider on the smk_kbd board —
// see CLAUDE.md's GPIO map). Kept in C rather than Swift: ESP-IDF's
// adc_oneshot driver configures itself via structs passed by pointer
// (adc_oneshot_unit_init_cfg_t, adc_oneshot_chan_cfg_t) — the same
// "constructing C-ABI structs as literals" exception this project
// documents elsewhere (e.g. BTstack's hci_transport_t in the nRF52840
// port) rather than hand-rolling a matching Swift struct layout.
// Everything downstream of the reading —
// percentage curve, periodic scheduling, BLE reporting — lives in Swift
// (Sources/smk/BatteryMonitor.swift), per this project's Swift-first
// preference; this file only does the unavoidable struct-heavy driver
// setup and exposes plain scalar functions to Swift.
//
// mV conversion uses ESP-IDF's adc_cali (curve-fitting scheme), which
// applies this specific chip's factory eFuse-burnt calibration constants —
// no per-board multimeter measurement needed, unlike the percentage curve
// itself (see BatteryMonitor.swift). Falls back to the nominal
// raw/4095*3300mV conversion if calibration isn't available (e.g. an older
// chip revision with the calibration eFuse bits unburnt).

#include "esp_adc/adc_oneshot.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"

#define SMK_BATTERY_ADC_CHANNEL ADC_CHANNEL_4 // IO4
#define SMK_BATTERY_ADC_ATTEN ADC_ATTEN_DB_12
#define SMK_BATTERY_ADC_BITWIDTH ADC_BITWIDTH_DEFAULT

static adc_oneshot_unit_handle_t s_adc_handle = NULL;
static adc_cali_handle_t s_cali_handle = NULL;

// Returns 0 on success, a negative esp_err_t on failure.
int smk_battery_adc_init(void) {
    if (s_adc_handle != NULL) {
        return 0; // already initialized
    }

    adc_oneshot_unit_init_cfg_t init_config = {
        .unit_id = ADC_UNIT_1,
    };
    esp_err_t err = adc_oneshot_new_unit(&init_config, &s_adc_handle);
    if (err != ESP_OK) {
        s_adc_handle = NULL;
        return (int)err;
    }

    adc_oneshot_chan_cfg_t chan_config = {
        .atten = SMK_BATTERY_ADC_ATTEN,
        .bitwidth = SMK_BATTERY_ADC_BITWIDTH,
    };
    err = adc_oneshot_config_channel(s_adc_handle, SMK_BATTERY_ADC_CHANNEL, &chan_config);
    if (err != ESP_OK) {
        s_adc_handle = NULL;
        return (int)err;
    }

    adc_cali_curve_fitting_config_t cali_config = {
        .unit_id = ADC_UNIT_1,
        .chan = SMK_BATTERY_ADC_CHANNEL,
        .atten = SMK_BATTERY_ADC_ATTEN,
        .bitwidth = SMK_BATTERY_ADC_BITWIDTH,
    };
    // Not fatal if this fails (e.g. ESP_ERR_NOT_SUPPORTED on a chip without
    // the calibration eFuse burnt) — smk_battery_adc_read_mv() falls back
    // to an uncalibrated nominal conversion when s_cali_handle is NULL.
    if (adc_cali_create_scheme_curve_fitting(&cali_config, &s_cali_handle) != ESP_OK) {
        s_cali_handle = NULL;
    }

    return 0;
}

// Returns the VBAT-pin voltage in mV (calibrated if the eFuse scheme was
// available, otherwise a nominal-full-scale approximation), or -1 if the
// ADC isn't initialized or the read failed. This is the pin voltage only —
// the caller (BatteryMonitor.swift) applies the board's ÷2 divider ratio.
int smk_battery_adc_read_mv(void) {
    if (s_adc_handle == NULL) {
        return -1;
    }
    int raw = 0;
    esp_err_t err = adc_oneshot_read(s_adc_handle, SMK_BATTERY_ADC_CHANNEL, &raw);
    if (err != ESP_OK) {
        return -1;
    }

    if (s_cali_handle != NULL) {
        int mv = 0;
        if (adc_cali_raw_to_voltage(s_cali_handle, raw, &mv) == ESP_OK) {
            return mv;
        }
    }

    // Uncalibrated fallback: ADC_ATTEN_DB_12's nominal ~3300mV full-scale
    // at the default 12-bit width.
    return raw * 3300 / 4095;
}
