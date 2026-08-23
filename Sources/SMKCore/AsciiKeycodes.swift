// Maps a printable-ASCII byte to the HID keystroke that types it, for the
// macro engine's "type this text" step: a byte comes off the wire, and the
// board must turn it into a usage plus whether Shift is held (`'A'` is
// shift+`a`; `'!'` is shift+`1`).
//
// This assumes US QWERTY on the host. The same text macro types different
// characters if the host is set to another keyboard layout -- the board has
// no way to detect that, so this table is necessarily a guess about the far
// end. It is the standard assumption boot-protocol keyboards make.
//
// The table cannot be generated from keycodes.json: that manifest maps key
// *names* to usages and carries no shift state, so `'A'` and `'!'` have no
// entry there. It is hand-written, and pinned by AsciiKeycodesTests against
// KeyCode so it cannot silently drift from the generated vocabulary.
//
// KeyCode overrides its synthesized `rawValue` getter to return real HID
// usages, but the compiler-synthesized `init?(rawValue:)` still maps
// ordinals (see KeyCodesGenerated.swift). So this file never constructs a
// KeyCode from an arithmetic offset into its raw value -- only from fixed
// case literals, or by indexing into the small arrays below (which are
// ordered by us, not by KeyCode's declaration order) and then reading
// `.rawValue` off the resulting case, which is always safe.

/// The `KeyCode` cases for '0'...'9', indexed by digit value (index 0 is
/// the '0' key, matching the physical digit row's `k0`...`k9` naming).
private let digitKeyCodes: [KeyCode] = [
    .k0, .k1, .k2, .k3, .k4, .k5, .k6, .k7, .k8, .k9,
]

/// The `KeyCode` cases for 'a'...'z', indexed by letter offset from 'a'.
private let letterKeyCodes: [KeyCode] = [
    .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
    .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
]

/// Looks up the HID usage and shift state needed to type a printable-ASCII
/// byte, assuming a US QWERTY host layout. Returns `nil` outside
/// `0x20...0x7E` -- callers must reject the macro rather than substitute a
/// guess. Note `0x7F` (DEL) is not printable and is rejected too.
func asciiKeystroke(_ byte: UInt8) -> (usage: UInt8, shift: Bool)? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
        let code = digitKeyCodes[Int(byte - UInt8(ascii: "0"))]
        return (code.rawValue, false)

    case UInt8(ascii: "a")...UInt8(ascii: "z"):
        let code = letterKeyCodes[Int(byte - UInt8(ascii: "a"))]
        return (code.rawValue, false)

    case UInt8(ascii: "A")...UInt8(ascii: "Z"):
        let code = letterKeyCodes[Int(byte - UInt8(ascii: "A"))]
        return (code.rawValue, true)

    case UInt8(ascii: " "): return (KeyCode.space.rawValue, false)

    // Shifted digit-row symbols.
    case UInt8(ascii: "!"): return (KeyCode.k1.rawValue, true)
    case UInt8(ascii: "@"): return (KeyCode.k2.rawValue, true)
    case UInt8(ascii: "#"): return (KeyCode.k3.rawValue, true)
    case UInt8(ascii: "$"): return (KeyCode.k4.rawValue, true)
    case UInt8(ascii: "%"): return (KeyCode.k5.rawValue, true)
    case UInt8(ascii: "^"): return (KeyCode.k6.rawValue, true)
    case UInt8(ascii: "&"): return (KeyCode.k7.rawValue, true)
    case UInt8(ascii: "*"): return (KeyCode.k8.rawValue, true)
    case UInt8(ascii: "("): return (KeyCode.k9.rawValue, true)
    case UInt8(ascii: ")"): return (KeyCode.k0.rawValue, true)

    // Unshifted/shifted punctuation pairs.
    case UInt8(ascii: "-"): return (KeyCode.minus.rawValue, false)
    case UInt8(ascii: "_"): return (KeyCode.minus.rawValue, true)
    case UInt8(ascii: "="): return (KeyCode.equal.rawValue, false)
    case UInt8(ascii: "+"): return (KeyCode.equal.rawValue, true)
    case UInt8(ascii: "["): return (KeyCode.leftBracket.rawValue, false)
    case UInt8(ascii: "{"): return (KeyCode.leftBracket.rawValue, true)
    case UInt8(ascii: "]"): return (KeyCode.rightBracket.rawValue, false)
    case UInt8(ascii: "}"): return (KeyCode.rightBracket.rawValue, true)
    case UInt8(ascii: "\\"): return (KeyCode.backslash.rawValue, false)
    case UInt8(ascii: "|"): return (KeyCode.backslash.rawValue, true)
    case UInt8(ascii: ";"): return (KeyCode.semicolon.rawValue, false)
    case UInt8(ascii: ":"): return (KeyCode.semicolon.rawValue, true)
    case UInt8(ascii: "'"): return (KeyCode.quote.rawValue, false)
    case UInt8(ascii: "\""): return (KeyCode.quote.rawValue, true)
    case UInt8(ascii: "`"): return (KeyCode.grave.rawValue, false)
    case UInt8(ascii: "~"): return (KeyCode.grave.rawValue, true)
    case UInt8(ascii: ","): return (KeyCode.comma.rawValue, false)
    case UInt8(ascii: "<"): return (KeyCode.comma.rawValue, true)
    case UInt8(ascii: "."): return (KeyCode.period.rawValue, false)
    case UInt8(ascii: ">"): return (KeyCode.period.rawValue, true)
    case UInt8(ascii: "/"): return (KeyCode.slash.rawValue, false)
    case UInt8(ascii: "?"): return (KeyCode.slash.rawValue, true)

    default: return nil
    }
}
