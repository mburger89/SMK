enum ConnectionMode {
    case wired
    case bluetooth

    mutating func toggle() {
        if self == .wired {
            self = .bluetooth
        } else {
            self = .wired
        }
    }
}
