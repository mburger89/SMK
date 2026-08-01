cmake_minimum_required(VERSION 3.29)

# ---------------------------------------------------------------------------
# pico-sdk bootstrap — must happen before project()
# ---------------------------------------------------------------------------
if(NOT DEFINED ENV{PICO_SDK_PATH} AND NOT PICO_SDK_PATH)
    set(ENV{PICO_SDK_PATH} "$ENV{HOME}/pico-sdk")
endif()

include(${CMAKE_CURRENT_LIST_DIR}/pico_sdk_import.cmake)

# ---------------------------------------------------------------------------
# Swift toolchain discovery
# Prefer SWIFTC env/CMake var, then scan ~/Library/Developer/Toolchains for a
# toolchain that supports armv6m-none-none-eabi Embedded mode.
# ---------------------------------------------------------------------------
if(NOT SWIFTC_PATH OR NOT EXISTS "${SWIFTC_PATH}")
    if(DEFINED ENV{SWIFTC_PATH} AND EXISTS "$ENV{SWIFTC_PATH}")
        set(SWIFTC_PATH "$ENV{SWIFTC_PATH}" CACHE PATH "Path to swiftc")
    endif()
endif()

if(NOT SWIFTC_PATH OR NOT EXISTS "${SWIFTC_PATH}")
    set(_tc_dirs
        "$ENV{HOME}/Library/Developer/Toolchains"
        "/Library/Developer/Toolchains"
    )
    set(_probe_target "armv6m-none-none-eabi")
    foreach(_dir ${_tc_dirs})
        file(GLOB _tcs "${_dir}/*.xctoolchain")
        foreach(_tc ${_tcs})
            set(_sc "${_tc}/usr/bin/swiftc")
            if(EXISTS "${_sc}")
                execute_process(
                    COMMAND "${_sc}" -target ${_probe_target}
                            -enable-experimental-feature Embedded
                            -print-target-info
                    RESULT_VARIABLE _ok OUTPUT_QUIET ERROR_QUIET
                )
                if(_ok EQUAL 0)
                    set(SWIFTC_PATH "${_sc}" CACHE PATH "Path to swiftc")
                    break()
                endif()
            endif()
        endforeach()
        if(SWIFTC_PATH)
            break()
        endif()
    endforeach()
endif()

if(NOT SWIFTC_PATH OR NOT EXISTS "${SWIFTC_PATH}")
    message(FATAL_ERROR
        "Swift compiler (swiftc) supporting armv6m Embedded not found.\n"
        "Set SWIFTC_PATH to the path of a compatible swiftc, e.g.:\n"
        "  cmake -DSWIFTC_PATH=~/Library/Developer/Toolchains/"
        "swift-6.3.2-RELEASE.xctoolchain/usr/bin/swiftc ...")
endif()
message(STATUS "Using Swift compiler: ${SWIFTC_PATH}")

# Tell CMake where the Swift compiler is before project() / enable_language().
set(CMAKE_Swift_COMPILER "${SWIFTC_PATH}")
set(CMAKE_Swift_COMPILATION_MODE wholemodule)
# Skip the built-in Swift compiler detection (it tries to build a test program
# with the host compiler flags, which fails for bare-metal cross-compilation).
set(CMAKE_Swift_COMPILER_WORKS YES)

# ---------------------------------------------------------------------------
# Project
# ---------------------------------------------------------------------------
project(smk_rp2040 LANGUAGES C CXX ASM)

pico_sdk_init()
enable_language(Swift)

# ---------------------------------------------------------------------------
# Source files
# ---------------------------------------------------------------------------
set(SHARED_SWIFT_SRCS
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/Main.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/LayerEngine.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/KeyMatrix.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/GPIORegisters.swift"
)

set(PLATFORM_C_SRCS
    platform/gpio_init.c
    platform/usb_hid.c
    platform/usb_descriptors.c
    platform/platform_glue.c
    platform/ble_hid.c
    platform/smk_keymap_store.c
    # Portable cJSON (no ESP-IDF dependency)
    "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON/cJSON.c"
    # Shared upload-packet dispatch (see Sources/componets/smk_keymap_protocol.c)
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/componets/smk_keymap_protocol.c"
)

# ---------------------------------------------------------------------------
# Executable target
# ---------------------------------------------------------------------------
add_executable(smk_rp2040 ${SHARED_SWIFT_SRCS} ${PLATFORM_C_SRCS})

# pico-sdk provides C/C++ main by default; our main() is in platform_glue.c.
# Linker language must be CXX (pico-sdk requirement for Swift targets).
set_target_properties(smk_rp2040 PROPERTIES LINKER_LANGUAGE CXX)

# ---------------------------------------------------------------------------
# pico-sdk standard settings
# ---------------------------------------------------------------------------
# Enable USB stdio for kb_log() output (optional: disable for smaller binary).
pico_enable_stdio_usb(smk_rp2040 1)
pico_enable_stdio_uart(smk_rp2040 0)

# Emit .uf2 / .hex / .bin / .dis outputs alongside the ELF.
pico_add_extra_outputs(smk_rp2040)

# ---------------------------------------------------------------------------
# Link libraries — base set (both boards)
# ---------------------------------------------------------------------------
target_link_libraries(smk_rp2040
    pico_stdlib
    hardware_gpio
    hardware_flash
    hardware_sync
    tinyusb_device
    tinyusb_board
)

# ---------------------------------------------------------------------------
# Pico W: CYW43 + BTstack BLE HID (scaffolded)
# ---------------------------------------------------------------------------
if(PICO_BOARD STREQUAL "pico_w")
    message(STATUS "Building for Pico W — enabling CYW43 + BTstack BLE HID")

    # Generate smk_hid.h from smk_hid.gatt in the build directory.
    pico_btstack_make_gatt_header(smk_rp2040 PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/platform/smk_hid.gatt"
    )

    target_link_libraries(smk_rp2040
        pico_cyw43_arch_none      # CYW43 driver (no lwIP/network)
        pico_btstack_base
        pico_btstack_ble
    )

    # Expose the generated smk_hid.h to ble_hid.c, plus btstack_config.h.
    target_include_directories(smk_rp2040 PRIVATE
        "${CMAKE_CURRENT_BINARY_DIR}"    # smk_hid.h lands here
        "${CMAKE_CURRENT_SOURCE_DIR}/platform"
    )

    target_compile_definitions(smk_rp2040 PRIVATE SMK_ENABLE_BLE)
else()
    message(STATUS "Building for plain Pico — USB HID only, BLE stubs active")
endif()

# ---------------------------------------------------------------------------
# Include paths for C sources (cJSON, tusb_config.h, platform headers)
# ---------------------------------------------------------------------------
target_include_directories(smk_rp2040 PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/platform"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/componets"
)

# ---------------------------------------------------------------------------
# Fix pico_standard_link: strip C-only flags that swiftc rejects.
# (Mirrors the fix in the official swift-embedded-examples pico builds.)
# ---------------------------------------------------------------------------
set_target_properties(pico_standard_link PROPERTIES INTERFACE_COMPILE_OPTIONS "")
target_compile_options(pico_standard_link INTERFACE
    "$<$<COMPILE_LANGUAGE:C,CXX,ASM>:SHELL: -ffunction-sections -fdata-sections>"
)

# ---------------------------------------------------------------------------
# Propagate C compile definitions + implicit includes to swiftc.
# (Adapted from swift-embedded-examples/rpi-pico-blink-sdk/CMakeLists.txt)
# ---------------------------------------------------------------------------
set_property(GLOBAL PROPERTY _smk_visited_targets "")
set_property(GLOBAL PROPERTY _smk_defs "")

function(_smk_gather_defs target)
    get_property(_visited GLOBAL PROPERTY _smk_visited_targets)
    if(${target} MATCHES "\\$<" OR ${target} MATCHES "::@" OR ${target} IN_LIST _visited)
        return()
    endif()
    list(APPEND _visited ${target})
    set_property(GLOBAL PROPERTY _smk_visited_targets "${_visited}")

    get_target_property(_defs ${target} INTERFACE_COMPILE_DEFINITIONS)
    if(_defs)
        get_property(_all GLOBAL PROPERTY _smk_defs)
        list(APPEND _all ${_defs})
        set_property(GLOBAL PROPERTY _smk_defs "${_all}")
    endif()

    get_target_property(_libs ${target} INTERFACE_LINK_LIBRARIES)
    if(_libs)
        foreach(_lib ${_libs})
            _smk_gather_defs(${_lib})
        endforeach()
    endif()
endfunction()

_smk_gather_defs(smk_rp2040)

get_property(_compile_defs GLOBAL PROPERTY _smk_defs)
list(REMOVE_DUPLICATES _compile_defs)
list(PREPEND _compile_defs "")
string(REPLACE
    "$<TARGET_PROPERTY:PICO_TARGET_BINARY_TYPE>"
    "$<TARGET_PROPERTY:smk_rp2040,PICO_TARGET_BINARY_TYPE>"
    _compile_defs "${_compile_defs}"
)
string(REPLACE ";" " -Xcc -D" _compile_defs "${_compile_defs}")

# Implicit C/C++ include dirs (arm-none-eabi headers that swiftc also needs).
set(_implicit_incs "")
foreach(_dir ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES})
    string(CONCAT _implicit_incs ${_implicit_incs} "-Xcc -I${_dir} ")
endforeach()
foreach(_dir ${CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES})
    string(CONCAT _implicit_incs ${_implicit_incs} "-Xcc -I${_dir} ")
endforeach()

# ---------------------------------------------------------------------------
# Swift compiler flags
# ---------------------------------------------------------------------------
target_compile_options(smk_rp2040 PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:
        -target armv6m-none-none-eabi
        -enable-experimental-feature Embedded
        -enable-experimental-feature Extern
        -parse-as-library
        -module-name smk_rp2040
        -Xcc -mfloat-abi=soft
        -Xcc -fshort-enums
        -Xfrontend -function-sections
        -import-bridging-header ${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h
        ${_compile_defs}
        ${_implicit_incs}
    >"
)
