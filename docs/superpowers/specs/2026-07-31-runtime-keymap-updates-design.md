# Runtime Keymap Updates (no reflash required)

Date: 2026-07-31
Status: Approved, pending implementation plan

## Problem

The keymap (layer/key-action layout) is currently a Swift string literal
(`configJson` in `Sources/smk/Main.swift`), compiled into the firmware. Any
keymap change requires editing that literal and reflashing the device via
`idf.py flash` (ESP32-C6) or picotool (RP2040). This spec adds a way to
change the keymap without reflashing, on both supported hardware targets.

Out of scope: matrix pin definitions (`rows`/`cols`/`colsAreDriven`) stay
compiled-in and fixed per board. Only the `layers` portion of the JSON
config becomes runtime-swappable.

## Design overview

Four pieces, designed together:

1. **On-device storage** — a small per-platform "keymap store" holding a
   framed JSON blob, loaded at boot in place of the compiled default.
2. **Upload transport** — a shared chunked-transfer packet protocol, carried
   over a raw HID channel on RP2040 and a dedicated BLE GATT characteristic
   on ESP32-C6.
3. **Factory reset** — a boot-time key-hold escape hatch that erases the
   stored keymap and reverts to the compiled default.
4. **Host tool** — device-transport support added to the existing
   `smk_configurator` macOS app (a separate repo at `~/esp/smk_configurator`),
   so the same GUI used to edit a keymap can push it to a connected device.

## 1. On-device storage

Reuse `LayerEngine.loadKeymap(json:)` (`Sources/smk/LayerEngine.swift:191`)
exactly as-is — it already parses a `{"layers": [...]}` object via cJSON.
Only the source of that JSON string changes: a stored blob instead of the
compiled `configJson` literal.

**Framed blob layout** (identical on both platforms):

```
[4 bytes] magic       "SMKM"
[1 byte]  version     0x01
[2 bytes] length      uint16, length of JSON payload in bytes
[4 bytes] crc32       CRC32 over the JSON payload bytes
[N bytes] json        UTF-8 `{"layers": [...]}`, N == length, capped at ~4KB
```

- **ESP32-C6**: stored as an NVS blob (`nvs_set_blob`/`nvs_get_blob`) in a
  dedicated namespace/key. NVS is already initialized in `ble_helper.c` for
  BLE bonding, so no new init path is needed.
- **RP2040**: stored in one dedicated flash sector (4KB, matching the
  minimum erase granularity of `hardware/flash.h`), reserved near the end of
  flash via a linker/CMake constant. Erase with `flash_range_erase`, write
  with `flash_range_program` (256-byte page granularity), both from a
  `platform_glue.c`-style shim so Swift stays IO-agnostic.

**Boot sequence** (`app_main_swift` in `Main.swift`): after computing `cfg`
from the compiled `configJson` (still the only source of matrix pins), try
loading the stored blob. If present and its magic/CRC check out, call
`engine.loadKeymap(json:)` with the stored JSON instead of `configJson`. On
missing store, bad magic, or CRC mismatch, fall back to `configJson`'s
layers and log a warning — the device always boots usable.

## 2. Upload transport

A shared packet protocol, identical framing on both platforms, carried over
different physical channels:

```
BEGIN(total_len: u16)         -> device erases/prepares a write buffer, ACK
CHUNK(seq: u8, data: bytes)   -> device appends chunk, ACK/NAK per packet
COMMIT(crc32: u32)            -> device verifies CRC over all received
                                  bytes, writes the framed blob to the
                                  store, ACK/NAK
ERASE                         -> device wipes the stored blob (reverts to
                                  compiled default on next boot), ACK
```

Each command gets a single-byte status ACK/NAK response so the host can
retry a failed chunk without restarting the whole transfer.

- **RP2040**: a second TinyUSB HID interface (vendor-defined usage page)
  added alongside the existing keyboard HID interface in
  `ports/rp2040/platform/usb_descriptors.c` / `tusb_config.h`. Fixed-size
  IN/OUT reports carry the packets above.
- **ESP32-C6**: a dedicated NimBLE GATT service + characteristic (write +
  notify) added in `Sources/componets/ble_helper.c`, separate from the
  existing HID-over-GATT service used for keystrokes. Write = host sends a
  packet; notify = device sends the ACK/NAK.

Rationale for two different physical channels sharing one packet format:
RP2040 boards have no BLE (plain Pico) or scaffolded-only BLE (Pico W), so
USB is the reliable channel there; ESP32-C6's only always-on link is BLE.

## 3. Factory reset

Before loading the keymap, `app_main_swift` scans the matrix once and
checks whether the key at row 0 / col 0 reads pressed for roughly one
second (a fixed number of consecutive raw scans, independent of and prior
to the normal `DebouncedMatrix`). If held, erase the stored blob and log
that a factory reset occurred; either way, proceed to the normal
store-load-with-fallback path described in §1. This is the escape hatch if
an uploaded keymap somehow makes the upload/erase command unreachable
(e.g. a botched raw-HID/BLE build) — reflashing is the only fallback below
this.

## 4. Host tool (smk_configurator)

Rather than a new CLI, extend the existing `smk_configurator` app
(`~/esp/smk_configurator`, a SwiftCrossUI macOS app that already edits
`KeymapDocument` — matrix + layers — matching this firmware's JSON schema
exactly via `ActionToken`/`KeyName`/`ModifierName`).

Add a `DeviceTransport` module with two backends:

- **USB (RP2040)**: IOKit HID Manager, targeting the vendor-usage-page raw
  HID interface described in §2.
- **BLE (ESP32-C6)**: CoreBluetooth, targeting the custom GATT
  characteristic described in §2.

Both backends implement the same BEGIN/CHUNK/COMMIT/ERASE protocol from
§2 and expose a common async interface so the UI layer doesn't need to
know which transport is active — backend selection is by which device
class is present (auto-detected) or an explicit picker if both are
available.

Add a "Send to Device" button to `ContentView`'s toolbar, next to
Save/Save As (`Sources/SMKConfigurator/Views/ContentView.swift` around the
existing Save/Save As buttons). It takes `editor.document.layers` — no
matrix data needed, since matrix stays compiled-in on the firmware side —
encodes it as `{"layers": [...]}`, and drives it through whichever
transport backend detects a connected device. Errors (no device found,
NAK'd chunk, CRC mismatch) surface via the existing `loadError`-style
banner already used for file I/O errors.

## Testing

- **Storage**: unit-testable in isolation on both platforms — write a
  known blob, reboot (or re-invoke the load path), verify `LayerEngine`
  produces the expected actions; corrupt the CRC and verify fallback to
  compiled default.
- **Transport**: a loopback/mock test harness in `smk_configurator`'s test
  target that exercises BEGIN/CHUNK/COMMIT/ERASE framing without real
  hardware, plus manual end-to-end testing against real RP2040/ESP32-C6
  boards.
- **Factory reset**: manual hardware test — flash a known-bad stored blob,
  hold row0/col0 at boot, confirm fallback and log message.
