// C remainder of the nrf52840 BLE HID transport — the SDC bring-up, the
// hci_transport_t vtable, the HCI poll loop, and init_ble_hid() are all
// Swift now (ports/nrf52840/BleHidSdc.swift; the HID-over-GATT half is the
// shared ports/common/BleHidGatt.swift). What stays here is only what Swift
// can't express:
//
//   - hal_cpu_* / hal_time_ms: BTstack's embedded run-loop HAL.
//     hal_cpu_disable_irqs/enable_irqs are CMSIS `asm volatile` intrinsics
//     (__disable_irq/__enable_irq) with no linkable symbol. hal_time_ms is
//     kept adjacent to them: still a monotonic per-call counter, NOT a real
//     millisecond clock, until a real RTC-backed clock replaces it — a
//     known, deliberate limitation of this build-only pass (BTstack's
//     timeouts elapse in "N calls" rather than "N ms").
//
//   - smk_sdc_rand_poll: NRF_RNG register polling — hardware-register
//     accesses that are naturally volatile in C, feeding LE Secure
//     Connections pairing (CONFIG.DERCEN bias correction on for that
//     reason). Blocking/polling per sdc_rand_source_t's contract ("must
//     block until length bytes were written").
//
//   - smk_sdc_fault_handler: registered with sdc_init() AND reused by the
//     Swift side as its hang-on-unrecoverable-error primitive — the
//     infinite spin stays in C where its semantics are unambiguous.
//
// hal_cpu_enable_irqs_and_sleep deliberately does NOT WFE/WFI — this
// project's main loop is cooperative busy-polling throughout and there is
// no guaranteed periodic wakeup source confirmed yet; re-enabling IRQs and
// returning costs power but cannot hang. See git history for the fuller
// original notes.

#include <stdint.h>

#include <nrf.h> // NRF_RNG + CMSIS core intrinsics via core_cm4.h

void smk_sdc_fault_handler(const char *file, uint32_t line) {
    (void)file; (void)line;
    while (1) { }
}

void smk_sdc_rand_poll(uint8_t *p_buff, uint8_t length) {
    NRF_RNG->CONFIG = (RNG_CONFIG_DERCEN_Enabled << RNG_CONFIG_DERCEN_Pos);
    NRF_RNG->TASKS_START = 1;
    for (uint8_t i = 0; i < length; i++) {
        NRF_RNG->EVENTS_VALRDY = 0;
        while (NRF_RNG->EVENTS_VALRDY == 0) { }
        p_buff[i] = (uint8_t)NRF_RNG->VALUE;
    }
    NRF_RNG->TASKS_STOP = 1;
}

// --- BTstack run loop HAL ----------------------------------------------------

static uint32_t s_hal_time_ms_counter = 0;

uint32_t hal_time_ms(void) {
    s_hal_time_ms_counter++;
    return s_hal_time_ms_counter;
}

void hal_cpu_disable_irqs(void) {
    __disable_irq();
}

void hal_cpu_enable_irqs(void) {
    __enable_irq();
}

void hal_cpu_enable_irqs_and_sleep(void) {
    __enable_irq(); // no real WFE/WFI sleep yet — see header comment
}
