import Testing
import CJSON

@Test func cJSONParsesAndReadsASimpleObject() {
    let root = "{\"answer\": 42}".withCString { cJSON_Parse($0) }
    #expect(root != nil)
    defer { cJSON_Delete(root) }

    let answer = cJSON_GetObjectItem(root, "answer")
    #expect(answer != nil)
    #expect(answer?.pointee.valuedouble == 42)
}
