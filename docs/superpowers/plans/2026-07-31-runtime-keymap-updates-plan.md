# Runtime Keymap Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a keymap be uploaded to an already-flashed SMK keyboard (ESP32-C6 or RP2040) and survive reboot, without running `idf.py flash` / picotool again.

**Architecture:** A framed JSON blob (`{"layers":[...]}`, matching what `LayerEngine.loadKeymap` already parses) lives in on-device storage — NVS on ESP32-C6, a reserved flash sector on RP2040 — loaded at boot in place of the compiled-in default. A shared 32-byte packet protocol (BEGIN/CHUNK/COMMIT/ERASE) writes new blobs in, carried over a second BLE HID report (ESP32-C6) or a second USB HID interface (RP2040). The existing `smk_configurator` macOS app gains a "Send to Device" button that drives this protocol over IOKit HID or CoreBluetooth. A boot-time key-hold (row 0 / col 0, ~1s) erases the store as a factory-reset escape hatch.

**Tech Stack:** Embedded Swift (shared `Sources/smk/*.swift`), ESP-IDF v6.0.1 C (NimBLE/esp_hidd, NVS), pico-sdk C (TinyUSB, `hardware/flash.h`), Swift 6 host app (SwiftCrossUI + IOKit HID + CoreBluetooth) in the sibling `~/esp/smk_configurator` repo.

## Global Constraints

- Only the `layers` portion of the keymap is runtime-swappable; matrix pin definitions (`rows`/`cols`/`colsAreDriven`) stay compiled-in, per the approved spec.
- Stored blob capacity: 4085 bytes of JSON payload (`SMK_KEYMAP_MAX_LEN`), inside an 11-byte framing header (`magic[4]` `"SMKM"` + `version[1]=1` + `length[2]` LE + `crc32[4]` LE) — total frame capacity 4096 bytes, matching RP2040's 4KB minimum flash-erase granularity.
- Upload packets are always exactly 32 bytes (`SMK_KEYMAP_PACKET_LEN`), no partial-size packets, on both transports.
- CRC32 is the standard bitwise IEEE 802.3 / zlib-compatible algorithm (poly `0xEDB88320`, init/final `0xFFFFFFFF`) — implemented identically (and independently — no shared library) in every C file and in Swift, so any two ends can verify each other's output.
- Deviation from the approved spec, discovered while reading the actual ESP-IDF `esp_hidd.h` API: the ESP32-C6 upload channel is **not** a dedicated NimBLE GATT service (that would require bypassing `esp_hidd`'s own internal GATT server registration). Instead it's a second HID Report ID (2) added to the existing BLE HID-over-GATT report map, using `esp_hidd`'s existing `ESP_HIDD_OUTPUT_EVENT` / `esp_hidd_dev_input_set` — same wire protocol and user-visible behavior the spec describes, different (and considerably lower-risk) underlying BLE mechanism.
- Reuse `LayerEngine.loadKeymap` verbatim in spirit — the existing cJSON parsing logic is not rewritten, only given a second entry point that skips the `String`-to-C-string bridging for a buffer that's already a C string.

---

### Task 1: ESP32-C6 keymap store (NVS-backed)

**Files:**
- Create: `Sources/componets/smk_keymap_store.c`
- Modify: `Sources/smk/Bridging.h`
- Modify: `main/CMakeLists.txt:9-16` (add to `c_srcs`)

**Interfaces:**
- Produces (called from Main.swift via `@_extern`, and from `smk_keymap_protocol.c` in Task 3):
  ```c
  int32_t smk_keymap_load(char *buf, uint32_t buf_size);
  void smk_keymap_erase(void);
  int32_t smk_keymap_begin_write(uint16_t total_len);
  int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len);
  int32_t smk_keymap_commit(uint32_t crc32);
  ```

- [ ] **Step 1: Write `Sources/componets/smk_keymap_store.c`**

```c
// Runtime keymap store (ESP32-C6, NVS-backed). Persists the framed
// {"layers":[...]} JSON blob uploaded over BLE (see smk_keymap_protocol.c)
// so LayerEngine.loadKeymap has something to load besides the compiled
// default. See docs/superpowers/specs/2026-07-31-runtime-keymap-updates-
// design.md for the frame layout and protocol.
//
// NVS is already initialized by init_ble_hid() (Sources/componets/
// ble_helper.c) before Main.swift reaches the keymap-load call site, so no
// separate init is needed here.

#include "nvs.h"
#include "nvs_flash.h"
#include <string.h>
#include <stdint.h>

#define SMK_KEYMAP_MAX_LEN 4085
#define SMK_KEYMAP_FRAME_LEN (11 + SMK_KEYMAP_MAX_LEN)

#define SMK_KEYMAP_MAGIC0 'S'
#define SMK_KEYMAP_MAGIC1 'M'
#define SMK_KEYMAP_MAGIC2 'K'
#define SMK_KEYMAP_MAGIC3 'M'
#define SMK_KEYMAP_VERSION 1

static const char *NVS_NAMESPACE = "smk_kmap";
static const char *NVS_KEY = "frame";

static uint8_t s_stage[SMK_KEYMAP_FRAME_LEN];
static uint16_t s_stage_total_len = 0;

static uint32_t smk_crc32(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            uint32_t mask = (uint32_t)(-(int32_t)(crc & 1u));
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

int32_t smk_keymap_load(char *buf, uint32_t buf_size) {
    nvs_handle_t handle;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &handle) != ESP_OK) {
        return -1;
    }

    uint8_t frame[SMK_KEYMAP_FRAME_LEN];
    size_t frame_len = sizeof(frame);
    esp_err_t err = nvs_get_blob(handle, NVS_KEY, frame, &frame_len);
    nvs_close(handle);
    if (err != ESP_OK || frame_len < 11) {
        return -1;
    }

    if (frame[0] != SMK_KEYMAP_MAGIC0 || frame[1] != SMK_KEYMAP_MAGIC1 ||
        frame[2] != SMK_KEYMAP_MAGIC2 || frame[3] != SMK_KEYMAP_MAGIC3 ||
        frame[4] != SMK_KEYMAP_VERSION) {
        return -1;
    }

    uint16_t json_len = (uint16_t)frame[5] | ((uint16_t)frame[6] << 8);
    uint32_t stored_crc = (uint32_t)frame[7] | ((uint32_t)frame[8] << 8) |
                          ((uint32_t)frame[9] << 16) | ((uint32_t)frame[10] << 24);

    if (json_len > SMK_KEYMAP_MAX_LEN || (uint32_t)(11 + json_len) > frame_len ||
        (uint32_t)json_len + 1 > buf_size) {
        return -1;
    }

    if (smk_crc32(&frame[11], json_len) != stored_crc) {
        return -1;
    }

    memcpy(buf, &frame[11], json_len);
    return (int32_t)json_len;
}

void smk_keymap_erase(void) {
    nvs_handle_t handle;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) {
        return;
    }
    nvs_erase_key(handle, NVS_KEY);
    nvs_commit(handle);
    nvs_close(handle);
}

int32_t smk_keymap_begin_write(uint16_t total_len) {
    if (total_len > SMK_KEYMAP_MAX_LEN) {
        return -1;
    }
    s_stage_total_len = total_len;
    memset(s_stage, 0, sizeof(s_stage));
    return 0;
}

int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len) {
    if ((uint32_t)offset + len > s_stage_total_len) {
        return -1;
    }
    memcpy(&s_stage[11 + offset], data, len);
    return 0;
}

int32_t smk_keymap_commit(uint32_t crc32) {
    if (smk_crc32(&s_stage[11], s_stage_total_len) != crc32) {
        return -1;
    }

    s_stage[0] = SMK_KEYMAP_MAGIC0;
    s_stage[1] = SMK_KEYMAP_MAGIC1;
    s_stage[2] = SMK_KEYMAP_MAGIC2;
    s_stage[3] = SMK_KEYMAP_MAGIC3;
    s_stage[4] = SMK_KEYMAP_VERSION;
    s_stage[5] = (uint8_t)(s_stage_total_len & 0xFF);
    s_stage[6] = (uint8_t)((s_stage_total_len >> 8) & 0xFF);
    s_stage[7] = (uint8_t)(crc32 & 0xFF);
    s_stage[8] = (uint8_t)((crc32 >> 8) & 0xFF);
    s_stage[9] = (uint8_t)((crc32 >> 16) & 0xFF);
    s_stage[10] = (uint8_t)((crc32 >> 24) & 0xFF);

    nvs_handle_t handle;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) {
        return -1;
    }
    esp_err_t err = nvs_set_blob(handle, NVS_KEY, s_stage, 11 + s_stage_total_len);
    if (err == ESP_OK) {
        err = nvs_commit(handle);
    }
    nvs_close(handle);
    return (err == ESP_OK) ? 0 : -1;
}
```

- [ ] **Step 2: Add source to `main/CMakeLists.txt`**

In the `c_srcs` list (around line 9-16), add the new file:

```cmake
set(c_srcs
    "../Sources/componets/ble_helper.c"
    "../Sources/componets/gpio_init.c"
    "../Sources/componets/uart_init.c"
    "../Sources/componets/kb_main.c"
    "../Sources/componets/smk_config.c"
    "../Sources/componets/smk_keymap_store.c"
    "../Sources/componets/led_strip_encoder.c"
    "../Sources/componets/led_strip_driver.c"
)
```

`nvs_flash` is already in `idf_component_register`'s `REQUIRES` list, so no other CMake change is needed.

- [ ] **Step 3: Add declarations to `Sources/smk/Bridging.h`**

```c
// Runtime keymap store (Sources/componets/smk_keymap_store.c, NVS-backed).
// See docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md.
int32_t smk_keymap_load(char *buf, uint32_t buf_size);
void smk_keymap_erase(void);
int32_t smk_keymap_begin_write(uint16_t total_len);
int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len);
int32_t smk_keymap_commit(uint32_t crc32);
```

- [ ] **Step 4: Verify it builds**

Run: `. $HOME/export-esp-idf.sh && idf.py build`
Expected: build succeeds (this file isn't called from Swift yet — that's Task 4 — so this step only proves it compiles and links cleanly).

- [ ] **Step 5: Commit**

```bash
git add Sources/componets/smk_keymap_store.c Sources/smk/Bridging.h main/CMakeLists.txt
git commit -m "Add ESP32-C6 NVS-backed runtime keymap store"
```

---

### Task 2: RP2040 keymap store (flash-backed)

**Files:**
- Create: `ports/rp2040/platform/smk_keymap_store.c`
- Modify: `ports/rp2040/BridgingHeader.h`
- Modify: `ports/rp2040/CMakeLists.txt:107-114` (add to `PLATFORM_C_SRCS`), `:156-161` (link `hardware_flash`/`hardware_sync`)

**Interfaces:**
- Produces (identical contract to Task 1, called from the same Main.swift `@_extern` declarations):
  ```c
  int32_t smk_keymap_load(char *buf, uint32_t buf_size);
  void smk_keymap_erase(void);
  int32_t smk_keymap_begin_write(uint16_t total_len);
  int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len);
  int32_t smk_keymap_commit(uint32_t crc32);
  ```

- [ ] **Step 1: Write `ports/rp2040/platform/smk_keymap_store.c`**

```c
// Runtime keymap store (RP2040, flash-backed). Counterpart to
// Sources/componets/smk_keymap_store.c (ESP32-C6, NVS-backed) — same framed
// blob layout and function contract (declared in BridgingHeader.h). Reserves
// the last flash sector (4KB, this chip's minimum erase granularity) for
// the stored keymap.

#include "hardware/flash.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"
#include <string.h>
#include <stdint.h>

#define SMK_KEYMAP_MAX_LEN 4085
#define SMK_KEYMAP_FRAME_LEN (11 + SMK_KEYMAP_MAX_LEN)

#define SMK_KEYMAP_MAGIC0 'S'
#define SMK_KEYMAP_MAGIC1 'M'
#define SMK_KEYMAP_MAGIC2 'K'
#define SMK_KEYMAP_MAGIC3 'M'
#define SMK_KEYMAP_VERSION 1

// Reserve the last flash sector. Flash is memory-mapped for reads at
// XIP_BASE at all times, so the store can be read directly as a pointer.
#define SMK_KEYMAP_FLASH_OFFSET (PICO_FLASH_SIZE_BYTES - FLASH_SECTOR_SIZE)
static const uint8_t *const s_flash_frame =
    (const uint8_t *)(XIP_BASE + SMK_KEYMAP_FLASH_OFFSET);

static uint8_t s_stage[SMK_KEYMAP_FRAME_LEN];
static uint16_t s_stage_total_len = 0;

static uint32_t smk_crc32(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            uint32_t mask = (uint32_t)(-(int32_t)(crc & 1u));
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

int32_t smk_keymap_load(char *buf, uint32_t buf_size) {
    if (s_flash_frame[0] != SMK_KEYMAP_MAGIC0 || s_flash_frame[1] != SMK_KEYMAP_MAGIC1 ||
        s_flash_frame[2] != SMK_KEYMAP_MAGIC2 || s_flash_frame[3] != SMK_KEYMAP_MAGIC3 ||
        s_flash_frame[4] != SMK_KEYMAP_VERSION) {
        return -1;
    }

    uint16_t json_len = (uint16_t)s_flash_frame[5] | ((uint16_t)s_flash_frame[6] << 8);
    uint32_t stored_crc = (uint32_t)s_flash_frame[7] | ((uint32_t)s_flash_frame[8] << 8) |
                          ((uint32_t)s_flash_frame[9] << 16) | ((uint32_t)s_flash_frame[10] << 24);

    if (json_len > SMK_KEYMAP_MAX_LEN || (uint32_t)json_len + 1 > buf_size) {
        return -1;
    }

    if (smk_crc32(&s_flash_frame[11], json_len) != stored_crc) {
        return -1;
    }

    memcpy(buf, &s_flash_frame[11], json_len);
    return (int32_t)json_len;
}

void smk_keymap_erase(void) {
    uint32_t ints = save_and_disable_interrupts();
    flash_range_erase(SMK_KEYMAP_FLASH_OFFSET, FLASH_SECTOR_SIZE);
    restore_interrupts(ints);
}

int32_t smk_keymap_begin_write(uint16_t total_len) {
    if (total_len > SMK_KEYMAP_MAX_LEN) {
        return -1;
    }
    s_stage_total_len = total_len;
    memset(s_stage, 0, sizeof(s_stage));
    return 0;
}

int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len) {
    if ((uint32_t)offset + len > s_stage_total_len) {
        return -1;
    }
    memcpy(&s_stage[11 + offset], data, len);
    return 0;
}

int32_t smk_keymap_commit(uint32_t crc32) {
    if (smk_crc32(&s_stage[11], s_stage_total_len) != crc32) {
        return -1;
    }

    s_stage[0] = SMK_KEYMAP_MAGIC0;
    s_stage[1] = SMK_KEYMAP_MAGIC1;
    s_stage[2] = SMK_KEYMAP_MAGIC2;
    s_stage[3] = SMK_KEYMAP_MAGIC3;
    s_stage[4] = SMK_KEYMAP_VERSION;
    s_stage[5] = (uint8_t)(s_stage_total_len & 0xFF);
    s_stage[6] = (uint8_t)((s_stage_total_len >> 8) & 0xFF);
    s_stage[7] = (uint8_t)(crc32 & 0xFF);
    s_stage[8] = (uint8_t)((crc32 >> 8) & 0xFF);
    s_stage[9] = (uint8_t)((crc32 >> 16) & 0xFF);
    s_stage[10] = (uint8_t)((crc32 >> 24) & 0xFF);

    // flash_range_program requires a length that's a multiple of
    // FLASH_PAGE_SIZE (256 bytes); s_stage is already zero-padded past the
    // real data (memset in smk_keymap_begin_write), so round up.
    uint32_t program_len =
        ((11 + s_stage_total_len + FLASH_PAGE_SIZE - 1) / FLASH_PAGE_SIZE) * FLASH_PAGE_SIZE;

    uint32_t ints = save_and_disable_interrupts();
    flash_range_erase(SMK_KEYMAP_FLASH_OFFSET, FLASH_SECTOR_SIZE);
    flash_range_program(SMK_KEYMAP_FLASH_OFFSET, s_stage, program_len);
    restore_interrupts(ints);
    return 0;
}
```

- [ ] **Step 2: Add declarations to `ports/rp2040/BridgingHeader.h`**

```c
// Runtime keymap store (platform/smk_keymap_store.c, flash-backed). See
// docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md.
int32_t smk_keymap_load(char *buf, uint32_t buf_size);
void smk_keymap_erase(void);
int32_t smk_keymap_begin_write(uint16_t total_len);
int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len);
int32_t smk_keymap_commit(uint32_t crc32);
```

- [ ] **Step 3: Add source + link libraries to `ports/rp2040/CMakeLists.txt`**

In `PLATFORM_C_SRCS` (line 107-114):

```cmake
set(PLATFORM_C_SRCS
    platform/gpio_init.c
    platform/usb_hid.c
    platform/usb_descriptors.c
    platform/platform_glue.c
    platform/smk_keymap_store.c
    # Portable cJSON (no ESP-IDF dependency)
    "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON/cJSON.c"
)
```

In the base `target_link_libraries(smk_rp2040 ...)` block (line 156-161):

```cmake
target_link_libraries(smk_rp2040
    pico_stdlib
    hardware_gpio
    hardware_flash
    hardware_sync
    tinyusb_device
    tinyusb_board
)
```

- [ ] **Step 4: Verify it builds**

Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: build succeeds, produces `build_rp2040_pico/smk_rp2040.uf2`.

- [ ] **Step 5: Commit**

```bash
git add ports/rp2040/platform/smk_keymap_store.c ports/rp2040/BridgingHeader.h ports/rp2040/CMakeLists.txt
git commit -m "Add RP2040 flash-backed runtime keymap store"
```

---

### Task 3: `LayerEngine.loadKeymap` C-string entry point

**Files:**
- Modify: `Sources/smk/LayerEngine.swift:191-238`

**Interfaces:**
- Produces (used by Task 4's Main.swift boot integration):
  ```swift
  mutating func loadKeymap(cJsonStr: UnsafePointer<Int8>)
  ```
- Consumes: nothing new — this only restructures the existing `loadKeymap(json:)` body.

- [ ] **Step 1: Refactor `loadKeymap` to separate the C-string parsing from the `String` bridging**

Replace lines 191-238 (the entire current `loadKeymap(json:)` method) with:

```swift
    mutating func loadKeymap(json: String) {
        json.withCString { loadKeymap(cJsonStr: $0) }
    }

    // Parses a keymap already available as a C string — used both by
    // loadKeymap(json:) above (compiled-in default) and by Main.swift's
    // stored-keymap boot path (a null-terminated buffer read from the
    // on-device keymap store), which is already a C buffer and shouldn't be
    // round-tripped through a Swift String just to get back to one.
    mutating func loadKeymap(cJsonStr: UnsafePointer<Int8>) {
        guard let root = cJSON_Parse(cJsonStr) else {
            kb_log("JSON Parse Error")
            return
        }
        defer { cJSON_Delete(root) }

        guard let layersArray = cJSON_GetObjectItem(root, "layers") else {
            kb_log("JSON Missing 'layers' key")
            return
        }

        let layerCount = cJSON_GetArraySize(layersArray)
        if layerCount == 0 { return }

        var newKeymaps: [[[KeyAction]]] = []

        for i in 0..<layerCount {
            guard let layerObj = cJSON_GetArrayItem(layersArray, i) else { continue }
            let rowCount = cJSON_GetArraySize(layerObj)
            var layer: [[KeyAction]] = []

            for r in 0..<rowCount {
                guard let rowObj = cJSON_GetArrayItem(layerObj, r) else { continue }
                let colCount = cJSON_GetArraySize(rowObj)
                var row: [KeyAction] = []

                for c in 0..<colCount {
                    guard let cellObj = cJSON_GetArrayItem(rowObj, c) else { continue }
                    if let cStr = cellObj.pointee.valuestring {
                        row.append(KeyAction.fromCString(cStr))
                    } else {
                        row.append(.none)
                    }
                }
                layer.append(row)
            }
            newKeymaps.append(layer)
        }

        if !newKeymaps.isEmpty {
            self.keymaps = newKeymaps
            kb_log("Keymap loaded successfully")
        }
    }
```

- [ ] **Step 2: Verify both builds still succeed**

Run: `. $HOME/export-esp-idf.sh && idf.py build`
Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: both succeed (this is a pure refactor — `loadKeymap(json:)`'s behavior is unchanged, only its body moved).

- [ ] **Step 3: Manual regression check**

Flash either board (`idf.py flash monitor` or picotool) and confirm the keyboard still types normally with the compiled-in keymap — this refactor touches the only code path that loads every keymap, compiled-in or not, so a regression here would break typing entirely.

- [ ] **Step 4: Commit**

```bash
git add Sources/smk/LayerEngine.swift
git commit -m "Split LayerEngine.loadKeymap into String and C-string entry points"
```

---

### Task 4: Boot integration — load stored keymap, factory-reset combo

**Files:**
- Modify: `Sources/smk/Main.swift:1-41` (add `@_extern` declarations), `:259` (replace the single `engine.loadKeymap(json: configJson)` line)

**Interfaces:**
- Consumes: `smk_keymap_load`/`smk_keymap_erase` (Tasks 1-2), `LayerEngine.loadKeymap(cJsonStr:)` (Task 3), `KeyMatrix.scan() -> [Bool]` (existing), `LayerEngine.keymaps` (existing, `private(set)`, readable).
- Produces: nothing new for later tasks — this is the last piece needed for the store+fallback path to work end-to-end (modulo actually having a transport to write to the store, Tasks 5-6).

- [ ] **Step 1: Add `@_extern` declarations**

After the existing `smk_default_mode_is_wired` declaration (`Main.swift:28-29`), add:

```swift
// Runtime keymap store — see Sources/componets/smk_keymap_store.c (ESP32)
// and ports/rp2040/platform/smk_keymap_store.c (RP2040).
@_extern(c, "smk_keymap_load")
func smk_keymap_load(_ buf: UnsafeMutablePointer<Int8>, _ bufSize: UInt32) -> Int32

@_extern(c, "smk_keymap_erase")
func smk_keymap_erase()
```

- [ ] **Step 2: Replace the keymap-load line with the store+fallback+factory-reset block**

Replace line 259 (`engine.loadKeymap(json: configJson)`) with:

```swift
    // Factory-reset escape hatch: hold the key at row 0 / col 0 during boot
    // to erase the stored keymap and fall back to the compiled default.
    // Uses the same per-iteration vTaskDelay(1) unit as the main scan loop
    // below, so the actual wall-clock hold time follows whatever "1 tick"
    // means on this platform already (~1s intended — time it with a
    // stopwatch during hardware testing and adjust resetHoldScans if it
    // feels too short or too long). This runs before the store is even
    // consulted, so it works even if a bad uploaded keymap somehow makes
    // the upload/erase command itself unreachable.
    let resetHoldScans = 100
    var resetHeld = true
    for _ in 0..<resetHoldScans {
        if !matrix.scan()[0] { // row 0, col 0
            resetHeld = false
            break
        }
        vTaskDelay(1)
    }
    if resetHeld {
        smk_keymap_erase()
        kb_log("Factory reset: stored keymap erased, using compiled default")
    }

    // Load a previously-uploaded keymap from the on-device store in place
    // of the compiled default. keymapBufSize must exceed the store's
    // SMK_KEYMAP_MAX_LEN (4085) by at least 1 byte for the null terminator.
    let keymapBufSize = 4096
    var keymapBuf = [Int8](repeating: 0, count: keymapBufSize)
    var loadedFromStore = false
    if !resetHeld {
        let storedLen = keymapBuf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return smk_keymap_load(base, UInt32(ptr.count))
        }
        if storedLen >= 0 {
            keymapBuf[Int(storedLen)] = 0
            loadedFromStore = true
        }
    }

    if loadedFromStore {
        keymapBuf.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                engine.loadKeymap(cJsonStr: base)
            }
        }
        if engine.keymaps.isEmpty {
            kb_log("Stored keymap invalid, falling back to compiled default")
            engine.loadKeymap(json: configJson)
        } else {
            kb_log("Loaded keymap from on-device store")
        }
    } else {
        engine.loadKeymap(json: configJson)
    }
```

- [ ] **Step 3: Verify both builds succeed**

Run: `. $HOME/export-esp-idf.sh && idf.py build`
Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: both succeed.

- [ ] **Step 4: Manual hardware test — fallback path (no keymap stored yet)**

Flash either board and open the serial monitor (`idf.py flash monitor`, or `picotool` + a serial terminal). Confirm:
- Normal boot (no key held): the keyboard types normally using the compiled default keymap (no store has ever been written to yet, so `smk_keymap_load` returns -1 and `loadedFromStore` is `false` — same behavior as before this task).
- Boot while holding the top-left "1" key: confirm the log shows `Factory reset: stored keymap erased, using compiled default`, and time the hold with a stopwatch — adjust `resetHoldScans` in Step 2 if it's noticeably off from ~1 second.

- [ ] **Step 5: Commit**

```bash
git add Sources/smk/Main.swift
git commit -m "Boot: load keymap from on-device store with factory-reset combo"
```

---

### Task 5: Shared upload-packet dispatch

**Files:**
- Create: `Sources/componets/smk_keymap_protocol.h`
- Create: `Sources/componets/smk_keymap_protocol.c`
- Modify: `main/CMakeLists.txt` (add to `c_srcs`)
- Modify: `ports/rp2040/CMakeLists.txt` (add to `PLATFORM_C_SRCS` by relative path, add include dir)

**Interfaces:**
- Produces (called from Task 6's `ble_helper.c` and Task 7's `usb_descriptors.c`):
  ```c
  #define SMK_KEYMAP_PACKET_LEN 32
  void smk_keymap_dispatch_packet(const uint8_t *packet, uint8_t *response);
  ```
- Consumes: `smk_keymap_begin_write`/`write_chunk`/`commit`/`erase` (Tasks 1-2).

This is one physical file referenced by both build systems — the same pattern `ports/rp2040/CMakeLists.txt` already uses for `managed_components/espressif__cjson/cJSON/cJSON.c`.

- [ ] **Step 1: Write `Sources/componets/smk_keymap_protocol.h`**

```c
#pragma once
#include <stdint.h>

// Shared BEGIN/CHUNK/COMMIT/ERASE packet dispatch for the runtime keymap
// upload protocol. Transport-agnostic: the ESP32-C6 BLE Report ID 2 path
// (ble_helper.c) and the RP2040 raw-HID interface path
// (ports/rp2040/platform/usb_descriptors.c) each call this with whatever
// bytes their transport received, and send back whatever bytes it writes
// into `response` over that same transport. See
// docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md.

#define SMK_KEYMAP_PACKET_LEN 32

// packet and response must both point to SMK_KEYMAP_PACKET_LEN-byte
// buffers. Packet layout (byte 0 = opcode):
//   0x01 BEGIN:  bytes 1-2 = total_len (u16 LE)
//   0x02 CHUNK:  bytes 1-2 = offset (u16 LE), byte 3 = chunk len, bytes 4.. = data
//   0x03 COMMIT: bytes 1-4 = crc32 (u32 LE)
//   0x04 ERASE:  no payload
// Response layout: byte 0 = status (0x00 OK / 0x01 ERR), byte 1 = echoed opcode.
void smk_keymap_dispatch_packet(const uint8_t *packet, uint8_t *response);
```

- [ ] **Step 2: Write `Sources/componets/smk_keymap_protocol.c`**

```c
#include "smk_keymap_protocol.h"
#include <string.h>

int32_t smk_keymap_begin_write(uint16_t total_len);
int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len);
int32_t smk_keymap_commit(uint32_t crc32);
void smk_keymap_erase(void);

#define SMK_OP_BEGIN  0x01
#define SMK_OP_CHUNK  0x02
#define SMK_OP_COMMIT 0x03
#define SMK_OP_ERASE  0x04

#define SMK_STATUS_OK  0x00
#define SMK_STATUS_ERR 0x01

void smk_keymap_dispatch_packet(const uint8_t *packet, uint8_t *response) {
    memset(response, 0, SMK_KEYMAP_PACKET_LEN);
    uint8_t opcode = packet[0];
    int32_t result = -1;

    switch (opcode) {
        case SMK_OP_BEGIN: {
            uint16_t total_len = (uint16_t)packet[1] | ((uint16_t)packet[2] << 8);
            result = smk_keymap_begin_write(total_len);
            break;
        }
        case SMK_OP_CHUNK: {
            uint16_t offset = (uint16_t)packet[1] | ((uint16_t)packet[2] << 8);
            uint8_t chunk_len = packet[3];
            result = smk_keymap_write_chunk(offset, &packet[4], chunk_len);
            break;
        }
        case SMK_OP_COMMIT: {
            uint32_t crc32 = (uint32_t)packet[1] | ((uint32_t)packet[2] << 8) |
                             ((uint32_t)packet[3] << 16) | ((uint32_t)packet[4] << 24);
            result = smk_keymap_commit(crc32);
            break;
        }
        case SMK_OP_ERASE: {
            smk_keymap_erase();
            result = 0;
            break;
        }
        default:
            result = -1;
            break;
    }

    response[0] = (result == 0) ? SMK_STATUS_OK : SMK_STATUS_ERR;
    response[1] = opcode;
}
```

- [ ] **Step 3: Add to `main/CMakeLists.txt`'s `c_srcs`**

```cmake
set(c_srcs
    "../Sources/componets/ble_helper.c"
    "../Sources/componets/gpio_init.c"
    "../Sources/componets/uart_init.c"
    "../Sources/componets/kb_main.c"
    "../Sources/componets/smk_config.c"
    "../Sources/componets/smk_keymap_store.c"
    "../Sources/componets/smk_keymap_protocol.c"
    "../Sources/componets/led_strip_encoder.c"
    "../Sources/componets/led_strip_driver.c"
)
```

- [ ] **Step 4: Add to `ports/rp2040/CMakeLists.txt`'s `PLATFORM_C_SRCS` and include dirs**

```cmake
set(PLATFORM_C_SRCS
    platform/gpio_init.c
    platform/usb_hid.c
    platform/usb_descriptors.c
    platform/platform_glue.c
    platform/smk_keymap_store.c
    # Portable cJSON (no ESP-IDF dependency)
    "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON/cJSON.c"
    # Shared upload-packet dispatch (see Sources/componets/smk_keymap_protocol.c)
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/componets/smk_keymap_protocol.c"
)
```

In the include-dirs block (line 260-263):

```cmake
target_include_directories(smk_rp2040 PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/platform"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/componets"
)
```

- [ ] **Step 5: Verify both builds succeed**

Run: `. $HOME/export-esp-idf.sh && idf.py build`
Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: both succeed (nothing calls `smk_keymap_dispatch_packet` yet — that's Tasks 6-7 — so this only proves it compiles into both binaries).

- [ ] **Step 6: Commit**

```bash
git add Sources/componets/smk_keymap_protocol.h Sources/componets/smk_keymap_protocol.c main/CMakeLists.txt ports/rp2040/CMakeLists.txt
git commit -m "Add shared keymap-upload packet dispatch (BEGIN/CHUNK/COMMIT/ERASE)"
```

---

### Task 6: ESP32-C6 BLE upload channel (HID Report ID 2)

**Files:**
- Modify: `Sources/componets/ble_helper.c:18-24` (report map), `:73-94` (event callback)

**Interfaces:**
- Consumes: `smk_keymap_dispatch_packet` (Task 5), `esp_hidd_dev_input_set` (existing ESP-IDF API), `ESP_HIDD_OUTPUT_EVENT` (existing ESP-IDF API — confirmed present in `esp_hid/include/esp_hidd.h`, gives `output.report_id`/`output.length`/`output.data`).
- Produces: a working BLE upload channel — used end-to-end in Task 11.

- [ ] **Step 1: Extend the HID report map with a second collection (Report ID 2)**

Replace `Sources/componets/ble_helper.c:18-24`:

```c
// HID Report Map: a standard keyboard (Report ID 1) plus a 32-byte
// vendor-defined channel (Report ID 2) used only for keymap upload — see
// smk_keymap_protocol.c for what rides over it.
static const uint8_t hid_report_map[] = {
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xc0,
    // Keymap upload channel — Usage Page (Vendor Defined 0xFF00), Report ID 2
    0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x02,
    0x75, 0x08, 0x95, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00,
    0x09, 0x01, 0x81, 0x02,
    0x09, 0x01, 0x91, 0x02,
    0xC0
};
```

- [ ] **Step 2: Handle `ESP_HIDD_OUTPUT_EVENT` for Report ID 2**

Add a forward declaration near the top of the file (after the `#include`s, before `hid_report_map`):

```c
void smk_keymap_dispatch_packet(const uint8_t *packet, uint8_t *response);
```

Replace the `ble_hidd_event_callback` switch (`ble_helper.c:73-94`):

```c
static void ble_hidd_event_callback(void *handler_args, esp_event_base_t base, int32_t id, void *event_data) {
    (void)handler_args;
    (void)base;
    esp_hidd_event_t event = (esp_hidd_event_t)id;

    switch (event) {
        case ESP_HIDD_START_EVENT:
            ESP_LOGI(TAG, "BLE HID Stack Started");
            start_advertising();
            break;
        case ESP_HIDD_CONNECT_EVENT:
            ESP_LOGI(TAG, "BLE HID Connected");
            break;
        case ESP_HIDD_OUTPUT_EVENT: {
            esp_hidd_event_data_t *p = (esp_hidd_event_data_t *)event_data;
            if (p != NULL && p->output.report_id == 2 && p->output.length >= 32) {
                uint8_t response[32];
                smk_keymap_dispatch_packet(p->output.data, response);
                esp_hidd_dev_input_set(s_hid_dev, 0, 2, response, sizeof(response));
            }
            break;
        }
        case ESP_HIDD_DISCONNECT_EVENT:
            ESP_LOGI(TAG, "BLE HID Disconnected");
            start_advertising();
            break;
        default:
            break;
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `. $HOME/export-esp-idf.sh && idf.py build`
Expected: build succeeds.

- [ ] **Step 4: Manual hardware smoke test (no host tool yet)**

Flash the board and pair over BLE as normal (any BLE HID host). Confirm normal keyboard typing still works (Report ID 1 unaffected) — full upload-channel verification happens in Task 11 once `smk_configurator` can drive it.

- [ ] **Step 5: Commit**

```bash
git add Sources/componets/ble_helper.c
git commit -m "Add BLE HID Report ID 2 keymap-upload channel"
```

---

### Task 7: RP2040 USB raw HID upload channel

**Files:**
- Modify: `ports/rp2040/platform/tusb_config.h:40,47`
- Modify: `ports/rp2040/platform/usb_descriptors.c` (interface/endpoint numbering, report descriptors, `tud_hid_set_report_cb`)

**Interfaces:**
- Consumes: `smk_keymap_dispatch_packet` (Task 5), TinyUSB's `tud_hid_n_report` (existing pico-sdk/TinyUSB API).
- Produces: a working USB upload channel — used end-to-end in Task 11.

- [ ] **Step 1: Update `tusb_config.h`**

Change line 40 (`#define CFG_TUD_HID 1`) to:

```c
#define CFG_TUD_HID 2
```

Change line 47 (`#define CFG_TUD_HID_EP_BUFSIZE 16`) to:

```c
#define CFG_TUD_HID_EP_BUFSIZE 32
```

- [ ] **Step 2: Add the raw HID report descriptor**

After the existing `desc_hid_report` array (`usb_descriptors.c:39-41`), add:

```c
// ---------------------------------------------------------------------------
// HID Report Descriptor — 32-byte vendor-defined raw channel, used only for
// keymap upload (see smk_keymap_protocol.c). Its own interface, so no
// Report ID is needed (unlike the BLE side, which multiplexes this onto the
// same GATT report characteristic as the keyboard and needs one).
// ---------------------------------------------------------------------------
uint8_t const desc_hid_report_raw[] = {
    0x06, 0x00, 0xFF,        // Usage Page (Vendor Defined 0xFF00)
    0x09, 0x01,              // Usage (0x01)
    0xA1, 0x01,              // Collection (Application)
    0x15, 0x00,              //   Logical Minimum (0)
    0x26, 0xFF, 0x00,        //   Logical Maximum (255)
    0x75, 0x08,              //   Report Size (8)
    0x95, 0x20,              //   Report Count (32)
    0x09, 0x01,              //   Usage (0x01)
    0x81, 0x02,              //   Input (Data,Var,Abs)
    0x95, 0x20,              //   Report Count (32)
    0x09, 0x01,              //   Usage (0x01)
    0x91, 0x02,              //   Output (Data,Var,Abs)
    0xC0                     // End Collection
};
```

- [ ] **Step 3: Update `tud_hid_descriptor_report_cb` to serve the right descriptor per instance**

Replace (`usb_descriptors.c:43-46`):

```c
uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance) {
    // instance 0 = keyboard (desc_hid_report), instance 1 = raw upload
    // channel (desc_hid_report_raw) — TinyUSB numbers HID instances in
    // declaration order within desc_configuration below.
    return (instance == 1) ? desc_hid_report_raw : desc_hid_report;
}
```

- [ ] **Step 4: Add the second interface to the configuration descriptor**

Replace (`usb_descriptors.c:51-66`):

```c
enum { ITF_NUM_HID, ITF_NUM_RAWHID, ITF_NUM_TOTAL };

#define EPNUM_HID 0x81
#define EPNUM_RAWHID_OUT 0x02
#define EPNUM_RAWHID_IN  0x82

#define CONFIG_TOTAL_LEN (TUD_CONFIG_DESC_LEN + TUD_HID_DESC_LEN + TUD_HID_INOUT_DESC_LEN)

uint8_t const desc_configuration[] = {
    // Config: number, interface count, string index, total length, attribute, power (mA)
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, CONFIG_TOTAL_LEN,
                          TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP, 100),

    // Keyboard HID: string index, boot protocol, report descriptor len,
    //               EP In address, EP size, polling interval (ms)
    TUD_HID_DESCRIPTOR(ITF_NUM_HID, 0, HID_ITF_PROTOCOL_KEYBOARD,
                       sizeof(desc_hid_report), EPNUM_HID, CFG_TUD_HID_EP_BUFSIZE, 5),

    // Raw HID (keymap upload channel): vendor-defined, IN+OUT.
    TUD_HID_INOUT_DESCRIPTOR(ITF_NUM_RAWHID, 0, HID_ITF_PROTOCOL_NONE,
                             sizeof(desc_hid_report_raw), EPNUM_RAWHID_OUT, EPNUM_RAWHID_IN,
                             CFG_TUD_HID_EP_BUFSIZE, 5),
};
```

- [ ] **Step 5: Dispatch OUT reports on the raw HID interface**

Add a forward declaration near the top of the file (after the `#include "tusb.h"` line):

```c
void smk_keymap_dispatch_packet(const uint8_t *packet, uint8_t *response);
```

Replace `tud_hid_set_report_cb` (`usb_descriptors.c:119-124`):

```c
void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id,
                           hid_report_type_t report_type, uint8_t const *buffer,
                           uint16_t bufsize) {
    if (instance == 1 && bufsize >= 32) {
        uint8_t response[32];
        smk_keymap_dispatch_packet(buffer, response);
        tud_hid_n_report(1, 0, response, sizeof(response));
        return;
    }
    (void)report_id; (void)report_type;
}
```

- [ ] **Step 6: Verify it builds**

Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: build succeeds.

- [ ] **Step 7: Manual hardware smoke test (no host tool yet)**

Flash the board via BOOTSEL + `picotool load -f`. Confirm the keyboard still enumerates as a USB HID keyboard and types normally — full upload-channel verification happens in Task 11.

- [ ] **Step 8: Commit**

```bash
git add ports/rp2040/platform/tusb_config.h ports/rp2040/platform/usb_descriptors.c
git commit -m "Add USB raw HID keymap-upload channel (second HID interface)"
```

---

### Task 8: smk_configurator — upload protocol + CRC32 (TDD)

**Repo:** `~/esp/smk_configurator` (separate git repo from the firmware).

**Files:**
- Create: `Sources/SMKConfigurator/Device/KeymapUploadProtocol.swift`
- Create: `Sources/SMKConfigurator/Device/DeviceTransport.swift`
- Create: `Tests/SMKConfiguratorTests/KeymapUploadProtocolTests.swift`

**Interfaces:**
- Produces (used by Tasks 9-11):
  ```swift
  enum KeymapUploadProtocol {
      static let packetLength: Int
      static func begin(totalLen: UInt16) -> [UInt8]
      static func chunk(offset: UInt16, data: ArraySlice<UInt8>) -> [UInt8]
      static func commit(crc32: UInt32) -> [UInt8]
      static func erase() -> [UInt8]
      static func crc32(_ data: [UInt8]) -> UInt32
      static func isAck(_ response: [UInt8]) -> Bool
  }

  protocol DeviceTransport {
      func send(_ packet: [UInt8]) async throws -> [UInt8]
  }

  enum DeviceTransportError: Error {
      case noDeviceFound, nak, payloadTooLarge, encodingFailed
  }

  enum KeymapUploader {
      static func upload(json: String, using transport: DeviceTransport) async throws
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/SMKConfiguratorTests/KeymapUploadProtocolTests.swift`:

```swift
import Testing
@testable import SMKConfigurator

@Suite("KeymapUploadProtocol frames BEGIN/CHUNK/COMMIT/ERASE packets correctly")
struct KeymapUploadProtocolTests {
    @Test("begin() encodes opcode 0x01 and total length as u16 LE")
    func beginEncoding() {
        let packet = KeymapUploadProtocol.begin(totalLen: 0x0102)
        #expect(packet.count == 32)
        #expect(packet[0] == 0x01)
        #expect(packet[1] == 0x02)
        #expect(packet[2] == 0x01)
    }

    @Test("chunk() encodes opcode 0x02, offset, length, and data")
    func chunkEncoding() {
        let data: [UInt8] = [0xAA, 0xBB, 0xCC]
        let packet = KeymapUploadProtocol.chunk(offset: 0x0010, data: data[...])
        #expect(packet[0] == 0x02)
        #expect(packet[1] == 0x10)
        #expect(packet[2] == 0x00)
        #expect(packet[3] == 3)
        #expect(Array(packet[4..<7]) == data)
    }

    @Test("commit() encodes opcode 0x03 and crc32 as u32 LE")
    func commitEncoding() {
        let packet = KeymapUploadProtocol.commit(crc32: 0x04030201)
        #expect(packet[0] == 0x03)
        #expect(Array(packet[1...4]) == [0x01, 0x02, 0x03, 0x04])
    }

    @Test("erase() encodes opcode 0x04 with no payload")
    func eraseEncoding() {
        let packet = KeymapUploadProtocol.erase()
        #expect(packet[0] == 0x04)
        #expect(packet[1...].allSatisfy { $0 == 0 })
    }

    @Test("crc32 matches the known IEEE 802.3 test vector for \"123456789\"")
    func crc32KnownVector() {
        let bytes = Array("123456789".utf8)
        #expect(KeymapUploadProtocol.crc32(bytes) == 0xCBF43926)
    }

    @Test("isAck reads the status byte")
    func ackDetection() {
        #expect(KeymapUploadProtocol.isAck([0x00, 0x01]))
        #expect(!KeymapUploadProtocol.isAck([0x01, 0x01]))
    }
}

@Suite("KeymapUploader drives BEGIN/CHUNK.../COMMIT over a transport")
struct KeymapUploaderTests {
    final class MockTransport: DeviceTransport {
        var sent: [[UInt8]] = []
        var responses: [[UInt8]]
        init(responses: [[UInt8]]) { self.responses = responses }
        func send(_ packet: [UInt8]) async throws -> [UInt8] {
            sent.append(packet)
            return responses.isEmpty ? [0x00, 0x00] : responses.removeFirst()
        }
    }

    @Test("uploads a small JSON payload as BEGIN, one CHUNK, then COMMIT")
    func fullUpload() async throws {
        let json = #"{"layers":[]}"#
        let transport = MockTransport(responses: [])
        try await KeymapUploader.upload(json: json, using: transport)

        #expect(transport.sent.count == 3)
        #expect(transport.sent[0][0] == 0x01) // BEGIN
        #expect(transport.sent[1][0] == 0x02) // CHUNK
        #expect(transport.sent[2][0] == 0x03) // COMMIT

        let expectedCrc = KeymapUploadProtocol.crc32(Array(json.utf8))
        let sentCrcBytes = Array(transport.sent[2][1...4])
        let sentCrc = UInt32(sentCrcBytes[0]) | (UInt32(sentCrcBytes[1]) << 8) |
                      (UInt32(sentCrcBytes[2]) << 16) | (UInt32(sentCrcBytes[3]) << 24)
        #expect(sentCrc == expectedCrc)
    }

    @Test("throws .nak when the device NAKs any packet")
    func nakPropagates() async {
        let transport = MockTransport(responses: [[0x01, 0x01]]) // NAK on BEGIN
        await #expect(throws: DeviceTransportError.nak) {
            try await KeymapUploader.upload(json: "{}", using: transport)
        }
    }

    @Test("throws .payloadTooLarge for JSON exceeding the store's capacity")
    func payloadTooLarge() async {
        let json = String(repeating: "x", count: 4086)
        let transport = MockTransport(responses: [])
        await #expect(throws: DeviceTransportError.payloadTooLarge) {
            try await KeymapUploader.upload(json: json, using: transport)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeymapUploadProtocolTests`
Expected: FAIL — `KeymapUploadProtocol`, `DeviceTransport`, `KeymapUploader` don't exist yet.

- [ ] **Step 3: Write `Sources/SMKConfigurator/Device/KeymapUploadProtocol.swift`**

```swift
import Foundation

/// 32-byte packet framing for the BEGIN/CHUNK/COMMIT/ERASE keymap-upload
/// protocol shared with the firmware (Sources/componets/
/// smk_keymap_protocol.c in the SMK firmware repo). See
/// ~/esp/SMK/docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md.
enum KeymapUploadProtocol {
    static let packetLength = 32
    static let maxChunkDataLength = 28 // packetLength - 4-byte CHUNK header

    private enum Opcode: UInt8 {
        case begin = 0x01
        case chunk = 0x02
        case commit = 0x03
        case erase = 0x04
    }

    static func begin(totalLen: UInt16) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: packetLength)
        p[0] = Opcode.begin.rawValue
        p[1] = UInt8(totalLen & 0xFF)
        p[2] = UInt8((totalLen >> 8) & 0xFF)
        return p
    }

    static func chunk(offset: UInt16, data: ArraySlice<UInt8>) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: packetLength)
        p[0] = Opcode.chunk.rawValue
        p[1] = UInt8(offset & 0xFF)
        p[2] = UInt8((offset >> 8) & 0xFF)
        p[3] = UInt8(data.count)
        for (i, byte) in data.enumerated() {
            p[4 + i] = byte
        }
        return p
    }

    static func commit(crc32: UInt32) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: packetLength)
        p[0] = Opcode.commit.rawValue
        p[1] = UInt8(crc32 & 0xFF)
        p[2] = UInt8((crc32 >> 8) & 0xFF)
        p[3] = UInt8((crc32 >> 16) & 0xFF)
        p[4] = UInt8((crc32 >> 24) & 0xFF)
        return p
    }

    static func erase() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: packetLength)
        p[0] = Opcode.erase.rawValue
        return p
    }

    /// Standard bitwise IEEE 802.3 / zlib-compatible CRC32 (poly 0xEDB88320,
    /// init/final 0xFFFFFFFF) — implemented independently (no shared
    /// library) on both firmware platforms and here, matching by
    /// construction rather than by dependency.
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(bitPattern: crc & 1))
                crc = (crc >> 1) ^ (0xEDB88320 & mask)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    static func isAck(_ response: [UInt8]) -> Bool {
        response.first == 0x00
    }
}
```

- [ ] **Step 4: Write `Sources/SMKConfigurator/Device/DeviceTransport.swift`**

```swift
import Foundation

/// A channel that can carry one keymap-upload packet round trip. Two
/// concrete implementations: USBRawHIDTransport (IOKit HID, RP2040) and
/// BLETransport (CoreBluetooth, ESP32-C6) — see those files.
protocol DeviceTransport {
    func send(_ packet: [UInt8]) async throws -> [UInt8]
}

enum DeviceTransportError: Error, Equatable {
    case noDeviceFound
    case nak
    case payloadTooLarge
    case encodingFailed
}

/// Drives a full keymap upload (BEGIN, N x CHUNK, COMMIT) over any
/// DeviceTransport. Transport-agnostic — the same sequence works whether
/// bytes travel over USB raw HID or a BLE GATT characteristic.
enum KeymapUploader {
    /// Must match the firmware's SMK_KEYMAP_MAX_LEN (Sources/componets/
    /// smk_keymap_store.c / ports/rp2040/platform/smk_keymap_store.c).
    static let maxPayloadLength = 4085

    static func upload(json: String, using transport: DeviceTransport) async throws {
        let bytes = Array(json.utf8)
        guard bytes.count <= maxPayloadLength else {
            throw DeviceTransportError.payloadTooLarge
        }

        let beginResponse = try await transport.send(
            KeymapUploadProtocol.begin(totalLen: UInt16(bytes.count))
        )
        guard KeymapUploadProtocol.isAck(beginResponse) else {
            throw DeviceTransportError.nak
        }

        var offset = 0
        while offset < bytes.count {
            let end = min(offset + KeymapUploadProtocol.maxChunkDataLength, bytes.count)
            let response = try await transport.send(
                KeymapUploadProtocol.chunk(offset: UInt16(offset), data: bytes[offset..<end])
            )
            guard KeymapUploadProtocol.isAck(response) else {
                throw DeviceTransportError.nak
            }
            offset = end
        }

        let crc = KeymapUploadProtocol.crc32(bytes)
        let commitResponse = try await transport.send(KeymapUploadProtocol.commit(crc32: crc))
        guard KeymapUploadProtocol.isAck(commitResponse) else {
            throw DeviceTransportError.nak
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter KeymapUploadProtocolTests`
Expected: PASS (all cases in both suites).

- [ ] **Step 6: Commit**

```bash
git add Sources/SMKConfigurator/Device/KeymapUploadProtocol.swift Sources/SMKConfigurator/Device/DeviceTransport.swift Tests/SMKConfiguratorTests/KeymapUploadProtocolTests.swift
git commit -m "Add keymap-upload packet protocol and transport abstraction"
```

---

### Task 9: smk_configurator — USB raw HID transport (IOKit)

**Repo:** `~/esp/smk_configurator`

**Files:**
- Create: `Sources/SMKConfigurator/Device/USBRawHIDTransport.swift`
- Modify: `Package.swift` (link `IOKit`)

**Interfaces:**
- Consumes: `DeviceTransport`, `DeviceTransportError`, `KeymapUploadProtocol.packetLength` (Task 8).
- Produces:
  ```swift
  final class USBRawHIDTransport: DeviceTransport {
      init() throws
      func send(_ packet: [UInt8]) async throws -> [UInt8]
  }
  ```

- [ ] **Step 1: Add the IOKit framework to `Package.swift`**

Modify the `.executableTarget` in `Package.swift:11-17`:

```swift
        .executableTarget(
            name: "SMKConfigurator",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
```

- [ ] **Step 2: Write `Sources/SMKConfigurator/Device/USBRawHIDTransport.swift`**

```swift
import Foundation
import IOKit
import IOKit.hid

/// Talks to the RP2040 build's raw HID upload interface (vendor usage page
/// 0xFF00, usage 0x01 — see ports/rp2040/platform/usb_descriptors.c in the
/// SMK firmware repo) via IOKit's HID Manager.
final class USBRawHIDTransport: DeviceTransport {
    private static let vendorID = 0x16C0
    private static let productID = 0x05DF
    private static let usagePage = 0xFF00
    private static let usage = 0x01

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private let reportBufferLength = KeymapUploadProtocol.packetLength
    private var pendingContinuation: CheckedContinuation<[UInt8], Error>?
    private let queue = DispatchQueue(label: "USBRawHIDTransport")

    init() throws {
        reportBuffer = .allocate(capacity: reportBufferLength)
        reportBuffer.initialize(repeating: 0, count: reportBufferLength)

        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: Self.usagePage,
            kIOHIDPrimaryUsageKey: Self.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let matched = (IOHIDManagerCopyMatchingDevices(manager) as? Set<IOHIDDevice>)?.first
        else {
            reportBuffer.deallocate()
            throw DeviceTransportError.noDeviceFound
        }
        device = matched

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, reportBuffer, reportBufferLength,
            { context, _, _, _, _, report, length in
                guard let context else { return }
                let transport = Unmanaged<USBRawHIDTransport>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                transport.queue.async {
                    transport.pendingContinuation?.resume(returning: bytes)
                    transport.pendingContinuation = nil
                }
            },
            context
        )
    }

    deinit {
        reportBuffer.deallocate()
    }

    func send(_ packet: [UInt8]) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            queue.sync { self.pendingContinuation = continuation }
            let sendResult = packet.withUnsafeBufferPointer { ptr in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, ptr.baseAddress!, ptr.count)
            }
            if sendResult != kIOReturnSuccess {
                queue.sync { self.pendingContinuation = nil }
                continuation.resume(throwing: DeviceTransportError.noDeviceFound)
            }
        }
    }
}
```

Note: `reportBuffer` is a heap allocation held for the object's lifetime (not a stack/local buffer) — `IOHIDDeviceRegisterInputReportCallback` keeps writing to this exact address on every future input report, so a buffer that only lived for the duration of a `withUnsafeMutableBufferPointer` closure would leave IOKit writing through a dangling pointer the moment that closure returned.

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Manual hardware test**

With a Task 7-flashed RP2040 board connected over USB, run a short throwaway script (or a debugger breakpoint) instantiating `USBRawHIDTransport()` and calling `send(KeymapUploadProtocol.erase())` — confirm it returns an ACK (`[0x00, 0x04, ...]`) rather than throwing `.noDeviceFound`. Full exercise via the real UI happens in Task 11.

- [ ] **Step 5: Commit**

```bash
git add Sources/SMKConfigurator/Device/USBRawHIDTransport.swift Package.swift
git commit -m "Add IOKit HID transport for RP2040 keymap upload"
```

---

### Task 10: smk_configurator — BLE transport (CoreBluetooth) + UI wiring

**Repo:** `~/esp/smk_configurator`

**Files:**
- Create: `Sources/SMKConfigurator/Device/BLETransport.swift`
- Modify: `Package.swift` (link `CoreBluetooth`)
- Modify: `Sources/SMKConfigurator/Model/EditorState.swift` (add `sendToDevice()`)
- Modify: `Sources/SMKConfigurator/Views/ContentView.swift:162-204` (add toolbar button)

**Interfaces:**
- Consumes: `DeviceTransport`, `DeviceTransportError`, `KeymapUploader.upload` (Task 8), `USBRawHIDTransport` (Task 9), `EditorState.document` / `.loadError` (existing).
- Produces: `EditorState.sendToDevice()`, `EditorState.isSendingToDevice` — the user-facing feature.

- [ ] **Step 1: Add CoreBluetooth to `Package.swift`**

```swift
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreBluetooth"),
            ]
```

- [ ] **Step 2: Write `Sources/SMKConfigurator/Device/BLETransport.swift`**

```swift
import CoreBluetooth
import Foundation

/// Talks to the ESP32-C6 build's BLE HID Report ID 2 upload channel (see
/// Sources/componets/ble_helper.c in the SMK firmware repo) via
/// CoreBluetooth, using the standard HID-over-GATT service (0x1812) and the
/// Report Reference descriptor (0x2908) to find the right Report
/// characteristic among possibly several.
final class BLETransport: NSObject, DeviceTransport {
    private static let hidServiceUUID = CBUUID(string: "1812")
    private static let reportCharacteristicUUID = CBUUID(string: "2A4D")
    private static let reportReferenceDescriptorUUID = CBUUID(string: "2908")
    private static let targetReportID: UInt8 = 2

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var outputCharacteristic: CBCharacteristic?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var pendingContinuation: CheckedContinuation<[UInt8], Error>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Scans for, connects to, and locates the upload characteristic on the
    /// keyboard. Must complete before send(_:) is called.
    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.readyContinuation = continuation
            if central.state == .poweredOn {
                central.scanForPeripherals(withServices: [Self.hidServiceUUID])
            }
        }
    }

    func send(_ packet: [UInt8]) async throws -> [UInt8] {
        guard let peripheral, let outputCharacteristic else {
            throw DeviceTransportError.noDeviceFound
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
            peripheral.writeValue(Data(packet), for: outputCharacteristic, type: .withResponse)
        }
    }
}

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.hidServiceUUID])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        readyContinuation?.resume(throwing: DeviceTransportError.noDeviceFound)
        readyContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.hidServiceUUID])
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.hidServiceUUID }) else {
            readyContinuation?.resume(throwing: DeviceTransportError.noDeviceFound)
            readyContinuation = nil
            return
        }
        peripheral.discoverCharacteristics([Self.reportCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.reportCharacteristicUUID {
            peripheral.discoverDescriptors(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard let descriptor = characteristic.descriptors?.first(where: { $0.uuid == Self.reportReferenceDescriptorUUID }) else {
            return
        }
        peripheral.readValue(for: descriptor)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard let data = descriptor.value as? Data, data.first == Self.targetReportID,
              let characteristic = descriptor.characteristic
        else { return }
        outputCharacteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
        readyContinuation?.resume(returning: ())
        readyContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.reportCharacteristicUUID, let data = characteristic.value else { return }
        pendingContinuation?.resume(returning: Array(data))
        pendingContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            pendingContinuation?.resume(throwing: error)
            pendingContinuation = nil
        }
    }
}
```

- [ ] **Step 3: Add `sendToDevice()` to `EditorState`**

In `Sources/SMKConfigurator/Model/EditorState.swift`, add near the "Keymap file I/O" section (after `newDocument()`, around line 110):

```swift
    // MARK: - Device upload

    var isSendingToDevice: Bool = false

    /// Tries USB (RP2040) first, then BLE (ESP32-C6), and pushes
    /// document.layers to whichever responds. Matrix data isn't sent — the
    /// firmware's matrix stays compiled-in (see the design spec).
    func sendToDevice() {
        guard !isSendingToDevice else { return }
        isSendingToDevice = true
        Task {
            defer { isSendingToDevice = false }
            do {
                let json = try encodeLayersJSON(document.layers)
                if let usb = try? USBRawHIDTransport() {
                    try await KeymapUploader.upload(json: json, using: usb)
                } else {
                    let ble = BLETransport()
                    try await ble.connect()
                    try await KeymapUploader.upload(json: json, using: ble)
                }
            } catch {
                loadError = "Couldn't send keymap to device: \(error.localizedDescription)"
            }
        }
    }

    private func encodeLayersJSON(_ layers: [[[String]]]) throws -> String {
        struct LayersPayload: Encodable { let layers: [[[String]]] }
        let data = try JSONEncoder().encode(LayersPayload(layers: layers))
        guard let json = String(data: data, encoding: .utf8) else {
            throw DeviceTransportError.encodingFailed
        }
        return json
    }
```

- [ ] **Step 4: Add the toolbar button in `ContentView.swift`**

In the `toolbar` computed property (`ContentView.swift:162-204`), after the "Save As…" button and before the `Text(editor.fileURL?.path ...)` line:

```swift
            Button("Save As…") {
                Task { await saveAs() }
            }
            Button(editor.isSendingToDevice ? "Sending…" : "Send to Device") {
                editor.sendToDevice()
            }
            .disabled(editor.isSendingToDevice)
            Text(editor.fileURL?.path ?? "(unsaved)")
                .foregroundColor(.gray)
```

`editor.loadError` already drives an alert via the existing `.onChange(of: editor.loadError)` in `ContentView.body` (`ContentView.swift:37-43`) — reusing it for device-transport errors means no new alert plumbing is needed.

- [ ] **Step 5: Verify it builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 6: Manual UI test**

Run the app (`swift run`), click "Send to Device" with no keyboard connected, confirm the existing error-alert UI shows a "Couldn't send keymap to device: ..." message rather than crashing. Full success-path testing happens in Task 11 with real hardware.

- [ ] **Step 7: Commit**

```bash
git add Sources/SMKConfigurator/Device/BLETransport.swift Package.swift Sources/SMKConfigurator/Model/EditorState.swift Sources/SMKConfigurator/Views/ContentView.swift
git commit -m "Add BLE transport and \"Send to Device\" button"
```

---

### Task 11: End-to-end hardware verification

**Files:** none (verification only).

- [ ] **Step 1: RP2040 round trip**

Flash a Task 7-built RP2040 board. In `smk_configurator`, edit a key (e.g. change the top-left key's action away from `key:1`), click "Send to Device", confirm no error banner appears. Press the physical key and confirm the new action fires instead of the old one. Power-cycle the board and confirm the change survived reboot (the store, not just RAM, was written).

- [ ] **Step 2: RP2040 factory reset**

With a modified keymap active from Step 1, hold the physical top-left key while powering on the board. Confirm the keyboard reverts to the compiled default keymap (the key you remapped now does its original thing again).

- [ ] **Step 3: ESP32-C6 round trip**

Repeat Step 1 against a Task 6-built ESP32-C6 board over its existing BLE pairing.

- [ ] **Step 4: ESP32-C6 factory reset**

Repeat Step 2 against the ESP32-C6 board.

- [ ] **Step 5: Note any deviations**

If any step behaves differently than expected (wrong key remapped, upload silently fails, reset combo timing feels off), fix the relevant task's code before considering this plan complete — this task has no code of its own precisely because it's the final check on everything the other ten produced.
