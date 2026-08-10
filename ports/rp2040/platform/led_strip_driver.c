// SK6812MINI-E chain driver (PIO-based), smk_kbd_rp2040 board only.
//
// Counterpart to Sources/components/led_strip_driver.c (ESP32, RMT-based).
// RP2040 has no RMT peripheral; PIO is the equivalent hardware-timed engine
// here — one state machine bit-bangs the single-wire NRZ protocol at the
// cycle-accurate timing ws2812.pio encodes, immune to the same scheduling
// jitter a plain GPIO bit-bang loop would suffer. Wire format is GRB,
// MSB-first per channel, matching the ESP32 driver and led_chain_index() in
// generate_kbd_rp2040.py / RGBLighting.swift's ledChainIndex.
//
// Only compiled in for SMK_TARGET_BOARD=smk_kbd_rp2040 (see
// ports/rp2040/CMakeLists.txt) — plain Pico/Pico W builds have no RGB
// hardware and don't link this file or pull in hardware_pio.

#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#include "pico/stdlib.h"
#include "hardware/pio.h"
#include "hardware/clocks.h"
#include "ws2812.pio.h"

#define LED_STRIP_MAX_LEDS 60 // matches ROWS*COLS in generate_kbd_rp2040.py
#define WS2812_FREQ_HZ 800000.0f // standard WS2812/SK6812 bit rate

static PIO s_pio = NULL;
static uint s_sm = 0;
static uint s_offset = 0;
static uint8_t s_pixels[LED_STRIP_MAX_LEDS * 3]; // GRB per LED
static int s_num_leds = 0;
static bool s_ready = false;

void led_strip_driver_init(int32_t gpio_num, int32_t num_leds) {
    if (num_leds < 0) {
        num_leds = 0;
    }
    if (num_leds > LED_STRIP_MAX_LEDS) {
        num_leds = LED_STRIP_MAX_LEDS;
    }
    s_num_leds = num_leds;
    memset(s_pixels, 0, sizeof(s_pixels));

    // Claim a free PIO block + state machine. pio0 is used elsewhere (never,
    // currently, on this board) so this should always succeed on first boot;
    // pio_claim_unused_sm asserts if none are free rather than returning an
    // error code, which is fine here (RGB is the only PIO user on this board).
    s_pio = pio0;
    if (!pio_can_add_program(s_pio, &ws2812_program)) {
        s_pio = pio1;
    }
    s_offset = pio_add_program(s_pio, &ws2812_program);
    s_sm = pio_claim_unused_sm(s_pio, true);

    ws2812_program_init(s_pio, s_sm, s_offset, (uint)gpio_num, WS2812_FREQ_HZ, false);

    s_ready = true;
}

void led_strip_set_pixel(int32_t index, uint8_t r, uint8_t g, uint8_t b) {
    if (!s_ready || index < 0 || index >= s_num_leds) {
        return;
    }
    // SK6812/WS2812 wire order is G, R, B (matches the ESP32 driver).
    s_pixels[index * 3 + 0] = g;
    s_pixels[index * 3 + 1] = r;
    s_pixels[index * 3 + 2] = b;
}

void led_strip_refresh(void) {
    if (!s_ready) {
        return;
    }
    for (int i = 0; i < s_num_leds; i++) {
        // ws2812_program_init configured an autopull, left-justified 24-bit
        // OSR shift (rgbw=false), so the packed GRB triplet must be shifted
        // up into the top 24 bits of the 32-bit FIFO word.
        uint32_t grb = ((uint32_t)s_pixels[i * 3 + 0] << 16) |
                       ((uint32_t)s_pixels[i * 3 + 1] << 8) |
                       ((uint32_t)s_pixels[i * 3 + 2]);
        pio_sm_put_blocking(s_pio, s_sm, grb << 8u);
    }
    // >=280us low period latches the frame on WS2812/SK6812 — 300us margin.
    sleep_us(300);
}

void led_strip_clear(void) {
    if (!s_ready) {
        return;
    }
    memset(s_pixels, 0, (size_t)(s_num_leds * 3));
    led_strip_refresh();
}

// --- RGB backlight config ---------------------------------------------------
// Unlike the ESP32 build (Kconfig-driven, off by default — see
// Sources/components/smk_config.c), this board has real SK6812MINI-E hardware
// on a fixed pin, so RGB is simply always-on here. GPIO17 = RGB_GPIO per
// generate_kbd_rp2040.py's GPIO map.
int smk_has_rgb_backlight(void) { return 1; }
int smk_rgb_gpio(void) { return 17; }
