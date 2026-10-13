struct DebouncedMatrix {
    private let totalKeys: Int
    private let debounceThreshold: UInt8 = 5

    // Fixed-size inline state (KeyBitset.capacity positions) so a debounce
    // pass never touches the heap.
    private var counters: InlineArray<256, UInt8> = .init(repeating: 0)
    private var stableState = KeyBitset()

    init(totalKeys: Int) {
        self.totalKeys = min(totalKeys, KeyBitset.capacity)
    }

    mutating func update(rawScan: KeyBitset) -> KeyBitset {
        for i in 0..<totalKeys {
            if rawScan[i] != stableState[i] {
                counters[i] += 1
                if counters[i] >= debounceThreshold {
                    stableState[i] = rawScan[i]
                    counters[i] = 0
                }
            } else {
                counters[i] = 0
            }
        }
        return stableState
    }
}
