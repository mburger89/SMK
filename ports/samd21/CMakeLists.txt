cmake_minimum_required(VERSION 3.29)

# ---------------------------------------------------------------------------
# Vendor dependency paths. The SAMD21 device support (CMSIS headers +
# startup) ships inside TinyUSB's dependency tree — fetched with
#   cd $TINYUSB_PATH && python3 tools/get_deps.py samd2x_l2x
# — so only TINYUSB_PATH and CMSIS_CORE_PATH are needed (same ~/CMSIS_6
# checkout the STM32 ports use, for core_cm0plus.h).
# ---------------------------------------------------------------------------
if(NOT DEFINED ENV{TINYUSB_PATH})
    message(FATAL_ERROR "TINYUSB_PATH not set. See CLAUDE.md's SAMD21 Prerequisites section.")
endif()
if(NOT DEFINED ENV{CMSIS_CORE_PATH})
    message(FATAL_ERROR "CMSIS_CORE_PATH not set. See CLAUDE.md's SAMD21 Prerequisites section.")
endif()
set(TINYUSB_PATH "$ENV{TINYUSB_PATH}")
set(CMSIS_CORE_PATH "$ENV{CMSIS_CORE_PATH}")
set(SAMD21_SDK "${TINYUSB_PATH}/hw/mcu/microchip/samd21")
if(NOT EXISTS "${SAMD21_SDK}/include/samd21g18a.h")
    message(FATAL_ERROR
        "SAMD21 device support not found at ${SAMD21_SDK}.\n"
        "Fetch it with: cd ${TINYUSB_PATH} && python3 tools/get_deps.py samd2x_l2x")
endif()
set(SAMD21_INCLUDE "${SAMD21_SDK}/include")
set(CMSIS_CORE_INCLUDE "${CMSIS_CORE_PATH}/CMSIS/Core/Include")
# Vendored from TinyUSB's seeeduino_xiao board (Apache-2.0, Microchip ASF):
# rom ORIGIN at 0x2000 so the stock UF2 bootloader (first 8K) is preserved.
set(LINKER_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/linker/samd21g18a_xiao_flash.ld")

# Bare-metal cross-compile boilerplate — same as the other hand-rolled ports.
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

project(smk_samd21 C ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_COMPILER arm-none-eabi-gcc)
set(CMAKE_ASM_COMPILER arm-none-eabi-gcc)
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -T${LINKER_SCRIPT}")

set(C_ASM_FLAGS
    -mcpu=cortex-m0plus
    -mthumb
    -mfloat-abi=soft
    -D__SAMD21G18A__
)
add_compile_options(${C_ASM_FLAGS} -ffunction-sections -fdata-sections)
add_link_options(${C_ASM_FLAGS} --specs=nosys.specs -nostartfiles -Wl,--gc-sections)

# ---------------------------------------------------------------------------
# Swift toolchain discovery — same real-stdlib-typecheck probe as the other
# ports. armv6m (Cortex-M0+) is the same triple the RP2040 build uses, with
# a real stdlib on every released swift-6.3.x toolchain.
# ---------------------------------------------------------------------------
set(SMK_SWIFT_TARGET "armv6m-none-none-eabi")

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
        "Set SWIFTC_PATH to the path of a compatible swiftc.")
endif()
message(STATUS "Using Swift compiler: ${SWIFTC_PATH}")

# swiftc's ClangImporter needs arm-none-eabi-gcc's own newlib header paths —
# same probe as the other hand-rolled ports.
execute_process(
    COMMAND ${CMAKE_C_COMPILER} ${C_ASM_FLAGS} -E -Wp,-v -xc /dev/null
    ERROR_VARIABLE _samd21_gcc_include_dump
    OUTPUT_QUIET
)
string(REGEX MATCH "search starts here:\n(.*)\nEnd of search list" _samd21_gcc_include_match "${_samd21_gcc_include_dump}")
string(REGEX REPLACE "\n" ";" _samd21_gcc_include_lines "${CMAKE_MATCH_1}")
set(SAMD21_GCC_XCC_INCLUDES "")
foreach(_line ${_samd21_gcc_include_lines})
    string(STRIP "${_line}" _dir)
    if(_dir)
        list(APPEND SAMD21_GCC_XCC_INCLUDES "-Xcc" "-I${_dir}")
    endif()
endforeach()
if(NOT SAMD21_GCC_XCC_INCLUDES)
    message(FATAL_ERROR "Failed to determine arm-none-eabi-gcc's system include search path. Command output:\n${_samd21_gcc_include_dump}")
endif()

# ---------------------------------------------------------------------------
# Full shared application layer + this board's own glue. No RGB (no chain
# on a bare XIAO M0), no BLE (no radio on this chip, permanently).
# ---------------------------------------------------------------------------
set(swift_srcs
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/Main.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/KeyMatrix.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/ClockInit.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/GPIORegisters.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/GPIOInit.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/KeymapStoreStub.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/UsbHid.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/UartDebug.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Modifier.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Debounce.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/ConnectionMode.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/HIDReport.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/Config.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/LayerEngine.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeyEventProcessing.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeymapFrame.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/SMKCore/KeymapProtocol.swift"
)

set(SAMD21_CJSON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON")

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
            -DSMK_TARGET_SAMD21
            -DSMK_BOARD_XIAO_M0
            -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
            -wmo
            # One section per function, so the -Wl,--gc-sections link can
            # strip unused Swift (SMKCore compiles in whole, flat).
            -Xfrontend -function-sections
            -Xcc -mfloat-abi=soft
            -Xcc -mcpu=cortex-m0plus
            -Xcc -mthumb
            -Xcc -I${SAMD21_CJSON_DIR}
            ${SAMD21_GCC_XCC_INCLUDES}
            -emit-object
            -o "${swift_obj}"
            ${swift_srcs}
    DEPENDS ${swift_srcs} "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
    COMMENT "Compiling SMK Swift sources (SAMD21)..."
    VERBATIM
)

set(c_srcs
    platform/platform_glue.c
    # Shared across all TinyUSB/Embedded-Swift ports — see ports/common/
    ../common/usb_descriptors.c
    ../common/embedded_swift_glue.c
    # smk_cpu_nop() — the opaque call ClockInit.swift's register-poll loops
    # need so LLVM can't delete them.
    platform/cortex_m_intrinsics.c
    # armv6m has no LDREX/STREX — Swift's refcounting needs these helpers
    # (pico-sdk supplies them on RP2040; here we provide them ourselves).
    platform/armv6m_atomics.c
    "${SAMD21_CJSON_DIR}/cJSON.c"
)

add_executable(smk_samd21
    "${SAMD21_SDK}/gcc/gcc/startup_samd21.c"
    ${c_srcs}
    "${swift_obj}"
)
target_include_directories(smk_samd21 PRIVATE "${SAMD21_INCLUDE}" "${CMSIS_CORE_INCLUDE}" "${SAMD21_CJSON_DIR}")

# ---------------------------------------------------------------------------
# TinyUSB (device stack, HID class, microchip/samd driver) — the "wired"
# USB HID transport, glued from Swift (UsbHid.swift above). dcd_samd.c also
# performs the USB pad calibration from the factory fuses itself.
# ---------------------------------------------------------------------------
target_include_directories(smk_samd21 PRIVATE
    "${TINYUSB_PATH}/src"
    platform
)
target_sources(smk_samd21 PRIVATE
    "${TINYUSB_PATH}/src/tusb.c"
    "${TINYUSB_PATH}/src/common/tusb_fifo.c"
    "${TINYUSB_PATH}/src/device/usbd.c"
    "${TINYUSB_PATH}/src/class/hid/hid_device.c"
    "${TINYUSB_PATH}/src/portable/microchip/samd/dcd_samd.c"
)

add_custom_command(TARGET smk_samd21 POST_BUILD
    COMMAND arm-none-eabi-objcopy -O binary $<TARGET_FILE:smk_samd21> smk_samd21.bin
    COMMAND python3 "${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/bin2uf2.py"
            --base 0x2000 --family 0x68ed2b88
            smk_samd21.bin smk_samd21.uf2
    COMMENT "Generating smk_samd21.bin + smk_samd21.uf2"
)
