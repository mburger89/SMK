// swift-tools-version: 6.0
import PackageDescription
import Foundation

let home = ProcessInfo.processInfo.environment["HOME"] ?? "/Users/maxburger"
let idfPath = "\(home)/.espressif/v6.0.1/esp-idf"
let toolchainInclude = "\(home)/.espressif/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/riscv32-esp-elf/include"

let package = Package(
    name: "smk",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SMK", targets: ["smk"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-mmio", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "smk",
            dependencies: [
                .product(name: "MMIO", package: "swift-mmio")
            ],
            path: "Sources/smk",
            exclude: ["Bridging.h"],
            sources: ["Main.swift", "LayerEngine.swift", "KeyMatrix.swift", "GPIORegisters.swift"],
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
        ),
    ]
)
