cmake_minimum_required(VERSION 3.29)

# ---------------------------------------------------------------------------
# Early RP2350 detection — must happen before pico_sdk_import.cmake, since
# PICO_NO_CMSE is consumed by pico-sdk's toolchain *preload* phase (which
# runs before project()/pico_sdk_init(), i.e. before the canonical
# SMK_TARGET_BOARD CACHE variable further down this file is set). Mirrors
# that later block's PICO_BOARD fallback so a bare
# `cmake -DPICO_BOARD=pico2 ...` (no explicit -DSMK_TARGET_BOARD) still
# works.
# ---------------------------------------------------------------------------
if(NOT DEFINED SMK_TARGET_BOARD)
    set(SMK_TARGET_BOARD "${PICO_BOARD}")
endif()
if(SMK_TARGET_BOARD STREQUAL "pico2" OR SMK_TARGET_BOARD STREQUAL "pico2_w")
    # No TrustZone secure/non-secure partitioning in this project — disable
    # CMSE codegen (-mcmse) rather than carry its untested interaction with
    # Swift-emitted code for no benefit.
    set(PICO_NO_CMSE 1)
endif()

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
    if(SMK_TARGET_BOARD STREQUAL "pico2" OR SMK_TARGET_BOARD STREQUAL "pico2_w")
        set(_probe_target "armv8m.main-none-none-eabi")
    else()
        set(_probe_target "armv6m-none-none-eabi")
    endif()
    # -print-target-info below only confirms LLVM recognizes the target
    # triple, not that this toolchain ships a prebuilt Embedded Swift
    # stdlib for it (confirmed: swift-6.3.2-RELEASE returns 0 for
    # -target armv8m.main-none-none-eabi -print-target-info yet has no
    # such stdlib, failing later at the real build with "could not find
    # module 'Swift'"). Typecheck a trivial probe source against the
    # target as a second, stronger gate before accepting a toolchain.
    set(_smk_probe_src "${CMAKE_BINARY_DIR}/_smk_toolchain_probe.swift")
    file(WRITE "${_smk_probe_src}" "public func _smkToolchainProbe() {}\n")
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
                    execute_process(
                        COMMAND "${_sc}" -target ${_probe_target}
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
# Target board selection — independent of PICO_BOARD.
#
# PICO_BOARD tells pico-sdk which *electrical* hardware descriptor to use
# (flash size/timing, crystal, default pin muxing). SMK_TARGET_BOARD picks
# which *application* pin map / feature set SMK itself uses (matrix GPIOs,
# RGB chain, BLE transport). These are usually the same ("pico" / "pico_w"),
# but the custom smk_kbd_rp2040 chip-down PCB (see ~/esp/SMK_Keyboard)
# reuses PICO_BOARD=pico as its electrical descriptor — its external flash
# (Winbond W25Q16JV) and 12MHz crystal are electrically identical to the
# stock Pico's own (generate_kbd_rp2040.py deliberately chose the same part
# Raspberry Pi's Pico uses) — while selecting its own real matrix/RGB/BLE
# code paths via this separate variable. Set by build_rp2040.sh; defaults to
# mirroring PICO_BOARD for plain `cmake ... -DPICO_BOARD=pico_w` invocations.
set(SMK_TARGET_BOARD "${PICO_BOARD}" CACHE STRING
    "SMK application board profile: pico | pico_w | pico2 | pico2_w | smk_kbd_rp2040")
set(SMK_IS_KBD_RP2040 FALSE)
if(SMK_TARGET_BOARD STREQUAL "smk_kbd_rp2040")
    set(SMK_IS_KBD_RP2040 TRUE)
endif()
set(SMK_IS_RP2350 FALSE)
if(SMK_TARGET_BOARD STREQUAL "pico2" OR SMK_TARGET_BOARD STREQUAL "pico2_w")
    set(SMK_IS_RP2350 TRUE)
endif()

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
    platform/smk_keymap_store.c
    # Portable cJSON (no ESP-IDF dependency)
    "${CMAKE_CURRENT_SOURCE_DIR}/../../managed_components/espressif__cjson/cJSON/cJSON.c"
    # Shared upload-packet dispatch (see Sources/componets/smk_keymap_protocol.c)
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/componets/smk_keymap_protocol.c"
)

if(SMK_IS_KBD_RP2040)
    # smk_kbd_rp2040 has a real 59-key SK6812MINI-E chain (RGBLighting
    # is opt-in/off elsewhere, but always-on here since the hardware exists)
    # and its own CYW43439-over-UART BLE transport instead of Pico W's
    # SPI-wired one — see platform/ble_hid_kbd_uart.c.
    list(APPEND SHARED_SWIFT_SRCS
        "${CMAKE_CURRENT_SOURCE_DIR}/../../Sources/smk/RGBLighting.swift"
    )
    list(APPEND PLATFORM_C_SRCS
        platform/led_strip_driver.c
        platform/ble_hid_kbd_uart.c
        platform/cyw43439_patchram.c
    )
else()
    # Plain Pico / Pico W: unchanged behavior from before this board existed.
    list(APPEND PLATFORM_C_SRCS platform/ble_hid.c)
endif()

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
# BLE: three distinct paths depending on SMK_TARGET_BOARD.
#   - pico_w: Pico W's onboard CYW43 (SPI-wired) + BTstack BLE HID (scaffolded,
#             unchanged from before this board existed).
#   - smk_kbd_rp2040: chip-down CYW43439 wired over a dedicated 4-wire
#             UART instead of SPI (see generate_kbd_rp2040.py's GPIO map) —
#             needs BTstack's generic H4/UART transport, not pico_cyw43_arch
#             (which assumes the SPI/PIO wiring pico-sdk's cyw43-driver talks
#             to), plus BTstack's own btstack_chipset_bcm PatchRAM driver
#             (chipset/bcm/ in the vendored BTstack source, added as a raw
#             source file below since pico_btstack's CMakeLists.txt doesn't
#             expose it as its own library target) and the async_context-
#             based run loop (pico_btstack_run_loop_async_context) so
#             BTstack's HCI/L2CAP/SM state machines actually get pumped from
#             this project's cooperative tick loop. See
#             platform/ble_hid_kbd_uart.c for what's implemented vs. the one
#             remaining gap (the actual PatchRAM firmware bytes — see
#             platform/cyw43439_patchram.c).
#   - plain pico: no radio at all; ble_hid.c's stub branch is linked instead.
# ---------------------------------------------------------------------------
if((PICO_BOARD STREQUAL "pico_w" OR PICO_BOARD STREQUAL "pico2_w") AND NOT SMK_IS_KBD_RP2040)
    message(STATUS "Building for ${PICO_BOARD} — enabling CYW43 + BTstack BLE HID")

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
elseif(SMK_IS_KBD_RP2040)
    message(STATUS "Building for smk_kbd_rp2040 — enabling CYW43439-over-UART BLE HID + RGB")

    # Generate smk_hid.h from smk_hid.gatt in the build directory (same GATT
    # profile as Pico W — the HID-over-GATT service doesn't depend on transport).
    pico_btstack_make_gatt_header(smk_rp2040 PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/platform/smk_hid.gatt"
    )

    target_link_libraries(smk_rp2040
        pico_btstack_base         # BTstack core (run loop glue) — transport-agnostic
        pico_btstack_ble
        pico_btstack_run_loop_async_context # async_context-driven run loop (see ble_hid_kbd_uart.c)
        pico_async_context_poll   # plain polling async_context — nothing here is IRQ-driven
        hardware_uart              # CYW43439 HCI link (GPIO20/21, +CTS/RTS on 22/23)
        hardware_pio                # SK6812MINI-E chain driver
    )

    # btstack_chipset_bcm.c isn't exposed as its own pico_btstack library
    # target, so it's added directly here as a source file. Same story for
    # hci_transport_h4.c: pico_btstack_base's own CMakeLists.txt doesn't
    # compile it in (Pico W's onboard CYW43 talks over cyw43-driver's SPI/PIO
    # link, not literal UART H4, so pico-sdk has no need for it) -- but this
    # board's dedicated 4-wire BT UART does need it, for hci_transport_h4_instance()
    # (used in init_ble_hid() below). PICO_BTSTACK_PATH is set by
    # pico_btstack's own CMakeLists.txt (promoted via
    # pico_promote_common_scope_vars() once pico_btstack_base is linked
    # above); fall back to pico-sdk's own default location if for some
    # reason it isn't visible yet in this scope.
    if(NOT PICO_BTSTACK_PATH)
        set(PICO_BTSTACK_PATH "${PICO_SDK_PATH}/lib/btstack")
    endif()
    target_sources(smk_rp2040 PRIVATE
        "${PICO_BTSTACK_PATH}/chipset/bcm/btstack_chipset_bcm.c"
        "${PICO_BTSTACK_PATH}/src/hci_transport_h4.c"
    )
    target_include_directories(smk_rp2040 PRIVATE
        "${PICO_BTSTACK_PATH}/chipset/bcm"
    )

    target_include_directories(smk_rp2040 PRIVATE
        "${CMAKE_CURRENT_BINARY_DIR}"    # smk_hid.h lands here
        "${CMAKE_CURRENT_SOURCE_DIR}/platform"
    )

    # Generate ws2812.pio.h from the PIO program used by led_strip_driver.c.
    pico_generate_pio_header(smk_rp2040
        "${CMAKE_CURRENT_SOURCE_DIR}/platform/ws2812.pio"
    )

    target_compile_definitions(smk_rp2040 PRIVATE
        SMK_ENABLE_BLE            # reused by smk_hid.gatt / profile plumbing
        SMK_BOARD_KBD_RP2040
        SMK_RGB_AVAILABLE
    )
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

# SMK's own Swift compilation-condition flags (`#if FOO` in Main.swift /
# RGBLighting.swift) — passed as bare swiftc `-D` (Swift's own conditional-
# compilation flag), distinct from ${_compile_defs} above which is C-level
# `-Xcc -D...` for the Clang importer. target_compile_definitions() also sets
# these for the C sources (gpio_init.c etc. see them as normal #ifdef macros);
# this is the belt-and-suspenders explicit form so Main.swift's own `#if`
# definitely sees them too, regardless of how CMake's native Swift-language
# support maps COMPILE_DEFINITIONS for a mixed C/Swift target.
set(_smk_swift_defs "")
if(SMK_IS_KBD_RP2040)
    set(_smk_swift_defs "-DSMK_BOARD_KBD_RP2040 -DSMK_RGB_AVAILABLE")
endif()

# RP2350 (Cortex-M33, Armv8-M Mainline) needs a different Swift target
# triple than RP2040 (Cortex-M0+, Armv6-M), plus matching -Xcc arch/float
# flags. RP2350's Cortex-M33 has a real FPU and pico-sdk's own toolchain
# preset (pico_arm_cortex_m33_gcc.cmake) builds its C sources / prebuilt
# objects expecting `-march=armv8-m.main+fp+dsp -mfloat-abi=softfp` — so
# Swift's Clang-importer flags mirror that instead of forcing soft-float
# the way the RP2040/Armv6-M path does (Armv6-M has no FPU at all, so soft
# float there is the only option).
if(SMK_IS_RP2350)
    set(_smk_swift_arch_flags
        "-target armv8m.main-none-none-eabi
        -Xcc -march=armv8-m.main+fp+dsp
        -Xcc -mfloat-abi=softfp
        -Xcc -mfpu=fpv5-sp-d16"
    )
else()
    set(_smk_swift_arch_flags
        "-target armv6m-none-none-eabi
        -Xcc -mfloat-abi=soft"
    )
endif()

# ---------------------------------------------------------------------------
# Swift compiler flags
# ---------------------------------------------------------------------------
target_compile_options(smk_rp2040 PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:
        ${_smk_swift_arch_flags}
        -enable-experimental-feature Embedded
        -enable-experimental-feature Extern
        -parse-as-library
        -module-name smk_rp2040
        -Xcc -fshort-enums
        -Xfrontend -function-sections
        -import-bridging-header ${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h
        ${_smk_swift_defs}
        ${_compile_defs}
        ${_implicit_incs}
    >"
)
