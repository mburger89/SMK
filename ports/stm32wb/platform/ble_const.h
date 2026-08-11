/* ble_const.h — project-local minimal replacement, NOT vendored from
 * STM32CubeWB.
 *
 * ST's real `Middlewares/ST/STM32_WPAN/ble/core/template/ble_const.h` is the
 * public constant/type header of ST's own BLE *host* stack: it pulls in
 * `ble_std.h`, `ble_defs.h`, `osal.h` and `compiler.h` from the same
 * `ble/core/template` tree and defines several hundred BLE protocol
 * constants. This port does not use ST's host stack — BTstack sits on top of
 * the vendored transport layer instead (Task 7) — so vendoring that whole
 * subtree would be dead weight.
 *
 * The only vendored file that includes it is `hci_tl.c`, and the only thing
 * it takes from it is `struct hci_request` (used by `hci_send_req`, which
 * `hci_tl.c` itself defines). Reproduced below field-for-field, in order,
 * from the upstream v1.24.0 definition at `ble_const.h:103-113` — the layout
 * must match exactly, since `hci_send_req` is part of the ABI ST's own host
 * stack would call if it were ever linked in.
 *
 * Keeping this here lets `hci_tl.c` stay byte-for-byte identical to upstream.
 */

#ifndef SMK_BLE_CONST_H
#define SMK_BLE_CONST_H

#include <stdint.h>

/* Verbatim layout of upstream ble_const.h's `struct hci_request`. */
struct hci_request
{
  uint16_t ogf;
  uint16_t ocf;
  int      event;
  void*    cparam;
  int      clen;
  void*    rparam;
  int      rlen;
};

extern int hci_send_req( struct hci_request* req, uint8_t async );

#endif /* SMK_BLE_CONST_H */
