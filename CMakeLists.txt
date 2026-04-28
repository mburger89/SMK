cmake_minimum_required(VERSION 3.16)

# Include the ESP-IDF build system
include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(my_swift_keyboard)

idf_component_register(SRCS
                       "Sources/smk/Main.swift"
                       "Sources/smk/LayerEngine.swift"
                       "Sources/smk/KeyMatrix.swift"
                       "Sources/smk/GPIORegisters.swift"
                       "Sources/componets/ble_helper.c"
                       "Sources/componets/gpio_init.c"
                       INCLUDE_DIRS "Sources/smk" "Sources/componets"
                       REQUIRES esp_hid nvs_flash bt json)

# Specific flags for Embedded Swift on ESP32-C6
target_compile_options(${COMPONENT_LIB} PRIVATE
                       "-target" "riscv32-none-elf"
                       "-O"
                       "-enable-experimental-feature" "Embedded"
                       "-enable-experimental-feature" "Extern"
                       "-wmo"
                       "-Xfrontend" "-disable-implicit-string-processing-module"
                       "-Xfrontend" "-disable-implicit-concurrency-module"
                       "-import-objc-header" "${CMAKE_CURRENT_SOURCE_DIR}/Sources/smk/Bridging.h")
