// VBAT sense on IO4/ADC1_CH4 (÷2 resistor divider on the smk_kbd board —
// see CLAUDE.md's GPIO map). Kept in C rather than Swift: ESP-IDF's
// adc_oneshot driver configures itself via structs passed by pointer
// (adc_oneshot_unit_init_cfg_t, adc_oneshot_chan_cfg_t) — the same
// "constructing C-ABI structs as literals" exception this project
// documents elsewhere (e.g. BTstack's hci_transport_t in the nRF52840
// port) rather than hand-rolling a matching Swift struct layout that
// can't be build-verified on this machine (idf.py build has a known
// pre-existing toolchain break unrelated to this file — see memory:
// project-esp32-build-env). Everything downstream of the raw reading —
// mV conversion, percentage curve, periodic scheduling, BLE reporting —
// lives in Swift (Sources/smk/BatteryMonitor.swift), per this project's
// Swift-first preference; this file only does the unavoidable struct-heavy
// driver setup and exposes plain scalar functions to Swift.

#include "esp_adc/adc_oneshot.h"

#define SMK_BATTERY_ADC_CHANNEL ADC_CHANNEL_4 // IO4

static adc_oneshot_unit_handle_t s_adc_handle = NULL;

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
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    err = adc_oneshot_config_channel(s_adc_handle, SMK_BATTERY_ADC_CHANNEL, &chan_config);
    if (err != ESP_OK) {
        s_adc_handle = NULL;
        return (int)err;
    }

    return 0;
}

// Returns the raw ADC conversion result (0-4095 at the default 12-bit
// width), or -1 if the ADC isn't initialized or the read failed.
int smk_battery_adc_read_raw(void) {
    if (s_adc_handle == NULL) {
        return -1;
    }
    int raw = 0;
    esp_err_t err = adc_oneshot_read(s_adc_handle, SMK_BATTERY_ADC_CHANNEL, &raw);
    if (err != ESP_OK) {
        return -1;
    }
    return raw;
}
