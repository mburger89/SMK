#include "driver/uart.h"
#include "esp_log.h"
#include <string.h>

#define UART_NUM UART_NUM_1
#define TX_PIN 21
#define RX_PIN 20
#define BAUD_RATE 115200 // Default is 300000, but 115200 is often more reliable on breadboards

static const char *TAG = "WIRED_HID";

void init_wired_link() {
    const uart_config_t uart_config = {
        .baud_rate = BAUD_RATE,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_ERROR_CHECK(uart_param_config(UART_NUM, &uart_config));
    ESP_ERROR_CHECK(uart_set_pin(UART_NUM, TX_PIN, RX_PIN, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM, 256, 0, 0, NULL, 0));

    ESP_LOGI(TAG, "Wired HID link initialized via UART1 (TX:%d, RX:%d)", TX_PIN, RX_PIN);
}

/**
 * CH9350 12-byte Frame Protocol:
 * [0-1]  Header: 0x57 0xAB
 * [2]    ID: 0x01 (Keyboard)
 * [3-10] Payload: 8-byte standard HID report
 * [11]   Checksum: Sum of ID + 8 Data bytes (low 8 bits)
 */
void send_wired_report(uint8_t modifier, uint8_t* keys) {
    uint8_t frame[12];
    frame[0] = 0x57;
    frame[1] = 0xAB;
    frame[2] = 0x01; // ID for Keyboard

    // Construct 8-byte HID report
    uint8_t hid_report[8];
    memset(hid_report, 0, 8);
    hid_report[0] = modifier;
    // hid_report[1] is reserved
    memcpy(&hid_report[2], keys, 6);

    // Copy payload to frame
    memcpy(&frame[3], hid_report, 8);

    // Calculate checksum: Sum of ID (byte 2) + 8 Data Bytes (bytes 3-10)
    uint8_t checksum = frame[2];
    for (int i = 0; i < 8; i++) {
        checksum += hid_report[i];
    }
    frame[11] = checksum;

    // Send frame via UART
    uart_write_bytes(UART_NUM, (const char*)frame, 12);
}
