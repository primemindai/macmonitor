import Testing
import Foundation
@testable import MonitorCore

/// A fake process table and clock, so ProcessSampler can be driven step by step.
final class FakeProcs: @unchecked Sendable {
    var procs: [RawProc] = []
    var now: Double = 1_000
}

func raw(_ pid: Int32, start: UInt64 = 1, name: String = "p", cpuNs: UInt64 = 0, energyNJ: UInt64 = 0) -> RawProc {
    RawProc(pid: pid, startAbs: start, name: name, cpuNs: cpuNs, pCoreNs: 0, energyNJ: energyNJ, wakeups: 0,
            diskReadBytes: 0, diskWriteBytes: 0, footprintBytes: 1_000)
}

@Suite struct ProcessesTests {
    func sampler(_ f: FakeProcs) -> ProcessSampler {
        ProcessSampler(reader: { f.procs }, clock: { f.now })
    }

    @Test func psParsesNamesWithSpaces() throws {
        let text = """
          1   0.2  18128 /sbin/launchd
        731  12.5 204800 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)
        bad line
        """
        let p = PSParser.parse(text)
        #expect(p[731]?.name == "Google Chrome Helper (GPU)")
        #expect(p[731]?.cpu == 12.5)
        #expect(p[731]?.rssBytes == 204_800 * 1024)
        #expect(p[1]?.name == "launchd")
        #expect(p.count == 2)
        // The real capture parses too.
        let real = PSParser.parse(try String(contentsOf: fixtureURL("ps.txt"), encoding: .utf8))
        #expect(real.count > 600)
        #expect(real[1]?.name == "launchd")
    }

    @Test func topUsesSecondSample() throws {
        let t = TopParser.parse(try String(contentsOf: fixtureURL("top.txt"), encoding: .utf8))
        // Second sample in the capture: com.apple.Virtualization 120.5 %CPU, kernel_task 47.5.
        #expect(t[85279]?.cpu == 120.5)
        #expect(t[0]?.cpu == 47.5)
        #expect(t[396]?.power == 42.2)
        // pid 99913 only shows in the first sample's list.
        #expect(t[99913] == nil)
    }

    @Test func energyFromNanojoules() throws {
        let f = FakeProcs()
        let s = sampler(f)
        f.procs = [raw(10, cpuNs: 0, energyNJ: 1_000)]
        _ = s.sample(gpuNs: [:], top: nil)
        f.now += 1
        f.procs = [raw(10, cpuNs: 500_000_000, energyNJ: 1_000 + 1_500_000_000)]
        let out = s.sample(gpuNs: [:], top: nil)
        let p = try #require(out.first { $0.pid == 10 })
        #expect(p.energyW == 1.5)
        #expect(p.cpuPercent == 50)
        #expect(p.isOwn)
    }

    @Test func pidReuseIsNewProcess() throws {
        let f = FakeProcs()
        let s = sampler(f)
        f.procs = [raw(10, start: 1, energyNJ: 1_000)]
        _ = s.sample(gpuNs: [:], top: nil)
        f.now += 1
        f.procs = [raw(10, start: 2, energyNJ: 9_000_000_000)]
        let p = try #require(s.sample(gpuNs: [:], top: nil).first { $0.pid == 10 })
        #expect(p.energyW == nil)
        #expect(p.cpuPercent == nil)
    }

    @Test func exitedProcessDropped() {
        let f = FakeProcs()
        let s = sampler(f)
        f.procs = [raw(10), raw(11)]
        _ = s.sample(gpuNs: [:], top: nil)
        f.now += 1
        f.procs = [raw(10)]
        let out = s.sample(gpuNs: [:], top: nil)
        #expect(out.contains { $0.pid == 10 })
        #expect(!out.contains { $0.pid == 11 })
    }

    @Test func gpuPercentFromNs() throws {
        let f = FakeProcs()
        let s = sampler(f)
        f.procs = [raw(10)]
        _ = s.sample(gpuNs: [10: 1_000, 396: 0], top: nil)
        f.now += 1
        let out = s.sample(gpuNs: [10: 1_000 + 500_000_000, 396: 100_000_000], top: nil)
        #expect(try #require(out.first { $0.pid == 10 }).gpuPercent == 50)
        // A root process seen only by the GPU counters still gets a row.
        #expect(try #require(out.first { $0.pid == 396 }).gpuPercent == 10)
    }

    @Test func rootProcessesFromPsAndTop() throws {
        let f = FakeProcs()
        let s = sampler(f)
        f.procs = []
        let ps: [Int32: (cpu: Double, rssBytes: UInt64, name: String)] = [0: (40, 0, "kernel_task"), 396: (30, 1 << 30, "WindowServer")]
        let out = s.sample(gpuNs: [:], top: [0: (47.5, 0), 396: (42.2, 42.2)], ps: ps)
        let k = try #require(out.first { $0.pid == 0 })
        #expect(k.cpuPercent == 47.5) // top beats ps for CPU (ps is a lifetime average)
        #expect(k.isOwn == false)
        #expect(k.energyW == nil)     // top POWER is a unitless impact score, never watts
        #expect(try #require(out.first { $0.pid == 396 }).energyImpact == 42.2)
        #expect(try #require(out.first { $0.pid == 396 }).memBytes == 1 << 30)
    }

    @Test(.tags(.live)) func liveProcessSample() async throws {
        let s = ProcessSampler()
        let t0 = Date()
        _ = s.sample(gpuNs: Registry.gpuTimeByPID(), top: nil)
        let cost = Date().timeIntervalSince(t0) * 1000
        try await Task.sleep(for: .milliseconds(500))
        let psText = try #require(await ProcessRunner.run("/bin/ps", ["-Aeo", "pid=,pcpu=,rss=,comm="]))
        let out = s.sample(gpuNs: Registry.gpuTimeByPID(), top: nil, ps: PSParser.parse(psText))
        print(String(format: "process snapshot cost %.1f ms, %d rows", cost, out.count))
        #expect(out.contains { $0.pid == getpid() && $0.isOwn })
        #expect(out.contains { $0.pid == 1 && !$0.isOwn })
    }
}
