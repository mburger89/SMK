// Task 4 stub — Main.swift calls init_wired_link()/send_wired_report()/
// kb_usb_task() unconditionally (no @_extern fallback exists anymore
// project-wide, since every board now backs this pair natively in Swift),
// so a placeholder definition is needed here just to make Task 4's build
// typecheck before Task 5 lands the real TinyUSB implementation. Found via
// a real compile error while executing this task, not anticipated by the
// plan text (which assumed this would still link, just be non-functional —
// it actually fails to compile at all without this).
func init_wired_link() {
    // Stub — Task 5 (TinyUSB dwc2) provides the real implementation.
}

func send_wired_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    // Stub — see init_wired_link above.
    _ = modifier
    _ = keys
}

// platform_glue.c's vTaskDelay calls this every tick via its own
// `extern void kb_usb_task(void);` declaration — a real Swift/C boundary
// crossing, so @_cdecl.
@_cdecl("kb_usb_task")
func kb_usb_task() {
    // Stub — see init_wired_link above.
}
