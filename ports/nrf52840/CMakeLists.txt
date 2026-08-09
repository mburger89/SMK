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
# Minimal smoke-test executable for this task: just the CMSIS startup +
# a trivial Swift @_cdecl entry point calling nothing else yet. Proves the
# whole pipeline (Swift compile -> C compile -> link against the nRF5 SDK
# startup/linker script) works before any real peripheral code exists.
# Tasks 2-8 grow swift_srcs/c_srcs and replace platform_glue.c's stub.
# ---------------------------------------------------------------------------
set(swift_srcs
    "${CMAKE_CURRENT_SOURCE_DIR}/smoke_test.swift"
)

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
            -wmo
            -Xcc -mfloat-abi=soft
            -Xcc -mcpu=cortex-m4
            -Xcc -mthumb
            -emit-object
            -o "${swift_obj}"
            ${swift_srcs}
    DEPENDS ${swift_srcs}
    COMMENT "Compiling SMK Swift sources (nRF52840)..."
    VERBATIM
)

add_executable(smk_nrf52840
    "${NRF5_MDK}/gcc_startup_nrf52840.S"
    "${NRF5_MDK}/system_nrf52840.c"
    platform/platform_glue.c
    "${swift_obj}"
)
target_include_directories(smk_nrf52840 PRIVATE "${NRF5_MDK}" "${NRF5_CMSIS_INCLUDE}")
target_compile_definitions(smk_nrf52840 PRIVATE INITIALIZE_USER_MEMORY_AREA)

add_custom_command(TARGET smk_nrf52840 POST_BUILD
    COMMAND arm-none-eabi-objcopy -O ihex $<TARGET_FILE:smk_nrf52840> smk_nrf52840.hex
    COMMENT "Generating smk_nrf52840.hex"
)
