#include "driver/i2c.h"

// Read 16 bits from an MCP23017 expander
uint16_t read_expander_cols() {
    uint8_t data[2];
    i2c_master_write_read_device(I2C_NUM_0, 0x20, &reg_addr, 1, data, 2, 1000 / portTICK_PERIOD_MS);
    return (data[1] << 8) | data[0];
}
