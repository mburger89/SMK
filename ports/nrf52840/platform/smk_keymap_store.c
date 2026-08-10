// Runtime keymap store (nRF52840) — BUILD-ONLY STUB.
//
// Counterpart to ports/rp2040/platform/smk_keymap_store.c (flash-backed) and
// Sources/components/smk_keymap_store.c (ESP32-C6, NVS-backed). This board
// has no hardware yet (see
// docs/superpowers/specs/2026-08-09-nrf52840-support-design.md's build-only
// scope for this task), so there is no flash layout to target — every
// operation here is a no-op / "nothing stored" placeholder, NOT a real
// implementation. This is a known gap flagged for follow-up: a real
// flash-backed store needs to replace this once hardware exists and a flash
// layout has been decided. NOTE: a raw NVMC driver (RP2040's approach) is
// NOT an option here once the SoftDevice Controller (Task 6/7) is running —
// nrfxlib's own docs (softdevice_controller.rst) list NVMC among the
// peripherals "owned by the controller and must not be accessed directly by
// the application" on the nRF52 series. As of this vendored ~/sdk-nrfxlib
// checkout, sdc_soc.h exposes only sdc_rand_source_register() — no public
// flash-write API (older SDC releases had sdc_soc_flash_write_async/
// sdc_soc_flash_page_erase_async per the CHANGELOG, but those were removed
// upstream and aren't present in this vendored version). Whoever implements
// this needs to re-check the SDC version in use at that time for whatever
// flash-write mechanism it currently exposes (or coordinate through
// nRF5 SDK's fstorage if that's still compatible with a running SDC) rather
// than assuming either of the approaches named above.
//
// USB HID (Task 4) is wired up now, so smk_keymap_begin_write/write_chunk/
// commit ARE reachable from a real host via Sources/components/
// smk_keymap_protocol.c's dispatch — they're not dead code. They just
// unconditionally fail (return -1), same as smk_keymap_load, since there's
// still no backing store: any keymap upload attempted against this board
// today will be accepted over USB but silently fail to persist.

#include <stdint.h>
#include <stddef.h>

int32_t smk_keymap_load(char *buf, uint32_t buf_size) {
    (void)buf;
    (void)buf_size;
    return -1; // no stored keymap
}

void smk_keymap_erase(void) {
    // no-op: nothing is ever stored yet
}

int32_t smk_keymap_begin_write(uint16_t total_len) {
    (void)total_len;
    return -1;
}

int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len) {
    (void)offset;
    (void)data;
    (void)len;
    return -1;
}

int32_t smk_keymap_commit(uint32_t crc32) {
    (void)crc32;
    return -1;
}
