import Testing
@testable import SMKCore

/// The keycode array's Logical/Usage Maximum used to be pinned at 0x65, which
/// silently excluded every usage above `application` -- F13-F24, the editing
/// block, International/Language, the legacy block. A host quietly dropping a
/// key is invisible from a dev machine, so the bytes are asserted here instead.
@Suite("BLE HID report map declares the full keyboard usage range")
struct HIDReportMapTests {
    @Test("report map is a Report ID 1 keyboard collection")
    func reportIDAndUsagePage() {
        #expect(hidKeyboardReportMap.starts(with: [0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01]))
    }

    @Test("logical and usage maximum both span the full 0-255 range")
    func usageRangeIsFull() {
        // Logical Maximum 255, two-byte form.
        #expect(hidKeyboardReportMap.contains(subsequence: [0x26, 0xFF, 0x00]))
        // Usage Maximum 255, two-byte form.
        #expect(hidKeyboardReportMap.contains(subsequence: [0x2A, 0xFF, 0x00]))
        // The old one-byte 101 caps must be gone.
        #expect(!hidKeyboardReportMap.contains(subsequence: [0x25, 0x65]))
        #expect(!hidKeyboardReportMap.contains(subsequence: [0x29, 0x65]))
    }

    @Test("the modifier range is untouched")
    func modifierRangeUnchanged() {
        // Usage Min LeftControl (0xE0) through Usage Max Right GUI (0xE7).
        #expect(hidKeyboardReportMap.contains(subsequence: [0x19, 0xe0, 0x29, 0xe7]))
    }

    @Test("collection is well-formed")
    func endsWithCollectionEnd() {
        #expect(hidKeyboardReportMap.last == 0xc0)
    }
}

private extension Array where Element == UInt8 {
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for i in 0...(count - needle.count) where Array(self[i..<i + needle.count]) == needle {
            return true
        }
        return false
    }
}
