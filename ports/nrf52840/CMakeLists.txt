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

# ---------------------------------------------------------------------------
# Board selection — same pattern as ports/rp2040/CMakeLists.txt's
# SMK_TARGET_BOARD, but with only two values so far. nrf52840dk (Nordic
# PCA10056, no bootloader — app owns all of flash from 0x0) is the default,
# matching this port's original build-only scope. feather_nrf52840 (Adafruit
# Feather nRF52840 Express) links against a different linker script because
# that board's factory UF2 bootloader + SoftDevice occupy the low end of
# flash — see linker/feather_nrf52840.ld's header comment for the address
# layout and why it must be confirmed against the real board before flashing.
# ---------------------------------------------------------------------------
set(SMK_TARGET_BOARD "nrf52840dk" CACHE STRING "nRF52840 board: nrf52840dk or feather_nrf52840")
if(SMK_TARGET_BOARD STREQUAL "feather_nrf52840")
    set(NRF52840_LINKER_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/linker/feather_nrf52840.ld")
    set(NRF52840_BOARD_DEFINE "SMK_BOARD_FEATHER_NRF52840")
elseif(SMK_TARGET_BOARD STREQUAL "nrf52840dk")
    set(NRF52840_LINKER_SCRIPT "${NRF5_MDK}/nrf52840_xxaa.ld")
    set(NRF52840_BOARD_DEFINE "SMK_BOARD_NRF52840DK")
else()
    message(FATAL_ERROR "Unknown SMK_TARGET_BOARD '${SMK_TARGET_BOARD}' — expected nrf52840dk or feather_nrf52840")
endif()

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
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -T${NRF52840_LINKER_SCRIPT} -L${NRF5_MDK}")

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
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeymapBinary.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/MacroPlayer.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeyCodesGenerated.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/AsciiKeycodes.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/HIDReportMap.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeyEventProcessing.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeymapFrame.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/LedPixelBuffer.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeymapProtocol.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/UsbHid.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/MpslGlue.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/KeymapStoreStub.swift"
    # Shared BTstack HID-over-GATT logic (GATT/SM/adv setup, packet handler,
    # send_keyboard_report) + this port's SDC transport bring-up
    # (BleHidSdc.swift) — platform/ble_hid_sdc.c keeps only the
    # asm-intrinsic HAL, the NRF_RNG entropy source, and the fault handler.
    "${CMAKE_CURRENT_SOURCE_DIR}/../common/BleHidGatt.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/BleHidSdc.swift"
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
            -D${NRF52840_BOARD_DEFINE}
            -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
            -wmo
            # One section per function, so the -Wl,--gc-sections link can
            # strip unused Swift (SMKCore compiles in whole, flat).
            -Xfrontend -function-sections
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
    # Shared across all TinyUSB/Embedded-Swift ports — see ports/common/
    ../common/usb_descriptors.c
    ../common/embedded_swift_glue.c
    # Instantiates profile_data[] from the generated smk_hid.h for the
    # shared BleHidGatt.swift's @_extern binding — see that file's comment.
    ../common/smk_hid_gatt_data.c
    "${NRF52840_CJSON_DIR}/cJSON.c"
)

add_executable(smk_nrf52840
    "${NRF5_MDK}/gcc_startup_nrf52840.S"
    "${NRF5_MDK}/system_nrf52840.c"
    ${c_srcs}
    "${swift_obj}"
)
target_include_directories(smk_nrf52840 PRIVATE "${NRF5_MDK}" "${NRF5_CMSIS_INCLUDE}" "${NRF52840_CJSON_DIR}")
target_compile_definitions(smk_nrf52840 PRIVATE INITIALIZE_USER_MEMORY_AREA ${NRF52840_BOARD_DEFINE})

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


# ---------------------------------------------------------------------------
# MPSL (Multiprotocol Service Layer) — required by the SoftDevice Controller
# (Task 7); bring-up/interrupt wiring done from Swift (MpslGlue.swift above)
# per this task's Swift-first preference. Prebuilt static lib, no headers
# needed at the C/Swift compile step (MpslGlue.swift declares the ABI it
# needs directly via @_extern(c, ...), same as UsbHid.swift does for
# TinyUSB, rather than importing mpsl.h through BridgingHeader.h).
# soft-float matches this project's armv7em-none-none-eabi Swift triple and
# -mfloat-abi=soft C/ASM flags (set above) — verified this exact path
# exists on disk under ${NRFXLIB_PATH}/mpsl/lib/nrf52/soft-float/libmpsl.a.
# ---------------------------------------------------------------------------
target_link_libraries(smk_nrf52840 PRIVATE "${NRFXLIB_PATH}/mpsl/lib/nrf52/soft-float/libmpsl.a")

# ---------------------------------------------------------------------------
# SoftDevice Controller HCI command dispatcher (Task 6) — Nordic's own
# hci_internal.c, vendored and adapted (Zephyr header deps replaced by
# sdc_bt_compat.h) rather than reimplemented from scratch; see
# platform/sdc_hci_dispatch.c's header comment. Not called from anywhere
# yet — Task 7 wires it up via the sdc_hci*.h-declared functions it calls
# and the hci_internal_cmd_put()/hci_internal_msg_get() it exposes. This
# step only proves the file compiles standalone.
# ---------------------------------------------------------------------------
target_include_directories(smk_nrf52840 PRIVATE "${NRFXLIB_PATH}/softdevice_controller/include")
target_sources(smk_nrf52840 PRIVATE platform/sdc_hci_dispatch.c)

# ---------------------------------------------------------------------------
# Task 7: SDC init + hci_transport_t + BTstack HID-over-GATT — wires the
# dispatcher above into a real init_ble_hid()/send_keyboard_report() pair.
# See platform/ble_hid_sdc.c's header comment for the transport shape; this
# is a near-verbatim adaptation of ports/rp2040/platform/ble_hid_kbd_uart.c
# with the CYW43439/UART transport bring-up replaced by SDC bring-up.
# ---------------------------------------------------------------------------

# Generate smk_hid.h from smk_hid.gatt (same GATT profile as the RP2040 BLE
# build — HID-over-GATT doesn't depend on transport). No pico-sdk here, so
# this drives btstack's own tool/compile_gatt.py directly instead of
# pico_btstack_make_gatt_header().
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(NRF52840_GATT_HEADER "${CMAKE_CURRENT_BINARY_DIR}/smk_hid.h")
add_custom_command(
    OUTPUT "${NRF52840_GATT_HEADER}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}"
    COMMAND ${Python3_EXECUTABLE} "${BTSTACK_PATH}/tool/compile_gatt.py"
            "${CMAKE_CURRENT_SOURCE_DIR}/platform/smk_hid.gatt"
            "${NRF52840_GATT_HEADER}"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/platform/smk_hid.gatt"
    COMMENT "Generating smk_hid.h (nRF52840)..."
    VERBATIM
)
add_custom_target(smk_nrf52840_gatt_header DEPENDS "${NRF52840_GATT_HEADER}")
add_dependencies(smk_nrf52840 smk_nrf52840_gatt_header)

target_include_directories(smk_nrf52840 PRIVATE
    "${BTSTACK_PATH}/src"
    "${BTSTACK_PATH}/platform/embedded"
    "${BTSTACK_PATH}/3rd-party/rijndael"   # rijndael.h — btstack_crypto.c's AES128 backend
    "${BTSTACK_PATH}/3rd-party/micro-ecc"  # uECC.h — btstack_crypto.c's ECC backend
    "${NRFXLIB_PATH}/mpsl/include"       # mpsl.h, mpsl_hwres.h (sdc_soc.h's #include chain)
    "${CMAKE_CURRENT_BINARY_DIR}"        # smk_hid.h lands here
)

# BTstack core (run loop, HCI/L2CAP/SM, generic memory pools) + the subset of
# BLE/GATT sources this app actually pulls in (att_db/att_server, LE device
# DB, SM, HID-over-GATT + battery + device-information GATT services).
# Cross-checked against pico-sdk's own pico_btstack_base/pico_btstack_ble
# library definitions (src/rp2_common/pico_btstack/CMakeLists.txt) — that
# list additionally builds in a large set of files this app never calls
# (classic-only pieces are irrelevant here since ENABLE_CLASSIC isn't set;
# ad_parser.c, btstack_hid.c (the higher-level HID-host driver — distinct
# from btstack_hid_parser.c below, which IS needed), gatt_client.c,
# le_device_db_tlv.c, hids_client.c and the other *_client.c GATT services,
# md5.c/yxml.c, TLV-on-flash persistence — all client-role, HID-host-role,
# or persistent-storage machinery this peripheral-only/no-persistence build
# doesn't use). Treated as a starting point, not gospel: any undefined
# symbol at link time gets a source file added here, per Step 5's
# instruction to resolve real gaps rather than stub around them — see
# btstack_hid_parser.c and libmpsl_fem_common.a below, both found that way.
target_sources(smk_nrf52840 PRIVATE
    "${BTSTACK_PATH}/src/btstack_util.c"
    "${BTSTACK_PATH}/src/btstack_linked_list.c"
    "${BTSTACK_PATH}/src/btstack_memory.c"
    "${BTSTACK_PATH}/src/btstack_memory_pool.c"
    "${BTSTACK_PATH}/src/btstack_run_loop.c"
    "${BTSTACK_PATH}/src/btstack_run_loop_base.c"
    "${BTSTACK_PATH}/src/btstack_tlv.c"
    "${BTSTACK_PATH}/src/btstack_tlv_none.c"
    "${BTSTACK_PATH}/src/btstack_crypto.c"
    "${BTSTACK_PATH}/src/hci.c"
    "${BTSTACK_PATH}/src/hci_cmd.c"
    "${BTSTACK_PATH}/src/hci_dump.c"
    "${BTSTACK_PATH}/src/hci_event.c"
    "${BTSTACK_PATH}/src/l2cap.c"
    "${BTSTACK_PATH}/src/l2cap_signaling.c"
    "${BTSTACK_PATH}/src/ble/att_db.c"
    "${BTSTACK_PATH}/src/ble/att_dispatch.c"
    "${BTSTACK_PATH}/src/ble/att_server.c"
    "${BTSTACK_PATH}/src/ble/le_device_db_memory.c"
    "${BTSTACK_PATH}/src/ble/sm.c"
    "${BTSTACK_PATH}/src/ble/gatt-service/hids_device.c"
    "${BTSTACK_PATH}/src/ble/gatt-service/battery_service_server.c"
    "${BTSTACK_PATH}/src/ble/gatt-service/device_information_service_server.c"
    "${BTSTACK_PATH}/platform/embedded/hci_dump_embedded_stdout.c"
    # Critical #2 fix-round finding: hci.c requires a real run loop
    # (btstack_run_loop_init()) before hci_init(), and something has to
    # pump it every tick — this is BTstack's own generic "embedded" run
    # loop, driven from platform_glue.c's vTaskDelay via
    # btstack_run_loop_embedded_execute_once(). See ble_hid_sdc.c's own
    # comment (next to its hal_time_ms()/hal_cpu_* implementations, which
    # this file requires) for the full story.
    "${BTSTACK_PATH}/platform/embedded/btstack_run_loop_embedded.c"
    "${BTSTACK_PATH}/3rd-party/rijndael/rijndael.c"     # AES (ENABLE_SOFTWARE_AES128)
    "${BTSTACK_PATH}/3rd-party/micro-ecc/uECC.c"        # ECC (ENABLE_MICRO_ECC_FOR_LE_SECURE_CONNECTIONS)
    # hids_device.c's variable-length-report path calls into the HID report
    # descriptor parser for report sizing (btstack_hid_get_report_size_for_id)
    # — found via a real undefined-symbol link error, not anticipated by the
    # plan's Step 3 source list (which only listed hids_device.c itself).
    "${BTSTACK_PATH}/src/btstack_hid_parser.c"
    platform/ble_hid_sdc.c
)
target_link_libraries(smk_nrf52840 PRIVATE
    "${NRFXLIB_PATH}/softdevice_controller/lib/nrf52/soft-float/libsoftdevice_controller_peripheral.a"
    # SDC's peripheral-role library calls into the generic Front-End-Module
    # (PA/LNA) runtime (mpsl_fem_enable/mpsl_fem_pa_configuration_set/etc.)
    # unconditionally, even though the nrf52840dk board has no external FEM
    # hardware wired up — found via undefined-symbol link errors, not
    # anticipated by the plan (which didn't mention FEM at all). This is
    # nrfxlib's own "no FEM" default implementation (as opposed to e.g.
    # libmpsl_fem_nrf21540_gpio.a for boards with a real nRF21540 PA/LNA
    # chip) — verified via nm against the prebuilt .a that it's the one
    # providing every one of the undefined mpsl_fem_* symbols the linker
    # reported.
    "${NRFXLIB_PATH}/mpsl/fem/common/lib/nrf52/soft-float/libmpsl_fem_common.a"
)
# See platform_glue.c's SMK_HAS_REAL_BLE_HID_SDC guard: disables that file's
# build-only init_ble_hid()/send_keyboard_report() stubs now that
# ble_hid_sdc.c provides the real definitions — without this, both files
# define the same C-linkage symbols and the link fails with a
# multiple-definition error. This define applies to the whole smk_nrf52840
# target (all its sources, including platform_glue.c), not just this
# translation unit.
target_compile_definitions(smk_nrf52840 PRIVATE SMK_HAS_REAL_BLE_HID_SDC)

add_custom_command(TARGET smk_nrf52840 POST_BUILD
    COMMAND arm-none-eabi-objcopy -O ihex $<TARGET_FILE:smk_nrf52840> smk_nrf52840.hex
    COMMENT "Generating smk_nrf52840.hex"
)

# ---------------------------------------------------------------------------
# UF2 packaging (feather_nrf52840 only) — this board's factory bootloader
# flashes via drag-and-drop UF2, not raw SWD. uf2conv.py/uf2families.json
# are vendored byte-identical from microsoft/uf2 (MIT-licensed, see
# tools/LICENSE.txt) — same "don't edit vendored files" policy as the
# STM32WB port's IPCC transport layer.
#
# --base MUST match linker/feather_nrf52840.ld's FLASH ORIGIN. Kept as a
# separate literal here (not derived from the .ld file) because CMake can't
# introspect a linker script's contents — if you change one, change both,
# and re-read that file's header comment about confirming the real
# SoftDevice/app-start offset against the board before flashing.
# ---------------------------------------------------------------------------
if(SMK_TARGET_BOARD STREQUAL "feather_nrf52840")
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    add_custom_command(TARGET smk_nrf52840 POST_BUILD
        COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tools/uf2conv.py"
                smk_nrf52840.hex
                --base 0x27000
                --family NRF52840
                --convert
                --output smk_nrf52840.uf2
        COMMENT "Generating smk_nrf52840.uf2 (Feather nRF52840 Express)"
    )
endif()
