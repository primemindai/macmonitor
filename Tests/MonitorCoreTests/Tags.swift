import Testing

extension Tag {
    /// Needs the real hardware of this Mac (SMC, IOReport, HID, NVMe...).
    @Tag static var live: Self
}

/// Path to Tests/Fixtures, found from this source file's location.
func fixtureURL(_ name: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name)
}
import Foundation
