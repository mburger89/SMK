# BLE Custom GATT Upload Service — see the configurator repo

The design and implementation plan for the ESP32-C6 custom GATT upload
service (which replaced the HID Report ID 2 channel, because macOS hides the
HID service from Core Bluetooth apps) live in the sibling configurator repo:

- `~/esp/smk_configurator/docs/superpowers/specs/2026-08-15-ble-custom-gatt-upload-design.md`
- `~/esp/smk_configurator/docs/superpowers/plans/2026-08-15-ble-custom-gatt-upload-plan.md`

Firmware pieces this repo owns: `Sources/components/ble_helper.c`
(`smk_upload_svcs`, `smk_upload_access_cb`, advertising layout),
`ble_upload_uuids.json` + `generate_ble_uuids.sh`, and
`CONFIG_BT_NIMBLE_MAX_BONDS`.
