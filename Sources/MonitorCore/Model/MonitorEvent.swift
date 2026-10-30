import Foundation

/// One row in the Events log (fan ramps, thermal pressure, throttle signs, wake...).
public struct MonitorEvent: Codable, Equatable, Sendable {
    public var ts: Date
    public var kind: String
    public var title: String
    public var body: String
    public init(ts: Date, kind: String, title: String, body: String) {
        self.ts = ts; self.kind = kind; self.title = title; self.body = body
    }
}
