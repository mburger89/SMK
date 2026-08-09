cmake_minimum_required(VERSION 3.29)

# ---------------------------------------------------------------------------
# Vendor dependency paths (env vars, same pattern as PICO_SDK_PATH)
# ---------------------------------------------------------------------------
if(NOT DEFINED ENV{NRF5_SDK_PATH})
    message(FATAL_ERROR "NRF5_SDK_PATH not set. See CLAUDE.md's nRF52840 Prerequisites section.")
endif()
if(NOT DEFINED ENV{NRFXLIB_PATH})
    message(FATAL_ERROR "NRFXLIB_PATH not set. See CLAUDE.md's nRF52840 Prerequisites section.")
endif()
if(NOT DEFINED ENV{TINYUSB_PATH})
    message(FATAL_ERROR "TINYUSB_PATH not set. See CLAUDE.md's nRF52840 Prerequisites section.")
endif()
if(NOT DEFINED ENV{BTSTACK_PATH})
    message(FATAL_ERROR "BTSTACK_PATH not set. See CLAUDE.md's nRF52840 Prerequisites section.")
endif()
set(NRF5_SDK_PATH "$ENV{NRF5_SDK_PATH}")
set(NRFXLIB_PATH "$ENV{NRFXLIB_PATH}")
set(TINYUSB_PATH "$ENV{TINYUSB_PATH}")
set(BTSTACK_PATH "$ENV{BTSTACK_PATH}")
set(NRF5_MDK "${NRF5_SDK_PATH}/modules/nrfx/mdk")
# nrf52840.h #includes core_cm4.h (the ARM CMSIS core header), which the nRF5
# SDK ships separately from modules/nrfx/mdk, under components/toolchain/cmsis.
set(NRF5_CMSIS_INCLUDE "${NRF5_SDK_PATH}/components/toolchain/cmsis/include")

# Bare-metal cross-compile boilerplate: without CMAKE_SYSTEM_NAME set to a
# non-Darwin value, CMake's Platform/Darwin module assumes we're building a
# macOS host binary and silently injects -arch/-isysroot into every compile
# command, which arm-none-eabi-gcc rejects. RP2040's pico-sdk toolchain file
# does the equivalent (CMAKE_SYSTEM_NAME PICO) via a CMAKE_TOOLCHAIN_FILE;
# since this project has no such preload toolchain file, it must be set
# directly, and it must come before project(). CMAKE_TRY_COMPILE_TARGET_TYPE
# is STATIC_LIBRARY because the default compiler-works check tries to link a
# full executable, which fails here without a valid entry point/linker script
# satisfied yet at that probe stage.
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

project(smk_nrf52840 C ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_COMPILER arm-none-eabi-gcc)
set(CMAKE_ASM_COMPILER arm-none-eabi-gcc)
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -T${NRF5_MDK}/nrf52840_xxaa.ld -L${NRF5_MDK}")

set(C_ASM_FLAGS
    -mcpu=cortex-m4
    -mthumb
    -mfloat-abi=soft
    -DNRF52840_XXAA
    -DCONFIG_GPIO_AS_PINRESET
    # gcc_startup_nrf52840.S's Reset_Handler calls __START (default: _start,
    # provided by libc's crt0) after SystemInit. We link with -nostartfiles
    # (no crt0), so redirect it straight to our own main().
    -D__START=main
)
add_compile_options(${C_ASM_FLAGS})
add_link_options(${C_ASM_FLAGS} -nostartfiles -Wl,--gc-sections)

# ---------------------------------------------------------------------------
# Swift toolchain discovery — same real-stdlib-typecheck probe pattern as
# ports/rp2040/CMakeLists.txt (see that file's comment for why
# -print-target-info alone isn't trustworthy). armv7em-none-none-eabi has a
# real stdlib on every currently-installed toolchain (verified during this
# port's feasibility spike, docs/superpowers/specs/2026-08-09-nrf52840-support-design.md),
# so no board-keyed probe-target branching is needed here, unlike RP2040's
# armv6m/armv8m.main split.
# ---------------------------------------------------------------------------
set(SMK_SWIFT_TARGET "armv7em-none-none-eabi")

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
    set(_smk_probe_src "${CMAKE_BINARY_DIR}/_smk_toolchain_probe.swift")
    file(WRITE "${_smk_probe_src}" "public func _smkToolchainProbe() {}\n")
    foreach(_dir ${_tc_dirs})
        file(GLOB _tcs "${_dir}/*.xctoolchain")
        foreach(_tc ${_tcs})
            set(_sc "${_tc}/usr/bin/swiftc")
            if(EXISTS "${_sc}")
                execute_process(
                    COMMAND "${_sc}" -target ${SMK_SWIFT_TARGET}
                            -enable-experimental-feature Embedded
                            -parse-as-library
                            -typecheck
                            "${_smk_probe_src}"
                    RESULT_VARIABLE _stdlib_ok OUTPUT_QUIET ERROR_QUIET
                )
                if(_stdlib_ok EQUAL 0)
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
        "Swift compiler (swiftc) supporting ${SMK_SWIFT_TARGET} Embedded (with a "
        "real stdlib for it) not found.\n"
        "Set SWIFTC_PATH to the path of a compatible swiftc, e.g.:\n"
        "  cmake -DSWIFTC_PATH=~/Library/Developer/Toolchains/"
        "<toolchain>.xctoolchain/usr/bin/swiftc ...")
endif()
message(STATUS "Using Swift compiler: ${SWIFTC_PATH}")

# ---------------------------------------------------------------------------
# Full shared application layer: Sources/smk (Main.swift's scan loop/config
# parsing, KeyMatrix.swift) + Sources/SMKCore (LayerEngine's cJSON-backed
# keymap parsing, HIDReport, Debounce, Modifier, ConnectionMode,
# KeyEventProcessing) + this board's own GPIO glue. No RGB
# (LEDChainMapping.swift/RGBLighting.swift) — this board has no RGB chain,
# same as plain Pico/Pico W. See ports/rp2040/CMakeLists.txt's
# SHARED_SWIFT_SRCS for the equivalent RP2040 list.
# ---------------------------------------------------------------------------
set(swift_srcs
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/Main.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/KeyMatrix.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/GPIORegisters.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/GPIOInit.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Modifier.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Debounce.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/ConnectionMode.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/HIDReport.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Config.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/LayerEngine.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeyEventProcessing.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/UsbHid.swift"
)

# cJSON (portable, no ESP-IDF dependency) — LayerEngine.swift/Config.swift
# parse JSON via cJSON_* calls imported through BridgingHeader.h's
# `#include "cJSON.h"`; matches ports/rp2040/CMakeLists.txt's use of the
# same vendored copy under managed_components/.
set(NRF52840_CJSON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON")

# swiftc's bundled ClangImporter (used both to precompile BridgingHeader.h
# and to satisfy its `#include <string.h>`/`<stdlib.h>` etc.) has no idea
# where arm-none-eabi-gcc's own libc (newlib) headers live — unlike
# ports/rp2040/CMakeLists.txt, which can lean on
# CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES (populated correctly there because
# pico-sdk's toolchain file makes CMake's C-compiler-works probe succeed
# against arm-none-eabi-gcc). Here that probe is unreliable (CMake's
# Generic-cross-compile C-language detection for this project falls back to
# probing the host AppleClang for its "identification" step — see Task 1's
# report — so CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES ends up pointing at
# Xcode's SDK, not arm-none-eabi's). Ask the real compiler directly instead:
# `-E -Wp,-v` on an empty source dumps its exact system include search path
# (newlib headers under the sysroot, plus GCC's own freestanding headers
# like stddef.h/stdint.h/stdarg.h) to stderr.
execute_process(
    COMMAND ${CMAKE_C_COMPILER} ${C_ASM_FLAGS} -E -Wp,-v -xc /dev/null
    ERROR_VARIABLE _nrf52840_gcc_include_dump
    OUTPUT_QUIET
)
string(REGEX MATCH "search starts here:\n(.*)\nEnd of search list" _nrf52840_gcc_include_match "${_nrf52840_gcc_include_dump}")
string(REGEX REPLACE "\n" ";" _nrf52840_gcc_include_lines "${CMAKE_MATCH_1}")
set(NRF52840_GCC_XCC_INCLUDES "")
foreach(_line ${_nrf52840_gcc_include_lines})
    string(STRIP "${_line}" _dir)
    if(_dir)
        list(APPEND NRF52840_GCC_XCC_INCLUDES "-Xcc" "-I${_dir}")
    endif()
endforeach()
if(NOT NRF52840_GCC_XCC_INCLUDES)
    message(FATAL_ERROR "Failed to determine arm-none-eabi-gcc's system include search path (needed by swiftc's ClangImporter for BridgingHeader.h). Command output:\n${_nrf52840_gcc_include_dump}")
endif()

set(swift_obj "${CMAKE_CURRENT_BINARY_DIR}/smk_swift.o")
add_custom_command(
    OUTPUT "${swift_obj}"
    COMMAND ${SWIFTC_PATH}
            -target ${SMK_SWIFT_TARGET}
            -Osize
            -static
            -enable-experimental-feature Embedded
            -enable-experimental-feature Extern
            -parse-as-library
            -DSMK_TARGET_NRF52840
            -DSMK_BOARD_NRF52840DK
            -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
            -wmo
            -Xcc -mfloat-abi=soft
            -Xcc -mcpu=cortex-m4
            -Xcc -mthumb
            -Xcc -I${NRF52840_CJSON_DIR}
            ${NRF52840_GCC_XCC_INCLUDES}
            -emit-object
            -o "${swift_obj}"
            ${swift_srcs}
    DEPENDS ${swift_srcs} "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
    COMMENT "Compiling SMK Swift sources (nRF52840)..."
    VERBATIM
)

set(c_srcs
    platform/platform_glue.c
    platform/smk_keymap_store.c
    platform/usb_descriptors.c
    "${NRF52840_CJSON_DIR}/cJSON.c"
    # Shared upload-packet dispatch (see Sources/componets/smk_keymap_protocol.c)
    # — usb_descriptors.c's smk_keymap_usb_service() calls
    # smk_keymap_dispatch_packet(), defined there; matches
    # ports/rp2040/CMakeLists.txt's PLATFORM_C_SRCS list.
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/componets/smk_keymap_protocol.c"
)

add_executable(smk_nrf52840
    "${NRF5_MDK}/gcc_startup_nrf52840.S"
    "${NRF5_MDK}/system_nrf52840.c"
    ${c_srcs}
    "${swift_obj}"
)
target_include_directories(smk_nrf52840 PRIVATE "${NRF5_MDK}" "${NRF5_CMSIS_INCLUDE}" "${NRF52840_CJSON_DIR}")
target_compile_definitions(smk_nrf52840 PRIVATE INITIALIZE_USER_MEMORY_AREA)

# ---------------------------------------------------------------------------
# TinyUSB (device stack, HID class, nRF5x device-controller driver) — the
# "wired" USB HID transport, glued from Swift (UsbHid.swift above) per this
# task's Swift-first preference; usb_descriptors.c stays C (macro-computed
# descriptor byte tables — see that file's header comment).
# ---------------------------------------------------------------------------
target_include_directories(smk_nrf52840 PRIVATE
    "${TINYUSB_PATH}/src"
    platform
    # dcd_nrf5x.c (the nRF5x device-controller driver) pulls in nrfx's clock
    # driver headers directly (nrfx_clock.h, nrf_erratas.h — the latter
    # already covered by NRF5_MDK above), which in turn need nrfx_config.h
    # and nrfx_glue.h — nrfx expects the *integrating app*, not the SDK, to
    # supply both. nrfx_config.h comes straight from the vendored SDK's own
    # per-chip template (modules/nrfx/templates/nRF52840/nrfx_config.h) —
    # TinyUSB's own hw/bsp/nrf/nrfx_config alternative targets a newer/
    # refactored nrfx (single flat templates/nrfx_config_<chip>.h) than the
    # one vendored in this nRF5 SDK release, so it 404s on that #include.
    # nrfx_glue.h is this project's own (platform/nrfx_glue.h, added to
    # PRIVATE include dirs above via "platform") — see that file's header
    # comment for why neither of the SDK's own two candidates was usable
    # as-is.
    "${NRF5_SDK_PATH}/modules/nrfx"
    "${NRF5_SDK_PATH}/modules/nrfx/drivers/include"
    "${NRF5_SDK_PATH}/modules/nrfx/hal"
    "${NRF5_SDK_PATH}/modules/nrfx/templates/nRF52840"
)
target_sources(smk_nrf52840 PRIVATE
    "${TINYUSB_PATH}/src/tusb.c"
    "${TINYUSB_PATH}/src/common/tusb_fifo.c"
    "${TINYUSB_PATH}/src/device/usbd.c"
    "${TINYUSB_PATH}/src/class/hid/hid_device.c"
    "${TINYUSB_PATH}/src/portable/nordic/nrf5x/dcd_nrf5x.c"
)

add_custom_command(TARGET smk_nrf52840 POST_BUILD
    COMMAND arm-none-eabi-objcopy -O ihex $<TARGET_FILE:smk_nrf52840> smk_nrf52840.hex
    COMMENT "Generating smk_nrf52840.hex"
)
