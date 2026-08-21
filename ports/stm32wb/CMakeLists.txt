cmake_minimum_required(VERSION 3.29)

# ---------------------------------------------------------------------------
# Vendor dependency paths (env vars, same pattern as PICO_SDK_PATH/NRF5_SDK_PATH
# and ports/stm32f4/CMakeLists.txt's CMSIS_F4_PATH/etc.)
# ---------------------------------------------------------------------------
if(NOT DEFINED ENV{CMSIS_WB_PATH})
    message(FATAL_ERROR "CMSIS_WB_PATH not set. See CLAUDE.md's STM32WB Prerequisites section.")
endif()
if(NOT DEFINED ENV{CMSIS_CORE_PATH})
    message(FATAL_ERROR "CMSIS_CORE_PATH not set. See CLAUDE.md's STM32WB Prerequisites section.")
endif()
if(NOT DEFINED ENV{TINYUSB_PATH})
    message(FATAL_ERROR "TINYUSB_PATH not set. See CLAUDE.md's STM32WB Prerequisites section.")
endif()
if(NOT DEFINED ENV{BTSTACK_PATH})
    message(FATAL_ERROR "BTSTACK_PATH not set. See CLAUDE.md's STM32WB Prerequisites section.")
endif()
if(NOT DEFINED ENV{STM32CUBEWB_PATH})
    message(FATAL_ERROR "STM32CUBEWB_PATH not set. See CLAUDE.md's STM32WB Prerequisites section.")
endif()
set(CMSIS_WB_PATH "$ENV{CMSIS_WB_PATH}")
set(CMSIS_CORE_PATH "$ENV{CMSIS_CORE_PATH}")
set(TINYUSB_PATH "$ENV{TINYUSB_PATH}")
set(BTSTACK_PATH "$ENV{BTSTACK_PATH}")
set(STM32CUBEWB_PATH "$ENV{STM32CUBEWB_PATH}")
set(CMSIS_WB_INCLUDE "${CMSIS_WB_PATH}/Include")
set(CMSIS_WB_GCC "${CMSIS_WB_PATH}/Source/Templates/gcc")
set(CMSIS_WB_TEMPLATES "${CMSIS_WB_PATH}/Source/Templates")
set(CMSIS_CORE_INCLUDE "${CMSIS_CORE_PATH}/CMSIS/Core/Include")
set(LINKER_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/linker/STM32WB55RGVx_FLASH.ld")

# Bare-metal cross-compile boilerplate: without CMAKE_SYSTEM_NAME set to a
# non-Darwin value, CMake's Platform/Darwin module assumes we're building a
# macOS host binary and silently injects -arch/-isysroot into every compile
# command, which arm-none-eabi-gcc rejects. Same fix ports/stm32f4/CMakeLists.txt
# (and ports/nrf52840/CMakeLists.txt before it) already needed — must come
# before project().
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

project(smk_stm32wb C ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_COMPILER arm-none-eabi-gcc)
set(CMAKE_ASM_COMPILER arm-none-eabi-gcc)
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -T${LINKER_SCRIPT}")

set(C_ASM_FLAGS
    -mcpu=cortex-m4
    -mthumb
    -mfloat-abi=soft
    -DSTM32WB55xx
    -DHSE_VALUE=32000000U
)
add_compile_options(${C_ASM_FLAGS})
# --specs=nosys.specs: same real finding from the STM32F4 port's Task 1 —
# apply it from the start here.
add_link_options(${C_ASM_FLAGS} --specs=nosys.specs -nostartfiles -Wl,--gc-sections)

# ---------------------------------------------------------------------------
# Swift toolchain discovery — same real-stdlib-typecheck probe pattern as
# ports/rp2040/CMakeLists.txt, ports/nrf52840/CMakeLists.txt, and
# ports/stm32f4/CMakeLists.txt. armv7em-none-none-eabi has a real stdlib on
# every currently-installed toolchain, so no board-keyed probe-target
# branching is needed here.
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

# swiftc's bundled ClangImporter has no idea where arm-none-eabi-gcc's own
# newlib headers live. Same fix ports/stm32f4/CMakeLists.txt (and
# ports/nrf52840/CMakeLists.txt before it) already needed — ask the real
# compiler directly via `-E -Wp,-v` on an empty source, which dumps its
# exact system include search path to stderr.
execute_process(
    COMMAND ${CMAKE_C_COMPILER} ${C_ASM_FLAGS} -E -Wp,-v -xc /dev/null
    ERROR_VARIABLE _stm32wb_gcc_include_dump
    OUTPUT_QUIET
)
string(REGEX MATCH "search starts here:\n(.*)\nEnd of search list" _stm32wb_gcc_include_match "${_stm32wb_gcc_include_dump}")
string(REGEX REPLACE "\n" ";" _stm32wb_gcc_include_lines "${CMAKE_MATCH_1}")
set(STM32WB_GCC_XCC_INCLUDES "")
foreach(_line ${_stm32wb_gcc_include_lines})
    string(STRIP "${_line}" _dir)
    if(_dir)
        list(APPEND STM32WB_GCC_XCC_INCLUDES "-Xcc" "-I${_dir}")
    endif()
endforeach()
if(NOT STM32WB_GCC_XCC_INCLUDES)
    message(FATAL_ERROR "Failed to determine arm-none-eabi-gcc's system include search path. Command output:\n${_stm32wb_gcc_include_dump}")
endif()

# ---------------------------------------------------------------------------
# Full shared application layer: Sources/smk (Main.swift's scan loop/config
# parsing, KeyMatrix.swift) + Sources/SMKCore (LayerEngine's cJSON-backed
# keymap parsing, HIDReport, Debounce, Modifier, ConnectionMode,
# KeyEventProcessing, KeymapFrame, KeymapProtocol) + this board's own
# GPIO/clock/keymap-store glue. No RGB (LEDChainMapping.swift/
# RGBLighting.swift/LedPixelBuffer.swift) — this board has no RGB chain.
# ---------------------------------------------------------------------------
set(swift_srcs
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/Main.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/KeyMatrix.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/ClockInit.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/GPIORegisters.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/GPIOInit.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/KeymapStoreStub.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/UsbHid.swift"
    # IPCC hardware layer for the vendored mailbox transport (Task 6). Not
    # called by anything yet — Task 7 wires up the real CPU2 boot sequence.
    # Swift rather than C (the brief left this open): every HW_IPCC_* entry
    # point is void(void) apart from one function-pointer argument, and the
    # two IRQ vectors are the same @_cdecl weak-symbol override this port's
    # UsbHid.swift already uses. See that file's header comment.
    "${CMAKE_CURRENT_SOURCE_DIR}/HwIpcc.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Modifier.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Debounce.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/ConnectionMode.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/HIDReport.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Config.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/LayerEngine.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeymapBinary.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeyCodesGenerated.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/AsciiKeycodes.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/HIDReportMap.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeyEventProcessing.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeymapFrame.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeymapProtocol.swift"
    # Shared BTstack HID-over-GATT logic (GATT/SM/adv setup, packet handler,
    # send_keyboard_report) — platform/ble_hid_wb.c keeps only the
    # IPCC/CPU2 transport bring-up and calls smk_ble_hid_gatt_setup().
    "${CMAKE_CURRENT_SOURCE_DIR}/../common/BleHidGatt.swift"
)

# cJSON (portable, no ESP-IDF dependency) — LayerEngine.swift/Config.swift
# parse JSON via cJSON_* calls imported through BridgingHeader.h's
# `#include "cJSON.h"`; matches the other four ports' use of the same
# vendored copy under managed_components/.
set(STM32WB_CJSON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON")

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
            -DSMK_TARGET_STM32WB
            -DSMK_BOARD_STM32WB_NUCLEO
            -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
            -wmo
            # One section per function, so the -Wl,--gc-sections link can
            # strip unused Swift (SMKCore compiles in whole, flat).
            -Xfrontend -function-sections
            -Xcc -mfloat-abi=soft
            -Xcc -mcpu=cortex-m4
            -Xcc -mthumb
            -Xcc -I${STM32WB_CJSON_DIR}
            ${STM32WB_GCC_XCC_INCLUDES}
            -emit-object
            -o "${swift_obj}"
            ${swift_srcs}
    DEPENDS ${swift_srcs} "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
    COMMENT "Compiling SMK Swift sources (STM32WB)..."
    VERBATIM
)

# ---------------------------------------------------------------------------
# IPCC mailbox transport layer (Task 6).
#
# platform/{tl.h,tl_mbox.c,mbox_def.h,hci_tl.c,hci_tl.h,hci_tl_if.c,
# shci_tl.c,shci_tl.h,shci_tl_if.c,shci.c,shci.h,stm_list.c,stm_list.h,
# stm32_wpan_common.h,hw.h} are vendored BYTE-FOR-BYTE from STM32CubeWB
# v1.24.0 (Middlewares/ST/STM32_WPAN/...); their ST copyright headers are
# preserved and no line of any of them was modified. Every adaptation this
# project needed lives instead in four small project-local headers that
# stand in for CubeMX-generated ones the vendored files #include:
# tl_dbg_conf.h, utilities_common.h, ble_common.h, ble_const.h — each
# carries a header comment explaining exactly what it replaces and why.
#
# platform/cortex_m_intrinsics.c is new (not vendored): the four CMSIS core
# intrinsics HwIpcc.swift can't bind to from Swift.
#
# Nothing calls any of this yet — this is the "prove it compiles and links
# standalone" scope, same as the nRF52840 port's own Task 6. Task 7 calls
# TL_Init()/TL_BLE_Init()/shci_init()/SHCI_C2_BLE_Init() for real.
#
# TASK 7 UPDATE — platform/hci_tl.c and platform/hci_tl_if.c are vendored on
# disk but deliberately NOT built. Two independent hard reasons, both found
# by reading the real vendored code (full write-up in ble_hid_wb.c's header
# comment):
#   1. hci_tl.c:68 defines `void hci_init(void(*)(void*), void*)`, colliding
#      with BTstack src/hci.c's `void hci_init(const hci_transport_t*,
#      const void*)`. Both are unconditionally in the link -> duplicate
#      symbol.
#   2. hci_tl.c:275-289 routes HCI Command Complete/Status events into a
#      private queue drained only by ST's own blocking hci_send_req() API,
#      which BTstack never calls — BTstack is the HCI host here and needs
#      every event.
# BTstack's own reference port for this exact chip makes the same call:
# ~/btstack/port/stm32-wb55xx-nucleo-freertos/Makefile:91-96 builds shci_tl.c,
# shci_tl_if.c, tl_mbox.c, shci.c and stm_list.c — and no hci_tl.c.
# Consequence: of the two application-layer callbacks Task 6 left
# deliberately unstubbed, only shci_notify_asynch_evt() still has a caller
# (shci_tl.c:127/142/230); it is implemented in ble_hid_wb.c.
# platform/ble_common.h and platform/ble_const.h existed solely to satisfy
# hci_tl.c's #includes and are now unused; left in place as part of Task 6's
# vendoring record.
set(stm32wb_ipcc_srcs
    platform/tl_mbox.c
    platform/stm_list.c
    platform/shci.c
    platform/shci_tl.c
    platform/shci_tl_if.c
    platform/cortex_m_intrinsics.c
)

set(c_srcs
    platform/platform_glue.c
    # Shared across all TinyUSB/Embedded-Swift ports — see ports/common/
    ../common/usb_descriptors.c
    ../common/embedded_swift_glue.c
    # Instantiates profile_data[] from the generated smk_hid.h for the
    # shared BleHidGatt.swift's @_extern binding — see that file's comment.
    ../common/smk_hid_gatt_data.c
    ${stm32wb_ipcc_srcs}
    "${STM32WB_CJSON_DIR}/cJSON.c"
)

add_executable(smk_stm32wb
    "${CMSIS_WB_GCC}/startup_stm32wb55xx_cm4.s"
    "${CMSIS_WB_TEMPLATES}/system_stm32wbxx.c"
    ${c_srcs}
    "${swift_obj}"
)
target_include_directories(smk_stm32wb PRIVATE "${CMSIS_WB_INCLUDE}" "${CMSIS_CORE_INCLUDE}" "${STM32WB_CJSON_DIR}")

# ---------------------------------------------------------------------------
# TinyUSB (device stack, HID class, fsdev driver) — the "wired" USB HID
# transport, glued from Swift (UsbHid.swift above) per this project's
# Swift-first preference; usb_descriptors.c stays C (macro-computed
# descriptor byte tables — see that file's header comment). fsdev is WB55's
# classic device-only "USB_FS" peripheral, a different (simpler, FS-only)
# driver than STM32F4's dwc2 OTG_FS core — confirmed present at this path in
# the vendored TinyUSB checkout during this task's implementation.
# ---------------------------------------------------------------------------
target_include_directories(smk_stm32wb PRIVATE
    "${TINYUSB_PATH}/src"
    platform
)
target_sources(smk_stm32wb PRIVATE
    "${TINYUSB_PATH}/src/tusb.c"
    "${TINYUSB_PATH}/src/common/tusb_fifo.c"
    "${TINYUSB_PATH}/src/device/usbd.c"
    "${TINYUSB_PATH}/src/class/hid/hid_device.c"
    "${TINYUSB_PATH}/src/portable/st/stm32_fsdev/dcd_stm32_fsdev.c"
    # fsdev_common.c: shared PMA/BTABLE helpers (fsdev_core_reset/fsdev_deinit/
    # btable_set_rx_bufsize/pma_align_buffer_size) that dcd_stm32_fsdev.c calls
    # into but doesn't itself define — found via a real "undefined reference"
    # link error during this task's implementation; the brief's snippet only
    # listed dcd_stm32_fsdev.c, which is the driver's dcd_* API surface but not
    # its whole translation unit set.
    "${TINYUSB_PATH}/src/portable/st/stm32_fsdev/fsdev_common.c"
)

# ---------------------------------------------------------------------------
# Task 7: CPU2 boot + hci_transport_t bridge + BTstack HID-over-GATT.
# See platform/ble_hid_wb.c's header comment for the transport design and for
# why the vendored hci_tl.c is not in the build.
# ---------------------------------------------------------------------------

# Generate smk_hid.h from smk_hid.gatt (byte-identical to the RP2040 and
# nRF52840 copies — HID-over-GATT doesn't depend on the transport under it).
# No pico-sdk here, so drive btstack's own tool/compile_gatt.py directly,
# same as ports/nrf52840/CMakeLists.txt.
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(STM32WB_GATT_HEADER "${CMAKE_CURRENT_BINARY_DIR}/smk_hid.h")
add_custom_command(
    OUTPUT "${STM32WB_GATT_HEADER}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}"
    COMMAND ${Python3_EXECUTABLE} "${BTSTACK_PATH}/tool/compile_gatt.py"
            "${CMAKE_CURRENT_SOURCE_DIR}/platform/smk_hid.gatt"
            "${STM32WB_GATT_HEADER}"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/platform/smk_hid.gatt"
    COMMENT "Generating smk_hid.h (STM32WB)..."
    VERBATIM
)
add_custom_target(smk_stm32wb_gatt_header DEPENDS "${STM32WB_GATT_HEADER}")
add_dependencies(smk_stm32wb smk_stm32wb_gatt_header)

# NOTE on include-path ordering (the warning Task 6 left in
# platform/{ble_common,ble_const,utilities_common,tl_dbg_conf}.h): BTstack's
# checkout also vendors a full ST HAL tree under
# ~/btstack/port/stm32-wb55xx-nucleo-freertos/Drivers/, whose Middlewares
# copy contains real ST headers with those same four filenames. Only
# ${BTSTACK_PATH}/src, /platform/embedded and /3rd-party/* are added below —
# nothing from that port/ subtree — so Task 6's stand-ins are not shadowed
# and the vendored .c files stay byte-identical to upstream.
target_include_directories(smk_stm32wb PRIVATE
    "${BTSTACK_PATH}/src"
    "${BTSTACK_PATH}/platform/embedded"
    "${BTSTACK_PATH}/3rd-party/rijndael"   # rijndael.h — btstack_crypto.c's AES128 backend
    "${BTSTACK_PATH}/3rd-party/micro-ecc"  # uECC.h — btstack_crypto.c's ECC backend
    "${CMAKE_CURRENT_BINARY_DIR}"          # smk_hid.h lands here
)

# BTstack source list: started as a verbatim copy of
# ports/nrf52840/CMakeLists.txt's (itself cross-checked against pico-sdk's
# pico_btstack_base/pico_btstack_ble), per the brief's "copy that list as a
# starting point, not gospel". It turned out to be exactly right for this
# port too — the transport underneath BTstack changed, the host-side source
# set did not — so no file had to be added or removed for undefined symbols.
target_sources(smk_stm32wb PRIVATE
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
    "${BTSTACK_PATH}/src/btstack_hid_parser.c"   # hids_device.c's report-size lookup
    "${BTSTACK_PATH}/platform/embedded/hci_dump_embedded_stdout.c"
    # Generic "embedded" run loop: hci.c needs a run loop installed before
    # hci_init(), and this port's transport hangs its polling data source off
    # it. Pumped from platform_glue.c's vTaskDelay via smk_ble_poll().
    "${BTSTACK_PATH}/platform/embedded/btstack_run_loop_embedded.c"
    "${BTSTACK_PATH}/3rd-party/rijndael/rijndael.c"     # AES (ENABLE_SOFTWARE_AES128)
    "${BTSTACK_PATH}/3rd-party/micro-ecc/uECC.c"        # ECC (ENABLE_MICRO_ECC_FOR_LE_SECURE_CONNECTIONS)
    platform/ble_hid_wb.c
)

# Disables platform_glue.c's Task-4 init_ble_hid()/send_keyboard_report()
# stubs now that ble_hid_wb.c defines them for real, and enables that file's
# smk_ble_poll() call in vTaskDelay. Applies to every source in the target,
# not just this line's neighbours — same mechanism as
# ports/nrf52840/CMakeLists.txt's SMK_HAS_REAL_BLE_HID_SDC.
target_compile_definitions(smk_stm32wb PRIVATE SMK_HAS_REAL_BLE_HID_WB)

add_custom_command(TARGET smk_stm32wb POST_BUILD
    COMMAND arm-none-eabi-objcopy -O binary $<TARGET_FILE:smk_stm32wb> smk_stm32wb.bin
    COMMENT "Generating smk_stm32wb.bin"
)
