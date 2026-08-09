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
