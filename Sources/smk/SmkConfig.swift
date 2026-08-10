// ESP32-C6 board/connection-mode config, backed by Kconfig
// (main/Kconfig.projbuild) — Swift port of the former
// Sources/components/smk_config.c. Only compiled into the ESP32-C6 build
// (main/CMakeLists.txt), so these are plain module-internal Swift
// functions, not `@_extern`/`@_cdecl` — nothing outside this Swift module
// calls them. RP2040 backs the same `@_extern(c, ...)` declarations in
// Main.swift (conditional on SMK_TARGET_ESP32C6 being undefined — see
// main/CMakeLists.txt) with its own hardcoded C definitions
// (ports/rp2040/platform/platform_glue.c and friends).
//
// SMK_HAS_WIRED_BRIDGE / SMK_DEFAULT_MODE_WIRED / SMK_HAS_RGB_BACKLIGHT
// are genuine Swift compilation conditions (passed as bare swiftc `-D`,
// not `-Xcc -D`) that main/CMakeLists.txt derives from the matching
// CONFIG_SMK_* Kconfig options. That indirection exists because a Kconfig
// bool that's off isn't defined as 0 in sdkconfig.h — it's entirely
// absent — and Swift's `#if` has no way to ask "was this C macro defined"
// the way C's `#if defined(...)` can; only CMake (which loads
// sdkconfig.cmake project-wide, exposing every CONFIG_SMK_* option as an
// ordinary CMake variable) can see that and turn it into a Swift-level
// flag.
//
// CONFIG_SMK_RGB_GPIO itself is referenced directly below — Bridging.h
// includes sdkconfig.h, so simple integer Kconfig macros like this one
// import straight into Swift as global constants when Kconfig actually
// emits them (which, per its `depends on SMK_HAS_RGB_BACKLIGHT` + `default
// 16`, is exactly whenever SMK_HAS_RGB_BACKLIGHT is set).

func smk_has_wired_bridge() -> Int32 {
#if SMK_HAS_WIRED_BRIDGE
    return 1
#else
    return 0
#endif
}

func smk_default_mode_is_wired() -> Int32 {
#if SMK_DEFAULT_MODE_WIRED && SMK_HAS_WIRED_BRIDGE
    return 1
#else
    return 0
#endif
}

func smk_has_rgb_backlight() -> Int32 {
#if SMK_HAS_RGB_BACKLIGHT
    return 1
#else
    return 0
#endif
}

func smk_rgb_gpio() -> Int32 {
#if SMK_HAS_RGB_BACKLIGHT
    return CONFIG_SMK_RGB_GPIO
#else
    return 16 // spare/unconnected pad on smk_kbd
#endif
}
