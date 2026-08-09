struct HIDReport {
    var modifier: UInt8 = 0
    var keys: [UInt8] = [0, 0, 0, 0, 0, 0]

    mutating func reset() {
        modifier = 0
        for i in 0..<keys.count { keys[i] = 0 }
    }

    mutating func addKey(_ keycode: UInt8) {
        if keycode == 0 { return }
        for i in 0..<keys.count {
            if keys[i] == 0 {
                keys[i] = keycode
                return
            }
        }
    }

    mutating func addModifier(_ mod: Modifier) {
        modifier |= mod.rawValue
    }
}
