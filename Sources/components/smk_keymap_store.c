// Runtime keymap store (ESP32-C6, NVS-backed). Persists the framed
// {"layers":[...]} JSON blob uploaded over BLE (see smk_keymap_protocol.c)
// so LayerEngine.loadKeymap has something to load besides the compiled
// default. See docs/superpowers/specs/2026-07-31-runtime-keymap-updates-
// design.md for the frame layout and protocol.
//
// NVS is already initialized by init_ble_hid() (Sources/components/
// ble_helper.c) before Main.swift reaches the keymap-load call site, so no
// separate init is needed here.

#include "nvs.h"
#include "nvs_flash.h"
#include <string.h>
#include <stdint.h>

#define SMK_KEYMAP_MAX_LEN 4085
#define SMK_KEYMAP_FRAME_LEN (11 + SMK_KEYMAP_MAX_LEN)

#define SMK_KEYMAP_MAGIC0 'S'
#define SMK_KEYMAP_MAGIC1 'M'
#define SMK_KEYMAP_MAGIC2 'K'
#define SMK_KEYMAP_MAGIC3 'M'
#define SMK_KEYMAP_VERSION 1

static const char *NVS_NAMESPACE = "smk_kmap";
static const char *NVS_KEY = "frame";

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
    nvs_handle_t handle;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &handle) != ESP_OK) {
        return -1;
    }

    static uint8_t frame[SMK_KEYMAP_FRAME_LEN];
    size_t frame_len = sizeof(frame);
    esp_err_t err = nvs_get_blob(handle, NVS_KEY, frame, &frame_len);
    nvs_close(handle);
    if (err != ESP_OK || frame_len < 11) {
        return -1;
    }

    if (frame[0] != SMK_KEYMAP_MAGIC0 || frame[1] != SMK_KEYMAP_MAGIC1 ||
        frame[2] != SMK_KEYMAP_MAGIC2 || frame[3] != SMK_KEYMAP_MAGIC3 ||
        frame[4] != SMK_KEYMAP_VERSION) {
        return -1;
    }

    uint16_t json_len = (uint16_t)frame[5] | ((uint16_t)frame[6] << 8);
    uint32_t stored_crc = (uint32_t)frame[7] | ((uint32_t)frame[8] << 8) |
                          ((uint32_t)frame[9] << 16) | ((uint32_t)frame[10] << 24);

    if (json_len > SMK_KEYMAP_MAX_LEN || (uint32_t)(11 + json_len) > frame_len ||
        (uint32_t)json_len + 1 > buf_size) {
        return -1;
    }

    if (smk_crc32(&frame[11], json_len) != stored_crc) {
        return -1;
    }

    memcpy(buf, &frame[11], json_len);
    return (int32_t)json_len;
}

void smk_keymap_erase(void) {
    nvs_handle_t handle;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) {
        return;
    }
    nvs_erase_key(handle, NVS_KEY);
    nvs_commit(handle);
    nvs_close(handle);
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

    nvs_handle_t handle;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) {
        return -1;
    }
    esp_err_t err = nvs_set_blob(handle, NVS_KEY, s_stage, 11 + s_stage_total_len);
    if (err == ESP_OK) {
        err = nvs_commit(handle);
    }
    nvs_close(handle);
    return (err == ESP_OK) ? 0 : -1;
}
