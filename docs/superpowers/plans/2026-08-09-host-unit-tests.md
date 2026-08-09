# Host Unit Tests for Hardware-Independent Logic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract SMK's hardware-independent logic into `Sources/SMKCore/` and cover it with a host-side Swift Testing suite, runnable via `swift test` with no ESP-IDF/pico-sdk toolchain, plus CI.

**Architecture:** New `Sources/SMKCore/` directory holds plain Swift files with zero `@_extern`/hardware calls (JSON parsing, layer resolution, debounce, HID report building, connection-mode toggling, LED-chain math, and a new key-event-processing unit extracted from the main scan loop). The real embedded builds (`main/CMakeLists.txt`, `ports/rp2040/CMakeLists.txt`) add these files to their existing flat `swiftc -wmo` file lists — no module boundary, no behavior change, same as how `Main.swift`/`KeyMatrix.swift` already see each other's types today. `Package.swift` (IDE/LSP-only, never the real build — see CLAUDE.md) gains `SMKCore`/`SMKCoreTests`/`CJSON` targets, gated so `swift test` never touches the real `smk` executable target.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`), vendored cJSON (`managed_components/espressif__cjson`) compiled as a host SPM C target, GitHub Actions (`macos-latest`).

## Global Constraints

- Scope is 100% of hardware-independent logic only. GPIO config/scan, BLE, UART, RMT/PIO LED drivers, and Kconfig compile-time selection (`GPIOInit.swift`/`SmkConfig.swift`) are explicitly out of scope — no protocol/mock seams introduced for them in this plan.
- All 6 embedded targets (ESP32-C6, Pico, Pico W, Pico 2, Pico 2 W, smk_kbd_rp2040) must keep building clean after every extraction — this is the regression check that code motion didn't change firmware behavior.
- `swift test` must never require ESP-IDF, pico-sdk, or the Embedded Swift RISC-V toolchain — CI sets `SMK_HOST_TESTS_ONLY=1` to skip the `smk` executable target and swift-mmio dependency entirely.
- Extracted files are moved/split, not rewritten — behavior must stay byte-identical to what shipped before, except the one named addition: `KeyAction: Equatable` conformance (needed for tests, verified to be a behavior-neutral addition).
- No coverage-percentage tooling/threshold — out of scope per the approved design.

---

### Task 1: Host test harness — Package.swift restructure + first extraction (`Modifier`)

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/smk/KeyMatrix.swift` (remove `Modifier` enum, lines 1-23)
- Create: `Sources/SMKCore/Modifier.swift`
- Create: `Tests/SMKCoreTests/ModifierTests.swift`
- Create: `Tests/SMKCoreTests/CJSONSmokeTests.swift`
- Modify: `main/CMakeLists.txt` (add `Sources/SMKCore/Modifier.swift` to `swift_srcs`)
- Modify: `ports/rp2040/CMakeLists.txt` (add `Sources/SMKCore/Modifier.swift` to `SHARED_SWIFT_SRCS`)

**Interfaces:**
- Produces: `enum Modifier: UInt8` with cases `leftCtrl, leftShift, leftAlt, leftGUI, rightCtrl, rightShift, rightAlt, rightGUI` and a `rawValue` bit-mask — used by `HIDReport.addModifier` (Task 3) and `LayerEngine`'s `Modifier.fromCString` extension (Task 5).

- [ ] **Step 1: Move `Modifier` out of `KeyMatrix.swift` into `Sources/SMKCore/Modifier.swift`**

Read `Sources/smk/KeyMatrix.swift` lines 1-23 (the `enum Modifier` block) and delete them from that file, leaving `Sources/smk/KeyMatrix.swift` starting at what is currently line 25 (the `init_keyboard_pins` extern-declaration comment).

Create `Sources/SMKCore/Modifier.swift`:

```swift
enum Modifier: UInt8 {
    case leftCtrl
    case leftShift
    case leftAlt
    case leftGUI
    case rightCtrl
    case rightShift
    case rightAlt
    case rightGUI

    var rawValue: UInt8 {
        switch self {
        case .leftCtrl:   return 0b00000001
        case .leftShift:  return 0b00000010
        case .leftAlt:    return 0b00000100
        case .leftGUI:    return 0b00001000
        case .rightCtrl:  return 0b00010000
        case .rightShift: return 0b00100000
        case .rightAlt:   return 0b01000000
        case .rightGUI:   return 0b10000000
        }
    }
}
```

- [ ] **Step 2: Rewrite `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription
import Foundation

let home = ProcessInfo.processInfo.environment["HOME"] ?? "/Users/maxburger"
let idfPath = "\(home)/.espressif/v6.0.1/esp-idf"
let toolchainInclude = "\(home)/.espressif/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/riscv32-esp-elf/include"

// CI (and anyone who only wants the host-side SMKCore test suite) sets
// this so `swift build`/`swift test` never touch the `smk` executable
// target — it needs a real ESP-IDF checkout, the Embedded Swift RISC-V
// toolchain, and unsafe flags hardcoding this machine's paths, none of
// which exist on a CI runner. See
// docs/superpowers/specs/2026-08-09-host-unit-tests-design.md.
let hostTestsOnly = ProcessInfo.processInfo.environment["SMK_HOST_TESTS_ONLY"] != nil

var packageDependencies: [Package.Dependency] = []
if !hostTestsOnly {
    packageDependencies.append(.package(url: "https://github.com/apple/swift-mmio", branch: "main"))
}

var packageTargets: [Target] = [
    // Vendored cJSON (managed_components/espressif__cjson), compiled for
    // the host so SMKCore's JSON-parsing code (Config, LayerEngine) runs
    // in tests against the exact same parser the firmware ships.
    .target(
        name: "CJSON",
        path: "managed_components/espressif__cjson/cJSON",
        sources: ["cJSON.c"],
        publicHeadersPath: "."
    ),
    // Hardware-independent logic shared with the embedded build. NOT a
    // real module boundary for the embedded build — main/CMakeLists.txt
    // and ports/rp2040/CMakeLists.txt compile these files directly into
    // their flat swiftc invocation, same as Sources/smk's own files, no
    // `import` involved there. This target exists so `swift test` can
    // build and run them on the host.
    .target(
        name: "SMKCore",
        dependencies: ["CJSON"],
        path: "Sources/SMKCore"
    ),
    .testTarget(
        name: "SMKCoreTests",
        dependencies: ["SMKCore"],
        path: "Tests/SMKCoreTests"
    ),
]

if !hostTestsOnly {
    packageTargets.append(
        .executableTarget(
            name: "smk",
            dependencies: [
                .product(name: "MMIO", package: "swift-mmio")
            ],
            path: "Sources/smk",
            exclude: ["Bridging.h"],
            sources: ["Main.swift", "LayerEngine.swift", "KeyMatrix.swift", "GPIORegisters.swift", "RGBLighting.swift", "GPIOInit.swift", "SmkConfig.swift"],
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
                .unsafeFlags([
                    "-wmo",
                    "-Xfrontend", "-gnone",
                    "-import-objc-header", "Sources/smk/Bridging.h",
                    "-Xcc", "-I\(toolchainInclude)",
                    "-Xcc", "-I\(idfPath)/components/newlib/platform_include",
                    "-Xcc", "-I\(idfPath)/components/esp_libc/platform_include",
                    "-Xcc", "-I\(idfPath)/components/freertos/FreeRTOS-Kernel/include",
                    "-Xcc", "-I\(idfPath)/components/freertos/FreeRTOS-Kernel/include/freertos",
                    "-Xcc", "-I\(idfPath)/components/freertos/FreeRTOS-Kernel/portable/riscv/include",
                    "-Xcc", "-I\(idfPath)/components/freertos/FreeRTOS-Kernel/portable/riscv/include/freertos",
                    "-Xcc", "-I\(idfPath)/components/freertos/config/include",
                    "-Xcc", "-I\(idfPath)/components/freertos/config/include/freertos",
                    "-Xcc", "-I\(idfPath)/components/freertos/config/riscv/include",
                    "-Xcc", "-I\(idfPath)/components/freertos/config/riscv/include/freertos",
                    "-Xcc", "-I\(idfPath)/components/freertos/esp_additions/include",
                    "-Xcc", "-I\(idfPath)/components/esp_hw_support/include",
                    "-Xcc", "-I\(idfPath)/components/esp_hw_support/include/soc",
                    "-Xcc", "-I\(idfPath)/components/esp_hw_support/port/esp32c6/include",
                    "-Xcc", "-I\(idfPath)/components/heap/include",
                    "-Xcc", "-I\(idfPath)/components/log/include",
                    "-Xcc", "-I\(idfPath)/components/soc/include",
                    "-Xcc", "-I\(idfPath)/components/soc/esp32c6/include",
                    "-Xcc", "-I\(idfPath)/components/soc/esp32c6/register",
                    "-Xcc", "-I\(idfPath)/components/hal/include",
                    "-Xcc", "-I\(idfPath)/components/hal/esp32c6/include",
                    "-Xcc", "-I\(idfPath)/components/hal/platform_port/include",
                    "-Xcc", "-I\(idfPath)/components/esp_rom/include",
                    "-Xcc", "-I\(idfPath)/components/esp_rom/esp32c6/include",
                    "-Xcc", "-I\(idfPath)/components/esp_rom/include/esp32c6",
                    "-Xcc", "-I\(idfPath)/components/esp_common/include",
                    "-Xcc", "-I\(idfPath)/components/esp_system/include",
                    "-Xcc", "-I\(idfPath)/components/esp_system/port/include",
                    "-Xcc", "-I\(idfPath)/components/riscv/include",
                    "-Xcc", "-I\(idfPath)/components/esp_hid/include",
                    "-Xcc", "-I\(idfPath)/components/esp_event/include",
                    "-Xcc", "-I\(idfPath)/components/esp_driver_uart/include",
                    "-Xcc", "-I\(idfPath)/components/esp_driver_gpio/include",
                    "-Xcc", "-I\(idfPath)/components/nvs_flash/include",
                    "-Xcc", "-I\(idfPath)/components/bt/host/nimble/nimble/porting/nimble/include",
                    "-Xcc", "-I\(idfPath)/components/bt/host/nimble/nimble/nimble/host/include",
                    "-Xcc", "-I\(idfPath)/components/bt/host/nimble/nimble/nimble/include",
                    "-Xcc", "-I\(home)/esp/smk/managed_components/espressif__cjson/cJSON",
                    "-Xcc", "-I\(home)/esp/smk/build/config"
                ])
            ]
        )
    )
}

let package = Package(
    name: "smk",
    platforms: [.macOS(.v15)],
    products: hostTestsOnly ? [] : [
        .executable(name: "SMK", targets: ["smk"])
    ],
    dependencies: packageDependencies,
    targets: packageTargets
)
```

Note: `Sources/smk`'s `sources:` list is corrected here to include `RGBLighting.swift`, `GPIOInit.swift`, `SmkConfig.swift` — it was already missing these (pre-existing drift, unrelated to this plan) since Package.swift is IDE/LSP-only and easy to forget when adding new production files.

- [ ] **Step 3: Write the smoke tests**

Create `Tests/SMKCoreTests/ModifierTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func modifierRawValuesAreDistinctBitFlags() {
    #expect(Modifier.leftCtrl.rawValue == 0b00000001)
    #expect(Modifier.leftShift.rawValue == 0b00000010)
    #expect(Modifier.leftAlt.rawValue == 0b00000100)
    #expect(Modifier.leftGUI.rawValue == 0b00001000)
    #expect(Modifier.rightCtrl.rawValue == 0b00010000)
    #expect(Modifier.rightShift.rawValue == 0b00100000)
    #expect(Modifier.rightAlt.rawValue == 0b01000000)
    #expect(Modifier.rightGUI.rawValue == 0b10000000)
}
```

Create `Tests/SMKCoreTests/CJSONSmokeTests.swift` (validates the vendored-cJSON-as-host-C-target wiring the design flagged as an open risk, before any real code depends on it):

```swift
import Testing
import CJSON

@Test func cJSONParsesAndReadsASimpleObject() {
    let root = "{\"answer\": 42}".withCString { cJSON_Parse($0) }
    #expect(root != nil)
    defer { cJSON_Delete(root) }

    let answer = cJSON_GetObjectItem(root, "answer")
    #expect(answer != nil)
    #expect(answer?.pointee.valuedouble == 42)
}
```

- [ ] **Step 4: Update CMake source lists**

In `main/CMakeLists.txt`, in the `set(swift_srcs ...)` block, add a line right after the `Sources/smk/Main.swift` entry:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/SMKCore/Modifier.swift"
```

In `ports/rp2040/CMakeLists.txt`, in the `set(SHARED_SWIFT_SRCS ...)` block (around line 163), add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Modifier.swift"
```

- [ ] **Step 5: Run the host test suite**

Run: `SMK_HOST_TESTS_ONLY=1 swift test`
Expected: `Test Suite 'All tests' passed`, both `modifierRawValuesAreDistinctBitFlags` and `cJSONParsesAndReadsASimpleObject` pass, and no attempt is made to build the `smk` target or fetch swift-mmio.

- [ ] **Step 6: Verify the embedded build still compiles**

Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: build succeeds (this is the fastest of the 6 targets — full 6-target sweep happens in Task 9).

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/smk/KeyMatrix.swift Sources/SMKCore/Modifier.swift Tests/SMKCoreTests/ModifierTests.swift Tests/SMKCoreTests/CJSONSmokeTests.swift main/CMakeLists.txt ports/rp2040/CMakeLists.txt
git commit -m "Add SMKCore host test harness; extract Modifier"
```

---

### Task 2: Extract `Debounce.swift` (`DebouncedMatrix`)

**Files:**
- Modify: `Sources/smk/KeyMatrix.swift` (remove `struct DebouncedMatrix`)
- Create: `Sources/SMKCore/Debounce.swift`
- Create: `Tests/SMKCoreTests/DebounceTests.swift`
- Modify: `main/CMakeLists.txt`
- Modify: `ports/rp2040/CMakeLists.txt`

**Interfaces:**
- Produces: `struct DebouncedMatrix { init(totalKeys: Int); mutating func update(rawScan: [Bool]) -> [Bool] }` — counter-based debounce, 5 consecutive agreeing samples required to flip a key's stable state (used by `Main.swift`'s scan loop, unchanged call site).

- [ ] **Step 1: Move `DebouncedMatrix` out of `KeyMatrix.swift`**

Delete the `struct DebouncedMatrix { ... }` block (the last block in the file, after `struct KeyMatrix`) from `Sources/smk/KeyMatrix.swift`.

Create `Sources/SMKCore/Debounce.swift`:

```swift
struct DebouncedMatrix {
    private let totalKeys: Int
    private let debounceThreshold = 5

    private var counters: [Int]
    private var stableState: [Bool]

    init(totalKeys: Int) {
        self.totalKeys = totalKeys
        self.counters = [Int](repeating: 0, count: totalKeys)
        self.stableState = [Bool](repeating: false, count: totalKeys)
    }

    mutating func update(rawScan: [Bool]) -> [Bool] {
        for i in 0..<totalKeys {
            if i >= rawScan.count { break }
            if rawScan[i] != stableState[i] {
                counters[i] += 1
                if counters[i] >= debounceThreshold {
                    stableState[i] = rawScan[i]
                    counters[i] = 0
                }
            } else {
                counters[i] = 0
            }
        }
        return stableState
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/SMKCoreTests/DebounceTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func debounceRequiresFiveConsecutiveSamplesToFlip() {
    var matrix = DebouncedMatrix(totalKeys: 1)
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [true])
}

@Test func debounceBounceResetsCounter() {
    var matrix = DebouncedMatrix(totalKeys: 1)
    _ = matrix.update(rawScan: [true])
    _ = matrix.update(rawScan: [true])
    _ = matrix.update(rawScan: [true])
    _ = matrix.update(rawScan: [false]) // bounces back to the still-stable `false`, resets the counter
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [false])
    #expect(matrix.update(rawScan: [true]) == [true])
}

@Test func debounceAppliesSameThresholdOnRelease() {
    var matrix = DebouncedMatrix(totalKeys: 1)
    for _ in 0..<5 { _ = matrix.update(rawScan: [true]) }
    #expect(matrix.update(rawScan: [false]) == [true])
    #expect(matrix.update(rawScan: [false]) == [true])
    #expect(matrix.update(rawScan: [false]) == [true])
    #expect(matrix.update(rawScan: [false]) == [true])
    #expect(matrix.update(rawScan: [false]) == [false])
}

@Test func debounceTracksKeysIndependently() {
    var matrix = DebouncedMatrix(totalKeys: 2)
    for _ in 0..<5 { _ = matrix.update(rawScan: [true, false]) }
    #expect(matrix.update(rawScan: [true, false]) == [true, false])
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter DebounceTests`
Expected: all 4 tests PASS.

- [ ] **Step 4: Update CMake source lists**

In `main/CMakeLists.txt`'s `swift_srcs`, add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/SMKCore/Debounce.swift"
```

In `ports/rp2040/CMakeLists.txt`'s `SHARED_SWIFT_SRCS`, add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Debounce.swift"
```

- [ ] **Step 5: Verify the embedded build still compiles**

Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/smk/KeyMatrix.swift Sources/SMKCore/Debounce.swift Tests/SMKCoreTests/DebounceTests.swift main/CMakeLists.txt ports/rp2040/CMakeLists.txt
git commit -m "Extract DebouncedMatrix into SMKCore, add debounce tests"
```

---

### Task 3: Extract `ConnectionMode.swift` and `HIDReport.swift`

**Files:**
- Modify: `Sources/smk/Main.swift` (remove `enum ConnectionMode` and `struct HIDReport`)
- Create: `Sources/SMKCore/ConnectionMode.swift`
- Create: `Sources/SMKCore/HIDReport.swift`
- Create: `Tests/SMKCoreTests/ConnectionModeTests.swift`
- Create: `Tests/SMKCoreTests/HIDReportTests.swift`
- Modify: `main/CMakeLists.txt`
- Modify: `ports/rp2040/CMakeLists.txt`

**Interfaces:**
- Consumes: `Modifier` (Task 1, `SMKCore/Modifier.swift`).
- Produces: `enum ConnectionMode { case wired, bluetooth; mutating func toggle() }`; `struct HIDReport { var modifier: UInt8; var keys: [UInt8]; mutating func reset(); mutating func addKey(_ keycode: UInt8); mutating func addModifier(_ mod: Modifier) }`.

- [ ] **Step 1: Move both types out of `Main.swift`**

Delete the `enum ConnectionMode { ... }` block and the `struct HIDReport { ... }` block from `Sources/smk/Main.swift` (they currently sit between the `@_extern` declarations and `struct Config`).

Create `Sources/SMKCore/ConnectionMode.swift`:

```swift
enum ConnectionMode {
    case wired
    case bluetooth

    mutating func toggle() {
        if self == .wired {
            self = .bluetooth
        } else {
            self = .wired
        }
    }
}
```

Create `Sources/SMKCore/HIDReport.swift`:

```swift
struct HIDReport {
    var modifier: UInt8 = 0
    var keys: [UInt8] = [0, 0, 0, 0, 0, 0]

    mutating func reset() {
        modifier = 0
        for i in 0..<keys.count { keys[i] = 0 }
    }

    mutating func addKey(_ keycode: UInt8) {
        if keycode == 0 { return }
        for i in 0..<keys.count {
            if keys[i] == 0 {
                keys[i] = keycode
                return
            }
        }
    }

    mutating func addModifier(_ mod: Modifier) {
        modifier |= mod.rawValue
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/SMKCoreTests/ConnectionModeTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func connectionModeTogglesBetweenWiredAndBluetooth() {
    var mode = ConnectionMode.bluetooth
    mode.toggle()
    #expect(mode == .wired)
    mode.toggle()
    #expect(mode == .bluetooth)
}
```

Create `Tests/SMKCoreTests/HIDReportTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func hidReportAddKeyFillsFirstEmptySlot() {
    var report = HIDReport()
    report.addKey(0x04)
    report.addKey(0x05)
    #expect(report.keys == [0x04, 0x05, 0, 0, 0, 0])
}

@Test func hidReportAddKeyIgnoresZeroKeycode() {
    var report = HIDReport()
    report.addKey(0x00)
    #expect(report.keys == [0, 0, 0, 0, 0, 0])
}

@Test func hidReportAddKeyDropsBeyondSixSimultaneousKeys() {
    var report = HIDReport()
    for code: UInt8 in [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A] {
        report.addKey(code)
    }
    #expect(report.keys == [0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
}

@Test func hidReportResetClearsModifierAndKeys() {
    var report = HIDReport()
    report.addKey(0x04)
    report.addModifier(.leftShift)
    report.reset()
    #expect(report.modifier == 0)
    #expect(report.keys == [0, 0, 0, 0, 0, 0])
}

@Test func hidReportAddModifierOrsBits() {
    var report = HIDReport()
    report.addModifier(.leftShift)
    report.addModifier(.leftCtrl)
    #expect(report.modifier == Modifier.leftShift.rawValue | Modifier.leftCtrl.rawValue)
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter ConnectionModeTests`
Expected: PASS.
Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter HIDReportTests`
Expected: all 5 tests PASS.

- [ ] **Step 4: Update CMake source lists**

In `main/CMakeLists.txt`'s `swift_srcs`, add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/SMKCore/ConnectionMode.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/SMKCore/HIDReport.swift"
```

In `ports/rp2040/CMakeLists.txt`'s `SHARED_SWIFT_SRCS`, add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/ConnectionMode.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/HIDReport.swift"
```

- [ ] **Step 5: Verify the embedded build still compiles**

Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/smk/Main.swift Sources/SMKCore/ConnectionMode.swift Sources/SMKCore/HIDReport.swift Tests/SMKCoreTests/ConnectionModeTests.swift Tests/SMKCoreTests/HIDReportTests.swift main/CMakeLists.txt ports/rp2040/CMakeLists.txt
git commit -m "Extract ConnectionMode and HIDReport into SMKCore, add tests"
```

---

### Task 4: Extract `Config.swift`

**Files:**
- Modify: `Sources/smk/Main.swift` (remove `struct Config`)
- Create: `Sources/SMKCore/Config.swift`
- Create: `Tests/SMKCoreTests/ConfigTests.swift`
- Modify: `main/CMakeLists.txt`
- Modify: `ports/rp2040/CMakeLists.txt`

**Interfaces:**
- Consumes: `CJSON` (Task 1, vendored cJSON host target).
- Produces: `struct Config { var rowPins: [Int32]; var colPins: [Int32]; var colsAreDriven: Bool; static func fromJson(_ json: String) -> Config }`.

- [ ] **Step 1: Move `Config` out of `Main.swift`**

Delete the `struct Config { ... }` block from `Sources/smk/Main.swift`.

Create `Sources/SMKCore/Config.swift`:

```swift
import CJSON

struct Config {
    var rowPins: [Int32] = []
    var colPins: [Int32] = []
    var colsAreDriven: Bool = false

    static func fromJson(_ json: String) -> Config {
        var cfg = Config()
        guard let root = cJSON_Parse(json) else { return cfg }
        defer { cJSON_Delete(root) }

        if let matrix = cJSON_GetObjectItem(root, "matrix") {
            if let rows = cJSON_GetObjectItem(matrix, "rows") {
                for i in 0..<cJSON_GetArraySize(rows) {
                    if let item = cJSON_GetArrayItem(rows, i) {
                        cfg.rowPins.append(Int32(item.pointee.valuedouble))
                    }
                }
            }
            if let cols = cJSON_GetObjectItem(matrix, "cols") {
                for i in 0..<cJSON_GetArraySize(cols) {
                    if let item = cJSON_GetArrayItem(cols, i) {
                        cfg.colPins.append(Int32(item.pointee.valuedouble))
                    }
                }
            }
            if let driven = cJSON_GetObjectItem(matrix, "colsAreDriven") {
                cfg.colsAreDriven = driven.pointee.valuedouble != 0
            }
        }
        return cfg
    }
}
```

Note: the embedded build gets `cJSON_Parse`/etc. via `Sources/smk/Bridging.h`'s `#include "cJSON.h"` (unconditional whole-module import, no `import CJSON` needed or wanted there — adding one would break the flat embedded compile, which has no `CJSON` module). Since `Config.swift` moves into `Sources/SMKCore/` and gets compiled into the SAME flat embedded pass as before (just from a new path), it must NOT carry the `import CJSON` line into that build. Because Swift conditionally ignores an `import` for a module that isn't part of the current compilation *only in specific configurations*, don't rely on that — instead the embedded CMake invocations already put `-Xcc -I.../managed_components/espressif__cjson/cJSON` on the include path and pull in `cJSON.h` via the bridging header, so `cJSON_Parse` etc. are already visible there without any `import`. Confirm this by checking that `import CJSON` is guarded out for the embedded build in Step 2 below.

- [ ] **Step 2: Guard the `import CJSON` so it only applies to the host build**

Edit `Sources/SMKCore/Config.swift` from Step 1 to guard the import, since the real embedded build's flat `swiftc` invocation has no `CJSON` Swift module (only the C header via the bridging header) and would fail with "no such module 'CJSON'" if this import weren't skipped there:

```swift
#if canImport(CJSON)
import CJSON
#endif
```

Replace the plain `import CJSON` line at the top of `Sources/SMKCore/Config.swift` with the above. `#canImport` is a genuine Swift conditional-compilation check (unlike a plain `#if defined`-style macro check) and evaluates to false when compiling outside SPM's `CJSON` target, i.e. exactly the embedded CMake build.

- [ ] **Step 3: Write the failing tests**

Create `Tests/SMKCoreTests/ConfigTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func configParsesMatrixRowsColsAndColsAreDriven() {
    let json = """
    { "matrix": { "rows": [0, 1, 2], "cols": [3, 4], "colsAreDriven": 1 } }
    """
    let cfg = Config.fromJson(json)
    #expect(cfg.rowPins == [0, 1, 2])
    #expect(cfg.colPins == [3, 4])
    #expect(cfg.colsAreDriven == true)
}

@Test func configDefaultsColsAreDrivenToFalseWhenAbsent() {
    let json = """
    { "matrix": { "rows": [0], "cols": [1] } }
    """
    let cfg = Config.fromJson(json)
    #expect(cfg.colsAreDriven == false)
}

@Test func configReturnsEmptyPinsOnMalformedJson() {
    let cfg = Config.fromJson("not json")
    #expect(cfg.rowPins.isEmpty)
    #expect(cfg.colPins.isEmpty)
}

@Test func configReturnsEmptyPinsWhenMatrixKeyMissing() {
    let cfg = Config.fromJson("{}")
    #expect(cfg.rowPins.isEmpty)
    #expect(cfg.colPins.isEmpty)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter ConfigTests`
Expected: all 4 tests PASS.

- [ ] **Step 5: Update CMake source lists**

In `main/CMakeLists.txt`'s `swift_srcs`, add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/SMKCore/Config.swift"
```

In `ports/rp2040/CMakeLists.txt`'s `SHARED_SWIFT_SRCS`, add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Config.swift"
```

- [ ] **Step 6: Verify the embedded build still compiles (this is the real check for Step 2's `canImport` guard)**

Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: build succeeds — if `#if canImport(CJSON)` didn't correctly exclude the import, this fails with "no such module 'CJSON'".

- [ ] **Step 7: Commit**

```bash
git add Sources/smk/Main.swift Sources/SMKCore/Config.swift Tests/SMKCoreTests/ConfigTests.swift main/CMakeLists.txt ports/rp2040/CMakeLists.txt
git commit -m "Extract Config into SMKCore, add JSON parsing tests"
```

---

### Task 5: Extract `LayerEngine.swift` + host `kb_log` shim

**Files:**
- Delete: `Sources/smk/LayerEngine.swift` (moved, not copied)
- Create: `Sources/SMKCore/LayerEngine.swift` (same content, plus one conformance edit)
- Create: `Sources/SMKCore/Logging.swift`
- Create: `Tests/SMKCoreTests/LayerEngineTests.swift`
- Modify: `Package.swift` (remove `"LayerEngine.swift"` from the `smk` target's `sources:`)
- Modify: `main/CMakeLists.txt` (change the `LayerEngine.swift` path)
- Modify: `ports/rp2040/CMakeLists.txt` (change the `LayerEngine.swift` path)

**Interfaces:**
- Consumes: `Modifier` (Task 1), `CJSON`/`#if canImport(CJSON)` pattern (Task 4), host-only `kb_log` shim (this task).
- Produces: `enum KeyCode: UInt8`, `enum KeyAction: Equatable` (cases: `none, key(KeyCode), modifier(Modifier), momentaryLayer(Int), toggleLayer(Int), transparent, toggleConnection`), `struct LayerEngine { mutating func loadKeymap(json: String); mutating func loadKeymap(cJsonStr: UnsafePointer<Int8>); mutating func toggleLayer(_ layer: Int); mutating func addMomentaryLayer(_ layer: Int); mutating func removeMomentaryLayer(_ layer: Int); func isLayerActive(_ layer: Int) -> Bool; func getAction(row: Int, col: Int) -> KeyAction; private(set) var keymaps: [[[KeyAction]]] }` — used by `KeyEventProcessing` (Task 7).

- [ ] **Step 1: Move the file**

```bash
git mv Sources/smk/LayerEngine.swift Sources/SMKCore/LayerEngine.swift
```

- [ ] **Step 2: Add `Equatable` to `KeyAction` and guard the `CJSON` import**

In `Sources/SMKCore/LayerEngine.swift`, change:

```swift
enum KeyAction {
```

to:

```swift
enum KeyAction: Equatable {
```

(Verified behavior-neutral: enums without associated values already get `==` for free in Swift; `KeyAction` has associated values — `.key(KeyCode)`, `.modifier(Modifier)`, `.momentaryLayer(Int)`, `.toggleLayer(Int)` — so it needs this explicit conformance for `==` to compile at all. All its associated types — `KeyCode`, `Modifier`, `Int` — are themselves already `Equatable`, so this is a pure addition with no other code changes needed.)

At the top of the file, add the same guarded import Task 4 introduced, since `loadKeymap(cJsonStr:)` calls `cJSON_Parse`/`cJSON_GetObjectItem`/etc.:

```swift
#if canImport(CJSON)
import CJSON
#endif
```

- [ ] **Step 3: Add the host-only `kb_log` shim**

`LayerEngine.loadKeymap(cJsonStr:)` calls `kb_log("JSON Parse Error")` and `kb_log("Keymap loaded successfully")`. The real firmware gets `kb_log` from `Sources/smk/Main.swift`'s `@_extern(c, "kb_log")` declaration, resolved by the platform's C logging implementation. The host `SMKCore` build has no such C function linked, so it needs its own definition — but this file must **not** be added to either embedded CMake source list (Step 5), or the embedded build would get two conflicting definitions of `kb_log` (Main.swift's `@_extern` declaration and this one) in the same flat compile.

Create `Sources/SMKCore/Logging.swift`:

```swift
// Host-only shim for LayerEngine.swift's kb_log() calls. Real firmware
// builds get kb_log from Sources/smk/Main.swift's `@_extern(c, "kb_log")`
// declaration, resolved by the platform's C logging implementation
// (Sources/componets/kb_main.c on ESP32-C6, platform_glue.c on RP2040).
// This file exists only for the SMKCore/SMKCoreTests host build
// (Package.swift) and must NOT be added to main/CMakeLists.txt's or
// ports/rp2040/CMakeLists.txt's Swift source lists — doing so would give
// the embedded build two conflicting definitions of kb_log.
func kb_log(_ msg: UnsafePointer<Int8>) {
    // no-op on host — tests assert on return values/state, not log output.
}
```

- [ ] **Step 4: Write the failing tests**

Create `Tests/SMKCoreTests/LayerEngineTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func layerEngineLoadsBasicKeymapAndResolvesLayerZero() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a", "key:b"] ] ] }
    """)
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
    #expect(engine.getAction(row: 0, col: 1) == .key(.b))
}

@Test func layerEngineOutOfRangePositionReturnsNone() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ] ] }
    """)
    #expect(engine.getAction(row: 5, col: 5) == .none)
}

@Test func layerEngineLayerZeroIsAlwaysActive() {
    let engine = LayerEngine()
    #expect(engine.isLayerActive(0) == true)
}

@Test func layerEngineMomentaryLayerActivatesOnAddAndDeactivatesOnRemove() {
    var engine = LayerEngine()
    #expect(engine.isLayerActive(1) == false)
    engine.addMomentaryLayer(1)
    #expect(engine.isLayerActive(1) == true)
    engine.removeMomentaryLayer(1)
    #expect(engine.isLayerActive(1) == false)
}

@Test func layerEngineToggleLayerFlipsActiveState() {
    var engine = LayerEngine()
    engine.toggleLayer(2)
    #expect(engine.isLayerActive(2) == true)
    engine.toggleLayer(2)
    #expect(engine.isLayerActive(2) == false)
}

@Test func layerEngineTransparentFallsThroughToLowerActiveLayer() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ], [ ["trans"] ] ] }
    """)
    engine.addMomentaryLayer(1)
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
}

@Test func layerEngineHigherActiveLayerOverridesLower() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ], [ ["key:b"] ] ] }
    """)
    engine.addMomentaryLayer(1)
    #expect(engine.getAction(row: 0, col: 0) == .key(.b))
}

@Test func keyActionFromCStringParsesAllPrefixes() {
    #expect("none".withCString { KeyAction.fromCString($0) } == .none)
    #expect("trans".withCString { KeyAction.fromCString($0) } == .transparent)
    #expect("toggle_conn".withCString { KeyAction.fromCString($0) } == .toggleConnection)
    #expect("key:a".withCString { KeyAction.fromCString($0) } == .key(.a))
    #expect("mod:leftShift".withCString { KeyAction.fromCString($0) } == .modifier(.leftShift))
    #expect("mo:2".withCString { KeyAction.fromCString($0) } == .momentaryLayer(2))
    #expect("tg:3".withCString { KeyAction.fromCString($0) } == .toggleLayer(3))
    #expect("garbage".withCString { KeyAction.fromCString($0) } == .none)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter LayerEngineTests`
Expected: all 8 tests PASS.

- [ ] **Step 6: Update Package.swift and CMake source lists**

In `Package.swift`, remove `"LayerEngine.swift"` from the `smk` target's `sources:` array (it now reads `["Main.swift", "KeyMatrix.swift", "GPIORegisters.swift", "RGBLighting.swift", "GPIOInit.swift", "SmkConfig.swift"]`).

In `main/CMakeLists.txt`'s `swift_srcs`, change:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/smk/LayerEngine.swift"
```

to:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/SMKCore/LayerEngine.swift"
```

In `ports/rp2040/CMakeLists.txt`'s `SHARED_SWIFT_SRCS`, change:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/LayerEngine.swift"
```

to:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/LayerEngine.swift"
```

- [ ] **Step 7: Verify the embedded build still compiles**

Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
git add Sources/smk/LayerEngine.swift Sources/SMKCore/LayerEngine.swift Sources/SMKCore/Logging.swift Tests/SMKCoreTests/LayerEngineTests.swift Package.swift main/CMakeLists.txt ports/rp2040/CMakeLists.txt
git commit -m "Move LayerEngine into SMKCore, add host kb_log shim and tests"
```

---

### Task 6: Extract `LEDChainMapping.swift` (`ledChainIndex`)

**Files:**
- Modify: `Sources/smk/RGBLighting.swift` (remove `func ledChainIndex`)
- Create: `Sources/SMKCore/LEDChainMapping.swift`
- Create: `Tests/SMKCoreTests/LEDChainMappingTests.swift`
- Modify: `main/CMakeLists.txt`
- Modify: `ports/rp2040/CMakeLists.txt`

**Interfaces:**
- Produces: `func ledChainIndex(row: Int, col: Int, colCount: Int) -> Int`.

- [ ] **Step 1: Move `ledChainIndex` out of `RGBLighting.swift`**

Delete this block from `Sources/smk/RGBLighting.swift` (currently between the `@_extern` declarations and `struct RGBLighting`):

```swift
/// Chain position (0-indexed) of key (row, col) — must match
/// generate_pcb.py's `led_chain_index`.
func ledChainIndex(row: Int, col: Int, colCount: Int) -> Int {
    if row % 2 == 0 {
        return row * colCount + col
    } else {
        return row * colCount + (colCount - 1 - col)
    }
}
```

Create `Sources/SMKCore/LEDChainMapping.swift`:

```swift
/// Chain position (0-indexed) of key (row, col) — must match
/// generate_pcb.py's `led_chain_index`. The chain is wired
/// serpentine/boustrophedon: even rows run col 0->COLS-1, odd rows run
/// COLS-1->0, so chain-adjacent LEDs stay physically adjacent.
func ledChainIndex(row: Int, col: Int, colCount: Int) -> Int {
    if row % 2 == 0 {
        return row * colCount + col
    } else {
        return row * colCount + (colCount - 1 - col)
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/SMKCoreTests/LEDChainMappingTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func ledChainIndexEvenRowsRunLeftToRight() {
    #expect(ledChainIndex(row: 0, col: 0, colCount: 12) == 0)
    #expect(ledChainIndex(row: 0, col: 5, colCount: 12) == 5)
    #expect(ledChainIndex(row: 0, col: 11, colCount: 12) == 11)
}

@Test func ledChainIndexOddRowsRunRightToLeft() {
    #expect(ledChainIndex(row: 1, col: 0, colCount: 12) == 23)
    #expect(ledChainIndex(row: 1, col: 11, colCount: 12) == 12)
}

@Test func ledChainIndexStaysAdjacentAcrossRowBoundary() {
    // last LED of row 0 must be chain-adjacent to the first LED of row 1
    #expect(ledChainIndex(row: 0, col: 11, colCount: 12) == 11)
    #expect(ledChainIndex(row: 1, col: 11, colCount: 12) == 12)
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter LEDChainMappingTests`
Expected: all 3 tests PASS.

- [ ] **Step 4: Update CMake source lists**

`ledChainIndex`/`RGBLighting.swift` is unconditional on ESP32-C6 but conditional (`SMK_IS_KBD_RP2040` only) on RP2040 — match that.

In `main/CMakeLists.txt`'s `swift_srcs`, add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/SMKCore/LEDChainMapping.swift"
```

In `ports/rp2040/CMakeLists.txt`, inside the existing `if(SMK_IS_KBD_RP2040)` block that already appends `RGBLighting.swift` (around line 187), add:

```cmake
        "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/LEDChainMapping.swift"
```

so that block's `list(APPEND SHARED_SWIFT_SRCS ...)` now lists both `RGBLighting.swift` and `LEDChainMapping.swift`.

- [ ] **Step 5: Verify the embedded build still compiles (both the default board and the RGB-carrying board)**

Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: build succeeds.
Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh smk_kbd_rp2040`
Expected: build succeeds (this is the target that actually compiles `RGBLighting.swift`/`ledChainIndex`).

- [ ] **Step 6: Commit**

```bash
git add Sources/smk/RGBLighting.swift Sources/SMKCore/LEDChainMapping.swift Tests/SMKCoreTests/LEDChainMappingTests.swift main/CMakeLists.txt ports/rp2040/CMakeLists.txt
git commit -m "Extract ledChainIndex into SMKCore, add tests"
```

---

### Task 7: Extract `KeyEventProcessing.swift` from the main scan loop

**Files:**
- Modify: `Sources/smk/Main.swift` (rewrite the edge-processing section of `app_main_swift`'s loop)
- Create: `Sources/SMKCore/KeyEventProcessing.swift`
- Create: `Tests/SMKCoreTests/KeyEventProcessingTests.swift`
- Modify: `main/CMakeLists.txt`
- Modify: `ports/rp2040/CMakeLists.txt`

**Interfaces:**
- Consumes: `LayerEngine`, `KeyAction` (Task 5); `HIDReport` (Task 3); `ConnectionMode` (Task 3).
- Produces: `struct KeyPosition: Equatable { let row: Int; let col: Int }`; `struct KeyTransition: Equatable { let position: KeyPosition; let pressed: Bool }`; `struct KeyEventProcessingResult { var report: HIDReport; var transitions: [KeyTransition]; var connectionModeChanged: Bool; var connectionToggleIgnored: Bool }`; `func processKeyEvents(cleanScan: [Bool], lastScan: [Bool], colCount: Int, pressedActions: inout [KeyAction], engine: inout LayerEngine, hasWiredBridge: Bool, currentMode: inout ConnectionMode) -> KeyEventProcessingResult`.

`transitions` is a single list in original scan-index order (not split into separate press/release arrays) specifically so the caller can replay press/release RGB calls in the *exact* order the original inline loop made them — see Global Constraints: this task's extraction must stay byte-identical in behavior, not just in outcome.

This is genuinely new code (an extraction *and* restructuring, not a pure move), so it gets real TDD: tests first, verified to fail (function doesn't exist yet), then the implementation.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SMKCoreTests/KeyEventProcessingTests.swift`:

```swift
import Testing
@testable import SMKCore

@Test func keyEventProcessingBuildsReportForHeldKey() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a", "none"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.none, .none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true, false],
        lastScan: [false, false],
        colCount: 2,
        pressedActions: &pressedActions,
        engine: &engine,
        hasWiredBridge: false,
        currentMode: &currentMode
    )

    #expect(result.report.keys == [KeyCode.a.rawValue, 0, 0, 0, 0, 0])
    #expect(result.transitions == [KeyTransition(position: KeyPosition(row: 0, col: 0), pressed: true)])
}

@Test func keyEventProcessingClearsActionOnRelease() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["key:a"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.key(.a)]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [false],
        lastScan: [true],
        colCount: 1,
        pressedActions: &pressedActions,
        engine: &engine,
        hasWiredBridge: false,
        currentMode: &currentMode
    )

    #expect(pressedActions == [.none])
    #expect(result.transitions == [KeyTransition(position: KeyPosition(row: 0, col: 0), pressed: false)])
    #expect(result.report.keys == [0, 0, 0, 0, 0, 0])
}

@Test func keyEventProcessingMomentaryLayerActivatesWhileHeld() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["mo:1"] ], [ ["key:b"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    _ = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(engine.isLayerActive(1) == true)

    _ = processKeyEvents(
        cleanScan: [false], lastScan: [true], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(engine.isLayerActive(1) == false)
}

@Test func keyEventProcessingToggleLayerStaysActiveAfterRelease() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["tg:1"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    _ = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    _ = processKeyEvents(
        cleanScan: [false], lastScan: [true], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )
    #expect(engine.isLayerActive(1) == true)
}

@Test func keyEventProcessingTogglesConnectionModeWhenWiredBridgeAvailable() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["toggle_conn"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: true, currentMode: &currentMode
    )

    #expect(currentMode == .wired)
    #expect(result.connectionModeChanged == true)
    #expect(result.connectionToggleIgnored == false)
}

@Test func keyEventProcessingIgnoresConnectionToggleWithoutWiredBridge() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["toggle_conn"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true], lastScan: [false], colCount: 1,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )

    #expect(currentMode == .bluetooth)
    #expect(result.connectionModeChanged == false)
    #expect(result.connectionToggleIgnored == true)
}

@Test func keyEventProcessingAddsModifierBitsSeparatelyFromKeys() {
    var engine = LayerEngine()
    engine.loadKeymap(json: """
    { "layers": [ [ ["mod:leftShift", "key:a"] ] ] }
    """)
    var pressedActions: [KeyAction] = [.none, .none]
    var currentMode = ConnectionMode.bluetooth

    let result = processKeyEvents(
        cleanScan: [true, true], lastScan: [false, false], colCount: 2,
        pressedActions: &pressedActions, engine: &engine,
        hasWiredBridge: false, currentMode: &currentMode
    )

    #expect(result.report.modifier == Modifier.leftShift.rawValue)
    #expect(result.report.keys == [KeyCode.a.rawValue, 0, 0, 0, 0, 0])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter KeyEventProcessingTests`
Expected: FAIL to build — "cannot find 'processKeyEvents' in scope" / "cannot find type 'KeyPosition' in scope" (the type/function don't exist yet).

- [ ] **Step 3: Implement `KeyEventProcessing.swift`**

Create `Sources/SMKCore/KeyEventProcessing.swift`:

```swift
struct KeyPosition: Equatable {
    let row: Int
    let col: Int
}

struct KeyTransition: Equatable {
    let position: KeyPosition
    let pressed: Bool
}

struct KeyEventProcessingResult {
    var report = HIDReport()
    var transitions: [KeyTransition] = []
    var connectionModeChanged = false
    var connectionToggleIgnored = false
}

/// Processes one debounced scan cycle against the current layer/connection
/// state: resolves press/release transitions (mutating `pressedActions`
/// and `engine`'s momentary/toggled layer state in place), decides
/// whether a `toggle_conn` press should flip `currentMode` (only when
/// `hasWiredBridge`), and assembles the resulting HID report from
/// currently-held keys. Pure data in/out — no hardware or logging calls;
/// callers use `transitions` (in scan-index order, matching the original
/// inline loop) to drive RGB, and the two flags to drive logging.
func processKeyEvents(
    cleanScan: [Bool],
    lastScan: [Bool],
    colCount: Int,
    pressedActions: inout [KeyAction],
    engine: inout LayerEngine,
    hasWiredBridge: Bool,
    currentMode: inout ConnectionMode
) -> KeyEventProcessingResult {
    var result = KeyEventProcessingResult()

    for i in 0..<cleanScan.count {
        let row = i / colCount
        let col = i % colCount

        if cleanScan[i] && !lastScan[i] {
            let action = engine.getAction(row: row, col: col)
            pressedActions[i] = action
            result.transitions.append(KeyTransition(position: KeyPosition(row: row, col: col), pressed: true))

            switch action {
            case .toggleLayer(let l):
                engine.toggleLayer(l)
            case .momentaryLayer(let l):
                engine.addMomentaryLayer(l)
            case .toggleConnection:
                if hasWiredBridge {
                    currentMode.toggle()
                    result.connectionModeChanged = true
                } else {
                    result.connectionToggleIgnored = true
                }
            default:
                break
            }
        } else if lastScan[i] && !cleanScan[i] {
            let action = pressedActions[i]
            result.transitions.append(KeyTransition(position: KeyPosition(row: row, col: col), pressed: false))

            switch action {
            case .momentaryLayer(let l):
                engine.removeMomentaryLayer(l)
            default:
                break
            }
            pressedActions[i] = .none
        }
    }

    for i in 0..<cleanScan.count {
        if cleanScan[i] {
            switch pressedActions[i] {
            case .key(let code):
                result.report.addKey(code.rawValue)
            case .modifier(let mod):
                result.report.addModifier(mod)
            default:
                break
            }
        }
    }

    return result
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `SMK_HOST_TESTS_ONLY=1 swift test --filter KeyEventProcessingTests`
Expected: all 7 tests PASS.

- [ ] **Step 5: Rewire `Main.swift`'s loop to use `processKeyEvents`**

In `Sources/smk/Main.swift`, replace the entire `while true { ... }` block (everything from `while true {` through its closing `}`, i.e. steps "1. Process Edges", "2. Build and Send HID Report", "3. Dispatch Reports" and the `vTaskDelay(1)` at the end) with:

```swift
    while true {
        let rawScan = matrix.scan()
        let cleanScan = debouncer.update(rawScan: rawScan)

        let result = processKeyEvents(
            cleanScan: cleanScan,
            lastScan: lastScan,
            colCount: colCount,
            pressedActions: &pressedActions,
            engine: &engine,
            hasWiredBridge: hasWiredBridge,
            currentMode: &currentMode
        )
        lastScan = cleanScan
        report = result.report

        #if SMK_RGB_AVAILABLE
        for t in result.transitions {
            if t.pressed {
                rgb?.setKey(row: t.position.row, col: t.position.col, r: 255, g: 255, b: 255)
            } else {
                rgb?.setKey(row: t.position.row, col: t.position.col, r: 0, g: 0, b: 0)
            }
        }
        rgb?.refreshIfDirty()
        #endif

        if result.connectionModeChanged {
            kb_log(currentMode == .wired ? "Connection switched to: WIRED" : "Connection switched to: BLUETOOTH")
        } else if result.connectionToggleIgnored {
            kb_log("toggle_conn ignored: this board has no wired HID bridge")
        }

        report.keys.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                if currentMode == .bluetooth {
                    send_keyboard_report(report.modifier, base)
                } else {
                    send_wired_report(report.modifier, base)
                }
            }
        }

        vTaskDelay(1)
    }
```

This preserves the original call order exactly: `transitions` is appended to in the same single scan-index pass the original inline loop used, so replaying it in order reproduces the exact sequence of `rgb?.setKey(...)` calls the original code made — no reordering, matching the Global Constraints' byte-identical-behavior requirement.

- [ ] **Step 6: Update CMake source lists**

In `main/CMakeLists.txt`'s `swift_srcs`, add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/SMKCore/KeyEventProcessing.swift"
```

In `ports/rp2040/CMakeLists.txt`'s `SHARED_SWIFT_SRCS`, add:

```cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeyEventProcessing.swift"
```

- [ ] **Step 7: Verify the embedded build still compiles**

Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh pico`
Expected: build succeeds.
Run: `export PICO_SDK_PATH=~/pico-sdk && ./build_rp2040.sh smk_kbd_rp2040`
Expected: build succeeds (exercises the `#if SMK_RGB_AVAILABLE` branch of the rewritten loop).

- [ ] **Step 8: Commit**

```bash
git add Sources/smk/Main.swift Sources/SMKCore/KeyEventProcessing.swift Tests/SMKCoreTests/KeyEventProcessingTests.swift main/CMakeLists.txt ports/rp2040/CMakeLists.txt
git commit -m "Extract key-event edge processing from the scan loop into SMKCore, add tests"
```

---

### Task 8: CI workflow

**Files:**
- Create: `.github/workflows/host-tests.yml`

**Interfaces:** None (CI-only).

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/host-tests.yml`:

```yaml
name: SMKCore Host Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: macos-latest
    env:
      SMK_HOST_TESTS_ONLY: "1"
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Run SMKCore test suite
        run: swift test
```

- [ ] **Step 2: Verify locally that the exact CI command works from a clean state**

Run: `rm -rf .build && SMK_HOST_TESTS_ONLY=1 swift test`
Expected: dependency resolution touches only `CJSON`/`SMKCore`/`SMKCoreTests` (no swift-mmio fetch attempt), and all tests from Tasks 1-7 pass (30 tests total: 1 Modifier + 1 CJSON smoke + 4 Debounce + 1 ConnectionMode + 5 HIDReport + 4 Config + 8 LayerEngine + 3 LEDChainMapping + 7 KeyEventProcessing... wait, exact count doesn't matter, just confirm 0 failures).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/host-tests.yml
git commit -m "Add CI workflow for the SMKCore host test suite"
```

---

### Task 9: Final six-target build sweep + documentation

**Files:**
- Modify: `CLAUDE.md` (document `Sources/SMKCore/` and the test suite)

**Interfaces:** None.

- [ ] **Step 1: Build all six embedded targets**

Run:
```bash
source $(python3 -c "import os; print(os.path.expanduser('~/.espressif/v6.0.1/esp-idf/export.sh'))") > /dev/null 2>&1
idf.py -B build -C . build
```
Expected: ESP32-C6 build succeeds.

Run each of:
```bash
export PICO_SDK_PATH=~/pico-sdk
./build_rp2040.sh pico
./build_rp2040.sh pico_w
./build_rp2040.sh pico2
./build_rp2040.sh pico2_w
./build_rp2040.sh smk_kbd_rp2040
```
Expected: all 5 succeed.

- [ ] **Step 2: Update `CLAUDE.md`**

In the `### Shared Swift Sources (`Sources/smk/`) — compiled for ALL targets` section, add a new section immediately after it:

```markdown
### Hardware-Independent Sources (`Sources/SMKCore/`) — compiled for ALL targets, host-testable

Same flat-file-compilation treatment as `Sources/smk/` (added to `main/CMakeLists.txt`'s and `ports/rp2040/CMakeLists.txt`'s `swift_srcs` lists, no module boundary in the real build) — but these files have zero hardware/`@_extern` calls, so `Package.swift` also exposes them as a real `SMKCore` library target for host-side testing (`swift test`, no ESP-IDF/pico-sdk needed). See `docs/superpowers/specs/2026-08-09-host-unit-tests-design.md`.

| File | Responsibility |
|---|---|
| `Modifier.swift` | Modifier-key bit-flag enum |
| `Debounce.swift` | `DebouncedMatrix` — counter-based debounce (threshold=5) |
| `ConnectionMode.swift` | wired/bluetooth toggle |
| `HIDReport.swift` | HID report byte-building |
| `Config.swift` | matrix-config JSON parsing |
| `LayerEngine.swift` | keymap JSON loading, layer state, action resolution |
| `LEDChainMapping.swift` | serpentine row/col -> RGB chain-position mapping |
| `KeyEventProcessing.swift` | press/release edge detection, layer toggle/momentary add-remove, connection-toggle decision, HID report assembly — the scan loop calls this once per cycle |
| `Logging.swift` | host-only `kb_log` no-op shim (not compiled into the embedded build) |

Run the test suite: `SMK_HOST_TESTS_ONLY=1 swift test`.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document SMKCore in CLAUDE.md"
```

## Self-Review Notes

- **Spec coverage:** every `SMKCore` file the design lists has a task (Modifier/Debounce/ConnectionMode/HIDReport/Config/LayerEngine/LEDChainMapping/KeyEventProcessing all covered, Tasks 1-7); CI is Task 8; the six-target regression check and doc update are Task 9. The design's two open risks (cJSON SPM wiring, KeyEventProcessing behavioral fidelity) are addressed directly — Task 1 Step 3 spikes cJSON before anything depends on it, and Task 7's `KeyTransition` design (a single ordered list, not split press/release arrays) preserves the original scan loop's exact call order rather than needing a reordering exception.
- **Type consistency:** `KeyAction`, `KeyCode`, `Modifier`, `ConnectionMode`, `HIDReport`, `LayerEngine`, `KeyPosition` are used with identical names/signatures everywhere they appear across tasks (cross-checked against Task 5/7's exact source).
- **No placeholders:** every step has real, complete code — no TBD/TODO, no "write tests for the above" without the tests.
