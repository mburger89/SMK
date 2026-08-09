// Compatibility shim replacing sdc_hci_dispatch.c's/.h's Zephyr header
// dependencies (<zephyr/bluetooth/hci.h>, <zephyr/bluetooth/buf.h>,
// <zephyr/sys/byteorder.h>, <zephyr/drivers/bluetooth.h>,
// <zephyr/sys/slist.h>) with the exact symbols they actually use — verified
// via grep over the vendored file, not guessed. See Task 6 of
// docs/superpowers/plans/2026-08-09-nrf52840-support.md for the full
// verification trail. All Bluetooth-named values/structs below are standard
// Bluetooth Core Specification wire-format definitions (HCI packet headers,
// event codes, error codes, OpCode Group Fields), not Zephyr-specific —
// cross-checked field-for-field against Zephyr's own
// include/zephyr/bluetooth/hci_types.h so the byte layout this dispatcher
// produces is spec-correct, not just "whatever compiles".
//
// IMPORTANT — this list is intentionally BIGGER than what the original task
// brief enumerated. The brief's research pass found 8 constants + 2
// functions + 3 Kconfig flags. Re-verifying against the actual fetched
// hci_internal.c/.h during implementation turned up several more real
// dependencies the brief's grep pass missed:
//   - BT_OGF/BT_OGF_LINK_CTRL/BT_OGF_BASEBAND/BT_OGF_INFO/BT_OGF_STATUS/
//     BT_OGF_LE/BT_OGF_VS: used unconditionally in cmd_put()'s opcode
//     dispatch switch — not gated by any #if, so genuinely required for
//     the file to compile at all, not just "nice to have".
//   - struct bt_hci_evt_hdr, struct bt_hci_cmd_hdr,
//     struct bt_hci_evt_cmd_complete, struct bt_hci_evt_cmd_status,
//     struct bt_hci_evt_cc_status: the actual HCI event/command packet
//     header layouts, used to encode/decode raw event bytes. The brief
//     listed BT_HCI_EVT_HDR_SIZE/BT_HCI_CMD_HDR_SIZE (the sizeof-equivalent
//     constants) but not the structs themselves, which are used directly
//     (e.g. `((struct bt_hci_evt_hdr *)event)->len = ...`) in several
//     places. Field layouts below are copied verbatim from Zephyr's
//     hci_types.h (Apache-2.0), packed to match the Bluetooth Core Spec
//     wire format exactly.
//   - bt_hci_recv_t: a function-pointer typedef used only inside the
//     unused `struct hci_driver_data` in sdc_hci_dispatch.h (nothing in
//     the .c file references that struct — Task 7 talks to this dispatcher
//     via hci_internal_cmd_put()/hci_internal_msg_get() directly). Given a
//     harmless generic signature here purely so the header parses; if a
//     future task actually needs a real net_buf-based receive callback
//     type, this typedef must be revisited.
//   - STRUCT_SECTION_FOREACH: Zephyr's linker-section-based iterable
//     registration mechanism, used once in cmd_put() to walk
//     user-registered HCI extension handlers
//     (DEFINE_HCI_USER_EXTENSION_HANDLER). This project registers no such
//     handlers anywhere, so it's implemented here as a loop that always
//     iterates zero times — semantically correct for "no handlers
//     registered", not a stub that silently drops behavior.
//   - IS_ENABLED: Zephyr's config-flag-to-0/1 preprocessor trick, used
//     once (`IS_ENABLED(CONFIG_BT_CTLR_ADV_EXT)`). Vendored verbatim from
//     Zephyr's sys/util_internal.h (Apache-2.0) since reimplementing it
//     sloppily (e.g. hardcoding 0) would silently break the moment any
//     CONFIG_BT_* flag in this file's #if-guards is ever defined.
//   - <errno.h> (EINVAL) and <string.h> (memcpy): plain standard C library
//     headers the vendored file relies on implicitly. In real Zephyr these
//     arrive transitively through kernel.h et al.; here, since we're
//     linking a bare-metal newlib toolchain (arm-none-eabi-gcc) rather
//     than Zephyr's kernel headers, they must be included explicitly.
//     Confirmed nothing else in the include chain (sdc_hci*.h) pulls them
//     in — grepped sdk-nrfxlib's own headers, no <string.h>/<errno.h>
//     anywhere in that tree.
//
// Also found: sdc_hci_dispatch.c unconditionally #includes
// "hci_internal_wrappers.h" (a *third* file the brief's fetch list didn't
// mention at all). Vendored alongside as sdc_hci_dispatch_wrappers.h — its
// one declaration is guarded by CONFIG_BT_HCI_ACL_FLOW_CONTROL, which this
// project leaves undefined, so it contributes nothing at link time, but the
// #include itself must resolve for the .c file to preprocess.
//
// One deliberate correction versus the brief's exact text: NRF_EPERM
// (referenced in sdc_hci_dispatch.c) is NOT part of this shim — it's
// already declared by sdc_hci.h's own transitive #include "nrf_errno.h",
// confirmed via grep over ~/sdk-nrfxlib/softdevice_controller/include/.
// Listing it here would just be a redundant/conflicting redefinition.
//
// --- Upstream attribution ---------------------------------------------
// Portions of this file — the five bt_hci_evt_hdr / bt_hci_cmd_hdr /
// bt_hci_evt_cmd_complete / bt_hci_evt_cmd_status / bt_hci_evt_cc_status
// struct layouts below, and the IS_ENABLED / Z_IS_ENABLED* macro chain —
// are adapted from the Zephyr Project's
// include/zephyr/bluetooth/hci_types.h and
// include/zephyr/sys/util_internal.h.
//
// Copyright (c) 2015-2016 Intel Corporation
// Copyright (c) 2011-2014 Wind River Systems, Inc.
// Copyright (c) 2020-2023 Nordic Semiconductor ASA
//
// SPDX-License-Identifier: Apache-2.0
#ifndef SMK_SDC_BT_COMPAT_H
#define SMK_SDC_BT_COMPAT_H

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// --- HCI packet header sizes (Bluetooth Core Spec Vol 4, Part E) ---------
#define BT_HCI_EVT_HDR_SIZE       2
#define BT_HCI_CMD_HDR_SIZE       3
#define BT_HCI_EVT_CMD_COMPLETE   0x0e
#define BT_HCI_EVT_CMD_STATUS     0x0f
#define BT_HCI_ERR_SUCCESS        0x00
#define BT_HCI_ERR_UNKNOWN_CMD    0x01
#define BT_HCI_ERR_CMD_DISALLOWED 0x0c
#define BT_BUF_EVT_RX_SIZE        258 // HCI_MSG_BUFFER_MAX_SIZE, sdc_hci.h

// --- BIT: Zephyr's sys/util.h bit-mask helper, used throughout the -------
// supported-states/feature-mask encoding tables below (e.g. `BIT(0) |
// BIT(1) | ...`). Plain (1UL << n), nothing Zephyr-specific about the
// semantics.
#define BIT(n) (1UL << (n))

// --- OpCode Group Fields (Bluetooth Core Spec Vol 4, Part E, 5.4.1) -------
// Used unconditionally by cmd_put()'s top-level opcode dispatch switch.
#define BT_OGF_LINK_CTRL 0x01
#define BT_OGF_BASEBAND  0x03
#define BT_OGF_INFO      0x04
#define BT_OGF_STATUS    0x05
#define BT_OGF_LE        0x08
#define BT_OGF_VS        0x3f
#define BT_OGF(opcode) (((opcode) >> 10) & 0x3f)

// --- HCI packet header layouts (Bluetooth Core Spec Vol 4, Part E) --------
// Field layouts match Zephyr's include/zephyr/bluetooth/hci_types.h
// (Apache-2.0) — this is wire format, not Zephyr-internal representation,
// so byte-for-byte compatibility with upstream Zephyr's struct layout is
// exactly what's needed here. (bt_hci_evt_hdr here omits upstream's
// trailing `uint8_t data[];` flexible array member — confirmed unused by
// this vendored dispatcher, so the fixed two-field layout is sufficient.)
struct bt_hci_evt_hdr {
    uint8_t evt;
    uint8_t len;
} __attribute__((packed));

struct bt_hci_cmd_hdr {
    uint16_t opcode;
    uint8_t param_len;
} __attribute__((packed));

struct bt_hci_evt_cmd_complete {
    uint8_t ncmd;
    uint16_t opcode;
} __attribute__((packed));

struct bt_hci_evt_cmd_status {
    uint8_t status;
    uint8_t ncmd;
    uint16_t opcode;
} __attribute__((packed));

struct bt_hci_evt_cc_status {
    uint8_t status;
} __attribute__((packed));

// --- Little-endian pack/unpack (this board's CPU is little-endian, so ----
// these are identity-shaped memcpy-with-a-cast, not real byteswapping). ---
static inline uint16_t sys_get_le16(const uint8_t *buf) {
    return (uint16_t)buf[0] | ((uint16_t)buf[1] << 8);
}

static inline void sys_put_le32(uint32_t val, uint8_t *buf) {
    buf[0] = (uint8_t)(val);
    buf[1] = (uint8_t)(val >> 8);
    buf[2] = (uint8_t)(val >> 16);
    buf[3] = (uint8_t)(val >> 24);
}

// --- bt_hci_recv_t: only referenced by the unused `struct hci_driver_data`
// in sdc_hci_dispatch.h. Generic signature — nothing in this project
// constructs a hci_driver_data, so this only needs to make the header
// parse, not be semantically real.
typedef int (*bt_hci_recv_t)(void *buf);

// --- STRUCT_SECTION_FOREACH: no-op iteration (always zero iterations) ----
// Real Zephyr walks a linker-section-registered list of
// hci_internal_user_extension_handler entries created via
// DEFINE_HCI_USER_EXTENSION_HANDLER. Nothing in this project registers any
// such handler, so "iterate zero registered handlers" is the semantically
// correct behavior here, not a stub.
#define STRUCT_SECTION_FOREACH(struct_type, iterator) \
    for (struct struct_type *iterator = (void *)0; false;)

// --- IS_ENABLED: vendored verbatim from Zephyr's sys/util_internal.h -----
// (Apache-2.0). Used once, on CONFIG_BT_CTLR_ADV_EXT, which this project
// always leaves undefined -> evaluates to 0. Kept as the real
// token-pasting implementation (rather than hardcoded to 0) so this
// doesn't silently break if a future task ever does define one of this
// file's CONFIG_BT_* guards.
#define Z_IS_ENABLED1(config_macro) Z_IS_ENABLED2(_XXXX##config_macro)
#define _XXXX1 _YYYY,
#define Z_IS_ENABLED2(one_or_two_args) Z_IS_ENABLED3(one_or_two_args 1, 0)
#define Z_IS_ENABLED3(ignore_this, val, ...) val
#define IS_ENABLED(config_macro) Z_IS_ENABLED1(config_macro)

#endif
