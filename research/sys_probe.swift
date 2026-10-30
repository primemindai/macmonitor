// sys_probe.swift : public / semi-public APIs, READ-ONLY. build: swiftc -O sys_probe.swift -o sys_probe
import Foundation
import Darwin
import notify
import IOKit.ps
setvbuf(stdout, nil, _IONBF, 0)

func ms(_ b: () -> Void) -> Double { let t = DispatchTime.now().uptimeNanoseconds; b(); return Double(DispatchTime.now().uptimeNanoseconds - t)/1e6 }
func sysctlInt(_ n: String) -> Int64? { var v: Int64 = 0; var s = MemoryLayout<Int64>.size; return sysctlbyname(n, &v, &s, nil, 0) == 0 ? (s == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v) : nil }
func sysctlStr(_ n: String) -> String? { var s = 0; guard sysctlbyname(n, nil, &s, nil, 0) == 0 else { return nil }; var b = [CChar](repeating: 0, count: s); sysctlbyname(n, &b, &s, nil, 0); return String(cString: b) }

print("== thermal state ==")
let ts = ProcessInfo.processInfo.thermalState
print("ProcessInfo.thermalState =", ts.rawValue, "(0 nominal,1 fair,2 serious,3 critical)")
var tok: Int32 = 0; var st: UInt64 = 0
let r = notify_register_check("com.apple.system.thermalpressurelevel", &tok)
notify_get_state(tok, &st)
print("notify com.apple.system.thermalpressurelevel reg=\(r) state=\(st)  (0 nominal,1 moderate,2 heavy,3 trapping,4 sleeping)")
print("lowPowerMode =", ProcessInfo.processInfo.isLowPowerModeEnabled)

print("== CPU ticks per core (host_processor_info), 1 s ==")
func ticks() -> [[UInt32]] {
  var n: natural_t = 0; var info: processor_info_array_t?; var cnt: mach_msg_type_number_t = 0
  host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt)
  var out: [[UInt32]] = []
  for i in 0..<Int(n) { out.append((0..<4).map { UInt32(bitPattern: info![i*4+$0]) }) }
  vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(cnt)*4)
  return out
}
var a = [[UInt32]](); let tcost = ms { a = ticks() }; sleep(1); let b = ticks()
let p0 = Int(sysctlInt("hw.perflevel0.logicalcpu") ?? 0)
for i in 0..<b.count { let d = (0..<4).map { Double(b[i][$0] &- a[i][$0]) }; let tot = d.reduce(0,+)
  print(String(format: "cpu%-2d %@ user %.0f%% sys %.0f%% idle %.0f%%", i, i < (b.count - p0) ? "E" : "P", 100*d[0]/tot, 100*d[1]/tot, 100*d[2]/tot)) }
print(String(format: "host_processor_info cost %.3f ms", tcost))
for k in ["hw.perflevel0.name","hw.perflevel1.name"] { print(k, "=", sysctlStr(k) ?? "n/a") }
for k in ["hw.perflevel0.physicalcpu","hw.perflevel0.l2cachesize","hw.perflevel1.physicalcpu","hw.perflevel1.l2cachesize","hw.nperflevels","hw.cpufamily","hw.cpusubfamily"] { print(k, "=", sysctlInt(k).map{String($0)} ?? "n/a") }
var la = [Double](repeating: 0, count: 3); getloadavg(&la, 3); print("loadavg", la)

print("== memory ==")
var vm = vm_statistics64(); var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
let mcost = ms { _ = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } } }
let pg = Double(vm_kernel_page_size); let G = 1073741824.0
print(String(format: "free %.2fG active %.2fG inactive %.2fG wired %.2fG compressor(occupied) %.2fG compressed(logical) %.2fG purgeable %.2fG speculative %.2fG external(file-backed) %.2fG internal(anon) %.2fG",
  Double(vm.free_count)*pg/G, Double(vm.active_count)*pg/G, Double(vm.inactive_count)*pg/G, Double(vm.wire_count)*pg/G, Double(vm.compressor_page_count)*pg/G, Double(vm.total_uncompressed_pages_in_compressor)*pg/G, Double(vm.purgeable_count)*pg/G, Double(vm.speculative_count)*pg/G, Double(vm.external_page_count)*pg/G, Double(vm.internal_page_count)*pg/G))
let app = Double(vm.internal_page_count - vm.purgeable_count)*pg/G
print(String(format: "Activity Monitor style: App %.2fG Wired %.2fG Compressed %.2fG Cached %.2fG", app, Double(vm.wire_count)*pg/G, Double(vm.compressor_page_count)*pg/G, Double(vm.external_page_count+vm.purgeable_count)*pg/G))
print("pageins \(vm.pageins) pageouts \(vm.pageouts) swapins \(vm.swapins) swapouts \(vm.swapouts) faults \(vm.faults) cow \(vm.cow_faults) compressions \(vm.compressions) decompressions \(vm.decompressions)")
print(String(format: "host_statistics64 cost %.3f ms", mcost))
var sw = xsw_usage(); var sws = MemoryLayout<xsw_usage>.size; sysctlbyname("vm.swapusage", &sw, &sws, nil, 0)
print(String(format: "swap total %.2fG used %.2fG", Double(sw.xsu_total)/G, Double(sw.xsu_used)/G))
for k in ["kern.memorystatus_vm_pressure_level","kern.memorystatus_level","vm.page_free_wanted","vm.compressor_mode","vm.memory_pressure","vm.page_pageable_internal_count","vm.page_purgeable_count","vm.compressor_bytes_used","vm.vm_page_free_target"] { print(k, "=", sysctlInt(k).map{String($0)} ?? "n/a") }

print("== counters ==")
var bt = timeval(); var bts = MemoryLayout<timeval>.size; sysctlbyname("kern.boottime", &bt, &bts, nil, 0); print("boot", Date(timeIntervalSince1970: Double(bt.tv_sec)))
var wt = timeval(); var wts = MemoryLayout<timeval>.size; sysctlbyname("kern.waketime", &wt, &wts, nil, 0); print("lastwake", Date(timeIntervalSince1970: Double(wt.tv_sec)))
print("uptime(s)", ProcessInfo.processInfo.systemUptime)
