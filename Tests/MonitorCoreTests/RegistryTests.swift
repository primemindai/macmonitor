import Testing
import Foundation
@testable import MonitorCore

@Suite struct RegistryTests {
    func batteryFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL("battery_ioreg.plist"))
        let arr = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]])
        return try #require(arr.first)
    }

    @Test func batteryFixtureParses() throws {
        let b = BatteryInfo.parse(ioreg: try batteryFixture(), iops: ["BatteryHealth": "Check Battery", "DesignCycleCount": 1000])
        #expect(b.cycleCount == 179)
        #expect(b.designCycles == 1000)
        #expect(b.designCapacity == 6_249)
        #expect(b.rawMaxCapacity == 5_099)
        #expect(b.rawHealthPercent == 81.6)
        #expect(b.appleMaxCapacityPercent == 84)
        #expect(b.iopsHealth == "Check Battery")
        #expect(b.cellVoltagesMV == [4_281, 4_282, 4_282])
        #expect(b.adapterName == "96W USB-C Power Adapter")
        #expect(b.adapterWatts == 94)
        #expect(b.temperatureC == 30.94)
        #expect(b.lifetimeMaxTempC == 41)
        #expect(b.cellResistance == [76, 73, 75])
        #expect(b.wallPowerW == 53.394)
        #expect(b.adapterLossW == 1.504)
        #expect(b.pdMenu.count == 4)
        // No serial field exists on the struct at all.
        let labels = Mirror(reflecting: b).children.compactMap { $0.label?.lowercased() }
        #expect(!labels.contains { $0.contains("serial") })
        let json = String(decoding: try JSONEncoder().encode(b), as: UTF8.self).lowercased()
        #expect(!json.contains("serial"))
    }

    @Test func smartUnitsToTB() {
        #expect(abs(NVMe.unitsToTB(218_243_862) - 111.74) < 0.01)
    }

    @Test func smartKelvin() {
        #expect(NVMe.kelvinToC(338) == 65)
    }

    @Test func hidDedupesAndDropsJunk() {
        let raw: [(String, Double)] = [("PMU tdev1", -9_200), ("PMU tdie1", 79.1), ("PMU tdie1", 80.0), ("PMU tdie1", 79.9),
                                       ("NAND CH0 temp", 63), ("(null)", -999)]
        let t = HIDSensors.clean(raw)
        #expect(t.filter { $0.name == "PMU tdie1" }.count == 1)
        #expect(t.first { $0.name == "PMU tdie1" }?.celsius == 80.0)
        #expect(!t.contains { $0.name == "PMU tdev1" })
        #expect(t.contains { $0.name == "NAND CH0 temp" })
        #expect(t.count == 2)
    }

    @Test func gpuCreatorParses() {
        let r = Registry.parseCreator("pid 396, WindowServer")
        #expect(r?.pid == 396)
        #expect(r?.name == "WindowServer")
        #expect(Registry.parseCreator("garbage") == nil)
    }

    @Test func gpuStatsParse() {
        let g = GPUStats.parse(["Device Utilization %": 41, "Renderer Utilization %": 40, "Tiler Utilization %": 15,
                                "In use system memory": 1_030_000_000, "Alloc system memory": 3_990_000_000, "recoveryCount": 0])
        #expect(g.deviceUtil == 41)
        #expect(g.tilerUtil == 15)
        #expect(g.inUseBytes == 1_030_000_000)
        #expect(g.resets == 0)
        #expect(GPUStats.parse([:]).deviceUtil == nil)
    }

    @Test(.tags(.live)) func liveReadersDoNotCrash() {
        let t0 = Date()
        let gpu = Registry.gpuStats()
        let gpuNs = Registry.gpuTimeByPID()
        let bat = Registry.battery()
        let disp = Registry.display()
        let hid = HIDSensors.temperatures()
        let lid = HIDSensors.lidAngle()
        let smart = NVMe.read()
        print(String(format: "registry+HID+NVMe cost %.1f ms", Date().timeIntervalSince(t0) * 1000))
        print("gpu:", gpu as Any)
        print("gpu clients:", gpuNs.count, "battery:", bat?.percent as Any, bat?.cycleCount as Any, "display:", disp as Any)
        print("hid temps:", hid.count, "lid:", lid as Any, "smart:", smart as Any)
        // This Mac has all of these; each reader must still never crash when one is missing.
        #expect(gpu?.deviceUtil != nil)
        #expect(bat?.cycleCount != nil)
        #expect(hid.count > 5)
        #expect(smart?.percentUsed != nil)
        #expect(!gpuNs.isEmpty) // WindowServer always has a GPU client
    }
}
