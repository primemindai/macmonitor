import Testing
import Foundation
@testable import MonitorCore

@Suite struct IOReportTests {
    func ch(_ name: String, _ value: Int64, _ unit: String = "mJ") -> IOReportChannel {
        IOReportChannel(group: "Energy Model", subgroup: "", name: name, unit: unit, value: value, states: [])
    }

    @Test func energyUnits() throws {
        #expect(EnergyModel.watts(value: 11_752, unit: "mJ", seconds: 1.0) == 11.752)
        let nj = try #require(EnergyModel.watts(value: 791_000_000, unit: "nJ", seconds: 1.0))
        #expect(abs(nj - 0.791) < 1e-9)
        let uj = try #require(EnergyModel.watts(value: 2_000_000, unit: "uJ", seconds: 2.0))
        #expect(abs(uj - 1.0) < 1e-9)
        #expect(EnergyModel.watts(value: 5, unit: "events", seconds: 1.0) == nil)
        let p = EnergyModel.parse([ch("PACC0_CPU", 11_752), ch("GPU", 1_746), ch("AMCC", 1_000), ch("DCS", 500)], seconds: 1.0)
        #expect(p.pCluster0W == 11.752)
        #expect(p.gpuW == 1.746)
        #expect(p.memSystemW == 1.5)
    }

    @Test func mhzWeighted() throws {
        var table = [Double](repeating: 0, count: 19)
        table[0] = 1_260; table[6] = 2_000; table[12] = 3_756
        let mhz = try #require(Residency.mhz(states: [("IDLE", 50), ("V0P0", 25), ("V6P0", 25)], tableMHz: table))
        #expect(mhz == 1_630)
        #expect(Residency.stateIndex("V12P6") == 12)
        #expect(Residency.mhz(states: [("V12P6", 10)], tableMHz: table) == 3_756)
    }

    @Test func allIdleIsNil() {
        #expect(Residency.mhz(states: [("IDLE", 100)], tableMHz: [1_000]) == nil)
        #expect(Residency.mhz(states: [], tableMHz: [1_000]) == nil)
    }

    @Test func gpuActivePercent() throws {
        let pct = try #require(Residency.activePercent(states: [("OFF", 356), ("P1", 644)]))
        #expect(abs(pct - 64.4) < 1e-9)
        #expect(Residency.activePercent(states: [("OFF", 0), ("P1", 0)]) == nil)
    }

    @Test func missingChannelsAreNil() {
        let p = EnergyModel.parse([], seconds: 1.0)
        #expect(p.pCluster0W == nil)
        #expect(p.pCluster1W == nil)
        #expect(p.eClusterW == nil)
        #expect(p.gpuW == nil)
        #expect(p.aneW == nil)
        #expect(p.dramW == nil)
        #expect(p.memSystemW == nil)
        #expect(p.cpuW == nil)
        #expect(p.perCoreW.isEmpty)
    }

    @Test(.tags(.live)) func liveSamplerReturnsCPUEnergy() async throws {
        let t0 = Date()
        let s = try #require(IOReportSampler(groups: IOReportSampler.fastGroups))
        let subscribeMs = Date().timeIntervalSince(t0) * 1000
        try await Task.sleep(for: .milliseconds(500))
        let t1 = Date()
        let chans = try #require(s.sample())
        let sampleMs = Date().timeIntervalSince(t1) * 1000
        print(String(format: "IOReport cost: subscribe %.1f ms, one sample %.1f ms, %d channels", subscribeMs, sampleMs, chans.count))
        let p = EnergyModel.parse(chans, seconds: s.lastIntervalSeconds)
        #expect((p.cpuW ?? -1) > 0)
        let tables = DVFSTables.load()
        #expect(tables.eMHz.count >= 5)
        #expect(tables.pMHz.count >= 10)
        #expect(tables.gpuMHz.count >= 2)
        let clocks = ClockModel.parse(chans, tables: tables)
        print("clocks:", clocks.eClusterMHz as Any, clocks.pCluster0MHz as Any, clocks.gpuMHz as Any, clocks.gpuCLTM as Any)
        #expect(clocks.perCoreActivePct.count == 14)
    }
}
