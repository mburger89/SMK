import Testing
@testable import SMKCore

// smk_keymap_dispatch_packet's real @_extern-backed storage calls only
// exist on embedded targets (see KeymapProtocol.swift), so these tests
// exercise smkKeymapDispatchPacket(...) directly with injected fake
// closures instead — that's the seam Task 4 added specifically to make
// this dispatch logic host-testable ahead of Task 5/6/7 moving the
// per-port storage layer to Swift.

private func packet(_ bytes: [UInt8]) -> [UInt8] {
    var p = bytes
    while p.count < smkKeymapPacketLen { p.append(0) }
    return p
}

private func neverCalledWriteChunk(_ offset: UInt16, _ data: UnsafePointer<UInt8>, _ len: UInt16) -> Int32 {
    Issue.record("writeChunk should not have been called")
    return -1
}

@Test func dispatchBeginCallsBeginWriteWithDecodedTotalLen() {
    var seenTotalLen: UInt16?
    let pkt = packet([smkKeymapOpBegin, 0x34, 0x12]) // totalLen = 0x1234 LE
    var response = [UInt8](repeating: 0xFF, count: smkKeymapPacketLen)

    pkt.withUnsafeBufferPointer { pktBuf in
        response.withUnsafeMutableBufferPointer { respBuf in
            smkKeymapDispatchPacket(
                pktBuf.baseAddress!, respBuf.baseAddress!,
                beginWrite: { totalLen in seenTotalLen = totalLen; return 0 },
                writeChunk: neverCalledWriteChunk,
                commit: { _ in Issue.record("commit should not have been called"); return -1 },
                erase: { Issue.record("erase should not have been called") },
                caps: { Issue.record("caps should not have been called"); return (0, 0, 0) }
            )
        }
    }

    #expect(seenTotalLen == 0x1234)
    #expect(response[0] == 0x00) // status OK
    #expect(response[1] == smkKeymapOpBegin)
}

@Test func dispatchChunkOversizedLenShortCircuitsWithoutCallingWriteChunk() {
    // smkKeymapPacketLen (32) - 4 header bytes = 28 max data bytes.
    let pkt = packet([smkKeymapOpChunk, 0x00, 0x00, 29])
    var response = [UInt8](repeating: 0xFF, count: smkKeymapPacketLen)

    pkt.withUnsafeBufferPointer { pktBuf in
        response.withUnsafeMutableBufferPointer { respBuf in
            smkKeymapDispatchPacket(
                pktBuf.baseAddress!, respBuf.baseAddress!,
                beginWrite: { _ in Issue.record("beginWrite should not have been called"); return -1 },
                writeChunk: neverCalledWriteChunk,
                commit: { _ in Issue.record("commit should not have been called"); return -1 },
                erase: { Issue.record("erase should not have been called") },
                caps: { Issue.record("caps should not have been called"); return (0, 0, 0) }
            )
        }
    }

    #expect(response[0] == 0x01) // status ERR
    #expect(response[1] == smkKeymapOpChunk)
}

@Test func dispatchChunkAtMaxLenCallsWriteChunkWithDecodedArgs() {
    var seenOffset: UInt16?
    var seenLen: UInt16?
    var seenFirstByte: UInt8?
    var header: [UInt8] = [smkKeymapOpChunk, 0x02, 0x00, 28] // offset = 2, chunkLen = 28
    header.append(contentsOf: (0..<28).map { UInt8($0) })
    let pkt = packet(header)
    var response = [UInt8](repeating: 0xFF, count: smkKeymapPacketLen)

    pkt.withUnsafeBufferPointer { pktBuf in
        response.withUnsafeMutableBufferPointer { respBuf in
            smkKeymapDispatchPacket(
                pktBuf.baseAddress!, respBuf.baseAddress!,
                beginWrite: { _ in Issue.record("beginWrite should not have been called"); return -1 },
                writeChunk: { offset, data, len in
                    seenOffset = offset
                    seenLen = len
                    seenFirstByte = data[0]
                    return 0
                },
                commit: { _ in Issue.record("commit should not have been called"); return -1 },
                erase: { Issue.record("erase should not have been called") },
                caps: { Issue.record("caps should not have been called"); return (0, 0, 0) }
            )
        }
    }

    #expect(seenOffset == 2)
    #expect(seenLen == 28)
    #expect(seenFirstByte == 0)
    #expect(response[0] == 0x00) // status OK
}

@Test func dispatchCommitCallsCommitWithDecodedCrc32() {
    var seenCrc: UInt32?
    let pkt = packet([smkKeymapOpCommit, 0x26, 0x39, 0xF4, 0xCB]) // 0xCBF43926 LE
    var response = [UInt8](repeating: 0xFF, count: smkKeymapPacketLen)

    pkt.withUnsafeBufferPointer { pktBuf in
        response.withUnsafeMutableBufferPointer { respBuf in
            smkKeymapDispatchPacket(
                pktBuf.baseAddress!, respBuf.baseAddress!,
                beginWrite: { _ in Issue.record("beginWrite should not have been called"); return -1 },
                writeChunk: neverCalledWriteChunk,
                commit: { crc32 in seenCrc = crc32; return 0 },
                erase: { Issue.record("erase should not have been called") },
                caps: { Issue.record("caps should not have been called"); return (0, 0, 0) }
            )
        }
    }

    #expect(seenCrc == 0xCBF4_3926)
    #expect(response[0] == 0x00) // status OK
}

@Test func dispatchEraseCallsEraseAndAlwaysReportsOk() {
    var eraseCalled = false
    let pkt = packet([smkKeymapOpErase])
    var response = [UInt8](repeating: 0xFF, count: smkKeymapPacketLen)

    pkt.withUnsafeBufferPointer { pktBuf in
        response.withUnsafeMutableBufferPointer { respBuf in
            smkKeymapDispatchPacket(
                pktBuf.baseAddress!, respBuf.baseAddress!,
                beginWrite: { _ in Issue.record("beginWrite should not have been called"); return -1 },
                writeChunk: neverCalledWriteChunk,
                commit: { _ in Issue.record("commit should not have been called"); return -1 },
                erase: { eraseCalled = true },
                caps: { Issue.record("caps should not have been called"); return (0, 0, 0) }
            )
        }
    }

    #expect(eraseCalled)
    #expect(response[0] == 0x00) // status OK
    #expect(response[1] == smkKeymapOpErase)
}

@Test func dispatchUnknownOpcodeReturnsErrWithoutCallingAnyStorageOp() {
    let pkt = packet([0xFF])
    var response = [UInt8](repeating: 0xFF, count: smkKeymapPacketLen)

    pkt.withUnsafeBufferPointer { pktBuf in
        response.withUnsafeMutableBufferPointer { respBuf in
            smkKeymapDispatchPacket(
                pktBuf.baseAddress!, respBuf.baseAddress!,
                beginWrite: { _ in Issue.record("beginWrite should not have been called"); return -1 },
                writeChunk: neverCalledWriteChunk,
                commit: { _ in Issue.record("commit should not have been called"); return -1 },
                erase: { Issue.record("erase should not have been called") },
                caps: { Issue.record("caps should not have been called"); return (0, 0, 0) }
            )
        }
    }

    #expect(response[0] == 0x01) // status ERR
    #expect(response[1] == 0xFF)
}

@Test func dispatchZeroesResponseBufferBeforeWriting() {
    let pkt = packet([smkKeymapOpErase])
    var response = [UInt8](repeating: 0xAB, count: smkKeymapPacketLen)

    pkt.withUnsafeBufferPointer { pktBuf in
        response.withUnsafeMutableBufferPointer { respBuf in
            smkKeymapDispatchPacket(
                pktBuf.baseAddress!, respBuf.baseAddress!,
                beginWrite: { _ in -1 },
                writeChunk: { _, _, _ in -1 },
                commit: { _ in -1 },
                erase: { },
                caps: { Issue.record("caps should not have been called"); return (0, 0, 0) }
            )
        }
    }

    // Everything past byte 1 (status/opcode) must be zeroed, not left at
    // the caller's stale 0xAB filler.
    #expect(response[2...].allSatisfy { $0 == 0 })
}

@Test func dispatchCapsReturnsMacroAndKeymapCapacityLittleEndian() {
    let pkt = packet([smkKeymapOpCaps])
    var response = [UInt8](repeating: 0xFF, count: smkKeymapPacketLen)

    pkt.withUnsafeBufferPointer { pktBuf in
        response.withUnsafeMutableBufferPointer { respBuf in
            smkKeymapDispatchPacket(
                pktBuf.baseAddress!, respBuf.baseAddress!,
                beginWrite: { _ in Issue.record("beginWrite should not have been called"); return -1 },
                writeChunk: neverCalledWriteChunk,
                commit: { _ in Issue.record("commit should not have been called"); return -1 },
                erase: { Issue.record("erase should not have been called") },
                caps: { (macroBytes: 0x1234, macroSlots: 7, keymapMaxLen: 0xABCD) }
            )
        }
    }

    #expect(response[0] == 0x00) // status OK
    #expect(response[1] == smkKeymapOpCaps)
    #expect(response[2] == 0x34) // macroBytes low byte
    #expect(response[3] == 0x12) // macroBytes high byte
    #expect(response[4] == 7) // macroSlots
    #expect(response[5] == 0xCD) // keymapMaxLen low byte
    #expect(response[6] == 0xAB) // keymapMaxLen high byte
}
