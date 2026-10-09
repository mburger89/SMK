# cmake/SwiftMMIO.cmake — swift-mmio (third_party/swift-mmio, pinned
# submodule) for SMK's flat swiftc builds.
#
# Route taken: FLAT COMPILATION (plan Task 2.1 Step 4, not Step 4b).
# swift-mmio's Sources/MMIO/*.swift are compiled straight into each
# target's single `swiftc -wmo` invocation, exactly like Sources/smk and
# Sources/SMKCore — no separate MMIO module, no `import MMIO`. This works
# because MMIO's only import is `public import MMIOVolatile` (a C module
# found via -I below) and none of its macro expansions module-qualify a
# name (`MMIO.Register` etc.). MMIOInterposer.swift has to stay in the
# glob even though it is only meaningful with FEATURE_INTERPOSABLE:
# Register.swift's `interposer` property names the protocol
# unconditionally (deprecated, compiled out of every access path).
#
# The @Register/@RegisterBlock macros run from a host plugin executable
# (MMIOMacros-tool) built from the submodule with the *same* toolchain as
# the firmware compiler. Building it means building swift-syntax, which
# takes minutes, and the gate (tools/build_all.sh) wipes every
# build_gate/<target> dir — so the plugin is NOT built in
# CMAKE_BINARY_DIR. It lives in one shared, gitignored, repo-level cache
# keyed by toolchain version:
#     <repo>/.build_mmio_plugin/<SMK_SWIFT_VERSION>/
# and every target/build dir reuses it once it exists. A CMake file lock
# serialises the build, so two configures running at once can't race on
# the same scratch dir. A stamp file records the swift-mmio commit and
# swiftc path the plugin was built from; a mismatch triggers an
# (incremental) rebuild.
#
# `--build-system native --product MMIOMacros` is deliberate: SwiftPM
# 6.4's default `swiftbuild` engine rejects both `--target MMIOMacros`
# ("Found multiple targets named 'MMIOMacros'") and `--product MMIOMacros`
# ("Could not find target named 'MMIOMacros-product'") for a .macro target,
# and native `--target MMIOMacros` compiles the macro's objects but never
# links the MMIOMacros-tool executable. Measured on an M-series Mac: a
# from-scratch plugin build is roughly 6-10 minutes (swift-syntax).
#
# Requires SWIFTC_PATH and SMK_SWIFT_VERSION (cmake/FindEmbeddedSwiftc.cmake).
get_filename_component(SMK_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(SMK_MMIO_DIR "${SMK_REPO_ROOT}/third_party/swift-mmio")

function(_smk_build_mmio_plugin out_plugin)
    if(NOT SWIFTC_PATH OR NOT SMK_SWIFT_VERSION)
        message(FATAL_ERROR "SwiftMMIO.cmake: call smk_find_embedded_swiftc() first.")
    endif()
    if(NOT EXISTS "${SMK_MMIO_DIR}/Package.swift")
        message(FATAL_ERROR
            "swift-mmio submodule missing at ${SMK_MMIO_DIR}.\n"
            "Run: git submodule update --init third_party/swift-mmio")
    endif()
    get_filename_component(_tc_bin "${SWIFTC_PATH}" DIRECTORY)
    set(_cache_root "${SMK_REPO_ROOT}/.build_mmio_plugin")
    set(_scratch "${_cache_root}/${SMK_SWIFT_VERSION}")
    set(_plugin "${_scratch}/release/MMIOMacros-tool")
    set(_stamp_file "${_scratch}/smk-plugin.stamp")

    execute_process(COMMAND git -C "${SMK_MMIO_DIR}" rev-parse HEAD
        OUTPUT_VARIABLE _rev OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    set(_want_stamp "${_rev}|${SWIFTC_PATH}")

    file(MAKE_DIRECTORY "${_cache_root}")
    file(LOCK "${_cache_root}/${SMK_SWIFT_VERSION}.lock" GUARD FUNCTION TIMEOUT 3600
        RESULT_VARIABLE _lock_r)
    if(NOT _lock_r EQUAL 0)
        message(FATAL_ERROR "Could not lock the swift-mmio plugin cache: ${_lock_r}")
    endif()

    set(_have_stamp "")
    if(EXISTS "${_stamp_file}")
        file(READ "${_stamp_file}" _have_stamp)
    endif()
    if(NOT EXISTS "${_plugin}" OR NOT _have_stamp STREQUAL _want_stamp)
        message(STATUS "Building swift-mmio macro plugin (Swift ${SMK_SWIFT_VERSION}) into ${_scratch} — takes a few minutes, once per toolchain...")
        string(TIMESTAMP _t0 "%s")
        execute_process(
            COMMAND "${_tc_bin}/swift" build -c release --build-system native
                    --product MMIOMacros
                    --package-path "${SMK_MMIO_DIR}"
                    --scratch-path "${_scratch}"
            RESULT_VARIABLE _r
            OUTPUT_VARIABLE _out ERROR_VARIABLE _out)
        string(TIMESTAMP _t1 "%s")
        math(EXPR _dt "${_t1} - ${_t0}")
        if(NOT _r EQUAL 0 OR NOT EXISTS "${_plugin}")
            message(FATAL_ERROR "swift-mmio MMIOMacros plugin build failed (expected ${_plugin}):\n${_out}")
        endif()
        file(WRITE "${_stamp_file}" "${_want_stamp}")
        message(STATUS "swift-mmio macro plugin built in ${_dt}s")
    endif()
    set(${out_plugin} "${_plugin}" PARENT_SCOPE)
endfunction()

# smk_add_swift_mmio(<out_sources_var> <out_flags_var>)
# Appends MMIO's .swift sources to the list named by the first argument and
# the swiftc flags it needs to the list named by the second, as plain list
# items (no SHELL: prefixes) for add_custom_command swiftc invocations.
function(smk_add_swift_mmio out_srcs out_flags)
    _smk_build_mmio_plugin(_plugin)
    file(GLOB _mmio_srcs "${SMK_MMIO_DIR}/Sources/MMIO/*.swift")
    list(SORT _mmio_srcs)
    set(${out_srcs} ${${out_srcs}} ${_mmio_srcs} PARENT_SCOPE)
    set(${out_flags} ${${out_flags}}
        -load-plugin-executable "${_plugin}#MMIOMacros"
        -I "${SMK_MMIO_DIR}/Sources/MMIOVolatile"
        -Xcc "-I${SMK_MMIO_DIR}/Sources/MMIOVolatile"
        PARENT_SCOPE)
endfunction()
