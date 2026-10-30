import Testing
import Foundation
@testable import MonitorCore

private let base = Date(timeIntervalSince1970: 1_800_000_000)

/// S6: a hung network mount must not stall sampling. Only local, browsable mounts are read.
@Suite struct VolumeReadTests {
    let mounts = [
        NetDisk.Mount(path: "/", isLocal: true, browsable: true),
        NetDisk.Mount(path: "/Volumes/TeamShare", isLocal: false, browsable: true),        // SMB or NFS share
        NetDisk.Mount(path: "/System/Volumes/Data/home", isLocal: false, browsable: false),  // autofs
        NetDisk.Mount(path: "/System/Volumes/VM", isLocal: true, browsable: false),
        NetDisk.Mount(path: "/Volumes/USB", isLocal: true, browsable: true),                  // an external drive
    ]

    @Test func hungNetworkMountIsNeverRead() {
        var readPaths: [String] = []
        let started = Date()
        let v = NetDisk.volumes(mounts: mounts) { path in
            readPaths.append(path)
            if path.hasPrefix("/Volumes/TeamShare") || path.hasSuffix("/home") { Thread.sleep(forTimeInterval: 3) }  // a hung mount
            return VolumeInfo(name: path, path: path, total: 100, free: 50, importantFree: 60, purgeable: 10)
        }
        #expect(readPaths == ["/", "/Volumes/USB"])
        #expect(v.map(\.path) == ["/", "/Volumes/USB"])   // local external volumes stay listed (review R5-N1)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}

/// S7: the first IOReport delta after a wake covers the whole sleep. It must not turn into a watts reading.
@Suite struct WakeIntervalTests {
    func ch(_ name: String, _ v: Int64) -> IOReportChannel {
        IOReportChannel(group: "Energy Model", subgroup: "", name: name, unit: "mJ", value: v, states: [])
    }

    @Test func normalTicksAreUsable() {
        #expect(EnergyModel.usableInterval(1.0))
        #expect(EnergyModel.usableInterval(2.05))     // eco mode ticks every 2 s
    }

    @Test func longIntervalsAreDropped() {
        #expect(!EnergyModel.usableInterval(3600))    // an hour asleep
        #expect(!EnergyModel.usableInterval(EnergyModel.maxIntervalSeconds + 1))
        #expect(!EnergyModel.usableInterval(0))
        let p = EnergyModel.parse([ch("GPU", 9_000_000), ch("CPU Energy", 50_000_000)], seconds: 3600)
        #expect(p.gpuW == nil && p.cpuW == nil)
    }

    @Test func counterGoingBackwardsIsNoReading() {
        let p = EnergyModel.parse([ch("GPU", -4_000), ch("CPU Energy", 3_000)], seconds: 1)
        #expect(p.gpuW == nil)
        #expect(p.cpuW == 3)
    }
}

/// A render copy started next to the menu bar app made the app quit (it counted any running copy).
/// The app now holds a file lock instead; render mode does not take it.
@Suite struct InstanceLockTests {
    func path() -> String { NSTemporaryDirectory() + "macmonitor-lock-\(UUID().uuidString)/instance.lock" }

    @Test func secondCopyCannotTakeTheLock() {
        let p = path()
        let first = InstanceLock.acquire(path: p)
        #expect(first != nil)
        #expect(InstanceLock.acquire(path: p) == nil)
        withExtendedLifetime(first) {}
    }

    @Test func lockFreesWhenTheAppQuits() {
        let p = path()
        var first = InstanceLock.acquire(path: p)
        #expect(first != nil)
        first = nil
        #expect(InstanceLock.acquire(path: p) != nil)
    }
}

/// P core temperature was blank for about 2 minutes after launch, until the picker had seen both Tp banks.
@Suite struct PCoreColdStartTests {
    let bankA = ["Tp1i", "Tp1j", "Tp1k", "Tp1o", "Tp1x", "Tp23", "Tp29", "Tp2G", "Tpx9", "TpxD"]
    let bankB = SMCKeys.pCoreTemps + ["Tpx1", "Tpx5"]

    func read(on: [String], off: [String]) -> [String: Double] {
        var raw: [String: Double] = [:]
        for (i, k) in on.enumerated() { raw[k] = 75 - Double(i) / 2 }
        for k in off { raw[k] = 40 }
        return raw
    }

    @Test func seedCoversTheOtherBankOnTheFirstRead() {
        var p = PCoreKeys.Picker(seed: SMCKeys.pCoreTemps)
        let keys = p.update(read(on: bankA, off: bankB), now: base)
        #expect(keys.filter { bankA.contains($0) }.count == 5)
        #expect(keys.filter { SMCKeys.pCoreTemps.contains($0) }.count == 5)
    }

    @Test func bothBanksSeenAfterEachHasReadReal() {
        var p = PCoreKeys.Picker(seed: SMCKeys.pCoreTemps)
        _ = p.update(read(on: bankB, off: bankA), now: base)
        #expect(!p.bothBanksSeen)
        let keys = p.update(read(on: bankA, off: bankB), now: base.addingTimeInterval(5))
        #expect(p.bothBanksSeen)
        #expect(keys.filter { bankA.contains($0) }.count == 5)
        #expect(keys.filter { bankB.contains($0) }.count == 5)
    }

    @Test func extraReadsOnlyDuringColdStart() {
        #expect(PCoreKeys.coldStartRead(elapsed: 1, lastRead: nil, bothBanksSeen: false))
        #expect(!PCoreKeys.coldStartRead(elapsed: 3, lastRead: 0, bothBanksSeen: false))
        #expect(PCoreKeys.coldStartRead(elapsed: 5, lastRead: 0, bothBanksSeen: false))
        #expect(!PCoreKeys.coldStartRead(elapsed: 10, lastRead: 5, bothBanksSeen: true))
        #expect(!PCoreKeys.coldStartRead(elapsed: PCoreKeys.coldStartSeconds + 5, lastRead: PCoreKeys.coldStartSeconds, bothBanksSeen: false))
    }
}

/// R5-S1: the IOReport interval uses mach_absolute_time, which stops during sleep, so a wake looks like a 1 s tick.
/// The interval is also measured with mach_continuous_time; a gap between the two means the Mac slept.
@Suite struct SleepGapTests {
    let ch = [IOReportChannel(group: "Energy Model", subgroup: "", name: "GPU", unit: "mJ", value: 9_000_000, states: [])]

    @Test func sleepBetweenTicksIsDropped() {
        #expect(!EnergyModel.usableInterval(1.0, continuous: 3600))
        #expect(EnergyModel.breakdown(ch, seconds: 1.0, continuous: 3600) == nil)
        #expect(!EnergyModel.usableInterval(1.0, continuous: 2.5))
    }

    @Test func awakeTicksStayUsable() {
        #expect(EnergyModel.usableInterval(1.0, continuous: 1.02))
        #expect(EnergyModel.usableInterval(2.05, continuous: 2.05))
        #expect(EnergyModel.usableInterval(1.0, continuous: nil))
        #expect(EnergyModel.breakdown(ch, seconds: 1.0, continuous: 1.0)?.gpuW == 9_000)
    }

    @Test func longAwakeStallStillDropped() {
        #expect(!EnergyModel.usableInterval(12, continuous: 12))
    }
}
