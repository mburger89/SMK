// Misc platform glue for the nRF52840 build: logging, the cooperative delay
// shim, the C entry point, board/connection-mode config, and the
// Embedded-Swift linker stubs.
//
// Counterpart to ports/rp2040/platform/platform_glue.c. Task 1's minimal
// smoke-test stub is replaced here with the real shape now that the full
// shared application layer (Sources/smk, Sources/SMKCore) is wired in.
//
// This is a build-only pass — no hardware exists for this board yet (see
// docs/superpowers/specs/2026-08-09-nrf52840-support-design.md). kb_log and
// vTaskDelay below are therefore placeholders, flagged for real
// implementations once Tasks 4-7 (USB/BLE) and hardware bring-up land:
//   - kb_log: no-op. Real firmware should route this to RTT (SEGGER
//     Real-Time Transfer, the usual no-UART-required logging channel for
//     nRF52 boards) or a UART, once one is selected.
//   - vTaskDelay: busy-loop only. Real timing should come from NRF_RTC (a
//     low-power hardware timer) once MPSL/SoftDevice Controller init
//     (Task 5) claims ownership of the relevant peripherals — this must be
//     coordinated with that init, not implemented independently here.

#include <stdint.h>

extern void app_main_swift(void); // shared entry point (Sources/smk/Main.swift)
// kb_usb_task (Task 4, ports/nrf52840/UsbHid.swift) pumps TinyUSB. Task 4's
// own UsbHid.swift header comment already claimed vTaskDelay calls this
// "via its own extern void kb_usb_task(void) declaration" — that turned out
// not to actually be true in this file (no declaration, no call site
// existed), so this pass adds both, fixing what would otherwise be a
// silent gap (USB HID reports never getting pumped) discovered while
// wiring in Task 5's mpsl_glue_poll() below it.
extern void kb_usb_task(void);
extern void mpsl_glue_init(void); // MPSL bring-up (Task 5, ports/nrf52840/MpslGlue.swift)
// USB VBUS/regulator power-event init (ports/nrf52840/MpslGlue.swift).
// Must run on every board, MPSL or not: TinyUSB's dcd_nrf5x.c only ever
// enables NRF_USBD and asserts the D+ pull-up from inside
// tusb_hal_nrf_power_event(), which nothing else calls.
extern void smk_usb_power_init(void);
extern void mpsl_glue_poll(void); // pumps MPSL's low-priority work queue (Task 5)
extern void sdc_transport_poll(void); // drains SDC HCI events/data into BTstack (Task 7, platform/ble_hid_sdc.c)
extern void btstack_run_loop_embedded_execute_once(void); // pumps BTstack's timers/callbacks (Task 7 fix round, Critical #2)

// --- Boot-stage LED probe (feather_nrf52840 bring-up only) -----------------
// This board has no logging channel at all (kb_log is a no-op, no RTT, no
// UART wired), so "the board is silent" is indistinguishable from "the app
// never started", "it hung in USB power init", and "it's looping fine but
// USB won't come up". The three onboard LEDs are the only output this
// board has, so they're used as a three-stage boot probe:
//   red   on  = main() reached (VTOR relocated)
//   green on  = smk_usb_power_init() returned (USB pull-up asserted)
//   blue blink = the scan loop is turning (vTaskDelay is being called)
// Pin numbers are the Seeed XIAO nRF52840 mapping (P0.26 red, P0.30 green,
// P0.06 blue, all active LOW). This board's JSON declares an empty matrix,
// so none of these can collide with a scanned pin.
//
// Raw MMIO rather than the nrfx GPIO driver, matching this port's existing
// register-poke style (GPIORegisters.swift, MpslGlue.swift's NVIC/POWER
// access): NRF_P0 base 0x50000000, PIN_CNF[n] @ 0x700 + 4n (DIR=output +
// INPUT=disconnect => 0x3), OUTSET @ 0x508, OUTCLR @ 0x50C.
#if SMK_BOARD_FEATHER_NRF52840
#define SMK_P0_BASE 0x50000000UL
#define SMK_LED_RED 26U
#define SMK_LED_GREEN 30U
#define SMK_LED_BLUE 6U

static void smk_led_init(uint32_t pin) {
    // Drive high (LED off, active-low) before enabling the output, so the
    // LED never flashes on during configuration.
    *(volatile uint32_t *)(SMK_P0_BASE + 0x508) = (1UL << pin);
    *(volatile uint32_t *)(SMK_P0_BASE + 0x700 + 4UL * pin) = 0x3UL;
}

static void smk_led_on(uint32_t pin) {
    *(volatile uint32_t *)(SMK_P0_BASE + 0x50C) = (1UL << pin); // active low
}

static void smk_led_off(uint32_t pin) {
    *(volatile uint32_t *)(SMK_P0_BASE + 0x508) = (1UL << pin);
}
#endif

// C-linkage probe hook so Swift (MpslGlue.swift's smk_usb_power_init) can
// mark its own sub-steps with the same LEDs. Defined unconditionally so the
// Swift side always links; the body compiles away on other boards.
//
// The stage number is displayed as a 3-bit binary code across the three
// LEDs (bit 0 = red, bit 1 = green, bit 2 = blue), so a single glance at a
// hung board names the exact last line reached — three separate on/off
// calls could not distinguish "stopped here" from "skipped this branch".
// Stages are listed at each call site; whatever code is showing when the
// board goes quiet is where it stopped.
void smk_boot_stage(uint32_t stage) {
#if SMK_BOARD_FEATHER_NRF52840
    if (stage & 1u) { smk_led_on(SMK_LED_RED); } else { smk_led_off(SMK_LED_RED); }
    if (stage & 2u) { smk_led_on(SMK_LED_GREEN); } else { smk_led_off(SMK_LED_GREEN); }
    if (stage & 4u) { smk_led_on(SMK_LED_BLUE); } else { smk_led_off(SMK_LED_BLUE); }
#else
    (void)stage;
#endif
}

// --- Logging -----------------------------------------------------------
// Placeholder: no-op until a real logging channel (RTT or UART) is wired
// up during hardware bring-up. Not wired to anything yet since this is a
// build-only pass with no hardware to verify against.
void kb_log(const char *msg) {
    (void)msg;
}

// --- Cooperative delay shim ----------------------------------------------
// The shared scan loop calls vTaskDelay(1) once per tick. Placeholder
// busy-loop only (no RTOS, no calibrated timer yet) — real timing should
// use NRF_RTC once Task 5's MPSL init claims the relevant peripherals.
// Loop count is an uncalibrated guess, NOT a real millisecond delay.
//
// kb_usb_task() pumps TinyUSB (see extern declaration above for why it's
// added here, alongside mpsl_glue_poll()). mpsl_glue_poll() is called
// every tick (same cooperative-poll pattern) to pump MPSL's low-priority
// work queue promptly, per mpsl.rst's "call within a couple of ms of the
// low_prio_irq firing" contract — see MpslGlue.swift's SWI0_EGU0_IRQHandler
// comment for why this project polls unconditionally rather than gating on
// that ISR. sdc_transport_poll() (Task 7) drains SDC's HCI event/data queue
// into BTstack the same way — without this call, BTstack never sees
// incoming HCI events and init_ble_hid() hangs or silently does nothing
// past hci_power_control(). btstack_run_loop_embedded_execute_once() (Task
// 7 fix round, Critical #2) is BTstack's own run loop pump — separate from
// sdc_transport_poll() above, which only forwards raw HCI packets; this
// call is what actually processes those packets into state transitions,
// fires timers, and runs deferred callbacks (see ble_hid_sdc.c's
// init_ble_hid() for where this run loop gets installed via
// btstack_run_loop_init()).
void vTaskDelay(uint32_t ticks) {
#if SMK_BOARD_FEATHER_NRF52840
    // Stage 3: the scan loop is turning. Divided down so the blink is
    // visible to the eye rather than a blur at the tick rate.
    static uint32_t smk_blink_counter = 0;
    if (++smk_blink_counter >= 20) {
        smk_blink_counter = 0;
        static uint32_t smk_blink_state = 0;
        smk_blink_state ^= 1u;
        // Alternate the full code and red-only: a *blinking* board is
        // running, a steady code is a board stopped at that stage.
        smk_boot_stage(smk_blink_state ? 7u : 1u);
    }
#endif
    kb_usb_task();
    // The radio-side pumps are skipped on feather_nrf52840: main() never
    // calls mpsl_glue_init() there and app_main_swift() never calls
    // init_ble_hid(), so MPSL, the SoftDevice Controller and BTstack's run
    // loop are all uninitialised on that board — pumping them every tick
    // would be driving three subsystems through undefined state. This
    // became reachable only once the scan loop started running on a
    // matrix-less board (see Sources/smk/Main.swift's hasMatrix); before
    // that, app_main_swift() returned before the loop and vTaskDelay was
    // never called here at all.
#if !SMK_BOARD_FEATHER_NRF52840
    mpsl_glue_poll();
    sdc_transport_poll();
    btstack_run_loop_embedded_execute_once();
#endif
    if (ticks == 0) ticks = 1;
    for (volatile uint32_t i = 0; i < ticks * 100000u; i++) {
        __asm__ volatile("nop");
    }
}

// --- Connection-mode config ------------------------------------------------
// This board always has real native-USB wired HID (Task 4, TinyUSB), so
// it's always available and stays the boot default, matching RP2040's
// pattern (see ports/rp2040/platform/platform_glue.c).
int smk_has_wired_bridge(void) { return 1; }
int smk_default_mode_is_wired(void) { return 1; }

// --- BLE HID stub (disabled once the real implementation is linked in) -----
// init_ble_hid()/send_keyboard_report() are declared in
// ports/nrf52840/BridgingHeader.h and called unconditionally from
// Sources/smk/Main.swift's scan loop. The wired pair (init_wired_link/
// send_wired_report) is backed directly in Swift instead
// (ports/nrf52840/UsbHid.swift, same-module resolution — see
// BridgingHeader.h's comment for why no C declaration/stub exists for
// those here). ports/nrf52840/platform/ble_hid_sdc.c provides the real
// C-linkage definitions of init_ble_hid/send_keyboard_report (MPSL/SDC +
// BTstack GATT HID); these stubs must stay disabled (see
// SMK_HAS_REAL_BLE_HID_SDC guard below) whenever ble_hid_sdc.c is linked
// in, or the build fails with a duplicate-symbol linker error.
#ifndef SMK_HAS_REAL_BLE_HID_SDC
void init_ble_hid(void) {
    // Stub — Task 7 (ble_hid_sdc.c) provides the real implementation.
    // Once ble_hid_sdc.c is added to the CMake source list, define
    // SMK_HAS_REAL_BLE_HID_SDC (e.g. via target_compile_definitions) to
    // disable this stub and avoid a duplicate-symbol link error.
}

void send_keyboard_report(uint8_t modifier, uint8_t *keycodes) {
    // Stub — see init_ble_hid above.
    (void)modifier;
    (void)keycodes;
}
#endif

// --- Vector table relocation (Feather nRF52840 Express only) ---------------
// This board's factory UF2 bootloader links the app above flash 0x0 (see
// ports/nrf52840/linker/feather_nrf52840.ld) and jumps straight to our
// Reset_Handler, but never touches the CPU's VTOR register on the way —
// confirmed by reading both gcc_startup_nrf52840.S and system_nrf52.c from
// the vendored nRF5 SDK, neither of which writes VTOR at all (they assume
// the CPU's power-on-reset default, VTOR=0x0, which IS correct for the
// nrf52840dk build linked at flash origin 0x0, but wrong here). Left
// unfixed, any interrupt firing while this app runs dispatches through the
// STALE vector table at address 0x0 (inside the SoftDevice's own reserved
// flash region, not ours) instead of our real handlers at __isr_vector's
// actual link address (0x27000) — found via real hardware bring-up: the
// board flashed and rebooted successfully but never enumerated any USB
// device at all, silently. Direct MMIO write rather than a CMSIS header,
// since SCB->VTOR's address (0xE000ED08) is fixed by the ARMv7-M
// architecture, not chip-specific.
#if SMK_BOARD_FEATHER_NRF52840
extern uint32_t __isr_vector[]; // linker symbol, gcc_startup_nrf52840.S
static void smk_relocate_vector_table(void) {
    *(volatile uint32_t *)0xE000ED08UL = (uint32_t)__isr_vector;
}
#endif

// --- Entry point -----------------------------------------------------------
int main(void) {
#if SMK_BOARD_FEATHER_NRF52840
    // VTOR must be fixed before anything can safely take an interrupt.
    // mpsl_glue_init() is skipped entirely on this board — this bring-up
    // pass is USB HID only (see Sources/smk/Main.swift's
    // SMK_BOARD_FEATHER_NRF52840 branch, which also skips init_ble_hid()),
    // and MPSL claiming RTC0/TIMER0/RADIO interrupts was the most likely
    // immediate trigger of the stale-VTOR crash before this fix.
    smk_relocate_vector_table();
    smk_led_init(SMK_LED_RED);
    smk_led_init(SMK_LED_GREEN);
    smk_led_init(SMK_LED_BLUE);
    smk_boot_stage(1); // stage 1: main() is running
#else
    mpsl_glue_init(); // bring up MPSL before the scan loop starts (Task 5)
#endif
    // Every board, MPSL or not — see the extern declaration above. Runs
    // before app_main_swift()'s init_wired_link()/tusb_rhport_init(), the
    // same ordering TinyUSB's own nRF BSP uses (board_init() before
    // tusb_init()).
    // Green/blue are driven from inside smk_usb_power_init itself now (see
    // MpslGlue.swift), which brackets its two blocking sub-steps:
    //   red + blue steady        = hung inside the USB DETECTED handler
    //   red + green + blue steady = hung inside the USB READY handler
    //   red + green, blue blinking = booted through to the scan loop
    smk_usb_power_init();
    app_main_swift(); // never returns (infinite scan loop)
    return 0;
}

// posix_memalign and the Embedded-Swift Unicode linker stubs moved to the
// shared ports/common/embedded_swift_glue.c (identical across all ARM ports).
