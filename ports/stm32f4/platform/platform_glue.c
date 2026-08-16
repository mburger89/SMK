// Misc platform glue for the STM32F4 build: logging, the cooperative delay
// shim, the C entry point, board/connection-mode config, BLE HID stubs (out
// of scope this pass), the newlib syscall stub bodies, and the
// Embedded-Swift linker stubs.
//
// This is a build-only pass — no hardware exists for this board yet. kb_log
// and vTaskDelay below are placeholders, same status as
// ports/nrf52840/platform/platform_glue.c's:
//   - kb_log: no-op. Real firmware should route this to a UART once one is
//     selected during hardware bring-up.
//   - vTaskDelay: busy-loop only. Real timing should come from a hardware
//     timer (e.g. SysTick) once one is set up — not done in this pass.
//
// posix_memalign/_init are needed even for the Task 1 smoke test, not just
// the full app: Swift's Embedded runtime (swift_allocObject/
// swift_slowAlloc) unconditionally references posix_memalign, and
// startup_stm32f411xe.s's Reset_Handler unconditionally calls
// __libc_init_array (which calls _init) before main() — found empirically
// via real link errors during this port's Task 1, not anticipated by the
// plan. _init would normally come from crti.o/crtn.o, but CMakeLists.txt's
// -nostartfiles excludes those, so a trivial no-op stub is needed here
// instead. The rest of newlib's syscall stubs (_exit/_sbrk/_write/_read/
// etc.) are satisfied by CMakeLists.txt's --specs=nosys.specs link flag.

#include <stdint.h>

extern void smk_clock_init(void); // RCC/PLL bring-up (Task 2, ports/stm32f4/ClockInit.swift)
extern void app_main_swift(void); // shared entry point (Sources/smk/Main.swift)
extern void kb_usb_task(void);    // pumps TinyUSB (Task 5, ports/stm32f4/UsbHid.swift)

// --- Logging -----------------------------------------------------------
void kb_log(const char *msg) {
    (void)msg;
}

// --- Cooperative delay shim ----------------------------------------------
// The shared scan loop calls vTaskDelay(1) once per tick. Placeholder
// busy-loop only (no calibrated timer yet) — real timing should use a
// hardware timer once hardware bring-up starts.
void vTaskDelay(uint32_t ticks) {
    kb_usb_task();
    if (ticks == 0) ticks = 1;
    for (volatile uint32_t i = 0; i < ticks * 100000u; i++) {
        __asm__ volatile("nop");
    }
}

// --- Connection-mode config ------------------------------------------------
// This board always has real native-USB wired HID, no BLE, no wired-HID
// bridge — matching RP2040/nRF52840's pattern for boards without one.
int smk_has_wired_bridge(void) { return 1; }
int smk_default_mode_is_wired(void) { return 1; }

// --- BLE HID stub (out of scope this pass, see the design spec's Future Work) ---
// Sources/smk/Main.swift calls these unconditionally regardless of board.
void init_ble_hid(void) {
    // Stub — BLE is a future STM32WB cycle, not this one.
}

void send_keyboard_report(uint8_t modifier, uint8_t *keycodes) {
    (void)modifier;
    (void)keycodes;
}

// --- Entry point -----------------------------------------------------------
int main(void) {
    smk_clock_init(); // RCC/PLL bring-up before anything else (Task 2)
    app_main_swift();  // never returns (infinite scan loop)
    return 0;
}

// posix_memalign and the Embedded-Swift Unicode linker stubs moved to the
// shared ports/common/embedded_swift_glue.c (identical across all ARM ports).

// --- _init (crti.o/crtn.o normally provide this; excluded by -nostartfiles) ---
void _init(void) {}
