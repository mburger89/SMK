#include "smk_keymap_protocol.h"
#include <string.h>

int32_t smk_keymap_begin_write(uint16_t total_len);
int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len);
int32_t smk_keymap_commit(uint32_t crc32);
void smk_keymap_erase(void);

#define SMK_OP_BEGIN  0x01
#define SMK_OP_CHUNK  0x02
#define SMK_OP_COMMIT 0x03
#define SMK_OP_ERASE  0x04

#define SMK_STATUS_OK  0x00
#define SMK_STATUS_ERR 0x01

void smk_keymap_dispatch_packet(const uint8_t *packet, uint8_t *response) {
    memset(response, 0, SMK_KEYMAP_PACKET_LEN);
    uint8_t opcode = packet[0];
    int32_t result = -1;

    switch (opcode) {
        case SMK_OP_BEGIN: {
            uint16_t total_len = (uint16_t)packet[1] | ((uint16_t)packet[2] << 8);
            result = smk_keymap_begin_write(total_len);
            break;
        }
        case SMK_OP_CHUNK: {
            uint16_t offset = (uint16_t)packet[1] | ((uint16_t)packet[2] << 8);
            uint8_t chunk_len = packet[3];
            result = smk_keymap_write_chunk(offset, &packet[4], chunk_len);
            break;
        }
        case SMK_OP_COMMIT: {
            uint32_t crc32 = (uint32_t)packet[1] | ((uint32_t)packet[2] << 8) |
                             ((uint32_t)packet[3] << 16) | ((uint32_t)packet[4] << 24);
            result = smk_keymap_commit(crc32);
            break;
        }
        case SMK_OP_ERASE: {
            smk_keymap_erase();
            result = 0;
            break;
        }
        default:
            result = -1;
            break;
    }

    response[0] = (result == 0) ? SMK_STATUS_OK : SMK_STATUS_ERR;
    response[1] = opcode;
}
