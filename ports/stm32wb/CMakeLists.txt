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
# Minimal smoke-test executable for this task: CMSIS startup + SystemInit +
# a trivial Swift @_cdecl entry point calling nothing else yet. Proves the
# whole pipeline (Swift compile -> C/ASM compile -> link against the
# hand-written linker script, including the separate MAILBOX_RAM region)
# works before any real peripheral code exists. Later tasks grow
# swift_srcs/c_srcs and replace platform_glue.c's stub.
# ---------------------------------------------------------------------------
set(swift_srcs
    "${CMAKE_CURRENT_SOURCE_DIR}/smoke_test.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/ClockInit.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/GPIORegisters.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/GPIOInit.swift"
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
            -DSMK_TARGET_STM32WB
            -wmo
            -Xcc -mfloat-abi=soft
            -Xcc -mcpu=cortex-m4
            -Xcc -mthumb
            ${STM32WB_GCC_XCC_INCLUDES}
            -emit-object
            -o "${swift_obj}"
            ${swift_srcs}
    DEPENDS ${swift_srcs}
    COMMENT "Compiling SMK Swift sources (STM32WB)..."
    VERBATIM
)

add_executable(smk_stm32wb
    "${CMSIS_WB_GCC}/startup_stm32wb55xx_cm4.s"
    "${CMSIS_WB_TEMPLATES}/system_stm32wbxx.c"
    platform/platform_glue.c
    "${swift_obj}"
)
target_include_directories(smk_stm32wb PRIVATE "${CMSIS_WB_INCLUDE}" "${CMSIS_CORE_INCLUDE}")

add_custom_command(TARGET smk_stm32wb POST_BUILD
    COMMAND arm-none-eabi-objcopy -O binary $<TARGET_FILE:smk_stm32wb> smk_stm32wb.bin
    COMMENT "Generating smk_stm32wb.bin"
)
