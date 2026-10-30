import Testing
import Foundation
@testable import MonitorCore

@Suite struct SMCTests {
    @Test func decodeFloat() throws {
        var f = Float(101.8)
        let bytes = withUnsafeBytes(of: &f) { Array($0) }
        let v = try #require(SMCDecode.value(type: "flt ", bytes: bytes))
        #expect(abs(v - 101.8) < 0.01)
    }

    @Test func decodeUInt16LittleEndian() {
        // B0AV proof from the research: little-endian 0x322C = 12,844 mV.
        #expect(SMCDecode.value(type: "ui16", bytes: [0x2C, 0x32]) == 12_844)
    }

    @Test func decodeIoft() throws {
        var raw = UInt64(65536.0 * 24.8)
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        let v = try #require(SMCDecode.value(type: "ioft", bytes: bytes))
        #expect(abs(v - 24.8) < 0.001)
    }

    @Test func unknownTypeIsNil() {
        #expect(SMCDecode.value(type: "{jst", bytes: [1, 2, 3, 4]) == nil)
        #expect(SMCDecode.value(type: "flt ", bytes: [1]) == nil) // too short
    }

    @Test func groupLabels() {
        let p = SMCGroup.group(for: "Tp0A")
        #expect(p.name == "P cores")
        #expect(p.proven == false)
        let b = SMCGroup.group(for: "TB0T")
        #expect(b.name == "Battery")
        #expect(b.proven == true)
        #expect(SMCGroup.group(for: "TR0Z").proven == true)
        #expect(SMCGroup.group(for: "Zzzz").name == "Unknown")
    }

    @Test(.tags(.live)) func liveSMCReadsFanCount() throws {
        let smc = try #require(SMC())
        #expect(smc.read("FNum") == 2)
    }
}
