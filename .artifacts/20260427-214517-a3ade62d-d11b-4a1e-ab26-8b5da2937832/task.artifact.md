# Task Management

- [x] Resolve ESP32-C6 build errors and linker issues
    - [x] Fix missing Bluetooth headers
    - [x] Fix undefined Swift symbols with stubs
    - [x] Fix undefined BLE HID symbols with correct config
    - [x] Fix linker layout "gap" error with linker fragment
- [x] Implement Wired HID support via CH9350 bridge
- [x] Implement Manual Connection Toggle (BT vs. Wired)
- [x] Enable Dynamic Matrix configuration via JSON
- [x] Port firmware to RP2040 architecture (Experimental)
- [x] Verify full stack on physical ESP32-C6 hardware using `idf.py build`
- [ ] Test Bluetooth pairing and HID report delivery to host OS (Requires physical hardware)
- [ ] Finalize RP2040 USB descriptors for production use
