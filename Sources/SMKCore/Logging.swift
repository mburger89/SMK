// Host-only shim for LayerEngine.swift's kb_log() calls. Real firmware
// builds get kb_log from Sources/smk/Main.swift's `@_extern(c, "kb_log")`
// declaration, resolved by the platform's C logging implementation
// (Sources/componets/kb_main.c on ESP32-C6, platform_glue.c on RP2040).
// This file exists only for the SMKCore/SMKCoreTests host build
// (Package.swift) and must NOT be added to main/CMakeLists.txt's or
// ports/rp2040/CMakeLists.txt's Swift source lists — doing so would give
// the embedded build two conflicting definitions of kb_log.
func kb_log(_ msg: UnsafePointer<Int8>) {
    // no-op on host — tests assert on return values/state, not log output.
}
