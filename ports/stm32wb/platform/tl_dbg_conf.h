/* tl_dbg_conf.h — project-local minimal replacement, NOT vendored from
 * STM32CubeWB.
 *
 * ST's own `tl_dbg_conf.h` (e.g.
 * Projects/P-NUCLEO-WB55.Nucleo/Applications/BLE/BLE_HeartRate/STM32_WPAN/App/
 * tl_dbg_conf.h) pulls in `app_conf.h`, `dbg_trace.h` and `hw_if.h` — a whole
 * CubeMX-generated tracing/UART stack this project doesn't have and doesn't
 * want. Every trace macro it defines is compiled out in ST's own default
 * configuration anyway (all TL_*_DBG_*_EN are 0), so the honest minimal
 * replacement is exactly that: the no-op branch of each `#if`.
 *
 * The 13 macro names below are not guessed — they are the complete set of
 * `TL_*_DBG_*` identifiers referenced by the vendored `tl_mbox.c`, obtained by
 * grepping that file. If a future vendored file references another one, the
 * build will fail loudly (implicit-function-declaration / undeclared) rather
 * than silently doing the wrong thing.
 */

#ifndef TL_DBG_CONF_H
#define TL_DBG_CONF_H

#ifdef __cplusplus
extern "C" {
#endif

/* System (SHCI) transport layer */
#define TL_SHCI_CMD_DBG_MSG(...)
#define TL_SHCI_CMD_DBG_BUF(...)
#define TL_SHCI_CMD_DBG_RAW(...)
#define TL_SHCI_EVT_DBG_MSG(...)
#define TL_SHCI_EVT_DBG_BUF(...)
#define TL_SHCI_EVT_DBG_RAW(...)

/* BLE (HCI) transport layer */
#define TL_HCI_CMD_DBG_MSG(...)
#define TL_HCI_CMD_DBG_BUF(...)
#define TL_HCI_CMD_DBG_RAW(...)
#define TL_HCI_EVT_DBG_MSG(...)
#define TL_HCI_EVT_DBG_BUF(...)
#define TL_HCI_EVT_DBG_RAW(...)

/* Memory manager — released-buffer tracing */
#define TL_MM_DBG_MSG(...)

#ifdef __cplusplus
}
#endif

#endif /* TL_DBG_CONF_H */
