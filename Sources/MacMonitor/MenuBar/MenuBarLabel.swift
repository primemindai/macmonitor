import AppKit
import MonitorCore

/// Draws the menu bar item: a tiny CPU sparkline plus "CPU 42% · 71° · 2.3k".
/// Plain AppKit drawing (no SwiftUI) keeps the per-second cost tiny while only the menu bar runs.
enum MenuBarLabel {
    static let sparkWidth: CGFloat = 30
    static let height: CGFloat = 16

    /// A template image (adapts to light and dark menu bars) of the last values, 0 to 100.
    static func sparkline(_ values: [Double?]) -> NSImage {
        let img = NSImage(size: NSSize(width: sparkWidth, height: height), flipped: false) { rect in
            let path = NSBezierPath()
            let vals = values
            guard vals.count > 1 else { return true }
            let step = rect.width / CGFloat(vals.count - 1)
            var started = false
            for (i, v) in vals.enumerated() {
                guard let v else { started = false; continue }
                let p = NSPoint(x: CGFloat(i) * step, y: 1.5 + CGFloat(min(100, max(0, v)) / 100) * (rect.height - 3))
                if started { path.line(to: p) } else { path.move(to: p); started = true }
            }
            NSColor.black.setStroke()
            path.lineWidth = 1.4
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
            // Baseline so the item still reads when the CPU is idle.
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: rect.width, height: 0.8)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    static func title(_ s: Snapshot?) -> NSAttributedString {
        NSAttributedString(string: " " + MenuBarText.make(s), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .baselineOffset: 0.5,
        ])
    }
}
