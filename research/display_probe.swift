// display_probe.swift : displays, refresh rate, brightness (DisplayServices private). READ-ONLY. build: swiftc -O display_probe.swift -o display_probe
import Foundation
import CoreGraphics
import AppKit
var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
CGGetOnlineDisplayList(8, &ids, &n)
typealias GetB = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
let getB = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetB.self) }
for i in 0..<Int(n) { let d = ids[i]; let m = CGDisplayCopyDisplayMode(d)
  var b: Float = -1; let r = getB?(d, &b) ?? -99
  print("display \(d) builtin \(CGDisplayIsBuiltin(d) != 0) \(m?.pixelWidth ?? 0)x\(m?.pixelHeight ?? 0) refresh \(m?.refreshRate ?? 0) Hz brightness \(b) (rc \(r))") }
for s in NSScreen.screens { print("NSScreen \(s.localizedName) maxFPS \(s.maximumFramesPerSecond) EDR headroom now \(s.maximumExtendedDynamicRangeColorComponentValue) potential \(s.maximumPotentialExtendedDynamicRangeColorComponentValue)") }
