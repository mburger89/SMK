#if canImport(CJSON)
import CJSON
#endif

struct Config {
    var rowPins: [Int32] = []
    var colPins: [Int32] = []
    var colsAreDriven: Bool = false

    static func fromJson(_ json: String) -> Config {
        var cfg = Config()
        guard let root = cJSON_Parse(json) else { return cfg }
        defer { cJSON_Delete(root) }

        if let matrix = cJSON_GetObjectItem(root, "matrix") {
            if let rows = cJSON_GetObjectItem(matrix, "rows") {
                for i in 0..<cJSON_GetArraySize(rows) {
                    if let item = cJSON_GetArrayItem(rows, i) {
                        cfg.rowPins.append(Int32(item.pointee.valuedouble))
                    }
                }
            }
            if let cols = cJSON_GetObjectItem(matrix, "cols") {
                for i in 0..<cJSON_GetArraySize(cols) {
                    if let item = cJSON_GetArrayItem(cols, i) {
                        cfg.colPins.append(Int32(item.pointee.valuedouble))
                    }
                }
            }
            if let driven = cJSON_GetObjectItem(matrix, "colsAreDriven") {
                cfg.colsAreDriven = driven.pointee.valuedouble != 0
            }
        }
        return cfg
    }
}

extension Config {
    /// Builds the GPIO matrix config from a decoded binary keymap payload.
    /// The payload header already carries every field `fromJson` dug out of
    /// a `"matrix"` object -- `rows[]`, `cols[]` and `colsAreDriven` -- so a
    /// board's matrix and its layers come from one artifact instead of two
    /// representations that can disagree.
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
