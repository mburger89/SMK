set(swift_srcs
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/smk/Main.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/smk/LayerEngine.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/smk/KeyMatrix.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/smk/GPIORegisters.swift"
)

set(c_srcs
    "../Sources/componets/ble_helper.c"
    "../Sources/componets/gpio_init.c"
    "../Sources/componets/uart_init.c"
    "../Sources/componets/kb_main.c"
)

# Register C sources and linker fragment
idf_component_register(SRCS ${c_srcs}
                       INCLUDE_DIRS "../Sources/smk" "../Sources/componets"
                       REQUIRES esp_hid nvs_flash bt cjson driver esp_event esp_driver_uart esp_driver_gpio
                       LDFRAGMENTS "linker.lf")

# --- Swift Compilation Step ---

# Target triple for ESP32-C6 (RISC-V)
set(TARGET_TRIPLE "riscv32-none-none-eabi")
message(STATUS "Targeting triple: ${TARGET_TRIPLE}")

# Absolute path for bridging header
get_filename_component(bridging_header "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/smk/Bridging.h" ABSOLUTE)

# Locate Swift Compiler
if(NOT SWIFTC_PATH)
    # 1. Check if swiftc is in the environment
    if(DEFINED ENV{SWIFTC_PATH})
        set(SWIFTC_PATH "$ENV{SWIFTC_PATH}")
    endif()
endif()

if(NOT SWIFTC_PATH)
    # 2. Prioritize custom toolchains over system ones
    file(GLOB custom_toolchains "/Users/maxburger/Library/Developer/Toolchains/*.xctoolchain")
    foreach(toolchain ${custom_toolchains})
        if(EXISTS "${toolchain}/usr/bin/swiftc")
            set(TRY_SWIFTC "${toolchain}/usr/bin/swiftc")
            # Test if this compiler supports our target
            execute_process(COMMAND ${TRY_SWIFTC} -target ${TARGET_TRIPLE} -print-target-info
                            RESULT_VARIABLE target_ok
                            OUTPUT_QUIET ERROR_QUIET)
            if(target_ok EQUAL 0)
                set(SWIFTC_PATH "${TRY_SWIFTC}")
                break()
            endif()
        endif()
    endforeach()
endif()

if(NOT SWIFTC_PATH)
    # 3. Fallback to system swiftc
    find_program(SWIFTC_PATH swiftc)
endif()
message(STATUS "Using Swift compiler: ${SWIFTC_PATH}")


set(idf_p "${IDF_PATH}")
if(NOT idf_p)
    set(idf_p "$ENV{IDF_PATH}")
endif()

# Identify the RISC-V toolchain's include directory dynamically
get_filename_component(gcc_dir "${CMAKE_C_COMPILER}" DIRECTORY)
get_filename_component(toolchain_root "${gcc_dir}/.." ABSOLUTE)
set(RISCV_TOOLCHAIN_INCLUDE "${toolchain_root}/riscv32-esp-elf/include")

# Comprehensive include directories for Swift
set(include_dirs
    "${RISCV_TOOLCHAIN_INCLUDE}"
    "${CMAKE_BINARY_DIR}/config"
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/smk"
    "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/componets"
    "${idf_p}/components/esp_libc/platform_include"
    "${idf_p}/components/freertos/FreeRTOS-Kernel/include"
    "${idf_p}/components/freertos/FreeRTOS-Kernel/include/freertos"
    "${idf_p}/components/freertos/FreeRTOS-Kernel/portable/riscv/include"
    "${idf_p}/components/freertos/FreeRTOS-Kernel/portable/riscv/include/freertos"
    "${idf_p}/components/freertos/config/include"
    "${idf_p}/components/freertos/config/include/freertos"
    "${idf_p}/components/freertos/config/riscv/include"
    "${idf_p}/components/freertos/config/riscv/include/freertos"
    "${idf_p}/components/freertos/esp_additions/include"
    "${idf_p}/components/esp_hw_support/include"
    "${idf_p}/components/esp_hw_support/include/soc"
    "${idf_p}/components/esp_hw_support/port/esp32c6/include"
    "${idf_p}/components/heap/include"
    "${idf_p}/components/log/include"
    "${idf_p}/components/soc/include"
    "${idf_p}/components/soc/esp32c6/include"
    "${idf_p}/components/soc/esp32c6/register"
    "${idf_p}/components/hal/include"
    "${idf_p}/components/hal/esp32c6/include"
    "${idf_p}/components/hal/platform_port/include"
    "${idf_p}/components/esp_rom/include"
    "${idf_p}/components/esp_rom/esp32c6/include"
    "${idf_p}/components/esp_rom/esp32c6"
    "${idf_p}/components/esp_common/include"
    "${idf_p}/components/esp_system/include"
    "${idf_p}/components/esp_system/port/soc"
    "${idf_p}/components/esp_system/port/include/riscv"
    "${idf_p}/components/riscv/include"
    "${idf_p}/components/esp_hid/include"
    "${idf_p}/components/esp_event/include"
    "${idf_p}/components/driver/include"
    "${idf_p}/components/esp_driver_uart/include"
    "${idf_p}/components/esp_driver_gpio/include"
    "${idf_p}/components/esp_timer/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/../managed_components/espressif__cjson/cJSON"
)

set(swift_flags "")
foreach(dir ${include_dirs})
    # Don't check for existence here as some might be generated or paths might be slightly different at config time
    list(APPEND swift_flags "-Xcc" "-I${dir}")
    list(APPEND swift_flags "-I" "${dir}")
endforeach()

# Collect compile definitions
get_target_property(component_defines ${COMPONENT_LIB} COMPILE_DEFINITIONS)
if(component_defines)
    foreach(def ${component_defines})
        if(NOT "${def}" MATCHES ".*NOTFOUND")
            list(APPEND swift_flags "-Xcc" "-D${def}")
        endif()
    endforeach()
endif()

set(swift_obj "${CMAKE_CURRENT_BINARY_DIR}/smk_swift.o")

# Custom command to compile Swift files
add_custom_command(
    OUTPUT "${swift_obj}"
    COMMAND ${SWIFTC_PATH}
            -target "${TARGET_TRIPLE}"
            -Osize
            -static
            -enable-experimental-feature Embedded
            -enable-experimental-feature Extern
            -wmo
            -import-objc-header "${bridging_header}"
            ${swift_flags}
            "-Xcc" "-fno-pic"
            -emit-object
            -o "${swift_obj}"
            ${swift_srcs}
    DEPENDS ${swift_srcs} "${bridging_header}"
    COMMENT "Compiling SMK Swift sources..."
    VERBATIM
)

# Add the Swift object file to the component library
target_sources(${COMPONENT_LIB} PRIVATE "${swift_obj}")
