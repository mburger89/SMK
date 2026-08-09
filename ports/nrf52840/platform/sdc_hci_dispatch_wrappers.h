/*
 * Vendored unmodified for SMK's nRF52840 port from nrfconnect/sdk-nrf's
 * subsys/bluetooth/controller/hci_internal_wrappers.h, pinned commit
 * f48ab6dfbddeb240a21cda86109480d0e2e12f57. sdc_hci_dispatch.c
 * unconditionally #includes this file even though this project doesn't
 * need the one declaration inside it (guarded by
 * CONFIG_BT_HCI_ACL_FLOW_CONTROL, which this project leaves undefined —
 * see sdc_bt_compat.h). Has no Zephyr header dependencies, so no
 * adaptation was required beyond vendoring it under this project's naming
 * scheme. See Task 6 of
 * docs/superpowers/plans/2026-08-09-nrf52840-support.md.
 *
 * Original copyright notice preserved below, as required by its license.
 *
 * Copyright (c) 2025 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

/** @file
 *  @brief Internal HCI interface Wrappers
 */

#include <stdint.h>
#include <stdbool.h>
#include <sdc_hci_cmd_controller_baseband.h>

#ifndef HCI_INTERNAL_WRAPPERS_H__
#define HCI_INTERNAL_WRAPPERS_H__

#if defined(__DOXYGEN__) || defined(CONFIG_BT_HCI_ACL_FLOW_CONTROL)
int sdc_hci_cmd_cb_host_buffer_size_wrapper(const sdc_hci_cmd_cb_host_buffer_size_t *cmd_params);
#endif

#endif
