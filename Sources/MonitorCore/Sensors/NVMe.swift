import Foundation
import CSensors

public struct SMARTInfo: Codable, Equatable, Sendable {
    public var tempC: Int?
    public var percentUsed: Int?
    public var spare: Int?
    public var spareThreshold: Int?
    public var tbWritten: Double?
    public var tbRead: Double?
    public var powerOnHours: Int?
    public var powerCycles: Int?
    public var unsafeShutdowns: Int?
    public var mediaErrors: Int?
    public var criticalWarning: Int?
}

public enum NVMe {
    /// NVMe data units are 1,000 blocks of 512 bytes.
    public static func unitsToTB(_ units: Double) -> Double { units * 512_000 / 1e12 }
    public static func kelvinToC(_ k: Int) -> Int { k - 273 }

    public static func read() -> SMARTInfo? {
        var r = nvme_smart_t()
        guard nvme_smart_read(&r) == 0 else { return nil }
        return SMARTInfo(
            tempC: r.temperature_k > 0 ? kelvinToC(Int(r.temperature_k)) : nil,
            percentUsed: Int(r.percentage_used),
            spare: Int(r.available_spare),
            spareThreshold: Int(r.spare_threshold),
            tbWritten: unitsToTB(r.data_units_written),
            tbRead: unitsToTB(r.data_units_read),
            powerOnHours: Int(r.power_on_hours),
            powerCycles: Int(r.power_cycles),
            unsafeShutdowns: Int(r.unsafe_shutdowns),
            mediaErrors: Int(r.media_errors),
            criticalWarning: Int(r.critical_warning))
    }
}
