/// The most key positions (rows × cols) any board may declare. Fixed so
/// scan/debounce state lives in inline storage with no per-tick heap
/// allocation; `decodeKeymapPayload` rejects larger matrices. The largest
/// real board (smk_kbd) uses 60.
let smkMaxMatrixPositions = 256

/// One bit per matrix position (index = row * colCount + col).
struct KeyBitset: Equatable {
    static let capacity = 256
    private var words: InlineArray<8, UInt32> = .init(repeating: 0)

    init() {}

    subscript(i: Int) -> Bool {
        get { (words[i >> 5] >> UInt32(i & 31)) & 1 == 1 }
        set {
            let mask: UInt32 = 1 << UInt32(i & 31)
            if newValue { words[i >> 5] |= mask } else { words[i >> 5] &= ~mask }
        }
    }

    // Hand-written: InlineArray isn't Equatable, so this can't be synthesized.
    static func == (lhs: KeyBitset, rhs: KeyBitset) -> Bool {
        for w in 0..<8 where lhs.words[w] != rhs.words[w] { return false }
        return true
    }
}
