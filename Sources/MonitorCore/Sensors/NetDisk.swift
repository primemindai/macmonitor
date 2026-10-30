import Foundation
import Darwin
import IOKit
import CoreWLAN

public struct VolumeInfo: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var total: Int64
    public var free: Int64
    /// "Available for important use" (counts purgeable space macOS can clear).
    public var importantFree: Int64
    /// importantFree minus free: space macOS says it can clear on demand (an estimate).
    public var purgeable: Int64
}

public struct WiFiInfo: Codable, Equatable, Sendable {
    public var rssi: Int?
    public var noise: Int?
    public var txRateMbps: Double?
    public var channel: Int?
}

public struct BlockStats: Equatable, Sendable {
    public var readBytes, writeBytes, readOps, writeOps, readNs, writeNs: UInt64
}

public enum NetDisk {
    /// 64-bit byte counters per interface (NET_RT_IFLIST2; getifaddrs counters wrap at 4 GB).
    public static func interfaces() -> [String: (rx: UInt64, tx: UInt64, baud: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: (rx: UInt64, tx: UInt64, baud: UInt64)] = [:]
        var off = 0
        while off + MemoryLayout<if_msghdr>.size <= len {
            let hdr = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: if_msghdr.self) }
            guard hdr.ifm_msglen > 0 else { break }
            if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                let m = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self) }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(m.ifm_index), &name) != nil {
                    out[cstr(name)] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes, m.ifm_data.ifi_baudrate)
                }
            }
            off += Int(hdr.ifm_msglen)
        }
        return out
    }

    /// Lifetime counters per whole disk (BSD name, for example disk0) from IOBlockStorageDriver.
    public static func blockStats() -> [String: BlockStats] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(it) }
        var out: [String: BlockStats] = [:]
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            guard let st = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let bsd = IORegistryEntrySearchCFProperty(s, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault,
                                                           IOOptionBits(kIORegistryIterateRecursively)) as? String else { continue }
            func u(_ k: String) -> UInt64 { UInt64(max(0, num(st[k]) ?? 0)) }
            out[bsd] = BlockStats(readBytes: u("Bytes (Read)"), writeBytes: u("Bytes (Write)"),
                                  readOps: u("Operations (Read)"), writeOps: u("Operations (Write)"),
                                  readNs: u("Total Time (Read)"), writeNs: u("Total Time (Write)"))
        }
        return out
    }

    /// One mount from the kernel's mount table.
    public struct Mount: Equatable, Sendable {
        public var path: String
        public var isLocal: Bool
        public var browsable: Bool
        public init(path: String, isLocal: Bool, browsable: Bool) { self.path = path; self.isLocal = isLocal; self.browsable = browsable }
    }

    /// The volumes to show: local mounts Finder would list. Network and autofs mounts are never read, since a hung
    /// server can block a stat call for minutes and the sampler would stall with it.
    public static func volumes(mounts: [Mount], read: (String) -> VolumeInfo?) -> [VolumeInfo] {
        mounts.filter { $0.isLocal && $0.browsable }.compactMap { read($0.path) }
    }

    /// The kernel's cached mount table (MNT_NOWAIT never asks a file server).
    static func mounts() -> [Mount] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        return (0..<Int(n)).map { i in
            let m = buf[i]
            let path = withUnsafeBytes(of: m.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return Mount(path: path, isLocal: m.f_flags & UInt32(MNT_LOCAL) != 0, browsable: m.f_flags & UInt32(MNT_DONTBROWSE) == 0)
        }
    }

    /// Size and free space for one local volume.
    static func readVolume(_ path: String) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        let u = URL(fileURLWithPath: path, isDirectory: true)
        guard let v = try? u.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity, total > 0 else { return nil }
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        let important = v.volumeAvailableCapacityForImportantUsage ?? free
        return VolumeInfo(name: v.volumeName ?? u.lastPathComponent, path: path, total: Int64(total), free: free,
                          importantFree: important, purgeable: max(0, important - free))
    }

    public static func volumes() -> [VolumeInfo] { volumes(mounts: mounts(), read: readVolume) }

    /// nil when there is no Wi-Fi interface or the radio is off. Never reads the SSID (that needs Location).
    public static func wifi() -> WiFiInfo? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return nil }
        let rssi = i.rssiValue(), noise = i.noiseMeasurement()
        guard rssi != 0 else { return nil }
        return WiFiInfo(rssi: rssi, noise: noise != 0 ? noise : nil,
                        txRateMbps: i.transmitRate() > 0 ? i.transmitRate() : nil,
                        channel: i.wlanChannel().map { $0.channelNumber })
    }
}
