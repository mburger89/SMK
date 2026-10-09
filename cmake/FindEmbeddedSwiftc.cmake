# cmake/FindEmbeddedSwiftc.cmake
# One toolchain finder for every SMK build. Order:
#   1. -DSWIFTC_PATH=... (cache)   2. $ENV{SWIFTC_PATH}
#   3. newest *release* toolchain in ~/Library/Developer/Toolchains or
#      /Library/Developer/Toolchains that passes both probes for <triple>.
# Snapshots (swift-DEVELOPMENT-SNAPSHOT-*) are skipped unless
# SMK_ALLOW_SNAPSHOT=ON; swift-latest is skipped (symlink duplicate).
# Any chosen compiler must report version >= SMK_MIN_SWIFT_VERSION.
set(SMK_MIN_SWIFT_VERSION "6.4" CACHE STRING "Minimum Swift version")
option(SMK_ALLOW_SNAPSHOT "Allow swift-DEVELOPMENT-SNAPSHOT toolchains" OFF)

function(_smk_swiftc_version sc out)
    execute_process(COMMAND "${sc}" --version OUTPUT_VARIABLE _v ERROR_QUIET)
    string(REGEX MATCH "Swift version ([0-9]+\\.[0-9]+(\\.[0-9]+)?)" _m "${_v}")
    set(${out} "${CMAKE_MATCH_1}" PARENT_SCOPE)
endfunction()

function(_smk_swiftc_probe sc triple out)
    set(_src "${CMAKE_BINARY_DIR}/_smk_toolchain_probe.swift")
    file(WRITE "${_src}" "public func _smkToolchainProbe() {}\n")
    execute_process(
        COMMAND "${sc}" -target ${triple} -enable-experimental-feature Embedded -print-target-info
        RESULT_VARIABLE _a OUTPUT_QUIET ERROR_QUIET)
    execute_process(
        COMMAND "${sc}" -target ${triple} -enable-experimental-feature Embedded
                -parse-as-library -typecheck "${_src}"
        RESULT_VARIABLE _b OUTPUT_QUIET ERROR_QUIET)
    if(_a EQUAL 0 AND _b EQUAL 0)
        set(${out} TRUE PARENT_SCOPE)
    else()
        set(${out} FALSE PARENT_SCOPE)
    endif()
endfunction()

function(smk_find_embedded_swiftc triple)
    if((NOT SWIFTC_PATH OR NOT EXISTS "${SWIFTC_PATH}") AND DEFINED ENV{SWIFTC_PATH} AND EXISTS "$ENV{SWIFTC_PATH}")
        set(SWIFTC_PATH "$ENV{SWIFTC_PATH}" CACHE PATH "Path to swiftc" FORCE)
    endif()

    if(NOT SWIFTC_PATH OR NOT EXISTS "${SWIFTC_PATH}")
        set(_cands "")
        foreach(_dir "$ENV{HOME}/Library/Developer/Toolchains" "/Library/Developer/Toolchains")
            file(GLOB _tcs "${_dir}/*.xctoolchain")
            foreach(_tc ${_tcs})
                get_filename_component(_name "${_tc}" NAME)
                if(_name STREQUAL "swift-latest.xctoolchain")
                    continue()
                endif()
                if(_name MATCHES "DEVELOPMENT-SNAPSHOT" AND NOT SMK_ALLOW_SNAPSHOT)
                    continue()
                endif()
                set(_sc "${_tc}/usr/bin/swiftc")
                if(EXISTS "${_sc}")
                    _smk_swiftc_version("${_sc}" _ver)
                    if(_ver)
                        list(APPEND _cands "${_ver}|${_sc}")
                    endif()
                endif()
            endforeach()
        endforeach()
        list(SORT _cands COMPARE NATURAL ORDER DESCENDING)
        foreach(_c ${_cands})
            string(REPLACE "|" ";" _parts "${_c}")
            list(GET _parts 1 _sc)
            _smk_swiftc_probe("${_sc}" ${triple} _ok)
            if(_ok)
                set(SWIFTC_PATH "${_sc}" CACHE PATH "Path to swiftc" FORCE)
                break()
            endif()
        endforeach()
    endif()

    if(NOT SWIFTC_PATH OR NOT EXISTS "${SWIFTC_PATH}")
        message(FATAL_ERROR
            "No Swift >= ${SMK_MIN_SWIFT_VERSION} toolchain with an Embedded stdlib for ${triple} found.\n"
            "Install swift-6.4.0-RELEASE or set -DSWIFTC_PATH=<toolchain>/usr/bin/swiftc.")
    endif()
    _smk_swiftc_version("${SWIFTC_PATH}" _ver)
    if(_ver VERSION_LESS SMK_MIN_SWIFT_VERSION)
        message(FATAL_ERROR
            "${SWIFTC_PATH} is Swift ${_ver}; SMK requires >= ${SMK_MIN_SWIFT_VERSION}. "
            "Delete this build dir or pass -DSWIFTC_PATH=<6.4 toolchain>/usr/bin/swiftc.")
    endif()
    set(SMK_SWIFT_VERSION "${_ver}" PARENT_SCOPE)
    message(STATUS "Using Swift ${_ver}: ${SWIFTC_PATH}")
endfunction()
