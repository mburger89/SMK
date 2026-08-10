#pragma once
#include <stdint.h>

// Shared BEGIN/CHUNK/COMMIT/ERASE packet dispatch for the runtime keymap
// upload protocol. Transport-agnostic: the ESP32-C6 BLE Report ID 2 path
// (ble_helper.c) and the RP2040 raw-HID interface path
// (ports/rp2040/platform/usb_descriptors.c) each call this with whatever
// bytes their transport received, and send back whatever bytes it writes
// into `response` over that same transport. See
// docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md.

#define SMK_KEYMAP_PACKET_LEN 32

// packet and response must both point to SMK_KEYMAP_PACKET_LEN-byte
// buffers. Packet layout (byte 0 = opcode):
//   0x01 BEGIN:  bytes 1-2 = total_len (u16 LE)
//   0x02 CHUNK:  bytes 1-2 = offset (u16 LE), byte 3 = chunk len, bytes 4.. = data
//   0x03 COMMIT: bytes 1-4 = crc32 (u32 LE)
//   0x04 ERASE:  no payload
// Response layout: byte 0 = status (0x00 OK / 0x01 ERR), byte 1 = echoed opcode.
void smk_keymap_dispatch_packet(const uint8_t *packet, uint8_t *response);
