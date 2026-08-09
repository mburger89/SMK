// BTstack configuration for the SMK nRF52840 BLE HID keyboard (LE peripheral
// only). Identical content to ports/rp2040/platform/btstack_config.h — none
// of this is transport-specific, and the RP2040 BLE build (Pico W /
// smk_kbd_rp2040) is the proven reference for these values.

#pragma once

// BTstack features
#define ENABLE_BLE
#define ENABLE_LE_PERIPHERAL
#define ENABLE_LE_SECURE_CONNECTIONS
#define ENABLE_L2CAP_LE_CREDIT_BASED_FLOW_CONTROL_MODE
#define ENABLE_LOG_INFO
#define ENABLE_LOG_ERROR
#define ENABLE_PRINTF_HEXDUMP

// BTstack configuration. buffers, sizes, ...
#define HCI_OUTGOING_PRE_BUFFER_SIZE 4
#define HCI_ACL_PAYLOAD_SIZE (255 + 4)
#define HCI_ACL_CHUNK_SIZE_ALIGNMENT 4
#define MAX_NR_GATT_CLIENTS 0
#define MAX_NR_HCI_CONNECTIONS 1
#define MAX_NR_L2CAP_SERVICES 3
#define MAX_NR_L2CAP_CHANNELS 3
#define MAX_NR_LE_DEVICE_DB_ENTRIES 16
#define MAX_NR_SM_LOOKUP_ENTRIES 3
#define MAX_NR_WHITELIST_ENTRIES 16

// Limit number of ACL/SCO Buffer to use by stack to avoid shared bus contention
#define MAX_NR_CONTROLLER_ACL_BUFFERS 3
#define MAX_NR_CONTROLLER_SCO_PACKETS 3

// Enable and configure HCI Controller to Host Flow Control to avoid shared bus overrun
#define ENABLE_HCI_CONTROLLER_TO_HOST_FLOW_CONTROL
#define HCI_HOST_ACL_PACKET_LEN (255+4)
#define HCI_HOST_ACL_PACKET_NUM 3
#define HCI_HOST_SCO_PACKET_LEN 120
#define HCI_HOST_SCO_PACKET_NUM 3

// Link Key DB / LE Device DB persistence: the RP2040 config (which this file
// is otherwise a straight copy of) defines NVM_NUM_DEVICE_DB_ENTRIES here to
// select btstack's flash-TLV-backed LE device DB (le_device_db_tlv.c) over
// its plain in-memory one (le_device_db_memory.c) — RP2040's BLE build links
// pico_btstack_flash_bank for that. This port has no flash-TLV backend wired
// up (out of scope for Task 7 — bonding persistence across reboots is a
// separate feature), so NVM_NUM_DEVICE_DB_ENTRIES is deliberately left
// undefined: le_device_db_memory.c's own `#ifndef NVM_NUM_DEVICE_DB_ENTRIES`
// guard (see that file) then compiles in its real implementation instead of
// silently reducing to zero exported symbols, which is what caused
// undefined-reference link errors for le_device_db_* from sm.c the first
// time this was tried with the define present. Consequence: LE bonding
// information does not survive a reboot on this board (every pairing starts
// fresh) — acceptable for this build-only, no-hardware-yet pass.
// #define NVM_NUM_DEVICE_DB_ENTRIES 16
// #define NVM_NUM_LINK_KEYS 16 -- classic Bluetooth only (ENABLE_CLASSIC is
// not defined for this LE-only build), kept out entirely rather than left
// as a dead define.

// We don't give btstack a malloc, so use a fixed-size ATT DB.
#define MAX_ATT_DB_SIZE 512

// BTstack HAL configuration
#define HAVE_EMBEDDED_TIME_MS

// map btstack_assert onto a real fault instead of the RP2040/Pico SDK assert()
// this file's SDC path has no equivalent — sdc_fault_handler() in
// ble_hid_sdc.c halts the same way, so HAVE_ASSERT is intentionally left
// undefined here (btstack_assert falls back to its own default, a no-op
// unless HAVE_ASSERT is set — matching this build's other placeholder
// fault-handling, e.g. platform_glue.c's busy-loop halts).

// Some USB dongles take longer to respond to HCI reset (e.g. BCM20702A).
// Not applicable to the in-firmware SDC transport (no real UART/USB dongle
// negotiation happens), but harmless to keep for parity with the RP2040
// config's timeout tuning.
#define HCI_RESET_RESEND_TIMEOUT_MS 1000

#define ENABLE_SOFTWARE_AES128
#define ENABLE_MICRO_ECC_FOR_LE_SECURE_CONNECTIONS
