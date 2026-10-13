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

/// Per-step wire opcodes for the macro bytecode this decoder reads --
/// 1-based, matching the configurator compiler's existing wire format
/// (not renumbered to 0-based tags the way `KeymapCellTag` is). This enum's
/// raw values are never overridden, so the compiler-synthesized
/// `init?(rawValue:)` maps them correctly -- no ordinal landmine here.
private enum MacroStepOpcode: UInt8 {
    case keystroke = 0x01
    case delay = 0x02
    case layer = 0x03
    case text = 0x04
    case repeatBlock = 0x05
}

/// Why a payload was refused. The caller treats every case the same way
/// (keep the previous / compiled-in keymap); the cases exist so tests can
/// pin *which* guard fired.
enum KeymapDecodeError: Error, Equatable {
    /// A declared length runs past the end of the bytes.
    case truncated
    /// `rowCount * colCount` exceeds `smkMaxMatrixPositions`, the number of
    /// keys `KeyBitset` can hold.
    case matrixTooLarge
    /// `layerCount > 0` over a 0x0 matrix -- see the guard's comment below.
    case layersWithoutMatrix
    /// A macro entry or step that is truncated, has an unknown opcode, nests
    /// a repeat block, or whose repeat body doesn't match its bodyLength.
    case badMacro
    /// Bytes left over after everything the header declared.
    case trailingBytes
}

/// Decodes a full binary keymap payload: the 6-byte header, the matrix's
/// `rows`/`cols` GPIO arrays, `layerCount` layers of two-byte cells, and
/// `macroCount` macro entries -- or throws if any of it doesn't fit.
///
/// Binary loses the bounds checking JSON parsing gave for free, so every
/// field is validated against the bytes actually remaining *before* it is
/// read -- header, then rows+cols, then the computed layer region, then
/// each macro's declared name length and step count -- never indexed first
/// and checked after. `Span`'s subscript is itself bounds-checked, but an
/// out-of-range index *traps* (a hard fault on device), so these guards are
/// still what turn a truncated stored keymap into a thrown error the caller
/// can fall back from (pinned by everyPrefixOfAValidPayloadThrowsInsteadOfTrapping).
/// Sizes are computed in `Int` throughout (each header
/// byte is widened with `Int(...)` immediately on read), never left as
/// `UInt8`/`UInt16` arithmetic, so a corrupt header claiming e.g. 200 rows
/// and 200 columns cannot overflow into a small number that then slips
/// past a bounds check -- it is instead rejected by the plain `Int`
/// comparison against how many bytes are actually present.
func decodeKeymapPayload(_ bytes: Span<UInt8>) throws(KeymapDecodeError) -> KeymapPayload {
    let count = bytes.count
    guard count >= 6 else { throw .truncated }

    let rowCount = Int(bytes[0])
    let colCount = Int(bytes[1])
    let colsAreDriven = bytes[2] != 0
    let layerCount = Int(bytes[3])
    let macroCount = Int(bytes[4])
    // bytes[5] is reserved.

    // KeyBitset (scan, debounce, event processing) holds exactly
    // smkMaxMatrixPositions keys; a larger matrix would index past it.
    guard rowCount * colCount <= smkMaxMatrixPositions else { throw .matrixTooLarge }

    var offset = 6
    guard offset + rowCount + colCount <= count else { throw .truncated }

    var rows: [UInt8] = []
    rows.reserveCapacity(rowCount)
    for i in 0..<rowCount { rows.append(bytes[offset + i]) }
    offset += rowCount
    var cols: [UInt8] = []
    cols.reserveCapacity(colCount)
    for i in 0..<colCount { cols.append(bytes[offset + i]) }
    offset += colCount

    // `layerRegionBytes` is 0 whenever rowCount or colCount is 0, regardless
    // of layerCount -- so without this guard a header claiming e.g. 200
    // layers of a 0x0 matrix would pass the size check below (0 <= count)
    // and decode into 200 layers that are each an empty array of empty
    // rows. `LayerEngine.loadKeymap(_:)`'s own `!layers.isEmpty` check
    // is true for that (the outer array has 200 elements), so it would
    // replace a working keymap with one where every cell resolves to
    // `.none` -- a six-byte payload permanently blanking the keyboard,
    // recoverable only via the reset-held boot path. A declared layer with
    // no rows or columns is never valid, so refuse it here instead.
    guard layerCount == 0 || (rowCount > 0 && colCount > 0) else { throw .layersWithoutMatrix }

    let layerRegionBytes = layerCount * rowCount * colCount * 2
    guard offset + layerRegionBytes <= count else { throw .truncated }

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
        macros.append(try decodeMacroEntry(bytes, &offset))
    }

    // Every length in this format is validated against bytes remaining
    // *before* being read, but nothing previously checked that the whole
    // payload was actually consumed by the header + matrix + layers +
    // macros it declared -- inconsistent with decodeMacroStep's own
    // strictness about exactly this for a repeat block's body (see
    // `guard offset == bodyEnd` below). Trailing garbage past what the
    // declared counts account for is a format error, not something to
    // silently ignore.
    guard offset == count else { throw .trailingBytes }

    return KeymapPayload(rows: rows, cols: cols, colsAreDriven: colsAreDriven, layers: layers, macros: macros)
}

/// Decodes one macro entry: id, a length-prefixed name (kept only for the
/// editor/library display this format's design doc describes -- discarded
/// here since `MacroDefinition` has no name field to hold it), then a
/// length-prefixed step list. Every length is checked against the bytes
/// remaining before anything past it is read.
private func decodeMacroEntry(_ bytes: Span<UInt8>, _ offset: inout Int) throws(KeymapDecodeError) -> MacroDefinition {
    let count = bytes.count
    guard offset + 1 <= count else { throw .badMacro }
    let id = Int(bytes[offset])
    offset += 1

    guard offset + 1 <= count else { throw .badMacro }
    let nameLen = Int(bytes[offset])
    offset += 1
    guard offset + nameLen <= count else { throw .badMacro }
    offset += nameLen  // Name bytes aren't retained; see comment above.

    guard offset + 1 <= count else { throw .badMacro }
    let stepCount = Int(bytes[offset])
    offset += 1

    var steps: [MacroStep] = []
    steps.reserveCapacity(stepCount)
    for _ in 0..<stepCount {
        steps.append(try decodeMacroStep(bytes, &offset, allowRepeatBlock: true))
    }
    return MacroDefinition(id: id, steps: steps)
}

/// Decodes one macro step in the wire format the configurator's compiler
/// emits: `opcode(1)` then opcode-specific fields. `allowRepeatBlock` is
/// `false` while decoding a repeat block's own body: a repeat block whose
/// steps contain another repeat block is refused here rather than at
/// playback, because `MacroPlayer` uses a single loop counter, not a
/// stack, and nesting must never reach it.
private func decodeMacroStep(
    _ bytes: Span<UInt8>, _ offset: inout Int, allowRepeatBlock: Bool
) throws(KeymapDecodeError) -> MacroStep {
    let count = bytes.count
    guard offset + 1 <= count else { throw .badMacro }
    guard let opcode = MacroStepOpcode(rawValue: bytes[offset]) else { throw .badMacro }
    offset += 1

    switch opcode {
    case .keystroke:
        // opcode(1) + mods(1) + keycode(1) + holdMs(2 LE) -- already consumed opcode.
        guard offset + 4 <= count else { throw .badMacro }
        let mods = bytes[offset]
        let key = bytes[offset + 1]
        let holdMs = Int(bytes[offset + 2]) | (Int(bytes[offset + 3]) << 8)
        offset += 4
        return .keystroke(mods: mods, key: key, holdMs: holdMs)

    case .delay:
        // opcode(1) + ms(2 LE)
        guard offset + 2 <= count else { throw .badMacro }
        let ms = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        offset += 2
        return .delay(ms: ms)

    case .layer:
        // opcode(1) + op(1) + index(1). op's momentary/toggle mapping is not
        // pinned by the format's own documentation -- 0 = momentary ("mo"),
        // 1 = toggle ("tg"), inferred from this codebase's consistent
        // mo-before-tg ordering (KeymapCellTag.momentaryLayer/.toggleLayer,
        // KeyAction.fromCString's "mo:"/"tg:" check order) and flagged for
        // confirmation against the configurator's actual compiler in the
        // task report -- NOT independently verified against another
        // implementation the way the modifier bit order was.
        guard offset + 2 <= count else { throw .badMacro }
        let op = bytes[offset]
        let index = Int(bytes[offset + 1])
        offset += 2
        return .layer(momentary: op == 0, n: index)

    case .text:
        // opcode(1) + delivery(1) + msPerChar(1) + length(1) + payload(length).
        // `delivery` (0x00 keystrokes / 0x01 paste) is preserved on the wire
        // by design -- paste can't work board-side and the editor already
        // refuses to save it, so this decoder reads past the byte without
        // interpreting it, rather than dropping the stride all three
        // implementations share.
        guard offset + 3 <= count else { throw .badMacro }
        let msPerChar = Int(bytes[offset + 1])
        let length = Int(bytes[offset + 2])
        offset += 3
        guard offset + length <= count else { throw .badMacro }
        let text = bytes.extracting(offset..<offset + length).withUnsafeBufferPointer {
            String(decoding: $0, as: UTF8.self)
        }
        offset += length
        return .text(text, msPerChar: msPerChar)

    case .repeatBlock:
        // opcode(1) + count(1) + bodyLength(2 LE) + body(bodyLength).
        // bodyLength is attacker-controlled (a corrupt/malicious frame), so
        // it is validated against the bytes remaining before any nested
        // step is decoded, exactly like every other length in this format.
        guard allowRepeatBlock else { throw .badMacro }
        guard offset + 3 <= count else { throw .badMacro }
        let repeatCount = Int(bytes[offset])
        let bodyLength = Int(bytes[offset + 1]) | (Int(bytes[offset + 2]) << 8)
        offset += 3
        guard offset + bodyLength <= count else { throw .badMacro }
        let bodyEnd = offset + bodyLength

        var nested: [MacroStep] = []
        while offset < bodyEnd {
            nested.append(try decodeMacroStep(bytes, &offset, allowRepeatBlock: false))
        }
        // A nested step's own fields are always bounds-checked against the
        // real buffer (`count`), so overrunning bodyEnd is never a memory
        // safety issue -- but a step landing short of or past the declared
        // bodyLength means the body doesn't parse as a clean sequence of
        // steps, which is refused as a format error rather than silently
        // accepted with a mismatched length.
        guard offset == bodyEnd else { throw .badMacro }
        return .repeatBlock(count: repeatCount, steps: nested)
    }
}
