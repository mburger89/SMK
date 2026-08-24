/// The board's GPIO matrix: which pins are rows, which are columns, and
/// which side is driven. Built from the compiled-in binary keymap payload's
/// header (see `Config(payload:)`); until cJSON was retired this was parsed
/// out of a `"matrix"` object in a JSON string literal instead.
struct Config {
    var rowPins: [Int32] = []
    var colPins: [Int32] = []
    var colsAreDriven: Bool = false
}

extension Config {
    /// Builds the matrix config from a decoded binary keymap payload. The
    /// payload header already carries `rows[]`, `cols[]` and
    /// `colsAreDriven`, so a board's matrix and its layers come from one
    /// artifact instead of two representations that can disagree.
    ///
    /// In an extension, not the struct body: declaring an initialiser in the
    /// body would suppress the compiler-provided `Config()` that this one
    /// delegates to.
    ///
    /// Explicit loops rather than `map`: SMKCore compiles under Embedded
    /// Swift for every board, and the rest of this module builds arrays the
    /// same way.
    init(payload: KeymapPayload) {
        self.init()
        rowPins.reserveCapacity(payload.rows.count)
        for pin in payload.rows { rowPins.append(Int32(pin)) }
        colPins.reserveCapacity(payload.cols.count)
        for pin in payload.cols { colPins.append(Int32(pin)) }
        colsAreDriven = payload.colsAreDriven
    }
}
