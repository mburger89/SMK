import Testing
@testable import SMKCore

@Test func connectionModeTogglesBetweenWiredAndBluetooth() {
    var mode = ConnectionMode.bluetooth
    mode.toggle()
    #expect(mode == .wired)
    mode.toggle()
    #expect(mode == .bluetooth)
}
