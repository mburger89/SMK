// Misc platform glue for the SAMD21 build: the C entry point, logging, the
// cooperative delay shim, board/connection-mode config, and BLE HID stubs
// (this board has no radio, permanently — a XIAO M0 is USB-only). Mirrors
// ports/stm32f4/platform/platform_glue.c.
//
// This is a build-only bring-up pass — kb_log and vTaskDelay are
// placeholders, same status as the other ARM ports':
//   - kb_log: no-op. Real firmware could route this to a UART or SWO once
//     one is selected during hardware bring-up.
//   - vTaskDelay: busy-loop only. Real timing should come from SysTick once
//     wired up — not done in this pass.
//
// Unlike the STM32 ports, no `_init` stub is needed here: the vendored
// startup_samd21.c ships with its `__libc_init_array()` call commented out
// upstream, so nothing references _init. posix_memalign + the
// Embedded-Swift stdlib stubs come from the shared
// ports/common/embedded_swift_glue.c.

#include <stdint.h>

extern void smk_clock_init(void); // DFLL48M bring-up (ports/samd21/ClockInit.swift)
extern void app_main_swift(void); // shared entry point (Sources/smk/Main.swift)
extern void kb_usb_task(void);    // pumps TinyUSB (ports/samd21/UsbHid.swift)

// TEMPORARY bring-up UART (ports/samd21/UartDebug.swift) — PA06/SERCOM0,
// 115200 8N1, TX-only. Added once LED-blink bit-decoding proved unreliable
// for byte-wide USB register dumps.
extern void uart_debug_init(void);
extern void uart_debug_write_cstr(const char *s);

// --- TEMPORARY bring-up tracer (XIAO M0 onboard LED, PA17, active low) ----
// No UART/SWO is wired on this port yet, so boot progress is signaled on
// the user LED: main() entry = 1 blink, post-clock-init = 2 blinks, then
// every kb_log() call = 1 short blink. Where the blinking stops is where
// the firmware died. Remove once USB enumeration works.
#define PORTA_BASE   0x41004400u
#define PORTA_DIRSET (*(volatile uint32_t *)(PORTA_BASE + 0x08))
#define PORTA_OUTCLR (*(volatile uint32_t *)(PORTA_BASE + 0x14))
#define PORTA_OUTSET (*(volatile uint32_t *)(PORTA_BASE + 0x18))
#define LED_PIN_MASK (1u << 17)

static void dbg_led_init(void) {
    PORTA_OUTSET = LED_PIN_MASK; // off (active low)
    PORTA_DIRSET = LED_PIN_MASK;
}

static void dbg_delay(volatile uint32_t n) {
    while (n--) { __asm__ volatile("nop"); }
}

// Blink counts are clock-relative: before smk_clock_init() the CPU runs at
// OSC8M/8 = 1MHz, after it at 48MHz — dbg_cycles_per_unit is bumped 48x
// once the clock is up so the blinks stay human-visible either way.
static uint32_t dbg_cycles_per_unit = 150000;

void dbg_blink(int times) {
    for (int i = 0; i < times; i++) {
        PORTA_OUTCLR = LED_PIN_MASK; // on
        dbg_delay(dbg_cycles_per_unit);
        PORTA_OUTSET = LED_PIN_MASK; // off
        dbg_delay(dbg_cycles_per_unit);
    }
    dbg_delay(dbg_cycles_per_unit * 3);
}

// TEMPORARY: unmistakable fault signal — rapid continuous strobe. The
// startup file weak-aliases HardFault_Handler to a bare infinite loop,
// which freezes the LED in whatever state it happened to be; this override
// makes a fault visually distinct from a hang.
void HardFault_Handler(void) {
    for (;;) {
        PORTA_OUTCLR = LED_PIN_MASK;
        dbg_delay(dbg_cycles_per_unit / 8);
        PORTA_OUTSET = LED_PIN_MASK;
        dbg_delay(dbg_cycles_per_unit / 8);
    }
}

// TEMPORARY: terminal diagnosis marker — blinks `code` in a repeating
// group forever, so "groups of N, repeating" identifies which check
// tripped (vs. plain silence = a hang inside a C wait loop).
void dbg_trap(int code) {
    for (;;) {
        dbg_blink(code);
        dbg_delay(dbg_cycles_per_unit * 6);
    }
}

// TEMPORARY: C-side USB clock/peripheral probe — volatile accesses the
// optimizer can't fold, distinct trap codes per failure mode. Offsets/bits
// verified against the DFP's component/{gclk,usb}.h: GCLK CLKCTRL 16-bit at
// 0x40000C02 (CLKEN bit 14; readback = 8-bit ID write then 16-bit read),
// USB CTRLA 8-bit at 0x41005000+0x00 (SWRST bit 0), SYNCBUSY 8-bit at
// +0x02 (SWRST bit 0).
void dbg_usb_probe(void) {
    volatile uint8_t  *clkctrl8  = (volatile uint8_t *)0x40000C02u;
    volatile uint16_t *clkctrl16 = (volatile uint16_t *)0x40000C02u;
    *clkctrl8 = 0x06; // select USB channel for readback
    if ((*clkctrl16 & (1u << 14)) == 0) {
        dbg_trap(4); // GCLK USB channel CLKEN did not stick
    }

    // REGISTER DUMP, LED-encoded: each value is reported as (value + 1)
    // blinks with a long gap after, then the LED parks ON. Values:
    //   1st group: GCLK channel 6's GEN field (readback)
    //   2nd group: its CLKEN bit
    //   3rd group: USB CTRLA readback after writing ENABLE (0x02)
    volatile uint16_t *clkctrl16b = (volatile uint16_t *)0x40000C02u;
    *clkctrl8 = 0x06;
    uint16_t ch = *clkctrl16b;
    uint32_t gen = (ch >> 8) & 0xF;
    uint32_t clken = (ch >> 14) & 0x1;

    volatile uint8_t *usb_ctrla = (volatile uint8_t *)0x41005000u;
    *usb_ctrla = 0x02; // ENABLE, device mode
    for (volatile uint32_t i = 0; i < 200000u; i++) { } // generous settle
    uint32_t ctrla_rb = *usb_ctrla;

    dbg_blink((int)gen + 1);
    dbg_delay(dbg_cycles_per_unit * 8);
    dbg_blink((int)clken + 1);
    dbg_delay(dbg_cycles_per_unit * 8);
    dbg_blink((int)ctrla_rb + 1);
    for (;;) { PORTA_OUTCLR = LED_PIN_MASK; } // park LED on: dump complete
}

// --- Logging -----------------------------------------------------------
void kb_log(const char *msg) {
    uart_debug_write_cstr(msg);
    dbg_blink(1);
}

// --- Cooperative delay shim ----------------------------------------------
// The shared scan loop calls vTaskDelay(1) once per tick. Placeholder
// busy-loop only (no calibrated timer yet).
void vTaskDelay(uint32_t ticks) {
    kb_usb_task();
    if (ticks == 0) ticks = 1;
    for (volatile uint32_t i = 0; i < ticks * 30000u; i++) {
        __asm__ volatile("nop");
    }
}

// --- Connection-mode config ------------------------------------------------
// This board always has real native-USB wired HID, no BLE, no wired-HID
// bridge — matching the STM32F4 pattern for radio-less boards.
int smk_has_wired_bridge(void) { return 1; }
int smk_default_mode_is_wired(void) { return 1; }

// --- BLE HID stubs (permanently out of scope — no radio on a XIAO M0) ------
// Sources/smk/Main.swift calls these unconditionally regardless of board.
void init_ble_hid(void) {
    // Stub — this chip has no radio.
}

void send_keyboard_report(uint8_t modifier, uint8_t *keycodes) {
    (void)modifier;
    (void)keycodes;
}

// --- Entry point -----------------------------------------------------------
extern int smk_debug_probe(void); // TEMPORARY (UsbHid.swift)

int main(void) {
    dbg_led_init();
    dbg_blink(1);     // TEMPORARY: reached main()
    smk_clock_init(); // DFLL48M/GCLK0 bring-up before anything else
    dbg_cycles_per_unit = 150000u * 48u; // clock is 48x faster now
    dbg_blink(2);     // TEMPORARY: clock init survived
    uart_debug_init(); // needs GCLK0 at 48MHz, so only after smk_clock_init()
    uart_debug_write_cstr("=== SAMD21 boot: UART debug online ===");
    if (smk_debug_probe() > 0) {
        dbg_blink(3); // TEMPORARY: Swift heap + string machinery works
    }
    app_main_swift(); // never returns (infinite scan loop)
    return 0;
}
