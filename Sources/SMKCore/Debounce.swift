struct DebouncedMatrix {
    private let totalKeys: Int
    private let debounceThreshold = 5

    private var counters: [Int]
    private var stableState: [Bool]

    init(totalKeys: Int) {
        self.totalKeys = totalKeys
        self.counters = [Int](repeating: 0, count: totalKeys)
        self.stableState = [Bool](repeating: false, count: totalKeys)
    }

    mutating func update(rawScan: [Bool]) -> [Bool] {
        for i in 0..<totalKeys {
            if i >= rawScan.count { break }
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
