cmake_minimum_required(VERSION 3.29)

# ---------------------------------------------------------------------------
# Vendor dependency paths (env vars, same pattern as PICO_SDK_PATH/NRF5_SDK_PATH)
# ---------------------------------------------------------------------------
if(NOT DEFINED ENV{CMSIS_F4_PATH})
    message(FATAL_ERROR "CMSIS_F4_PATH not set. See CLAUDE.md's STM32F4 Prerequisites section.")
endif()
if(NOT DEFINED ENV{CMSIS_CORE_PATH})
    message(FATAL_ERROR "CMSIS_CORE_PATH not set. See CLAUDE.md's STM32F4 Prerequisites section.")
endif()
if(NOT DEFINED ENV{TINYUSB_PATH})
    message(FATAL_ERROR "TINYUSB_PATH not set. See CLAUDE.md's STM32F4 Prerequisites section.")
endif()
set(CMSIS_F4_PATH "$ENV{CMSIS_F4_PATH}")
set(CMSIS_CORE_PATH "$ENV{CMSIS_CORE_PATH}")
set(TINYUSB_PATH "$ENV{TINYUSB_PATH}")
set(CMSIS_F4_INCLUDE "${CMSIS_F4_PATH}/Include")
set(CMSIS_F4_GCC "${CMSIS_F4_PATH}/Source/Templates/gcc")
set(CMSIS_F4_TEMPLATES "${CMSIS_F4_PATH}/Source/Templates")
set(CMSIS_CORE_INCLUDE "${CMSIS_CORE_PATH}/CMSIS/Core/Include")
set(LINKER_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/linker/STM32F411CEUx_FLASH.ld")

# Bare-metal cross-compile boilerplate: without CMAKE_SYSTEM_NAME set to a
# non-Darwin value, CMake's Platform/Darwin module assumes we're building a
# macOS host binary and silently injects -arch/-isysroot into every compile
# command, which arm-none-eabi-gcc rejects. Same fix ports/nrf52840/CMakeLists.txt
# already needed (see that file's own comment) — must come before project().
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

project(smk_stm32f4 C ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_COMPILER arm-none-eabi-gcc)
set(CMAKE_ASM_COMPILER arm-none-eabi-gcc)
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -T${LINKER_SCRIPT}")

set(C_ASM_FLAGS
    -mcpu=cortex-m4
    -mthumb
    -mfloat-abi=soft
    -DSTM32F411xE
    -DHSE_VALUE=25000000U
    # Required for -Wl,--gc-sections (below) to actually prune anything:
    # gc-sections operates at the granularity of one linker section per
    # symbol, which only exists if each function/data object was compiled
    # into its own section in the first place. Without these two, GCC
    # defaults to one .text/.data section per FILE, so gc-sections had
    # nothing finer-grained to collect and was a no-op against this
    # build-only target's 512KB flash budget.
    -ffunction-sections
    -fdata-sections
)
add_compile_options(${C_ASM_FLAGS})
# --specs=nosys.specs: newlib's always-fails syscall stubs (_exit/_sbrk/
# _write/_read/_close/_lseek/_kill/_getpid/_fstat/_isatty). Needed once any
# libc object pulls in __libc_init_array's transitive dependents — found via
# a real link error during Task 1 (posix_memalign/_init still need their own
# stubs, see platform_glue.c, since neither is part of nosys's syscall set).
add_link_options(${C_ASM_FLAGS} --specs=nosys.specs -nostartfiles -Wl,--gc-sections)

# ---------------------------------------------------------------------------
# Swift toolchain discovery — same real-stdlib-typecheck probe pattern as
# ports/rp2040/CMakeLists.txt and ports/nrf52840/CMakeLists.txt. armv7em-none-none-eabi
# has a real stdlib on every currently-installed toolchain (re-verified
# during this port's planning, docs/superpowers/specs/2026-08-10-stm32f4-support-design.md),
# so no board-keyed probe-target branching is needed here.
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
# newlib headers live. Same fix ports/nrf52840/CMakeLists.txt already needed
# (see that file's own comment for the full story) — ask the real compiler
# directly via `-E -Wp,-v` on an empty source, which dumps its exact system
# include search path to stderr.
execute_process(
    COMMAND ${CMAKE_C_COMPILER} ${C_ASM_FLAGS} -E -Wp,-v -xc /dev/null
    ERROR_VARIABLE _stm32f4_gcc_include_dump
    OUTPUT_QUIET
)
string(REGEX MATCH "search starts here:\n(.*)\nEnd of search list" _stm32f4_gcc_include_match "${_stm32f4_gcc_include_dump}")
string(REGEX REPLACE "\n" ";" _stm32f4_gcc_include_lines "${CMAKE_MATCH_1}")
set(STM32F4_GCC_XCC_INCLUDES "")
foreach(_line ${_stm32f4_gcc_include_lines})
    string(STRIP "${_line}" _dir)
    if(_dir)
        list(APPEND STM32F4_GCC_XCC_INCLUDES "-Xcc" "-I${_dir}")
    endif()
endforeach()
if(NOT STM32F4_GCC_XCC_INCLUDES)
    message(FATAL_ERROR "Failed to determine arm-none-eabi-gcc's system include search path. Command output:\n${_stm32f4_gcc_include_dump}")
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

# cJSON (portable, no ESP-IDF dependency) — LayerEngine.swift/Config.swift
# parse JSON via cJSON_* calls imported through BridgingHeader.h's
# `#include "cJSON.h"`; matches the other three ports' use of the same
# vendored copy under managed_components/.
set(STM32F4_CJSON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON")

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
            -DSMK_TARGET_STM32F4
            -DSMK_BOARD_STM32F4_BLACKPILL
            -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
            -wmo
            -Xcc -mfloat-abi=soft
            -Xcc -mcpu=cortex-m4
            -Xcc -mthumb
            -Xcc -I${STM32F4_CJSON_DIR}
            ${STM32F4_GCC_XCC_INCLUDES}
            -emit-object
            -o "${swift_obj}"
            ${swift_srcs}
    DEPENDS ${swift_srcs} "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
    COMMENT "Compiling SMK Swift sources (STM32F4)..."
    VERBATIM
)

set(c_srcs
    platform/platform_glue.c
    platform/usb_descriptors.c
    # smk_cpu_nop() — the opaque call ClockInit.swift's register-poll loops
    # need so LLVM can't delete them. See that file's header comment.
    platform/cortex_m_intrinsics.c
    "${STM32F4_CJSON_DIR}/cJSON.c"
)

add_executable(smk_stm32f4
    "${CMSIS_F4_GCC}/startup_stm32f411xe.s"
    "${CMSIS_F4_TEMPLATES}/system_stm32f4xx.c"
    ${c_srcs}
    "${swift_obj}"
)
target_include_directories(smk_stm32f4 PRIVATE "${CMSIS_F4_INCLUDE}" "${CMSIS_CORE_INCLUDE}" "${STM32F4_CJSON_DIR}")

# ---------------------------------------------------------------------------
# TinyUSB (device stack, HID class, dwc2 OTG_FS driver) — the "wired" USB
# HID transport, glued from Swift (UsbHid.swift above) per this project's
# Swift-first preference; usb_descriptors.c stays C (macro-computed
# descriptor byte tables — see that file's header comment).
# ---------------------------------------------------------------------------
target_include_directories(smk_stm32f4 PRIVATE
    "${TINYUSB_PATH}/src"
    platform
)
target_sources(smk_stm32f4 PRIVATE
    "${TINYUSB_PATH}/src/tusb.c"
    "${TINYUSB_PATH}/src/common/tusb_fifo.c"
    "${TINYUSB_PATH}/src/device/usbd.c"
    "${TINYUSB_PATH}/src/class/hid/hid_device.c"
    "${TINYUSB_PATH}/src/portable/synopsys/dwc2/dcd_dwc2.c"
    "${TINYUSB_PATH}/src/portable/synopsys/dwc2/dwc2_common.c"
)

add_custom_command(TARGET smk_stm32f4 POST_BUILD
    COMMAND arm-none-eabi-objcopy -O binary $<TARGET_FILE:smk_stm32f4> smk_stm32f4.bin
    COMMENT "Generating smk_stm32f4.bin"
)
