// BLE HID glue for smk_kbd_rp2040 — same SMK BLE contract as
// ble_hid.c's Pico W branch (init_ble_hid() / send_keyboard_report()), but
// talking to the CYW43439 over this board's dedicated 4-wire Bluetooth UART
// (GPIO20/21 + CTS/RTS on 22/23, BT_REG_ON on GPIO18, BT_DEV_WAKE on GPIO19,
// BT_HOST_WAKE on GPIO28 — see generate_kbd_rp2040.py's GPIO map) instead of
// Pico W's onboard CYW43 SPI/PIO link. Only compiled in for
// SMK_TARGET_BOARD=smk_kbd_rp2040 (see ports/rp2040/CMakeLists.txt);
// ble_hid.c (with its cyw43_arch-based pico_w branch and stub plain-Pico
// branch) is excluded from the build in that case, so there's exactly one
// definition of init_ble_hid()/send_keyboard_report() per target.
//
// *** STATUS as of this pass: power/UART transport, BTstack chipset/patchram
// wiring, and the cooperative run-loop pump are all real and datasheet-
// verified. The one remaining gap is the actual PatchRAM firmware bytes
// (proprietary, chip-revision-specific — see cyw43439_patchram.c for how to
// source and install them). Without them the chip stays on its ROM-only HCI
// command set (Reset / Read Local Version work; nothing else does), so BLE
// advertising will not start — but that's now a data problem, not a missing
// protocol implementation. ***
//
// Verified against the CYW43439 datasheet (Cypress/Infineon doc 002-30348
// Rev *D, in ~/esp/SMK_Keyboard/datasheets/cyw43439_lcsc.pdf) while writing
// this:
//   - Section 8 "Microprocessor and Memory Unit for Bluetooth": Bluetooth has
//     its own ARM Cortex-M3 core, 576KB ROM + 160KB RAM/patch memory, and its
//     own POR gated by BT_REG_ON alone — confirms this board's BT-only-over-
//     UART approach (WLAN held in reset, no SPI/gSPI wiring at all) is a
//     real, independent configuration, not a workaround.
//   - Section 19.1.1 / Figure 35 "WLAN = OFF, Bluetooth = ON": this exact
//     configuration is a documented reference case.
//   - Section 9.2 "UART Interface": default baud 115.2 kbaud, H4 transport
//     supported — matches BT_UART_BAUD_BOOT below and hci_transport_h4
//     already in use.
// This resolved an earlier (wrong) concern that Pico W's SPI-based BT
// transport (cyw43-driver's combined WiFi+BT memory-image loader) meant this
// chip needed the WLAN backplane for BT bring-up — it doesn't; Pico W's SPI
// routing is a Raspberry Pi board design choice, not a chip requirement.
//
// PatchRAM integration uses BTstack's own btstack_chipset_bcm driver (the
// same one used for e.g. Raspberry Pi 3/4/Zero W's BCM4345-family UART BT).
// There's no setter function to call: btstack_chipset_bcm.c's embedded
// (non-POSIX) build reads the firmware image straight from three extern
// globals (brcm_patchram_buf/brcm_patch_ram_length/brcm_patch_version,
// defined in cyw43439_patchram.c) once hci_set_chipset() below points it at
// btstack_chipset_bcm_instance() — BTstack's hci.c runs the whole
// Download-Minidriver/Write-RAM/Launch-RAM sequence internally from there;
// nothing bespoke needed here.
//
// send_keyboard_report() degrades gracefully either way (no-ops without a
// connection), so USB HID keeps working regardless of BLE's state.

#include <stdint.h>
#include <string.h>

#include "pico/stdlib.h"
#include "pico/async_context_poll.h"
#include "pico/btstack_run_loop_async_context.h"
#include "hardware/uart.h"
#include "hardware/gpio.h"

#include "btstack.h"
#include "btstack_uart_block.h"
#include "hci_transport_h4.h" // hci_transport_h4_instance() -- btstack.h only pulls in the generic hci_transport.h
#include "btstack_chipset_bcm.h" // <pico-sdk>/lib/btstack/chipset/bcm — see CMakeLists.txt
#include "ble/gatt-service/hids_device.h"
#include "ble/gatt-service/battery_service_server.h"
#include "ble/gatt-service/device_information_service_server.h"
#include "smk_hid.h" // generated from smk_hid.gatt by pico_btstack_make_gatt_header()
#include "cyw43439_patchram.h"

// --- Board pin map (generate_kbd_rp2040.py) ---------------------------------
#define PIN_BT_UART_TX    20  // GPIO20/UART1_TX -> BT_UART_RXD (chip's RX)
#define PIN_BT_UART_RX    21  // GPIO21/UART1_RX -> BT_UART_TXD (chip's TX)
#define PIN_BT_UART_CTS   22  // GPIO22/UART1_CTS -> BT_UART_RTS_N (chip's RTS)
#define PIN_BT_UART_RTS   23  // GPIO23/UART1_RTS -> BT_UART_CTS_N (chip's CTS)
#define PIN_BT_REG_ON     18  // power-on / reset, active high
#define PIN_BT_DEV_WAKE   19  // host->chip wake (assert before sending)
#define PIN_BT_HOST_WAKE  28  // chip->host wake (chip has data pending)
#define BT_UART_INST      uart1
#define BT_UART_BAUD_BOOT 115200 // CYW43439 default HCI UART baud out of reset

// --- btstack_uart_block_t: pico-sdk hardware_uart backed H4 transport ------
// Polling/blocking implementation (simplest correct thing to reason about
// without hardware in hand) rather than a fully interrupt/DMA-driven one —
// BTstack calls block_received/block_sent callbacks from its own run loop
// iteration, not from an ISR, so this drives the run loop's "poll" hook to
// check for pending RX bytes rather than using uart IRQs. Adequate for a
// low-throughput HID link; revisit if real hardware testing shows dropped
// events under load.

static void (*s_block_received_cb)(void) = NULL;
static void (*s_block_sent_cb)(void) = NULL;
static uint8_t *s_rx_buffer = NULL;
static uint16_t s_rx_len = 0;
static uint16_t s_rx_have = 0;

static int uart_driver_init(const btstack_uart_config_t *config) {
    uart_init(BT_UART_INST, BT_UART_BAUD_BOOT);
    gpio_set_function(PIN_BT_UART_TX, GPIO_FUNC_UART);
    gpio_set_function(PIN_BT_UART_RX, GPIO_FUNC_UART);
    gpio_set_function(PIN_BT_UART_CTS, GPIO_FUNC_UART);
    gpio_set_function(PIN_BT_UART_RTS, GPIO_FUNC_UART);
    uart_set_hw_flow(BT_UART_INST, true, true); // CTS/RTS, required by the chip's own flow control
    uart_set_format(BT_UART_INST, 8, 1, UART_PARITY_NONE);
    uart_set_fifo_enabled(BT_UART_INST, true);
    (void)config;
    return 0;
}

static int uart_driver_open(void) { return 0; }
static int uart_driver_close(void) { return 0; }

static void uart_driver_set_block_received(void (*block_handler)(void)) {
    s_block_received_cb = block_handler;
}
static void uart_driver_set_block_sent(void (*block_handler)(void)) {
    s_block_sent_cb = block_handler;
}

static int uart_driver_set_baudrate(uint32_t baudrate) {
    uart_set_baudrate(BT_UART_INST, baudrate);
    return 0;
}

static int uart_driver_set_parity(int parity) {
    uart_set_format(BT_UART_INST, 8, 1, parity ? UART_PARITY_EVEN : UART_PARITY_NONE);
    return 0;
}

static int uart_driver_set_flowcontrol(int flowcontrol) {
    uart_set_hw_flow(BT_UART_INST, flowcontrol != 0, flowcontrol != 0);
    return 0;
}

static void uart_driver_receive_block(uint8_t *buffer, uint16_t len) {
    s_rx_buffer = buffer;
    s_rx_len = len;
    s_rx_have = 0;
}

static void uart_driver_send_block(const uint8_t *buffer, uint16_t length) {
    uart_write_blocking(BT_UART_INST, buffer, length);
    if (s_block_sent_cb) s_block_sent_cb();
}

// async_context driving BTstack's run loop — see init_ble_hid() and the
// comment on ble_kbd_uart_poll() below. Polling (not IRQ/background) variant:
// nothing here runs from an interrupt, so a plain poll context is the
// correct match for this project's cooperative single-tick main loop
// (mirrors how pico-sdk's own pico_btstack_run_loop_async_context is meant
// to be driven when you're not using cyw43_arch's own background worker).
static async_context_poll_t s_async_ctx;

// Call regularly from the app's cooperative loop (see vTaskDelay() in
// platform_glue.c). Does two independent jobs each tick:
//  1. Drains the UART RX FIFO into whatever buffer BTstack last requested
//     via receive_block(), firing the block_received callback once full —
//     the "polling" half of this polling H4 transport (see uart_driver_*
//     above; nothing here is IRQ-driven).
//  2. Pumps BTstack's own run loop (timers, deferred callbacks, and the
//     HCI/L2CAP/SM state machines that those drive) via async_context_poll()
//     — non-blocking, returns immediately if there's nothing to do. This is
//     pico-sdk's supported async_context-based run loop
//     (pico_btstack_run_loop_async_context), set up once in init_ble_hid()
//     via btstack_run_loop_init(btstack_run_loop_async_context_get_instance(...)).
//     Without this call, HCI init would power up and drain UART bytes but
//     never actually process them into state transitions or fire our
//     packet_handler.
void ble_kbd_uart_poll(void) {
    while (s_rx_buffer && s_rx_have < s_rx_len && uart_is_readable(BT_UART_INST)) {
        s_rx_buffer[s_rx_have++] = uart_getc(BT_UART_INST);
    }
    if (s_rx_buffer && s_rx_have == s_rx_len && s_rx_len > 0) {
        s_rx_buffer = NULL;
        s_rx_len = 0;
        s_rx_have = 0;
        if (s_block_received_cb) s_block_received_cb();
    }

    async_context_poll(&s_async_ctx.core);
}

static const btstack_uart_block_t uart_driver = {
    .init = &uart_driver_init,
    .open = &uart_driver_open,
    .close = &uart_driver_close,
    .set_block_received = &uart_driver_set_block_received,
    .set_block_sent = &uart_driver_set_block_sent,
    .set_baudrate = &uart_driver_set_baudrate,
    .set_parity = &uart_driver_set_parity,
    .set_flowcontrol = &uart_driver_set_flowcontrol,
    .receive_block = &uart_driver_receive_block,
    .send_block = &uart_driver_send_block,
};

// --- CYW43439 power-up sequencing -------------------------------------------
// Datasheet-verified (section 19, "Power-Up Sequence and Timing"):
//   - BT_REG_ON and WL_REG_ON are internally OR'ed; either alone enables the
//     regulators (section 19.1.1) — we only ever drive BT_REG_ON, matching
//     Figure 35 "WLAN = OFF, Bluetooth = ON".
//   - BT POR releases when BT_REG_ON goes high; max reset duration is 110ms
//     (section 19.1) — the 150ms sleep below is a safe margin above that.
//   - Figure 17 "Startup Signaling Sequence" additionally shows the chip
//     driving BT_UART_RTS_N low only after the host drives BT_UART_CTS_N low
//     AND the chip has finished its own IO/reference-clock settling (its
//     "T3"/"T4" intervals) — hci_transport_h4's hardware flow control
//     (already enabled in uart_driver_init above) handles this handshake at
//     the UART-signal level automatically; no extra software wait is needed
//     beyond giving the chip time to reach that state, which this 150ms
//     already covers with margin.
static void cyw43439_power_up(void) {
    gpio_init(PIN_BT_REG_ON);
    gpio_set_dir(PIN_BT_REG_ON, GPIO_OUT);
    gpio_put(PIN_BT_REG_ON, 0);

    gpio_init(PIN_BT_DEV_WAKE);
    gpio_set_dir(PIN_BT_DEV_WAKE, GPIO_OUT);
    gpio_put(PIN_BT_DEV_WAKE, 0);

    gpio_init(PIN_BT_HOST_WAKE);
    gpio_set_dir(PIN_BT_HOST_WAKE, GPIO_IN);
    gpio_pull_down(PIN_BT_HOST_WAKE);

    gpio_put(PIN_BT_REG_ON, 1);
    sleep_ms(150); // let the chip boot its ROM before talking to it
    gpio_put(PIN_BT_DEV_WAKE, 1);
    sleep_ms(10);
}

// Wires BTstack's generic Broadcom/Cypress/Infineon chipset driver
// (btstack_chipset_bcm — the same one used for Raspberry Pi 3/4/Zero W's
// BCM4345-family UART Bluetooth) into our hci instance. Must be called after
// hci_init() (hci_set_chipset requires an initialized hci core) and before
// hci_power_control(HCI_POWER_ON) (that's what triggers the chipset's
// init()/next_command() sequence — HCI Reset, Read Local Version, Download
// Minidriver, the patchram records, Launch RAM — all driven internally by
// hci.c, not by code in this file).
//
// No data actually needs passing here: btstack_chipset_bcm.c's embedded
// build reads brcm_patchram_buf/brcm_patch_ram_length directly (see
// cyw43439_patchram.h) once this points hci at the chipset instance. If
// brcm_patch_ram_length were ever 0, the driver reports
// BTSTACK_CHIPSET_NO_INIT_SCRIPT and skips straight to done, so this stays
// safe to call unconditionally even without real firmware data installed —
// the chip would just stay on its ROM-only command set instead of failing.
static void cyw43439_bt_init(void) {
    hci_set_chipset(btstack_chipset_bcm_instance());
}

// --- HID-over-GATT (identical to ble_hid.c's Pico W branch; only the
// transport bring-up above differs) -----------------------------------------

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
    // BTstack's run loop must exist before hci_init(): hci.c registers
    // timers/data-source callbacks against whatever btstack_run_loop_init()
    // configured. async_context_poll (not the IRQ/background variant) is the
    // correct match here since nothing in this file runs from an interrupt —
    // it all happens synchronously inside ble_kbd_uart_poll(), called once
    // per tick from vTaskDelay() in platform_glue.c.
    async_context_poll_init_with_defaults(&s_async_ctx);
    btstack_run_loop_init(btstack_run_loop_async_context_get_instance(&s_async_ctx.core));

    cyw43439_power_up();

    hci_init(hci_transport_h4_instance(&uart_driver), NULL);
    cyw43439_bt_init(); // wires btstack_chipset_bcm; see its comment above

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

    // Triggers hci.c's internal power-on state machine, which now includes
    // the chipset init sequence wired up in cyw43439_bt_init() above. With
    // cyw43439_patchram_data_len == 0 (placeholder — see
    // cyw43439_patchram.c) this reaches HCI_STATE_WORKING using only the
    // chip's ROM HCI command set; advertising will not actually start until
    // real patch data is supplied there.
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
