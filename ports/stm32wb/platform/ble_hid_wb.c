// BLE HID glue for NUCLEO-WB55RG — same SMK BLE contract as
// ports/nrf52840/platform/ble_hid_sdc.c and
// ports/rp2040/platform/ble_hid_kbd_uart.c (init_ble_hid() /
// send_keyboard_report()), but the controller here is CPU2: a Cortex-M0+
// on the same die running ST's own prebuilt wireless-coprocessor firmware,
// reached over the IPCC mailbox rather than a UART or an in-image library.
//
// *** STATUS: build-only, no hardware verification. Every step below is a
// deliberate translation of a documented contract in the Task-6-vendored
// transport layer (platform/tl.h, shci_tl.h, shci.h, tl_mbox.c) and of
// BTstack's own STM32WB55 reference port, but nothing here has been
// exercised on real silicon. ***
//
// ---------------------------------------------------------------------------
// Why this file does NOT go through the vendored hci_tl.c
// ---------------------------------------------------------------------------
// Task 6 vendored ST's whole `interface/patterns/ble_thread/tl` directory,
// including hci_tl.c/hci_tl_if.c. Those two are deliberately NOT part of
// this target's source list any more (see ports/stm32wb/CMakeLists.txt's
// stm32wb_ipcc_srcs comment), for two independent reasons found by reading
// the real vendored code:
//
//   1. Symbol collision. hci_tl.h:185 declares
//        void hci_init(void(* UserEvtRx)(void* pData), void* pConf);
//      and hci_tl.c:68 defines it. BTstack's src/hci.c defines a function
//      with the same C-linkage name and a completely different signature
//      (`void hci_init(const hci_transport_t *, const void *)`). Both
//      objects are unconditionally part of the link, so keeping hci_tl.c
//      is a hard multiple-definition link error, not a stylistic choice.
//
//   2. It would swallow half the HCI event stream. hci_tl.c's
//      TlEvtReceived() (hci_tl.c:275-289) routes Command Complete
//      (TL_BLEEVT_CC_OPCODE) and Command Status (TL_BLEEVT_CS_OPCODE)
//      events into a *separate* queue (HciCmdEventQueue) that is drained
//      only by hci_send_req() — ST's own blocking ACI/HCI request API,
//      which BTstack never calls. Only "asynchronous" events reach
//      hci_user_evt_proc(). BTstack is the HCI *host* here and needs every
//      event, Command Complete/Status very much included (its init state
//      machine is driven by them), so that split is exactly wrong for this
//      integration.
//
// This is also precisely what BTstack's own reference port for this chip
// does: ~/btstack/port/stm32-wb55xx-nucleo-freertos/Makefile:91-96 builds
// shci_tl.c, shci_tl_if.c, tl_mbox.c, shci.c and stm_list.c — and no
// hci_tl.c. Its port/btstack_port.c talks to TL_BLE_Init()/TL_BLE_SendCmd()/
// TL_BLE_SendAclData() (tl.h:291-293) directly. This file follows that
// same design, adapted from FreeRTOS to this project's cooperative
// single-loop, no-RTOS style.
//
// Consequence for Task 6's two deliberately-unstubbed symbols: only
// shci_notify_asynch_evt() is still referenced (shci_tl.c:127, 142 and 230
// — the `void (*)(void*)` signature is read straight off shci_tl.h:108 and
// off those three real call sites, all of which pass
// `(void*) &SHciAsynchEventQueue`). hci_notify_asynch_evt() was referenced
// only from hci_tl.c (lines 131, 146, 285) and has no caller left in the
// link, so it is intentionally not defined here rather than added as dead
// code.

#include <stdint.h>
#include <string.h>

// --- BTstack ---------------------------------------------------------------
// Included before the ST headers on purpose: stm32_wpan_common.h #undefs and
// redefines a batch of very generic macro names (MIN/MAX/ALIGN/TRUE/FALSE/
// PAUSE/...), and BTstack's headers should be parsed with the compiler's own
// notion of those, not ST's.
#include "btstack.h"                 // pulls in hci.h / btstack_run_loop.h / bluetooth.h
#include "btstack_run_loop_embedded.h"
#include "hal_time_ms.h"             // hal_time_ms() — implemented below
#include "hal_cpu.h"                 // hal_cpu_* — implemented below
#include "hci_transport.h"
#include "ble/gatt-service/hids_device.h"
#include "ble/gatt-service/battery_service_server.h"
#include "ble/gatt-service/device_information_service_server.h"
#include "smk_hid.h"                 // generated from platform/smk_hid.gatt at build time

// --- CMSIS device (RCC/PWR/SysTick register definitions) -------------------
#include "stm32wbxx.h"

// --- Task 6's vendored IPCC mailbox transport layer ------------------------
#include "stm32_wpan_common.h"       // PLACE_IN_SECTION / ALIGN / DIVC
#include "stm_list.h"                // LST_* — IRQ-safe intrusive list, used as the event FIFO
#include "tl.h"                      // TL_Init/TL_Enable/TL_BLE_*/TL_MM_* + packet types
#include "shci_tl.h"                 // shci_init(), tSHCI_UserEvtRxParam, shci_user_evt_proc()
#include "shci.h"                    // SHCI_C2_BLE_Init(), SHCI_EVTCODE, SHCI_SUB_EVT_CODE_READY

// ===========================================================================
// CPU2 / BLE stack configuration
// ===========================================================================
// Values taken from ST's own app_conf.h for this exact board
// (~/STM32CubeWB/Projects/P-NUCLEO-WB55.Nucleo/Applications/BLE/BLE_HeartRate/
// Core/Inc/app_conf.h), except where noted. Reproduced here rather than
// vendoring app_conf.h, which is a ~450-line CubeMX-generated file whose
// other 90% (LPM, sequencer, trace, RTC/hw-timer-server, ST-host-stack
// feature switches) this project deliberately does not have.

#define SMK_BLE_NUM_LINK                 1      /* ST default is 2; this keyboard is a
                                                   single-connection peripheral, and
                                                   btstack_config.h's
                                                   MAX_NR_HCI_CONNECTIONS is 1 to match. */
#define SMK_BLE_NUM_GATT_ATTRIBUTES      0      /* ignored by CPU2 in LL_ONLY mode */
#define SMK_BLE_NUM_GATT_SERVICES        0      /* ignored by CPU2 in LL_ONLY mode */
#define SMK_BLE_ATT_VALUE_ARRAY_SIZE     0      /* ignored by CPU2 in LL_ONLY mode */
#define SMK_BLE_MAX_ATT_MTU              156    /* ignored in LL_ONLY; ST's default kept */
#define SMK_BLE_DATA_LENGTH_EXTENSION    1
#define SMK_BLE_PREPARE_WRITE_LIST_SIZE  0x3A   /* ignored in LL_ONLY; BTstack's WB55 port value */
#define SMK_BLE_MBLOCK_COUNT             0x79   /* overwritten by CPU2 in LL_ONLY; ditto */
#define SMK_BLE_PERIPHERAL_SCA           500
#define SMK_BLE_CENTRAL_SCA              0
#define SMK_BLE_MAX_CONN_EVENT_LENGTH    0xFFFFFFFF
#define SMK_BLE_HSE_STARTUP_TIME         0x148
#define SMK_BLE_VITERBI_MODE             1
#define SMK_BLE_MAX_COC_INITIATOR_NBR    32
#define SMK_BLE_MIN_TX_POWER             (-40)
#define SMK_BLE_MAX_TX_POWER             (6)
#define SMK_BLE_MAX_ADV_SET_NBR          3      /* only used when OPTIONS_EXT_ADV is set */
#define SMK_BLE_MAX_ADV_DATA_LEN         1650   /* likewise */
#define SMK_BLE_TX_PATH_COMPENS          0
#define SMK_BLE_RX_PATH_COMPENS          0
#define SMK_BLE_MAX_ADD_EATT_BEARERS     4

// LsSource bit field, shci.h:706-711. NOCALIB | OTHER_DEV (this is a plain
// WB55 SoC, not a WB5M module) | CLK_LSE — matches ST's own non-STM32WB5Mxx
// branch. enable_lse_and_rf_wakeup_clock() below actually starts that LSE.
#define SMK_BLE_LS_SOURCE  (SHCI_C2_BLE_INIT_CFG_BLE_LS_NOCALIB   \
                          | SHCI_C2_BLE_INIT_CFG_BLE_LS_OTHER_DEV \
                          | SHCI_C2_BLE_INIT_CFG_BLE_LS_CLK_LSE)

// THE key divergence from ST's own BLE examples: LL_ONLY. ST's app_conf.h
// defaults to SHCI_C2_BLE_INIT_OPTIONS_LL_HOST, i.e. CPU2 runs both the
// link layer *and* ST's BLE host (GAP/GATT/SM) and the application drives it
// over ACI. Here BTstack is the host, so CPU2 must expose a plain HCI
// controller and nothing above it — exactly what
// SHCI_C2_BLE_INIT_OPTIONS_LL_ONLY (shci.h:655) selects, and what BTstack's
// own WB55 port passes (CFG_BLE_LL_ONLY = 1, its app_conf.h:131).
// NOTE: this also means the "HCI only"/"LL only" CPU2 firmware binary
// (stm32wb5x_BLE_HCILayer_fw.bin) is the one that must be flashed to CPU2 —
// the full-stack binary would reject it. Not verifiable in this build-only
// pass; called out for hardware bring-up.
#define SMK_BLE_OPTIONS    (SHCI_C2_BLE_INIT_OPTIONS_LL_ONLY               \
                          | SHCI_C2_BLE_INIT_OPTIONS_WITH_SVC_CHANGE_DESC  \
                          | SHCI_C2_BLE_INIT_OPTIONS_DEVICE_NAME_RW        \
                          | SHCI_C2_BLE_INIT_OPTIONS_NO_EXT_ADV            \
                          | SHCI_C2_BLE_INIT_OPTIONS_NO_CS_ALGO2           \
                          | SHCI_C2_BLE_INIT_OPTIONS_FULL_GATTDB_NVM       \
                          | SHCI_C2_BLE_INIT_OPTIONS_GATT_CACHING_NOTUSED  \
                          | SHCI_C2_BLE_INIT_OPTIONS_POWER_CLASS_2_3)
#define SMK_BLE_OPTIONS_EXT  0

// ===========================================================================
// Mailbox buffers (SRAM2A)
// ===========================================================================
// CPU2 can only address SRAM2A/SRAM2B, so every buffer whose address is
// handed to the mailbox has to live there. PLACE_IN_SECTION's expansion is
// __attribute__((section(name))) with the name used verbatim, no leading dot
// (stm32_wpan_common.h:138) — the linker script's MB_MEM1/MB_MEM2 output
// sections (ports/stm32wb/linker/STM32WB55RGVx_FLASH.ld:192-208) match those
// exact names and place them in MAILBOX_RAM at 0x20030000.
//
// Sizes and section assignment are copied from BTstack's WB55 port
// (port/btstack_port.c:200-209), which in turn matches ST's own
// app_conf.h/app_entry.c pairing. Queue length and payload size are ST's
// defaults (CFG_TLBLE_EVT_QUEUE_LENGTH 5, CFG_TLBLE_MOST_EVENT_PAYLOAD_SIZE
// 255 — app_conf.h:409/419).
#define SMK_TLBLE_EVT_QUEUE_LENGTH        5
#define SMK_TLBLE_MOST_EVENT_PAYLOAD_SIZE 255
#define SMK_TL_BLE_EVENT_FRAME_SIZE       (TL_EVT_HDR_SIZE + SMK_TLBLE_MOST_EVENT_PAYLOAD_SIZE)
#define SMK_EVT_POOL_SIZE                                            \
    (SMK_TLBLE_EVT_QUEUE_LENGTH * 4 *                                \
     DIVC((sizeof(TL_PacketHeader_t) + SMK_TL_BLE_EVENT_FRAME_SIZE), 4))

PLACE_IN_SECTION("MB_MEM1") ALIGN(4) static TL_CmdPacket_t BleCmdBuffer;
PLACE_IN_SECTION("MB_MEM2") ALIGN(4) static uint8_t        EvtPool[SMK_EVT_POOL_SIZE];
PLACE_IN_SECTION("MB_MEM2") ALIGN(4) static TL_CmdPacket_t SystemCmdBuffer;
PLACE_IN_SECTION("MB_MEM2") ALIGN(4) static uint8_t        SystemSpareEvtBuffer[sizeof(TL_PacketHeader_t) + TL_EVT_HDR_SIZE + 255];
PLACE_IN_SECTION("MB_MEM2") ALIGN(4) static uint8_t        BleSpareEvtBuffer[sizeof(TL_PacketHeader_t) + TL_EVT_HDR_SIZE + 255];
PLACE_IN_SECTION("MB_MEM2") ALIGN(4) static uint8_t        HciAclDataBuffer[sizeof(TL_PacketHeader_t) + 5 + 251];

// ===========================================================================
// BTstack HAL (hal_time_ms.h / hal_cpu.h)
// ===========================================================================
// btstack_config.h sets HAVE_EMBEDDED_TIME_MS, so btstack_run_loop_embedded.c
// calls hal_time_ms() for "now" and for every timer deadline.
//
// Unlike ports/nrf52840/platform/ble_hid_sdc.c (which has no usable timer at
// all yet and fakes this with a per-call counter), this port CAN provide a
// real millisecond clock cheaply: SYSCLK is already fully configured by
// ports/stm32wb/ClockInit.swift (HSE 32MHz direct, no PLL) before
// app_main_swift() runs, so a plain Cortex-M SysTick at SYSCLK/1000 is a
// genuine 1ms tick. SystemCoreClockUpdate() (cmsis-device-wb's
// Source/Templates/system_stm32wbxx.c) recomputes SystemCoreClock from the
// live RCC registers, so this does not hardcode an assumption about what
// ClockInit.swift chose.
//
// This matters more than it might look: BTstack's HCI init state machine
// uses real timeouts (btstack_config.h's HCI_RESET_RESEND_TIMEOUT_MS), and a
// fake counter makes those elapse in "N loop iterations" instead of "N ms".
static volatile uint32_t s_systick_ms = 0;

void SysTick_Handler(void) {
    s_systick_ms++;
}

uint32_t hal_time_ms(void) {
    return s_systick_ms;
}

void hal_cpu_disable_irqs(void) {
    __disable_irq();
}

void hal_cpu_enable_irqs(void) {
    __enable_irq();
}

void hal_cpu_enable_irqs_and_sleep(void) {
    // Deliberately no WFE/WFI, same call as ble_hid_sdc.c made: this
    // project's main loop is cooperative busy-polling throughout
    // (platform_glue.c's vTaskDelay is a nop-loop, not a real sleep), and
    // with no hardware in hand there is nothing to confirm a real sleep
    // wakes back up correctly. Costs power, cannot hang.
    __enable_irq();
}

// ===========================================================================
// Step 1: clocks CPU2 needs, then the CPU2 boot sequence
// ===========================================================================

// The radio's low-speed/wakeup clock. ClockInit.swift (Task 2) brings up
// HSE/HSI48/CRS but deliberately never touches the backup domain — nothing
// before this task needed LSE. CPU2's link layer does: SMK_BLE_LS_SOURCE
// above tells it CLK_LSE, and RCC_CSR's RFWKPSEL field selects which clock
// actually feeds the RF wakeup logic. Mirrors ST's own SystemClock_Config
// for this board (BLE_HeartRate/Core/Src/main.c:169 __HAL_RCC_LSEDRIVE_CONFIG
// (RCC_LSEDRIVE_LOW), :179 RCC_OSCILLATORTYPE_LSE, :220
// PeriphClkInitStruct.RFWakeUpClockSelection = RCC_RFWKPCLKSOURCE_LSE).
// Register/bit names come from cmsis-device-wb's Include/stm32wb55xx.h
// (RCC_TypeDef BDCR at 0x90 / CSR at 0x94, RCC_CSR_RFWKPSEL_0 == 0x4000 ==
// "LSE selected").
//
// NUCLEO-WB55RG (MB1355) is fitted with a 32.768kHz LSE crystal (X3), so
// this is expected to succeed on real hardware; like the rest of
// ClockInit.swift this is a fail-stop busy-wait with no timeout.
static void enable_lse_and_rf_wakeup_clock(void) {
    // RTCAPB clock gates access to the backup-domain registers (BDCR).
    RCC->APB1ENR1 |= RCC_APB1ENR1_RTCAPBEN;
    (void)RCC->APB1ENR1;

    // Backup-domain writes are protected out of reset.
    PWR->CR1 |= PWR_CR1_DBP;
    while ((PWR->CR1 & PWR_CR1_DBP) == 0U) { }

    if ((RCC->BDCR & RCC_BDCR_LSERDY) == 0U) {
        RCC->BDCR &= ~RCC_BDCR_LSEDRV;            // RCC_LSEDRIVE_LOW, ST's choice for this board
        RCC->BDCR |= RCC_BDCR_LSEON;
        while ((RCC->BDCR & RCC_BDCR_LSERDY) == 0U) { }
    }

    // RFWKPSEL[1:0] = 01 -> LSE.
    RCC->CSR = (RCC->CSR & ~RCC_CSR_RFWKPSEL) | RCC_CSR_RFWKPSEL_0;
}

// BTstack's WB55 port calls this "ipcc_reset" (btstack_port.c:260-294) and
// runs it before TL_Init(). On a cold boot the IPCC is already at its reset
// values, but CPU1 can be reset independently of CPU2 (a debugger attach, a
// CPU1-only software reset) and then the leftover channel flags would make
// TL_Init()/TL_Enable() see phantom traffic. Reproduced here with direct
// register writes rather than ST's LL driver, which this build does not link
// — semantics per stm32wbxx_ll_ipcc.h: C1SCR/C2SCR bits 0-5 are
// write-1-to-clear receive flags, C1MR/C2MR bits 0-5 mask receive and bits
// 16-21 mask transmit (a *set* mask bit disables). This is the same register
// model ports/stm32wb/HwIpcc.swift documents in detail.
#define SMK_IPCC_ALL_CHANNELS 0x3FU  /* LL_IPCC_CHANNEL_1..6 == (1<<0)..(1<<5) */

static void ipcc_reset(void) {
    RCC->AHB3ENR |= RCC_AHB3ENR_IPCCEN;
    (void)RCC->AHB3ENR;

    IPCC->C1SCR = SMK_IPCC_ALL_CHANNELS;                 // clear CPU1's receive flags
    IPCC->C2SCR = SMK_IPCC_ALL_CHANNELS;                 // clear CPU2's receive flags
    IPCC->C1MR  = (SMK_IPCC_ALL_CHANNELS << 16) | SMK_IPCC_ALL_CHANNELS; // mask everything off
    IPCC->C2MR  = (SMK_IPCC_ALL_CHANNELS << 16) | SMK_IPCC_ALL_CHANNELS;
}

typedef enum {
    CPU2_STATE_RESET,
    CPU2_STATE_WAIT_FOR_STARTED,
    CPU2_STATE_W2_INIT_BLE,
    CPU2_STATE_READY,
} cpu2_state_t;

static volatile cpu2_state_t cpu2_state = CPU2_STATE_RESET;

// Sends SHCI_OPCODE_C2_BLE_INIT, i.e. "start the BLE stack on CPU2 with this
// configuration". shci.h:1192 declares
//   SHCI_CmdStatus_t SHCI_C2_BLE_Init(SHCI_C2_Ble_Init_Cmd_Packet_t *pCmdPacket);
// and shci.c implements it on top of shci_tl.c's shci_send(), which blocks in
// shci_cmd_resp_wait() until CPU2's command response comes back (see the
// "command response wait" note further down).
//
// Field order below follows the vendored shci.h:382-643
// SHCI_C2_Ble_Init_Cmd_Param_t declaration, cross-checked one-for-one
// against ST's own initializer at
// BLE_HeartRate/STM32_WPAN/App/app_ble.c:264-297. The struct's last two
// fields (extra_data_buffer/extra_data_buffer_size) are zeroed; ST's own
// initializer omits them entirely and relies on partial-initializer
// zero-filling, but spelling them out silences -Wmissing-field-initializers
// and, more usefully, makes a future CubeWB that grows the struct again fail
// loudly here instead of silently.
static void ble_init_and_start(void) {
    SHCI_C2_Ble_Init_Cmd_Packet_t ble_init_cmd_packet = {
        { { 0, 0, 0 } },                    /* Header — unused, filled in by shci.c */
        {
            0,                              /* pBleBufferAddress: NOT USED, shall be 0 */
            0,                              /* BleBufferSize:     NOT USED, shall be 0 */
            SMK_BLE_NUM_GATT_ATTRIBUTES,
            SMK_BLE_NUM_GATT_SERVICES,
            SMK_BLE_ATT_VALUE_ARRAY_SIZE,
            SMK_BLE_NUM_LINK,
            SMK_BLE_DATA_LENGTH_EXTENSION,
            SMK_BLE_PREPARE_WRITE_LIST_SIZE,
            SMK_BLE_MBLOCK_COUNT,
            SMK_BLE_MAX_ATT_MTU,
            SMK_BLE_PERIPHERAL_SCA,
            SMK_BLE_CENTRAL_SCA,
            SMK_BLE_LS_SOURCE,
            SMK_BLE_MAX_CONN_EVENT_LENGTH,
            SMK_BLE_HSE_STARTUP_TIME,
            SMK_BLE_VITERBI_MODE,
            SMK_BLE_OPTIONS,
            0,                              /* HwVersion — filled in by CPU2 */
            SMK_BLE_MAX_COC_INITIATOR_NBR,
            SMK_BLE_MIN_TX_POWER,
            SMK_BLE_MAX_TX_POWER,
            SHCI_C2_BLE_INIT_RX_MODEL_AGC_RSSI_LEGACY,
            SMK_BLE_MAX_ADV_SET_NBR,
            SMK_BLE_MAX_ADV_DATA_LEN,
            SMK_BLE_TX_PATH_COMPENS,
            SMK_BLE_RX_PATH_COMPENS,
            SHCI_C2_BLE_INIT_BLE_CORE_5_4,
            SMK_BLE_OPTIONS_EXT,
            SMK_BLE_MAX_ADD_EATT_BEARERS,
            NULL,                           /* extra_data_buffer: only needed by host
                                               commands this LL_ONLY build never issues */
            0,                              /* extra_data_buffer_size */
        }
    };

    (void)SHCI_C2_BLE_Init(&ble_init_cmd_packet);
}

// ===========================================================================
// Step 2: hci_transport_t bridge
// ===========================================================================

static void (*transport_packet_handler)(uint8_t packet_type, uint8_t *packet, uint16_t size);
static btstack_data_source_t transport_data_source;
// volatile: set from IPCC TX interrupt context (ble_acl_acknowledged), read
// from the run loop (transport_can_send_packet_now).
static volatile int hci_acl_can_send_now;

// Received-but-not-yet-delivered HCI event/ACL packets. BTstack's WB55 port
// uses a FreeRTOS queue here; this project has no RTOS, so the packets are
// chained through their own TL_PacketHeader_t (next/prev — tl.h:65-69, the
// first member of every TL_EvtPacket_t) using ST's stm_list.c. Every LST_*
// entry point brackets its body with __disable_irq()/__set_PRIMASK
// (stm_list.c:56-113), which is exactly the IRQ-vs-main-loop mutual
// exclusion needed here — ST's own hci_tl.c uses these lists for the same
// purpose from the same two contexts.
static tListNode hci_evt_queue;

// --- callbacks handed to the vendored transport layer ---

// TL_SYS_InitConf_t.IoBusCallBackUserEvt path: shci_tl.c's TlUserEvtReceived
// queues the packet and calls shci_notify_asynch_evt(); shci_user_evt_proc()
// then dequeues it and calls the UserEvtRx callback registered by
// shci_init(). The argument is a `tSHCI_UserEvtRxParam *` (shci_tl.c:102-104,
// shci_tl.h:70-74), NOT a bare packet — writing back .status is how the
// application can ask for the event to be re-queued; leaving it at
// SHCI_TL_UserEventFlow_Enable (as set by shci_user_evt_proc before the call)
// means "done, release the buffer".
static void sys_evt_received(void *pdata) {
    if (pdata == NULL) return;

    tSHCI_UserEvtRxParam *user_event = (tSHCI_UserEvtRxParam *)pdata;
    TL_EvtPacket_t *evt_packet = user_event->pckt;
    if (evt_packet == NULL) return;

    TL_EvtSerial_t *shci_evt = &evt_packet->evtserial;

    // shci.h:57 SHCI_EVTCODE == 0xFF (vendor-specific event code); the
    // sub-event code is the first 16-bit LE field of the payload, and
    // SHCI_SUB_EVT_CODE_READY (shci.h:65) is CPU2's "wireless firmware is
    // up" announcement. This is the real wait mechanism the brief asked to
    // be traced rather than guessed: there is no polling API — CPU2 pushes
    // this asynchronous system event up the system channel after
    // TL_Enable() releases it from reset.
    if (shci_evt->evt.evtcode == SHCI_EVTCODE) {
        if (little_endian_read_16(shci_evt->evt.payload, 0) == SHCI_SUB_EVT_CODE_READY) {
            if (cpu2_state == CPU2_STATE_WAIT_FOR_STARTED) {
                cpu2_state = CPU2_STATE_W2_INIT_BLE;
                btstack_run_loop_poll_data_sources_from_irq();
            }
        }
    }
}

// TL_BLE_InitConf_t.IoBusEvtCallBack — called from tl_mbox.c in IPCC RX
// interrupt context with a complete HCI event (or ACL packet) sitting in a
// mailbox buffer that stays ours until TL_MM_EvtDone() releases it.
static void ble_evt_received(TL_EvtPacket_t *hcievt) {
    LST_insert_tail(&hci_evt_queue, (tListNode *)hcievt);
    btstack_run_loop_poll_data_sources_from_irq();
}

// TL_BLE_InitConf_t.IoBusAclDataTxAck — CPU2 has consumed the ACL buffer.
static void ble_acl_acknowledged(void) {
    hci_acl_can_send_now = 1;
    btstack_run_loop_poll_data_sources_from_irq();
}

// --- main-context delivery -------------------------------------------------

static void transport_send_hardware_error(uint8_t error_code) {
    uint8_t event[] = { HCI_EVENT_HARDWARE_ERROR, 1, error_code };
    transport_packet_handler(HCI_EVENT_PACKET, &event[0], sizeof(event));
}

static void transport_notify_packet_send(void) {
    uint8_t event[] = { HCI_EVENT_TRANSPORT_PACKET_SENT, 0 };
    transport_packet_handler(HCI_EVENT_PACKET, &event[0], sizeof(event));
}

static void transport_notify_ready(void) {
    uint8_t event[] = { HCI_EVENT_TRANSPORT_READY, 0 };
    transport_packet_handler(HCI_EVENT_PACKET, &event[0], sizeof(event));
}

static void transport_deliver_hci_packets(void) {
    while (LST_is_empty(&hci_evt_queue) == FALSE) {
        TL_EvtPacket_t *hcievt;
        LST_remove_head(&hci_evt_queue, (tListNode **)&hcievt);

        switch (hcievt->evtserial.type) {
            case HCI_EVENT_PACKET:  // == TL_BLEEVT_PKT_TYPE (0x04)
                // evtserial.evt is {evtcode, plen, payload...}; BTstack wants
                // the event starting at evtcode, length = plen + 2 header bytes.
                transport_packet_handler(hcievt->evtserial.type,
                                         (uint8_t *)&hcievt->evtserial.evt,
                                         hcievt->evtserial.evt.plen + 2);
                break;

            case HCI_ACL_DATA_PACKET: {  // == TL_ACL_DATA_PKT_TYPE (0x02)
                TL_AclDataSerial_t *acl = &(((TL_AclDataPacket_t *)hcievt)->AclDataSerial);
                // Skip the 1-byte packet-type prefix; length = 4-byte ACL
                // header (handle + length) + payload.
                transport_packet_handler(acl->type, &((uint8_t *)acl)[1], acl->length + 4);
                break;
            }

            default:
                transport_send_hardware_error(0x01);
                break;
        }

        TL_MM_EvtDone(hcievt);  // hand the mailbox buffer back to CPU2's memory manager
    }
}

static void transport_process(btstack_data_source_t *ds, btstack_data_source_callback_type_t callback_type) {
    (void)ds;
    if (callback_type != DATA_SOURCE_CALLBACK_POLL) return;

    // Drains the system channel; may re-enter sys_evt_received() above.
    shci_user_evt_proc();

    if (cpu2_state == CPU2_STATE_W2_INIT_BLE) {
        cpu2_state = CPU2_STATE_READY;
        ble_init_and_start();
        transport_notify_ready();
    }

    transport_deliver_hci_packets();
}

// --- hci_transport_t -------------------------------------------------------
// Called by BTstack's hci.c when hci_power_control(HCI_POWER_ON) transitions
// the stack to INITIALIZING. Everything CPU2-related happens here, so CPU2
// is not released from reset until BTstack is actually ready to talk to it.
static void transport_init(const void *transport_config) {
    (void)transport_config;

    btstack_run_loop_set_data_source_handler(&transport_data_source, &transport_process);
    btstack_run_loop_enable_data_source_callbacks(&transport_data_source, DATA_SOURCE_CALLBACK_POLL);
    btstack_run_loop_add_data_source(&transport_data_source);

    LST_init_head(&hci_evt_queue);
    hci_acl_can_send_now = 1;
    cpu2_state = CPU2_STATE_WAIT_FOR_STARTED;

    ipcc_reset();

    // --- the CPU2 boot sequence proper, in the order tl.h/shci_tl.h document ---

    // 1. TL_Init() (tl.h:286) fills in TL_RefTable — the mailbox reference
    //    table CPU2 finds at the fixed SRAM2A base (IPCCDBA option byte) —
    //    and calls HW_IPCC_Init() (HwIpcc.swift) to clock IPCC and enable
    //    both NVIC lines. CPU2 is still in reset at this point.
    TL_Init();

    // 2. shci_init() (shci_tl.h:167) registers the system channel: our
    //    UserEvtRx callback plus the command buffer CPU2 will write
    //    responses into. Internally shci_register_io_bus() points the io
    //    ops at TL_SYS_Init/TL_SYS_SendCmd (shci_tl_if.c) and TlInit() calls
    //    TL_SYS_Init(), which arms the system receive channel.
    //    StatusNotCallBack is optional (shci_tl.c:200-213 null-checks it).
    {
        SHCI_TL_HciInitConf_t shci_init_config;
        shci_init_config.p_cmdbuffer = (uint8_t *)&SystemCmdBuffer;
        shci_init_config.StatusNotCallBack = NULL;
        shci_init(sys_evt_received, (void *)&shci_init_config);
    }

    // 3. TL_MM_Init() (tl.h:338) publishes the spare-event buffers and the
    //    asynchronous-event pool CPU2 allocates its event packets from.
    //    Must happen before CPU2 starts, or it has nowhere to put events.
    {
        TL_MM_Config_t tl_mm_config;
        tl_mm_config.p_BleSpareEvtBuffer = BleSpareEvtBuffer;
        tl_mm_config.p_SystemSpareEvtBuffer = SystemSpareEvtBuffer;
        tl_mm_config.p_AsynchEvtPool = EvtPool;
        tl_mm_config.AsynchEvtPoolSize = SMK_EVT_POOL_SIZE;
        TL_MM_Init(&tl_mm_config);
    }

    // 4. TL_Enable() (tl.h:285, tl_mbox.c:84-89) is a one-line wrapper around
    //    HW_IPCC_Enable(), which is where CPU2 actually comes out of reset:
    //    HwIpcc.swift's HW_IPCC_Enable() sets PWR_CR4's C2BOOT bit after
    //    arming the EXTI-line-41 wakeup path. This is the
    //    "HAL_PWREx_ReleaseCore-equivalent" the brief asked for — it already
    //    exists in Task 6's code, so there is nothing to duplicate here.
    //    From here on, CPU2 will eventually push SHCI_SUB_EVT_CODE_READY up
    //    the system channel; sys_evt_received() above catches it and
    //    transport_process() then sends SHCI_C2_BLE_Init.
    TL_Enable();

    // 5. BLE channel. Registers the command/ACL buffers and both RX
    //    callbacks, and arms the BLE receive channel (TL_BLE_Init ->
    //    HW_IPCC_BLE_Init). BTstack's WB55 port does this here, before the
    //    ready event, rather than after it (ST's own examples do it after);
    //    TL_BLE_Init only touches CPU1-side state and the IPCC mask, so
    //    either order is safe, and this follows the reference that was
    //    actually validated against BTstack.
    {
        TL_BLE_InitConf_t tl_ble_config;
        tl_ble_config.p_cmdbuffer = (uint8_t *)&BleCmdBuffer;
        tl_ble_config.p_AclDataBuffer = HciAclDataBuffer;
        tl_ble_config.IoBusEvtCallBack = ble_evt_received;
        tl_ble_config.IoBusAclDataTxAck = ble_acl_acknowledged;
        TL_BLE_Init((void *)&tl_ble_config);
    }
}

static int transport_open(void)  { return 0; }
static int transport_close(void) { return 0; }

static void transport_register_packet_handler(void (*handler)(uint8_t packet_type, uint8_t *packet, uint16_t size)) {
    transport_packet_handler = handler;
}

// Unlike ble_hid_sdc.c (whose transport is synchronous and therefore leaves
// this NULL — see its Critical #4 note), this transport really is
// asynchronous and must gate on CPU2 readiness and on ACL buffer ownership,
// so can_send_packet_now is provided AND every send is paired with an
// HCI_EVENT_TRANSPORT_PACKET_SENT via transport_notify_packet_send(). Those
// two go together: hci.c treats a non-NULL can_send_packet_now as "async
// transport, wait for the sent event before reusing the buffer".
static int transport_can_send_packet_now(uint8_t packet_type) {
    if (cpu2_state != CPU2_STATE_READY) return 0;
    switch (packet_type) {
        case HCI_COMMAND_DATA_PACKET: return 1;
        case HCI_ACL_DATA_PACKET:     return hci_acl_can_send_now;
        default:                      return 1;
    }
}

// TL_BLE_SendCmd/TL_BLE_SendAclData (tl.h:292-293) take (buffer, size), but
// tl_mbox.c ignores both arguments entirely: the payload must already be in
// the buffer registered via TL_BLE_InitConf_t, and the call just raises the
// IPCC flag for that channel. Passing (NULL, 0) is the documented usage and
// is what both ST's hci_tl.c (SendCmd: `hciContext.io.Send(0,0)`) and
// BTstack's WB55 port do.
static int transport_send_packet(uint8_t packet_type, uint8_t *packet, int size) {
    switch (packet_type) {
        case HCI_COMMAND_DATA_PACKET:
            // BTstack's HCI command packet is {opcode_lo, opcode_hi, plen,
            // params...} and TL_Cmd_t is {cmdcode:u16, plen:u8,
            // payload[255]} — identical layout, so a single memcpy at &cmd
            // fills cmdcode/plen/payload correctly. (BTstack's own WB55 port
            // additionally assigns cmd.plen = size just before this memcpy;
            // that store is dead, the memcpy overwrites it with the real
            // parameter length one byte in. Dropped rather than copied.)
            BleCmdBuffer.cmdserial.type = packet_type;
            memcpy((void *)&BleCmdBuffer.cmdserial.cmd, packet, size);
            TL_BLE_SendCmd(NULL, 0);
            transport_notify_packet_send();
            break;

        case HCI_ACL_DATA_PACKET:
            hci_acl_can_send_now = 0;
            ((TL_AclDataPacket_t *)HciAclDataBuffer)->AclDataSerial.type = packet_type;
            memcpy((void *)&(((TL_AclDataPacket_t *)HciAclDataBuffer)->AclDataSerial.handle), packet, size);
            TL_BLE_SendAclData(NULL, 0);
            transport_notify_packet_send();
            break;

        default:
            transport_send_hardware_error(0x01);
            return -1;
    }
    return 0;
}

// Field order verified against btstack/src/hci_transport.h.
static const hci_transport_t transport = {
    "stm32wb-ipcc",
    &transport_init,
    &transport_open,
    &transport_close,
    &transport_register_packet_handler,
    &transport_can_send_packet_now,
    &transport_send_packet,
    NULL, // set_baudrate
    NULL, // reset_link
    NULL, // set_sco_config
};

// ===========================================================================
// Command-response wait
// ===========================================================================
// shci_tl.c's shci_send() blocks in shci_cmd_resp_wait() until CPU2 answers,
// and both shci_cmd_resp_wait()/shci_cmd_resp_release() are __WEAK
// (shci_tl.c:236-252) so an application can replace the default spin with an
// RTOS primitive. BTstack's WB55 port replaces both with empty no-ops,
// relying on FreeRTOS scheduling; that is NOT safe here (an empty wait means
// shci_send() memcpy's the response buffer before CPU2 has written it), so
// this file deliberately does NOT override them. ST's default polling
// implementation is the correct one for a bare-metal build: it spins on a
// volatile flag that the IPCC TX interrupt path sets
// (HW_IPCC_Tx_Handler -> HW_IPCC_SYS_CmdEvtNot -> tl_mbox.c's
// TL_SYS_CmdEvtReceived -> shci_tl.c's TlCmdEvtReceived ->
// shci_cmd_resp_release), and interrupts are enabled throughout, so it
// terminates. The only caller is SHCI_C2_BLE_Init() from
// transport_process(), i.e. main context, never an ISR.

// shci_tl.c:127/142/230 call this to say "an SHCI event is queued, please
// call shci_user_evt_proc() soon". Signature from shci_tl.h:108:
// `void shci_notify_asynch_evt(void* pdata)`. transport_process()'s POLL
// callback already calls shci_user_evt_proc() every tick, so all this has
// to do is make sure the run loop gets a chance to run promptly; the
// argument (always &SHciAsynchEventQueue) is not needed.
void shci_notify_asynch_evt(void *pdata) {
    (void)pdata;
    btstack_run_loop_poll_data_sources_from_irq();
}

// ===========================================================================
// Step 3: HID-over-GATT (identical shape to ble_hid_sdc.c's)
// ===========================================================================

static const uint8_t hid_descriptor_keyboard[] = {
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xc0
};

static const uint8_t adv_data[] = {
    0x02, BLUETOOTH_DATA_TYPE_FLAGS, 0x06,
    0x03, BLUETOOTH_DATA_TYPE_APPEARANCE, 0xC1, 0x03,
    0x03, BLUETOOTH_DATA_TYPE_INCOMPLETE_LIST_OF_16_BIT_SERVICE_CLASS_UUIDS, 0x12, 0x18,
    0x0d, BLUETOOTH_DATA_TYPE_COMPLETE_LOCAL_NAME,
        'S','M','K',' ','K','e','y','b','o','a','r','d',
};

static btstack_packet_callback_registration_t hci_event_callback_registration;
static btstack_packet_callback_registration_t sm_event_callback_registration;
static uint8_t battery = 100;
static hci_con_handle_t con_handle = HCI_CON_HANDLE_INVALID;
static uint8_t protocol_mode = 1;

static uint8_t pending_report[8];
static int report_dirty = 0;

static void send_pending(void) {
    if (con_handle == HCI_CON_HANDLE_INVALID) return;
    report_dirty = 0;
    hids_device_send_input_report(con_handle, pending_report, sizeof(pending_report));
}

static void packet_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size) {
    (void)channel; (void)size;
    if (packet_type != HCI_EVENT_PACKET) return;

    switch (hci_event_packet_get_type(packet)) {
        case HCI_EVENT_DISCONNECTION_COMPLETE:
            con_handle = HCI_CON_HANDLE_INVALID;
            break;
        case HCI_EVENT_HIDS_META:
            switch (hci_event_hids_meta_get_subevent_code(packet)) {
                case HIDS_SUBEVENT_INPUT_REPORT_ENABLE:
                    con_handle = hids_subevent_input_report_enable_get_con_handle(packet);
                    break;
                case HIDS_SUBEVENT_PROTOCOL_MODE:
                    protocol_mode = hids_subevent_protocol_mode_get_protocol_mode(packet);
                    break;
                case HIDS_SUBEVENT_CAN_SEND_NOW:
                    if (report_dirty) send_pending();
                    break;
                default:
                    break;
            }
            break;
        default:
            break;
    }
}

void init_ble_hid(void) {
    // Clocks CPU2's radio needs, before anything can release CPU2.
    enable_lse_and_rf_wakeup_clock();

    // Real 1ms time base for BTstack's run loop / HCI timeouts. Placed here
    // rather than in ClockInit.swift because nothing before BLE needed it
    // (the scan loop's pacing is platform_glue.c's calibration-free busy
    // loop).
    SystemCoreClockUpdate();
    SysTick_Config(SystemCoreClock / 1000U);

    // BTstack's memory pools are all NULL until this runs — same Critical #3
    // finding documented in ble_hid_sdc.c.
    btstack_memory_init();

    // Must precede hci_init(): hci.c registers timers and data sources
    // against whatever run loop is installed. Pumped once per scan tick from
    // platform_glue.c's vTaskDelay via smk_ble_poll() below.
    btstack_run_loop_init(btstack_run_loop_embedded_get_instance());

    hci_init(&transport, NULL);

    l2cap_init();
    sm_init();
    sm_set_io_capabilities(IO_CAPABILITY_NO_INPUT_NO_OUTPUT);
    sm_set_authentication_requirements(SM_AUTHREQ_BONDING | SM_AUTHREQ_SECURE_CONNECTION);

    att_server_init(profile_data, NULL, NULL);

    battery_service_server_init(battery);
    device_information_service_server_init();
    hids_device_init(0, hid_descriptor_keyboard, sizeof(hid_descriptor_keyboard));

    uint16_t adv_int_min = 0x0030, adv_int_max = 0x0030;
    bd_addr_t null_addr;
    memset(null_addr, 0, sizeof(null_addr));
    gap_advertisements_set_params(adv_int_min, adv_int_max, 0, 0, null_addr, 0x07, 0x00);
    gap_advertisements_set_data(sizeof(adv_data), (uint8_t *)adv_data);
    gap_advertisements_enable(1);

    hci_event_callback_registration.callback = &packet_handler;
    hci_add_event_handler(&hci_event_callback_registration);
    sm_event_callback_registration.callback = &packet_handler;
    sm_add_event_handler(&sm_event_callback_registration);
    hids_device_register_packet_handler(packet_handler);

    // Triggers transport_init() above (and therefore the CPU2 boot sequence)
    // as hci.c transitions to INITIALIZING.
    hci_power_control(HCI_POWER_ON);
}

void send_keyboard_report(uint8_t modifier, uint8_t *keys) {
    pending_report[0] = modifier;
    pending_report[1] = 0;
    memcpy(&pending_report[2], keys, 6);
    report_dirty = 1;
    if (con_handle != HCI_CON_HANDLE_INVALID) {
        hids_device_request_can_send_now_event(con_handle);
    }
}

// Called every scan tick from platform_glue.c's vTaskDelay. One call drives
// the whole BLE side: the embedded run loop's execute_once() fires due
// timers and then polls registered data sources, which is what invokes
// transport_process() above (shci_user_evt_proc, the CPU2-ready transition
// and SHCI_C2_BLE_Init, and HCI packet delivery into BTstack).
void smk_ble_poll(void) {
    btstack_run_loop_embedded_execute_once();
}
