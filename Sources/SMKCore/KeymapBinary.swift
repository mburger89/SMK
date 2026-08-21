// Binary keymap cell encoding: one action tag byte + one parameter byte.
// See docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md.
//
// This is the wire/storage format the compiled binary payload uses -- a
// fixed two-byte stride per cell, chosen so 16 layers fit inside the
// existing 4085-byte keymap store (the JSON encoding this replaces costs
// ~11.9 bytes/cell and never actually fit 16 layers). The tag table below
// must stay in lockstep with the configurator's compiler
// (KeymapDocument -> binary payload) and with KeymapCellTag's cross-repo
// pin in KeyVocabularyTests-equivalent coverage there.

/// The action-tag byte of a two-byte binary cell. Raw values are the wire
/// format -- do not renumber existing cases without also updating the
/// configurator's compiler.
enum KeymapCellTag: UInt8 {
    case none = 0
    case key = 1
    case modifier = 2
    case momentaryLayer = 3
    case toggleLayer = 4
    case transparent = 5
    case toggleConnection = 6
    case macro = 7
}

/// Encodes one `KeyAction` as (tag, parameter) -- the two bytes stored per
/// keymap cell.
func encodeCell(_ action: KeyAction) -> (UInt8, UInt8) {
    switch action {
    case .none:
        return (KeymapCellTag.none.rawValue, 0)
    case .key(let code):
        return (KeymapCellTag.key.rawValue, code.rawValue)
    case .modifier(let mod):
        return (KeymapCellTag.modifier.rawValue, mod.rawValue)
    case .momentaryLayer(let layer):
        return (KeymapCellTag.momentaryLayer.rawValue, UInt8(layer))
    case .toggleLayer(let layer):
        return (KeymapCellTag.toggleLayer.rawValue, UInt8(layer))
    case .transparent:
        return (KeymapCellTag.transparent.rawValue, 0)
    case .toggleConnection:
        return (KeymapCellTag.toggleConnection.rawValue, 0)
    case .macro(let slot):
        return (KeymapCellTag.macro.rawValue, UInt8(slot))
    }
}

/// Decodes a two-byte binary cell back into a `KeyAction`. A tag this build
/// has no case for decodes to `.none` rather than trapping -- a corrupt
/// flash byte must degrade a single cell, not brick the keyboard.
func decodeCell(_ tag: UInt8, _ param: UInt8) -> KeyAction {
    guard let cellTag = KeymapCellTag(rawValue: tag) else { return .none }
    switch cellTag {
    case .none:
        return .none
    case .key:
        guard let code = keyCode(fromHIDUsage: param) else { return .none }
        return .key(code)
    case .modifier:
        guard let mod = modifier(fromBit: param) else { return .none }
        return .modifier(mod)
    case .momentaryLayer:
        return .momentaryLayer(Int(param))
    case .toggleLayer:
        return .toggleLayer(Int(param))
    case .transparent:
        return .transparent
    case .toggleConnection:
        return .toggleConnection
    case .macro:
        return .macro(Int(param))
    }
}

// KeyCode and Modifier both override their synthesized `rawValue` getter
// with hand-written HID usage codes / bit masks (see KeyCodesGenerated.swift's
// own warning comment on this), which leaves each type's *compiler-synthesized*
// `init?(rawValue:)` mapping ordinal case position instead -- inconsistent
// with the real value and unsafe to call directly with a wire byte.
// `KeyCode(rawValue: 4)` returns whichever case sits fifth in the enum
// declaration, not `.a` (HID usage 0x04).
//
// That synthesized initializer is still valid as a pure ordinal enumerator,
// though: `T(rawValue: 0)`, `T(rawValue: 1)`, ... walks every case in
// declaration order and returns `nil` once the ordinal runs past the last
// one. Comparing each candidate's real `.rawValue` against the wire byte
// gives the correct reverse lookup without hand-duplicating either type's
// generated/hand-written table here.
private func keyCode(fromHIDUsage usage: UInt8) -> KeyCode? {
    var ordinal: UInt8 = 0
    while let candidate = KeyCode(rawValue: ordinal) {
        if candidate.rawValue == usage { return candidate }
        if ordinal == UInt8.max { break }
        ordinal += 1
    }
    return nil
}

private func modifier(fromBit bit: UInt8) -> Modifier? {
    var ordinal: UInt8 = 0
    while let candidate = Modifier(rawValue: ordinal) {
        if candidate.rawValue == bit { return candidate }
        if ordinal == UInt8.max { break }
        ordinal += 1
    }
    return nil
}
