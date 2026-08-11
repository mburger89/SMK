/* ble_common.h — project-local minimal replacement, NOT vendored from
 * STM32CubeWB.
 *
 * ST's real `Middlewares/ST/STM32_WPAN/ble/ble_common.h` is:
 *   <stdint.h>/<string.h>/<stdio.h>/<stdlib.h>/<stdarg.h>
 *   + "ble_conf.h"      (CubeMX-generated per-project BLE feature config)
 *   + "ble_dbg_conf.h"  (CubeMX-generated per-project BLE trace config)
 *   + "tl.h"
 *
 * The only vendored file that includes it is `hci_tl.c`, and this port does
 * not use ST's BLE *host* stack at all — BTstack sits on top of this
 * transport layer instead (Task 7). `hci_tl.c`'s body references nothing from
 * `ble_conf.h`/`ble_dbg_conf.h`; what it actually needs out of this header is
 * `tl.h`'s types plus `stm32_wpan_common.h`'s PLACE_IN_SECTION/MIN/FALSE
 * macros (`tl.h` pulls the latter in itself, but include it explicitly here so
 * this header stands on its own).
 *
 * Forwarding keeps `hci_tl.c` byte-for-byte identical to upstream v1.24.0.
 */

#ifndef SMK_BLE_COMMON_H
#define SMK_BLE_COMMON_H

#include "stm32_wpan_common.h"
#include "tl.h"

#endif /* SMK_BLE_COMMON_H */
