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

// MARK: - Payload decoding

/// The decoded form of a binary keymap payload -- matrix header, per-cell
/// layer data, and macros. See
/// docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md for the
/// byte layout this mirrors.
struct KeymapPayload {
    var rows: [UInt8]
    var cols: [UInt8]
    var colsAreDriven: Bool
    var layers: [[[KeyAction]]]
    var macros: [MacroDefinition]
}

/// One step of a macro. `mods` is the packed HID modifier byte (bit order
/// per the configurator's CLAUDE.md, matching `Modifier.rawValue`), `key`
/// is a HID usage from `KeyCode`.
enum MacroStep: Equatable {
    case keystroke(mods: UInt8, key: UInt8, holdMs: Int)
    case text(String, msPerChar: Int)
    case delay(ms: Int)
    case layer(momentary: Bool, n: Int)
    case repeatBlock(count: Int, steps: [MacroStep])
}

struct MacroDefinition: Equatable {
    var id: Int
    var steps: [MacroStep]
}

/// Per-step wire tags for the macro bytecode this decoder reads. Unlike
/// `KeymapCellTag` matched against `KeyCode`/`Modifier`, this enum's raw
/// values are never overridden, so the compiler-synthesized
/// `init?(rawValue:)` maps them correctly -- no ordinal landmine here.
private enum MacroStepTag: UInt8 {
    case keystroke = 0
    case text = 1
    case delay = 2
    case layer = 3
    case repeatBlock = 4
}

/// Decodes a full binary keymap payload: the 6-byte header, the matrix's
/// `rows`/`cols` GPIO arrays, `layerCount` layers of two-byte cells, and
/// `macroCount` macro entries -- or `nil` if any of it doesn't fit.
///
/// Binary loses the bounds checking JSON parsing gave for free, so every
/// field is validated against the bytes actually remaining *before* it is
/// read -- header, then rows+cols, then the computed layer region, then
/// each macro's declared name length and step count -- never indexed first
/// and checked after. Sizes are computed in `Int` throughout (each header
/// byte is widened with `Int(...)` immediately on read), never left as
/// `UInt8`/`UInt16` arithmetic, so a corrupt header claiming e.g. 200 rows
/// and 200 columns cannot overflow into a small number that then slips
/// past a bounds check -- it is instead rejected by the plain `Int`
/// comparison against how many bytes are actually present.
func decodeKeymapPayload(_ bytes: UnsafePointer<UInt8>?, count: Int) -> KeymapPayload? {
    guard let bytes = bytes, count >= 6 else { return nil }

    let rowCount = Int(bytes[0])
    let colCount = Int(bytes[1])
    let colsAreDriven = bytes[2] != 0
    let layerCount = Int(bytes[3])
    let macroCount = Int(bytes[4])
    // bytes[5] is reserved.

    var offset = 6
    guard offset + rowCount + colCount <= count else { return nil }

    let rows = Array(UnsafeBufferPointer(start: bytes + offset, count: rowCount))
    offset += rowCount
    let cols = Array(UnsafeBufferPointer(start: bytes + offset, count: colCount))
    offset += colCount

    let layerRegionBytes = layerCount * rowCount * colCount * 2
    guard offset + layerRegionBytes <= count else { return nil }

    var layers: [[[KeyAction]]] = []
    layers.reserveCapacity(layerCount)
    for _ in 0..<layerCount {
        var layer: [[KeyAction]] = []
        layer.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            var row: [KeyAction] = []
            row.reserveCapacity(colCount)
            for _ in 0..<colCount {
                row.append(decodeCell(bytes[offset], bytes[offset + 1]))
                offset += 2
            }
            layer.append(row)
        }
        layers.append(layer)
    }

    var macros: [MacroDefinition] = []
    macros.reserveCapacity(macroCount)
    for _ in 0..<macroCount {
        guard let macro = decodeMacroEntry(bytes, &offset, count) else { return nil }
        macros.append(macro)
    }

    return KeymapPayload(rows: rows, cols: cols, colsAreDriven: colsAreDriven, layers: layers, macros: macros)
}

/// Decodes one macro entry: id, a length-prefixed name (kept only for the
/// editor/library display this format's design doc describes -- discarded
/// here since `MacroDefinition` has no name field to hold it), then a
/// length-prefixed step list. Every length is checked against the bytes
/// remaining before anything past it is read.
private func decodeMacroEntry(_ bytes: UnsafePointer<UInt8>, _ offset: inout Int, _ count: Int) -> MacroDefinition? {
    guard offset + 1 <= count else { return nil }
    let id = Int(bytes[offset])
    offset += 1

    guard offset + 1 <= count else { return nil }
    let nameLen = Int(bytes[offset])
    offset += 1
    guard offset + nameLen <= count else { return nil }
    offset += nameLen  // Name bytes aren't retained; see comment above.

    guard offset + 1 <= count else { return nil }
    let stepCount = Int(bytes[offset])
    offset += 1

    var steps: [MacroStep] = []
    steps.reserveCapacity(stepCount)
    for _ in 0..<stepCount {
        guard let step = decodeMacroStep(bytes, &offset, count, allowRepeatBlock: true) else { return nil }
        steps.append(step)
    }
    return MacroDefinition(id: id, steps: steps)
}

/// Decodes one macro step. `allowRepeatBlock` is `false` while decoding a
/// repeat block's own body: a repeat block whose steps contain another
/// repeat block is refused here rather than at playback, because
/// `MacroPlayer` uses a single loop counter, not a stack, and nesting must
/// never reach it.
private func decodeMacroStep(
    _ bytes: UnsafePointer<UInt8>, _ offset: inout Int, _ count: Int, allowRepeatBlock: Bool
) -> MacroStep? {
    guard offset + 1 <= count else { return nil }
    guard let tag = MacroStepTag(rawValue: bytes[offset]) else { return nil }
    offset += 1

    switch tag {
    case .keystroke:
        guard offset + 4 <= count else { return nil }
        let mods = bytes[offset]
        let key = bytes[offset + 1]
        let holdMs = Int(bytes[offset + 2]) | (Int(bytes[offset + 3]) << 8)
        offset += 4
        return .keystroke(mods: mods, key: key, holdMs: holdMs)

    case .text:
        guard offset + 1 <= count else { return nil }
        let len = Int(bytes[offset])
        offset += 1
        // Both the string bytes and the msPerChar field that follows them
        // must fit before either is read.
        guard offset + len + 2 <= count else { return nil }
        let text = String(decoding: UnsafeBufferPointer(start: bytes + offset, count: len), as: UTF8.self)
        offset += len
        let msPerChar = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        offset += 2
        return .text(text, msPerChar: msPerChar)

    case .delay:
        guard offset + 2 <= count else { return nil }
        let ms = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        offset += 2
        return .delay(ms: ms)

    case .layer:
        guard offset + 2 <= count else { return nil }
        let momentary = bytes[offset] != 0
        let n = Int(bytes[offset + 1])
        offset += 2
        return .layer(momentary: momentary, n: n)

    case .repeatBlock:
        guard allowRepeatBlock else { return nil }
        guard offset + 2 <= count else { return nil }
        let repeatCount = Int(bytes[offset])
        let nestedStepCount = Int(bytes[offset + 1])
        offset += 2
        var nested: [MacroStep] = []
        nested.reserveCapacity(nestedStepCount)
        for _ in 0..<nestedStepCount {
            guard let step = decodeMacroStep(bytes, &offset, count, allowRepeatBlock: false) else { return nil }
            nested.append(step)
        }
        return .repeatBlock(count: repeatCount, steps: nested)
    }
}
