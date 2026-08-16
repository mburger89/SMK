// swift-tools-version: 6.0
import PackageDescription
import Foundation

let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
// Repo root, derived from this file's own location rather than assuming
// ~/esp/smk — makes the LSP-only `smk` target below work from any clone
// path, not just this machine's.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// IDF_PATH matches the env var ESP-IDF's own export.sh sets (and that
// CMakeLists.txt already relies on — see README's "Scripts & Environment
// Variables"), so a normal `. $HOME/export-esp-idf.sh` is enough to pick
// this up; the hardcoded path below is only a fallback for whoever hasn't
// sourced it yet.
let idfPath = ProcessInfo.processInfo.environment["IDF_PATH"] ?? "\(home)/.espressif/v6.0.1/esp-idf"
// The ESP RISC-V GCC toolchain's own newlib headers (bundled by ESP-IDF's
// tool installer, not the Swift toolchain) — version-pinned by ESP-IDF
// itself, so this can't be derived from IDF_PATH alone. Override via
// SMK_ESP_TOOLCHAIN_INCLUDE if your installed tool version differs from
// the fallback below (check `~/.espressif/tools/riscv32-esp-elf/` for the
// exact directory name installed on your machine).
let toolchainInclude = ProcessInfo.processInfo.environment["SMK_ESP_TOOLCHAIN_INCLUDE"]
    ?? "\(home)/.espressif/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/riscv32-esp-elf/include"

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
        path: "Sources/CJSON",
        sources: ["cJSON.c"],
        publicHeadersPath: "include"
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
        path: "Sources/SMKCore",
        swiftSettings: [
            // These files also compile flat into every embedded target's
            // build. The host build is full Swift, so without this a
            // non-embeddable construct (weak, Codable, Mirror, ...) slips
            // through `swift test` and only fails days later in one of the
            // five cross builds. EmbeddedRestrictions surfaces it here.
            .unsafeFlags(["-Wwarning", "EmbeddedRestrictions"])
        ]
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
            sources: ["Main.swift", "KeyMatrix.swift", "GPIORegisters.swift", "RGBLighting.swift", "GPIOInit.swift", "SmkConfig.swift", "BatteryMonitor.swift"],
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
                    "-Xcc", "-I\(repoRoot)/managed_components/espressif__cjson/cJSON",
                    "-Xcc", "-I\(repoRoot)/build/config"
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
