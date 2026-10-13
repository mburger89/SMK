struct HIDReport: Equatable {
    var modifier: UInt8 = 0
    // Inline storage: building a report every scan tick allocates nothing.
    var keys: InlineArray<6, UInt8> = .init(repeating: 0)

    mutating func reset() {
        modifier = 0
        for i in 0..<6 { keys[i] = 0 }
    }

    mutating func addKey(_ keycode: UInt8) {
        if keycode == 0 { return }
        for i in 0..<6 where keys[i] == 0 {
            keys[i] = keycode
            return
        }
    }

    mutating func addModifier(_ mod: Modifier) {
        modifier |= mod.rawValue
    }

    /// The 6 keycode bytes as a C pointer, for transports' C send calls.
    func withKeyBytes<R>(_ body: (UnsafePointer<UInt8>) -> R) -> R {
        keys.span.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    // Hand-written: InlineArray is not Equatable, so this can't be synthesized.
    // It must compare all six slots — the scan loop's send-on-change check
    // relies on it, and a report differing only in keys[5] still has to go out.
    static func == (lhs: HIDReport, rhs: HIDReport) -> Bool {
        guard lhs.modifier == rhs.modifier else { return false }
        for i in 0..<6 where lhs.keys[i] != rhs.keys[i] { return false }
        return true
    }
}
