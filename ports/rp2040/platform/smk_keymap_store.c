// Runtime keymap store (RP2040, flash-backed). Counterpart to
// Sources/componets/smk_keymap_store.c (ESP32-C6, NVS-backed) — same framed
// blob layout and function contract (declared in BridgingHeader.h). Reserves
// the last flash sector (4KB, this chip's minimum erase granularity) for
// the stored keymap.

#include "hardware/flash.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"
#include <string.h>
#include <stdint.h>

#define SMK_KEYMAP_MAX_LEN 4085
#define SMK_KEYMAP_FRAME_LEN (11 + SMK_KEYMAP_MAX_LEN)

#define SMK_KEYMAP_MAGIC0 'S'
#define SMK_KEYMAP_MAGIC1 'M'
#define SMK_KEYMAP_MAGIC2 'K'
#define SMK_KEYMAP_MAGIC3 'M'
#define SMK_KEYMAP_VERSION 1

// Reserve the last flash sector. Flash is memory-mapped for reads at
// XIP_BASE at all times, so the store can be read directly as a pointer.
#define SMK_KEYMAP_FLASH_OFFSET (PICO_FLASH_SIZE_BYTES - FLASH_SECTOR_SIZE)
static const uint8_t *const s_flash_frame =
    (const uint8_t *)(XIP_BASE + SMK_KEYMAP_FLASH_OFFSET);

static uint8_t s_stage[SMK_KEYMAP_FRAME_LEN];
static uint16_t s_stage_total_len = 0;

static uint32_t smk_crc32(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            uint32_t mask = (uint32_t)(-(int32_t)(crc & 1u));
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

int32_t smk_keymap_load(char *buf, uint32_t buf_size) {
    if (s_flash_frame[0] != SMK_KEYMAP_MAGIC0 || s_flash_frame[1] != SMK_KEYMAP_MAGIC1 ||
        s_flash_frame[2] != SMK_KEYMAP_MAGIC2 || s_flash_frame[3] != SMK_KEYMAP_MAGIC3 ||
        s_flash_frame[4] != SMK_KEYMAP_VERSION) {
        return -1;
    }

    uint16_t json_len = (uint16_t)s_flash_frame[5] | ((uint16_t)s_flash_frame[6] << 8);
    uint32_t stored_crc = (uint32_t)s_flash_frame[7] | ((uint32_t)s_flash_frame[8] << 8) |
                          ((uint32_t)s_flash_frame[9] << 16) | ((uint32_t)s_flash_frame[10] << 24);

    if (json_len > SMK_KEYMAP_MAX_LEN || (uint32_t)json_len + 1 > buf_size) {
        return -1;
    }

    if (smk_crc32(&s_flash_frame[11], json_len) != stored_crc) {
        return -1;
    }

    memcpy(buf, &s_flash_frame[11], json_len);
    return (int32_t)json_len;
}

void smk_keymap_erase(void) {
    uint32_t ints = save_and_disable_interrupts();
    flash_range_erase(SMK_KEYMAP_FLASH_OFFSET, FLASH_SECTOR_SIZE);
    restore_interrupts(ints);
}

int32_t smk_keymap_begin_write(uint16_t total_len) {
    if (total_len > SMK_KEYMAP_MAX_LEN) {
        return -1;
    }
    s_stage_total_len = total_len;
    memset(s_stage, 0, sizeof(s_stage));
    return 0;
}

int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len) {
    if ((uint32_t)offset + len > s_stage_total_len) {
        return -1;
    }
    memcpy(&s_stage[11 + offset], data, len);
    return 0;
}

int32_t smk_keymap_commit(uint32_t crc32) {
    if (smk_crc32(&s_stage[11], s_stage_total_len) != crc32) {
        return -1;
    }

    s_stage[0] = SMK_KEYMAP_MAGIC0;
    s_stage[1] = SMK_KEYMAP_MAGIC1;
    s_stage[2] = SMK_KEYMAP_MAGIC2;
    s_stage[3] = SMK_KEYMAP_MAGIC3;
    s_stage[4] = SMK_KEYMAP_VERSION;
    s_stage[5] = (uint8_t)(s_stage_total_len & 0xFF);
    s_stage[6] = (uint8_t)((s_stage_total_len >> 8) & 0xFF);
    s_stage[7] = (uint8_t)(crc32 & 0xFF);
    s_stage[8] = (uint8_t)((crc32 >> 8) & 0xFF);
    s_stage[9] = (uint8_t)((crc32 >> 16) & 0xFF);
    s_stage[10] = (uint8_t)((crc32 >> 24) & 0xFF);

    // flash_range_program requires a length that's a multiple of
    // FLASH_PAGE_SIZE (256 bytes); s_stage is already zero-padded past the
    // real data (memset in smk_keymap_begin_write), so round up.
    uint32_t program_len =
        ((11 + s_stage_total_len + FLASH_PAGE_SIZE - 1) / FLASH_PAGE_SIZE) * FLASH_PAGE_SIZE;

    uint32_t ints = save_and_disable_interrupts();
    flash_range_erase(SMK_KEYMAP_FLASH_OFFSET, FLASH_SECTOR_SIZE);
    flash_range_program(SMK_KEYMAP_FLASH_OFFSET, s_stage, program_len);
    restore_interrupts(ints);
    return 0;
}
