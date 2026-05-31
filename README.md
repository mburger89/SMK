# SMK (Swift Matrix Keyboard)

A keyboard firmware written in **Embedded Swift**, targeting the **ESP32-C6**. SMK provides a modern development experience for keyboard enthusiasts, featuring Bluetooth (BLE) and Wired (USB/UART) connectivity, and a flexible JSON-based keymap system.

## Features
- **Embedded Swift**: Leverages Swift's safety and modern syntax on bare-metal hardware.
- **Dual Mode**: Switch between Bluetooth (NimBLE) and Wired (CH9350 bridge) modes.
- **Dynamic Matrix**: Configurable GPIO pins for rows and columns.
- **Layer Engine**: Supports momentary layers, toggled layers, and transparent keys (similar to QMK).
- **JSON Configuration**: Keymaps and hardware settings defined via JSON.

## Prerequisites

Before building, ensure you have the following installed:

1.  **ESP-IDF v6.0.1**: The official Espressif IoT Development Framework.
2.  **Swift 6.3.1 (Experimental Embedded RISC-V)**:
    - Download the appropriate toolchain from the Swift.org snapshots or use a compatible pre-built toolchain for RISC-V.
    - Ensure it is installed in `~/Library/Developer/Toolchains/`.
3.  **Python 3.11+**: Required by ESP-IDF.

## Getting Started

### 1. Configure the Environment

Ensure your ESP-IDF environment is sourced:
```bash
. $HOME/export-esp-idf.sh  # Path may vary based on your installation
```

### 2. Configure Hardware & Keymap
Currently, the hardware configuration and keymap are defined in `Sources/smk/Main.swift`. You can modify the `configJson` string to match your keyboard's matrix and desired layers.

**JSON Schema:**
- `matrix`: Defines the `rows` and `cols` GPIO pins.
- `layers`: An array of layers, where each layer is a 2D array of strings.
  - `key:<char>`: Standard keycode (e.g., `key:a`, `key:enter`).
  - `mod:<name>`: Modifier keys (e.g., `mod:leftShift`).
  - `mo:<index>`: Momentary layer switch.
  - `tg:<index>`: Toggle layer.
  - `trans`: Transparent key (falls through to lower layer).
  - `toggle_conn`: Switches between Wired and Bluetooth modes.

### 3. Build the Project

Set the target to ESP32-C6 and build:
```bash
idf.py set-target esp32c6
idf.py build
```

The build process uses a custom CMake integration to compile the Swift sources with the necessary experimental features (`-enable-experimental-feature Embedded`).

### 4. Flash and Monitor

Connect your ESP32-C6 via USB and run:
```bash
idf.py flash monitor
```

## Project Structure

- `Sources/smk/`: Swift source files.
  - `Main.swift`: Entry point and main loop.
  - `LayerEngine.swift`: Logic for handling layers and key actions.
  - `KeyMatrix.swift`: Hardware scanning and debouncing logic.
  - `GPIORegisters.swift`: Low-level Swift-friendly GPIO access.
- `Sources/componets/`: C helper files for Bluetooth, UART, and hardware initialization.
- `main/`: ESP-IDF component configuration and bridging.
  - `CMakeLists.txt`: Orchestrates the Swift and C compilation.
  - `Bridging.h`: C-to-Swift bridging header.
- `managed_components/`: External dependencies handled by the ESP-IDF component manager (e.g., `cJSON`).

## IDE Support

To enable code completion and syntax highlighting in VS Code or Xcode:
1. Ensure `Package.swift` is present in the root.
2. The `Package.swift` is configured to point to your local ESP-IDF headers.
3. Restart your Swift Language Server (SourceKit-LSP) after making changes to dependencies.

## License
[Add License Info Here]
