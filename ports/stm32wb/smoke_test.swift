// Task 1 smoke test only — proves the Swift/C/ASM/linker pipeline works.
// Replaced by real Main.swift/SMKCore wiring in Task 4.
@_cdecl("app_main_swift")
func app_main_swift() {
    while true {}
}
