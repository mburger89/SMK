/* utilities_common.h — project-local minimal replacement, NOT vendored from
 * STM32CubeWB.
 *
 * ST's real `Middlewares/ST/STM32_WPAN/utilities/utilities_common.h` is
 * literally `stm32_wpan_common.h`'s content (same NULL/TRUE/FALSE defines,
 * same BACKUP_PRIMASK/DISABLE_IRQ/RESTORE_PRIMASK critical-section macros,
 * same MIN/MAX/MODINC/... helpers) plus an unconditional
 * `#include "app_conf.h"` — the large CubeMX-generated per-project config
 * file that this port deliberately does not have (see this task's report).
 *
 * The only vendored file that includes it is `stm_list.c`, a plain
 * doubly-linked-list implementation whose entire dependency surface is
 * `TRUE`/`FALSE` and CMSIS's `__get_PRIMASK`/`__set_PRIMASK`/`__disable_irq`.
 * All of those come from `stm32_wpan_common.h`, so forwarding to it is an
 * exact, behaviour-preserving replacement and lets `stm_list.c` stay
 * byte-for-byte identical to upstream v1.24.0.
 */

#ifndef SMK_UTILITIES_COMMON_H
#define SMK_UTILITIES_COMMON_H

#include "stm32_wpan_common.h"

#endif /* SMK_UTILITIES_COMMON_H */
