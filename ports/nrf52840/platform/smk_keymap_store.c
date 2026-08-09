// Runtime keymap store (nRF52840) — BUILD-ONLY STUB.
//
// Counterpart to ports/rp2040/platform/smk_keymap_store.c (flash-backed) and
// Sources/componets/smk_keymap_store.c (ESP32-C6, NVS-backed). This board
// has no hardware yet (see
// docs/superpowers/specs/2026-08-09-nrf52840-support-design.md's build-only
// scope for this task), so there is no flash layout to target — every
// operation here is a no-op / "nothing stored" placeholder, NOT a real
// implementation. This is a known gap flagged for follow-up: a real
// flash-backed store (nRF5 SDK's fstorage, or a raw NVMC driver matching
// RP2040's approach) needs to replace this once hardware exists and a flash
// layout has been decided.
//
// Only smk_keymap_load/smk_keymap_erase are reachable from this task's
// build (called directly from Sources/smk/Main.swift). smk_keymap_begin_write
// /write_chunk/commit are unreachable until Task 4 wires up USB HID and
// links Sources/componets/smk_keymap_protocol.c's dispatch — they're
// stubbed here now for API-surface completeness with BridgingHeader.h.

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
