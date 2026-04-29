# SMK Keyboard Firmware Walkthrough

This walkthrough summarizes the implementation of a high-performance keyboard firmware written in **Embedded Swift**, supporting the **ESP32-C6** and **RP2040**.

## 🚀 Key Accomplishments

### 1. Dual-Mode Connectivity
- **Bluetooth (NimBLE)**: Implemented a full HID stack using the NimBLE library on the ESP32-C6.
- **Wired (CH9350)**: Developed a driver for the CH9350 UART-to-USB HID bridge, enabling wired mode on the ESP32-C6 via UART1.
- **Connection Toggle**: Integrated a runtime toggle between Bluetooth and Wired modes, mapped to a special key action.

### 2. Embedded Swift Optimization
- **Isolated Build Pipeline**: Created a custom CMake/Swiftc pipeline that provides full control over compiler flags, ensuring compatibility with the ESP-IDF environment.
- **Unicode & Stdlib Stubs**: Implemented minimal stubs to satisfy the linker for `String` and `Array` operations without bringing in the massive standard library overhead.
- **Efficient Matrix Scanning**: Optimized the key matrix scanning logic to use direct register access (memory-mapped I/O) for low latency.

### 3. Dynamic JSON Configuration
- **Runtime Keymaps**: Keymaps are parsed from a JSON string at startup using the `cJSON` library, allowing for easy customization without re-compiling.
- **Multi-Layer Logic**: Supports momentary (`mo`), toggle (`tg`), and transparent (`trans`) layer actions.
- **Dynamic Pin Mapping**: Row and Column pins are defined in the JSON config and initialized dynamically at runtime.

### 4. Cross-Platform Foundation
- **RP2040 Support**: Established the groundwork for Raspberry Pi Pico support with native USB HID via TinyUSB.

## 🛠️ Verification Results

### Build Verification
- **Target**: ESP32-C6 (RISC-V)
- **Status**: ✅ **SUCCESSFUL**
- **Command**: `idf.py build`
- **Result**: Final binary `my_swift_keyboard.bin` generated (approx. 680KB).

### Linker Consistency
- Resolved the "Gap between appdesc and rodata" error by properly mapping `.swift` metadata sections using a custom linker fragment ([linker.lf](file:///Users/ansonburger/esp/smk/main/linker.lf)).

## 📦 Project Structure
- [Main.swift](file:///Users/ansonburger/esp/smk/Sources/smk/Main.swift): Core application loop and report dispatching.
- [LayerEngine.swift](file:///Users/ansonburger/esp/smk/Sources/smk/LayerEngine.swift): Layer logic and JSON parsing.
- [KeyMatrix.swift](file:///Users/ansonburger/esp/smk/Sources/smk/KeyMatrix.swift): Hardware scanning logic.
- [ble_helper.c](file:///Users/ansonburger/esp/smk/Sources/componets/ble_helper.c): NimBLE HID implementation.
- [uart_init.c](file:///Users/ansonburger/esp/smk/Sources/componets/uart_init.c): CH9350 bridge driver.
- [kb_main.c](file:///Users/ansonburger/esp/smk/Sources/componets/kb_main.c): C entry point and Swift stubs.

## 📡 Next Steps for Testing
1. **Flash to Hardware**: Run `idf.py flash` to upload the firmware to your ESP32-C6.
2. **Bluetooth Pairing**: Search for "SMK Keyboard" on your computer/tablet and pair.
3. **JSON Customization**: Edit the `configJson` string in `Main.swift` to match your physical keyboard matrix.
