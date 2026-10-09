// Host-only shim for LayerEngine.swift's kb_log() calls. Real firmware
// builds get kb_log from the platform: a same-module Swift implementation
// (Sources/smk/BleHelper.swift on ESP32-C6, ports/rp2040/PlatformConfig.swift
// on RP2040), or the C platform_glue.c one whose prototype each other ARM
// port's BridgingHeader.h imports. This file exists only
// for the SMKCore/SMKCoreTests host build
// (Package.swift) and must NOT be added to main/CMakeLists.txt's or
// ports/rp2040/CMakeLists.txt's Swift source lists — doing so would give
// the embedded build two conflicting definitions of kb_log.
func kb_log(_ msg: UnsafePointer<Int8>) {
    // no-op on host — tests assert on return values/state, not log output.
}
