import Foundation
import CSensors

public struct HIDTemp: Codable, Equatable, Sendable {
    public var name: String
    public var celsius: Double
}

/// Named temperature sensors from IOHIDEventSystemClient (PMU die, NAND, battery gas gauge).
public enum HIDSensors {
    /// One value per name (the hottest of the copies; each sensor shows up about 3 times),
    /// dropping junk like "PMU tdev1" at about -9,200 C.
    public static func clean(_ raw: [(String, Double)]) -> [HIDTemp] {
        var best: [String: Double] = [:]
        for (name, v) in raw where (-20...150).contains(v) && !name.isEmpty && name != "(null)" {
            best[name] = max(best[name] ?? -.infinity, v)
        }
        return best.map { HIDTemp(name: $0.key, celsius: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func temperatures() -> [HIDTemp] {
        let max = 256
        var names = [CChar](repeating: 0, count: max * 64)
        var values = [Double](repeating: 0, count: max)
        let n = Int(hid_temps(&names, &values, Int32(max)))
        guard n > 0 else { return [] }
        var raw: [(String, Double)] = []
        for i in 0..<n {
            raw.append((cstr(Array(names[(i * 64)..<(i * 64 + 64)])), values[i]))
        }
        return clean(raw)
    }

    /// Hinge angle in degrees, nil when the sensor is missing.
    public static func lidAngle() -> Double? {
        var d = 0.0
        return lid_angle(&d) == 0 ? d : nil
    }
}
