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
 *
 * NOTE FOR TASK 7: this file deliberately reuses ST's real header name so the
 * vendored .c files can stay byte-identical to upstream. It lives on the shared
 * ports/stm32wb/platform/ include path, so it will SHADOW the genuine ST header
 * of the same name if a real ST HAL/middleware tree is ever added to this
 * target's include path (e.g. BTstack's vendored STM32WBxx_HAL_Driver copy
 * under ~/btstack/port/stm32-wb55xx-nucleo-freertos/Drivers/). If Task 7 adds
 * such a path and something mysteriously can't find an ST symbol it expects,
 * this shadowing is the first thing to check.
 */

#ifndef SMK_UTILITIES_COMMON_H
#define SMK_UTILITIES_COMMON_H

#include "stm32_wpan_common.h"

#endif /* SMK_UTILITIES_COMMON_H */
