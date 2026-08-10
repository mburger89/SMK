// BLE HID glue for nrf52840dk — same SMK BLE contract as
// ble_hid_kbd_uart.c's RP2040 smk_kbd_rp2040 branch, but talking to
// Nordic's SoftDevice Controller (running in this same firmware image,
// not a physically separate chip) via the adapted HCI dispatcher in
// sdc_hci_dispatch.c instead of a UART H4 link.
//
// *** STATUS as of this pass: build-only, no hardware verification. The
// transport wiring below (SDC init, hci_transport_t implementation,
// BTstack GATT/HID setup) is real and follows this plan's research
// (docs/superpowers/plans/2026-08-09-nrf52840-support.md, Tasks 5-7), but
// nothing has been exercised on real silicon. ***

#include <stdint.h>
#include <string.h>

#include <sdc.h>
#include <sdc_hci.h>
#include <sdc_soc.h>
#include <mpsl.h>
#include <nrf.h> // NRF_RNG — see sdc_rand_poll() below

#include "btstack.h"           // pulls in btstack_run_loop.h transitively
#include "btstack_run_loop_embedded.h"
#include "hal_time_ms.h"       // hal_time_ms() — implemented below, see that comment
#include "hal_cpu.h"           // hal_cpu_disable_irqs/enable_irqs/enable_irqs_and_sleep — implemented below
#include "hci_transport.h"
#include "ble/gatt-service/hids_device.h"
#include "ble/gatt-service/battery_service_server.h"
#include "ble/gatt-service/device_information_service_server.h"
#include "smk_hid.h" // generated from smk_hid.gatt, same as the RP2040 BLE build

#include "sdc_hci_dispatch.h"

// --- SDC resource buffer -----------------------------------------------
// Peripheral-role-only, single connection (MAX_NR_HCI_CONNECTIONS in
// btstack_config.h) — matches this project's needs, no Central role.
//
// The plan's original draft assumed a compile-time sizing macro
// (`SDC_MEM_PERIPHERAL_COUNT(n)`) analogous to sdc.h's other
// `SDC_MEM_PER_*`/`SDC_MEM_*_SHARED` helpers. Verified against the real
// vendored header (~/sdk-nrfxlib/softdevice_controller/include/sdc.h) while
// implementing this file: no such macro exists in this SDC release. The
// header's actual documented pattern (see sdc_cfg_set()'s doc comment) is
// to query the required size at *runtime*: call
// `sdc_cfg_set(tag, SDC_CFG_TYPE_NONE, NULL)` after configuring the desired
// role support, which returns the byte count needed for the memory pool
// sdc_enable() then consumes. Since this build has no heap-backed
// allocator wired up this early in boot, the buffer below is a static
// array sized generously for a single-peripheral/no-central/default-adv
// configuration, and init_ble_hid() below verifies at startup (via the
// same sdc_cfg_set() query) that the real requirement actually fits,
// halting via sdc_fault_handler() if it doesn't rather than silently
// overrunning the buffer.
#define SDC_MEM_BUFFER_SIZE 3600
static uint8_t sdc_mem_buffer[SDC_MEM_BUFFER_SIZE] __attribute__((aligned(8)));

static void sdc_fault_handler(const char *file, uint32_t line) {
    (void)file; (void)line;
    while (1) { }
}

// --- Entropy source -----------------------------------------------------
// sdc_enable()'s doc comment (sdc.h) states it returns -NRF_EPERM ("The
// entropy source is not configured") unless sdc_rand_source_register() has
// been called first — a real functional gap the plan's original draft
// didn't account for (only sdc_init/sdc_enable/sdc_support_* were listed).
// Without this, init_ble_hid() below would halt forever on the sdc_enable()
// error check the first time it runs, on real hardware or not. Backed by
// the nRF52840's onboard hardware RNG peripheral (product spec: TASKS_START
// starts sampling, EVENTS_VALRDY pulses once per byte, VALUE holds the
// latest byte; CONFIG.DERCEN enables the peripheral's own digital bias
// correction — worth having on since this randomness feeds LE Secure
// Connections pairing, not just non-cryptographic use). Blocking/polling
// implementation matches this file's other synchronous, no-RTOS style.
static void sdc_rand_poll(uint8_t *p_buff, uint8_t length) {
    NRF_RNG->CONFIG = (RNG_CONFIG_DERCEN_Enabled << RNG_CONFIG_DERCEN_Pos);
    NRF_RNG->TASKS_START = 1;
    for (uint8_t i = 0; i < length; i++) {
        NRF_RNG->EVENTS_VALRDY = 0;
        while (NRF_RNG->EVENTS_VALRDY == 0) { }
        p_buff[i] = (uint8_t)NRF_RNG->VALUE;
    }
    NRF_RNG->TASKS_STOP = 1;
}

static const sdc_rand_source_t sdc_rand_source = {
    .rand_poll = sdc_rand_poll,
};

// --- BTstack run loop HAL (Critical #2 review finding) -------------------
// hci.c registers timers/data-source callbacks against whatever
// btstack_run_loop_init() configured (see RP2040's
// ble_hid_kbd_uart.c:313-320 for the same requirement on that port,
// pico-sdk's async_context-based run loop there). This port had no run
// loop wired up at all in the first pass: btstack_run_loop_set_timer()
// dereferences a NULL `the_run_loop` (btstack_assert is a silent no-op
// here — HAVE_ASSERT/ENABLE_BTSTACK_ASSERT aren't defined in
// btstack_config.h — so the guard compiles out and this HardFaults),
// and even if it didn't, nothing pumped the run loop's timers/callbacks
// afterward. Fixed by using BTstack's own generic "embedded" run loop
// (platform/embedded/btstack_run_loop_embedded.c, added to
// ports/nrf52840/CMakeLists.txt), driven from btstack_run_loop_embedded_
// execute_once() in platform_glue.c's vTaskDelay — same cooperative-poll
// pattern as sdc_transport_poll()/mpsl_glue_poll()/kb_usb_task().
//
// That run loop implementation needs two small hardware abstraction
// layers the application is expected to provide (hal_time_ms.h/hal_cpu.h
// are declarations-only headers in btstack/platform/embedded — every
// embedded btstack port implements these itself):
//
//   hal_time_ms(): btstack_config.h sets HAVE_EMBEDDED_TIME_MS (not
//   HAVE_EMBEDDED_TICK), so btstack_run_loop_embedded.c calls this
//   directly for "now" and for computing timer deadlines. This port has
//   no calibrated hardware millisecond timer wired up yet (same
//   unresolved state as platform_glue.c's vTaskDelay busy-loop, and
//   UsbHid.swift's tusb_time_millis_api() — see that function's own
//   comment for the identical caveat) — Task 5's MPSL/RTC init claims
//   the relevant peripheral but nothing reads a real elapsed-time value
//   from it yet. Implemented the same way as tusb_time_millis_api(): a
//   monotonic per-call counter, NOT a real millisecond clock. This is
//   sufficient for btstack_run_loop_embedded.c's own correctness
//   requirement (monotonically increasing, used only for ordering timer
//   deadlines) but means BTstack's timeouts elapse in "N calls" rather
//   than "N milliseconds" until a real RTC-backed clock replaces this —
//   a known, deliberate limitation of this build-only pass, not a bug to
//   silently "fix" by guessing a scale factor.
//
//   hal_cpu_disable_irqs/enable_irqs: real, correct CMSIS Cortex-M4
//   primitives (__disable_irq()/__enable_irq(), reachable via the
//   <nrf.h> include above -> nrf52840.h -> core_cm4.h -> cmsis_gcc.h) —
//   these matter for real (protecting btstack_run_loop_embedded.c's
//   internal trigger_event_received flag against races with an ISR),
//   unlike hal_time_ms() above.
//
//   hal_cpu_enable_irqs_and_sleep: deliberately does NOT call __WFE()/
//   __WFI() to actually sleep, unlike a typical embedded btstack port.
//   This project has no guaranteed periodic interrupt source configured
//   yet to wake such a sleep (no RTOS tick, no confirmed-firing RTC
//   tick independent of MPSL's own scheduling) — using a real WFE here
//   risked trading today's proven hang (Critical #2 itself) for a new,
//   harder-to-diagnose one if no interrupt happens to be pending when
//   this runs. Just re-enabling IRQs and returning immediately is
//   functionally safe (this project's entire main loop is cooperative
//   busy-polling already — see vTaskDelay's own busy-loop, not a real
//   sleep, for the same reason) at the cost of not actually saving
//   power — acceptable for a build-only pass with no hardware in hand to
//   confirm a real low-power sleep wakes up correctly.
static uint32_t s_hal_time_ms_counter = 0;

uint32_t hal_time_ms(void) {
    s_hal_time_ms_counter++;
    return s_hal_time_ms_counter;
}

void hal_cpu_disable_irqs(void) {
    __disable_irq();
}

void hal_cpu_enable_irqs(void) {
    __enable_irq();
}

void hal_cpu_enable_irqs_and_sleep(void) {
    __enable_irq(); // see header comment above: no real WFE/WFI sleep yet
}

// hci_transport_t implementation — feeds BTstack's HCI host through the
// Task 6 dispatcher into SDC, instead of a UART H4 byte stream. Exact
// struct field list verified against btstack/src/hci_transport.h while
// implementing this file (name/init/open/close/register_packet_handler/
// can_send_packet_now/send_packet/set_baudrate/reset_link/
// set_sco_config) — only the fields this project actually uses are
// implemented; the rest are UART/USB-extension fields BTstack calls
// conditionally and are safe to leave NULL.
static void (*s_packet_handler)(uint8_t packet_type, uint8_t *packet, uint16_t size) = NULL;

static void sdc_transport_init(const void *transport_config) { (void)transport_config; }
static int sdc_transport_open(void) { return 0; }
static int sdc_transport_close(void) { return 0; }

static void sdc_transport_register_packet_handler(void (*handler)(uint8_t packet_type, uint8_t *packet, uint16_t size)) {
    s_packet_handler = handler;
}

static int sdc_transport_send_packet(uint8_t packet_type, uint8_t *packet, int size) {
    (void)size;
    int32_t err;
    switch (packet_type) {
        case HCI_COMMAND_DATA_PACKET:
            err = hci_internal_cmd_put(packet);
            break;
        case HCI_ACL_DATA_PACKET:
            err = sdc_hci_data_put(packet);
            break;
        default:
            return -1;
    }
    return (err == 0) ? 0 : -1;
}

// can_send_packet_now is deliberately NULL — Critical #4 review finding.
// BTstack decides sync-vs-async transport behavior purely by whether this
// field is NULL (hci.c: "assumption: synchronous implementations don't
// provide can_send_packet_now as they don't keep the buffer after the
// call" — hci_transport_synchronous() at hci.c ~line 885). The first pass
// supplied a non-NULL implementation that unconditionally returned 1,
// which told BTstack this transport is *asynchronous* — meaning BTstack
// would wait for an HCI_EVENT_TRANSPORT_PACKET_SENT event (delivered via
// the registered packet handler, the pattern hci_transport_h4.c uses)
// before releasing its packet buffer and moving on. This transport never
// sent that event, so hci_stack->hci_packet_buffer_reserved latches true
// after the very first packet and nothing after it can be sent — exactly
// one HID report would ever go out. sdc_transport_send_packet() below
// really is synchronous from this call site (hci_internal_cmd_put()/
// sdc_hci_data_put() both return before this function returns), so NULL
// here is not just the simpler fix, it's the correct one — no
// HCI_EVENT_TRANSPORT_PACKET_SENT synthesis needed.
static const hci_transport_t sdc_transport = {
    .name = "sdc",
    .init = &sdc_transport_init,
    .open = &sdc_transport_open,
    .close = &sdc_transport_close,
    .register_packet_handler = &sdc_transport_register_packet_handler,
    .can_send_packet_now = NULL,
    .send_packet = &sdc_transport_send_packet,
    .set_baudrate = NULL,
    .reset_link = NULL,
    .set_sco_config = NULL,
};

// Drains any pending event/data from SDC and forwards it to BTstack — the
// "read" half of this transport (send_packet above is the "write" half).
// Called every scan tick from platform_glue.c's vTaskDelay, same
// cooperative-polling style as mpsl_glue_poll()/kb_usb_task().
//
// Critical #1 review finding, fixed here: this used to call sdc_hci_get()
// (sdc_hci.h) directly. That's wrong. hci_internal_cmd_put() (Task 6's
// dispatcher, called from sdc_transport_send_packet() above) doesn't just
// forward raw HCI commands to SDC — for most opcodes it decodes the
// command, calls the matching sdc_hci_cmd_*() API itself, then
// *synthesizes* a Command Complete/Status event into its own static
// buffer and latches cmd_complete_or_status.occurred = true (see
// sdc_hci_dispatch.c's hci_internal_cmd_put(), ~line 1975-1990). That
// synthesized event is only ever delivered by hci_internal_msg_get()
// (sdc_hci_dispatch.c ~line 2026), which drains the latch (clearing
// occurred back to false) before falling through to a raw sdc_hci_get()
// call for anything else pending. Bare sdc_hci_get() knows nothing about
// this latch: it would return -NRF_EAGAIN forever for every command
// response (BTstack's init state machine stalls waiting for a Command
// Complete that never arrives via this path), and worse,
// cmd_complete_or_status.occurred never gets cleared, so
// hci_internal_cmd_put() then returns -NRF_EPERM on every subsequent
// command — permanently wedged after the very first one
// (hci_power_control(HCI_POWER_ON) sends HCI Reset first, so this fired
// immediately). Fixed by calling hci_internal_msg_get() instead, matching
// the signature Task 6 actually declared in sdc_hci_dispatch.h.
//
// Important #5 review finding: the review raised a concern that this
// build doesn't pass -fshort-enums, so sdc_hci_msg_type_t might compile
// to a 4-byte enum while hci_internal_msg_get()/sdc_hci_get() only write
// 1 byte into *msg_type_out (the real vendored sdc_hci_get() takes a
// plain `uint8_t *`, not an enum pointer at all — the enum typing only
// exists at hci_internal_msg_get()'s wrapper level, which casts to
// uint8_t* before calling in) — leaving 3 uninitialized garbage bytes
// that could make the switch below take an unpredictable branch.
// Checked empirically rather than trusting either claim: compiled a
// `sizeof(sdc_hci_msg_type_t)` probe with this exact toolchain/flags
// (arm-none-eabi-gcc 14.3.1, no -fshort-enums passed) and it's 1 byte,
// not 4 — the "Arm GNU Toolchain" distribution (as opposed to older
// Linaro/CodeSourcery builds) defaults bare-metal arm-none-eabi targets
// to short/variable-size enums already, matching what Nordic's prebuilt
// library was built expecting. So this specific field was never actually
// at risk of the garbage-bytes bug in this build. The
// "-fshort-enums ... output is to use 32-bit enums" linker warnings seen
// throughout this build are real (a Tag_ABI_enum_size mismatch exists
// somewhere in the link — most likely between this project's objects and
// one or more prebuilt archives) but don't appear to be this bug; not
// investigated further here as it's outside this fix round's scope.
// Kept the zero-initialization below anyway: it's free, and it's cheap
// insurance against this toolchain's enum-sizing default ever changing
// (a compiler upgrade, or someone adding -fshort-enums=0 later) turning
// a currently-theoretical risk into a real one.
void sdc_transport_poll(void) {
    static uint8_t msg_buf[HCI_MSG_BUFFER_MAX_SIZE];
    sdc_hci_msg_type_t msg_type = SDC_HCI_MSG_TYPE_NONE; // see enum-width comment above — must be zero-initialized
    while (hci_internal_msg_get(msg_buf, &msg_type) == 0) {
        if (!s_packet_handler) continue;
        switch (msg_type) {
            case SDC_HCI_MSG_TYPE_EVT:
                s_packet_handler(HCI_EVENT_PACKET, msg_buf, msg_buf[1] + 2); // BT_HCI_EVT_HDR_SIZE + param length
                break;
            case SDC_HCI_MSG_TYPE_DATA:
                s_packet_handler(HCI_ACL_DATA_PACKET, msg_buf, (msg_buf[2] | (msg_buf[3] << 8)) + 4); // HCI_DATA_HEADER_SIZE
                break;
            default:
                break;
        }
    }
}

// --- HID-over-GATT (identical shape to ble_hid_kbd_uart.c's) -----------

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
    // Critical #3 review finding: BTstack's memory pools (btstack_memory.c)
    // stay NULL forever unless this is called — e.g.
    // btstack_memory_hci_connection_get() would return NULL and no BLE
    // connection could ever be tracked. RP2040 gets this for free because
    // pico-sdk's own btstack integration calls it internally; this
    // from-scratch transport has no such wrapper, so it must be called
    // explicitly, first, before anything else below touches BTstack.
    btstack_memory_init();

    // Critical #2 review finding: hci.c registers timers/data sources
    // against whatever run loop btstack_run_loop_init() configured — must
    // happen before hci_init() below (see hci_power_control()'s later call
    // into btstack_run_loop_set_timer(), which dereferences a NULL
    // `the_run_loop` otherwise). See the hal_time_ms()/hal_cpu_* comment
    // above for the HAL this run loop needs and why each is implemented
    // the way it is. btstack_run_loop_embedded_execute_once() (which
    // actually pumps this run loop's timers/callbacks) is called every
    // tick from platform_glue.c's vTaskDelay, alongside sdc_transport_poll().
    btstack_run_loop_init(btstack_run_loop_embedded_get_instance());

    int32_t err = sdc_init(sdc_fault_handler);
    if (err != 0) { while (1) { } }

    // Legacy (non-extended) advertising only — matches gap_advertisements_
    // set_params()/set_data() below, BTstack's legacy GAP advertising API,
    // not its separate extended-advertising API. sdc.h's own doc comment
    // says to call *either* sdc_support_adv() *or* sdc_support_ext_adv(),
    // never both — and verified against the real prebuilt libs while
    // implementing this file: libsoftdevice_controller_peripheral.a (the
    // single-role, peripheral-only variant this target links, matching
    // this file's "no Central role" design) doesn't even export
    // sdc_support_ext_adv() — only libsoftdevice_controller_multirole.a
    // does. The plan's original draft called both; that would have been
    // both redundant and a link failure on this library variant.
    sdc_support_adv();
    sdc_support_peripheral();

    err = sdc_rand_source_register(&sdc_rand_source);
    if (err != 0) { while (1) { } }

    // Query the real memory requirement for the role/feature configuration
    // just set up above (see the sdc_mem_buffer comment for why this can't
    // be a compile-time macro) and fault rather than silently overrun the
    // static buffer if it doesn't fit.
    int32_t required_mem = sdc_cfg_set(SDC_DEFAULT_RESOURCE_CFG_TAG, SDC_CFG_TYPE_NONE, NULL);
    if (required_mem < 0 || (uint32_t)required_mem > sizeof(sdc_mem_buffer)) {
        sdc_fault_handler(__FILE__, __LINE__);
    }

    err = sdc_enable(NULL, sdc_mem_buffer);
    if (err != 0) { while (1) { } }

    hci_init(&sdc_transport, NULL);

    l2cap_init();
    sm_init();
    sm_set_io_capabilities(IO_CAPABILITY_NO_INPUT_NO_OUTPUT);
    sm_set_authentication_requirements(SM_AUTHREQ_BONDING | SM_AUTHREQ_SECURE_CONNECTION);

    att_server_init(profile_data, NULL, NULL);

    battery_service_server_init(battery);
    device_information_service_server_init();
    hids_device_init(0, hid_descriptor_keyboard, sizeof(hid_descriptor_keyboard));

    uint16_t adv_int_min = 0x0030, adv_int_max = 0x0030;
    bd_addr_t null_addr; memset(null_addr, 0, sizeof(null_addr));
    gap_advertisements_set_params(adv_int_min, adv_int_max, 0, 0, null_addr, 0x07, 0x00);
    gap_advertisements_set_data(sizeof(adv_data), (uint8_t *)adv_data);
    gap_advertisements_enable(1);

    hci_event_callback_registration.callback = &packet_handler;
    hci_add_event_handler(&hci_event_callback_registration);
    sm_event_callback_registration.callback = &packet_handler;
    sm_add_event_handler(&sm_event_callback_registration);
    hids_device_register_packet_handler(packet_handler);

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
