// SK6812MINI-E chain driver (RMT-based), SMK keyboard.
//
// SK6812/WS2812 need ~0.3-0.9us bit timing precision that bit-banged GPIO
// (as used for the key matrix scan) can't guarantee under FreeRTOS
// scheduling jitter — RMT is hardware-timed and immune to that. The wire
// format is GRB, MSB-first per channel (see led_strip_encoder.c).
//
// Chain wiring order is serpentine (see generate_pcb.py's led_chain_index
// and RGBLighting.swift's ledChainIndex) — this driver only deals in raw
// chain position 0..LED_STRIP_MAX_LEDS-1; the row/col -> chain-position
// mapping lives in Swift.

#include <string.h>
#include <stdbool.h>
#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/rmt_tx.h"
#include "led_strip_encoder.h"

#define LED_STRIP_MAX_LEDS        60      // matches ROWS*COLS in generate_pcb.py
#define LED_STRIP_RESOLUTION_HZ   10000000 // 10MHz, 1 tick = 0.1us

static const char *TAG = "led_strip_driver";

static rmt_channel_handle_t s_led_chan = NULL;
static rmt_encoder_handle_t s_led_encoder = NULL;
static uint8_t s_pixels[LED_STRIP_MAX_LEDS * 3]; // GRB per LED
static int s_num_leds = 0;
static bool s_ready = false;

void led_strip_driver_init(int32_t gpio_num, int32_t num_leds)
{
    if (num_leds < 0) {
        num_leds = 0;
    }
    if (num_leds > LED_STRIP_MAX_LEDS) {
        ESP_LOGW(TAG, "num_leds %ld exceeds max %d, clamping", (long)num_leds, LED_STRIP_MAX_LEDS);
        num_leds = LED_STRIP_MAX_LEDS;
    }
    s_num_leds = num_leds;
    memset(s_pixels, 0, sizeof(s_pixels));

    rmt_tx_channel_config_t tx_chan_config = {
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .gpio_num = gpio_num,
        .mem_block_symbols = 64,
        .resolution_hz = LED_STRIP_RESOLUTION_HZ,
        .trans_queue_depth = 4,
    };
    if (rmt_new_tx_channel(&tx_chan_config, &s_led_chan) != ESP_OK) {
        ESP_LOGE(TAG, "failed to create RMT TX channel on GPIO %ld", (long)gpio_num);
        return;
    }

    led_strip_encoder_config_t encoder_config = {
        .resolution = LED_STRIP_RESOLUTION_HZ,
    };
    if (rmt_new_led_strip_encoder(&encoder_config, &s_led_encoder) != ESP_OK) {
        ESP_LOGE(TAG, "failed to create LED strip encoder");
        return;
    }

    if (rmt_enable(s_led_chan) != ESP_OK) {
        ESP_LOGE(TAG, "failed to enable RMT TX channel");
        return;
    }

    s_ready = true;
    ESP_LOGI(TAG, "LED strip driver ready: GPIO %ld, %d LEDs", (long)gpio_num, s_num_leds);
}

void led_strip_set_pixel(int32_t index, uint8_t r, uint8_t g, uint8_t b)
{
    if (!s_ready || index < 0 || index >= s_num_leds) {
        return;
    }
    // SK6812/WS2812 wire order is G, R, B.
    s_pixels[index * 3 + 0] = g;
    s_pixels[index * 3 + 1] = r;
    s_pixels[index * 3 + 2] = b;
}

void led_strip_refresh(void)
{
    if (!s_ready) {
        return;
    }
    rmt_transmit_config_t tx_config = {
        .loop_count = 0,
    };
    if (rmt_transmit(s_led_chan, s_led_encoder, s_pixels, (size_t)(s_num_leds * 3), &tx_config) != ESP_OK) {
        ESP_LOGW(TAG, "rmt_transmit failed");
        return;
    }
    rmt_tx_wait_all_done(s_led_chan, pdMS_TO_TICKS(100));
}

void led_strip_clear(void)
{
    if (!s_ready) {
        return;
    }
    memset(s_pixels, 0, (size_t)(s_num_leds * 3));
    led_strip_refresh();
}
