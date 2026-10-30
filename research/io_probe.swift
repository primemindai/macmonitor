// io_probe.swift : disks (URLResourceValues/statfs), power sources (IOPS), Wi-Fi (CoreWLAN), network counters (NET_RT_IFLIST2). READ-ONLY.
// build: swiftc -O io_probe.swift -o io_probe
import Foundation
import IOKit.ps
import CoreWLAN
setvbuf(stdout, nil, _IONBF, 0)
func ms(_ b: () -> Void) -> Double { let t = DispatchTime.now().uptimeNanoseconds; b(); return Double(DispatchTime.now().uptimeNanoseconds - t)/1e6 }
let G = 1e9
print("== volumes ==")
let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeLocalizedFormatDescriptionKey]
var vt = 0.0
vt = ms {
for u in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
  guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
  print(String(format: "%@ [%@] total %.1fGB avail %.1fGB important %.1fGB opportunistic %.1fGB internal %@", v.volumeName ?? "?", v.volumeLocalizedFormatDescription ?? "", Double(v.volumeTotalCapacity ?? 0)/G, Double(v.volumeAvailableCapacity ?? 0)/G, Double(v.volumeAvailableCapacityForImportantUsage ?? 0)/G, Double(v.volumeAvailableCapacityForOpportunisticUsage ?? 0)/G, String(describing: v.volumeIsInternal ?? false)))
}}
print(String(format: "volume query cost %.1f ms", vt))
print("== IOPS power sources ==")
let ps = IOPSCopyPowerSourcesInfo().takeRetainedValue()
for s in IOPSCopyPowerSourcesList(ps).takeRetainedValue() as Array {
  if let d = IOPSGetPowerSourceDescription(ps, s)?.takeUnretainedValue() as? [String: Any] { print(d) } }
if let ad = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] { print("adapter:", ad) }
print("== CoreWLAN ==")
let wt = ms {
if let i = CWWiFiClient.shared().interface() {
  print("if \(i.interfaceName ?? "?") power \(i.powerOn()) ssid \(i.ssid() ?? "nil (needs Location permission)") bssid \(i.bssid() ?? "nil") rssi \(i.rssiValue()) dBm noise \(i.noiseMeasurement()) dBm txRate \(i.transmitRate()) Mbps txPower \(i.transmitPower()) mW phy \(i.activePHYMode().rawValue) channel \(i.wlanChannel()?.channelNumber ?? -1) band \(i.wlanChannel()?.channelBand.rawValue ?? -1) width \(i.wlanChannel()?.channelWidth.rawValue ?? -1) security \(i.security().rawValue) country \(i.countryCode() ?? "nil")")
}}
print(String(format: "CoreWLAN cost %.1f ms", wt))
print("== net counters (sysctl NET_RT_IFLIST2, 64-bit) ==")
func ifc() -> [String:(UInt64,UInt64,UInt32)] {
  var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]; var len = 0
  sysctl(&mib, 6, nil, &len, nil, 0); var buf = [UInt8](repeating: 0, count: len); sysctl(&mib, 6, &buf, &len, nil, 0)
  var out = [String:(UInt64,UInt64,UInt32)](); var off = 0
  while off < len {
    let hdr = buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: if_msghdr.self) }
    if Int32(hdr.ifm_type) == RTM_IFINFO2 {
      let m = buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: if_msghdr2.self) }
      var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE)); if_indextoname(UInt32(m.ifm_index), &name)
      out[String(cString: name)] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes, m.ifm_data.ifi_baudrate > UInt64(UInt32.max) ? UInt32.max : UInt32(m.ifm_data.ifi_baudrate))
    }
    off += Int(hdr.ifm_msglen)
  }
  return out
}
var a = [String:(UInt64,UInt64,UInt32)](); let nc = ms { a = ifc() }; sleep(1); let b = ifc()
for (k, v) in b.sorted(by: { $0.key < $1.key }) where v.0 + v.1 > 0 { let p = a[k] ?? v
  print(String(format: "%-8@ in %8.1f KB/s out %8.1f KB/s total in %.2f GB out %.2f GB baud %u", k, Double(v.0 - p.0)/1024, Double(v.1 - p.1)/1024, Double(v.0)/G, Double(v.1)/G, v.2)) }
print(String(format: "NET_RT_IFLIST2 cost %.2f ms", nc))
