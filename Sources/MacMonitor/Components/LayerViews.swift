import SwiftUI
import AppKit

// Live motion runs in Core Animation, not in SwiftUI. SwiftUI animations redraw the whole page layer on the CPU
// every frame (measured: about 48% of a core with ticking numbers and sliding bars). Core Animation runs these
// transitions in the system render server, so the app draws one SwiftUI frame per second and nothing in between.

/// A number that rolls to its new value (a push transition in Core Animation).
struct TickerText: NSViewRepresentable {
    var text: String
    var value: Double
    var font: NSFont
    var color: NSColor

    func makeNSView(context: Context) -> TickerView { TickerView() }

    func updateNSView(_ v: TickerView, context: Context) { v.set(text: text, value: value, font: font, color: color) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TickerView, context: Context) -> CGSize? {
        TickerView.measure(text, font)
    }
}

final class TickerView: NSView {
    private let textLayer = CATextLayer()
    private var text: String?
    private var value = 0.0
    private var font = NSFont.systemFont(ofSize: 12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        textLayer.isWrapped = false
        layer?.addSublayer(textLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func measure(_ text: String, _ font: NSFont) -> CGSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width) + 1, height: ceil(font.ascender - font.descender) + 1)
    }

    override var firstBaselineOffsetFromTop: CGFloat { font.ascender + 0.5 }
    override var lastBaselineOffsetFromBottom: CGFloat { -font.descender + 0.5 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func set(text: String, value: Double, font: NSFont, color: NSColor) {
        let changed = text != self.text
        if changed, self.text != nil, window != nil {
            let t = CATransition()
            t.type = .push
            t.subtype = value >= self.value ? .fromTop : .fromBottom
            t.duration = 0.3
            t.timingFunction = CAMediaTimingFunction(name: .easeOut)
            textLayer.add(t, forKey: "tick")
        }
        self.text = text
        self.value = value
        self.font = font
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        CATransaction.commit()
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = bounds
        CATransaction.commit()
    }
}

/// A bar whose fill slides to its new length (an implicit Core Animation on the fill layer).
struct LayerBar: NSViewRepresentable {
    var fraction: Double
    var color: NSColor
    var track: NSColor
    var vertical = false
    var radius: CGFloat

    func makeNSView(context: Context) -> BarView { BarView() }
    func updateNSView(_ v: BarView, context: Context) {
        v.set(fraction: fraction, color: color, track: track, vertical: vertical, radius: radius)
    }
}

final class BarView: NSView {
    private let fill = CAGradientLayer()
    private var fraction = 0.0
    private var vertical = false
    private var primed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(fraction: Double, color: NSColor, track: NSColor, vertical: Bool, radius: CGFloat) {
        let f = max(0, min(1, fraction.isFinite ? fraction : 0))
        self.vertical = vertical
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = track.cgColor
        layer?.cornerRadius = radius
        fill.cornerRadius = radius
        fill.colors = [color.withAlphaComponent(0.75).cgColor, color.cgColor]
        fill.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
        fill.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
        CATransaction.commit()
        guard f != self.fraction || !primed else { return }
        self.fraction = f
        CATransaction.begin()
        CATransaction.setDisableActions(!primed || window == nil)
        CATransaction.setAnimationDuration(0.5)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        fill.frame = fillFrame()
        CATransaction.commit()
        primed = true
    }

    private func fillFrame() -> CGRect {
        let b = bounds
        return vertical ? CGRect(x: 0, y: 0, width: b.width, height: b.height * fraction)
                        : CGRect(x: 0, y: 0, width: b.width * fraction, height: b.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = fillFrame()
        CATransaction.commit()
    }
}

extension NSFont {
    /// System font with tabular digits, optionally SF Rounded.
    static func numbers(size: CGFloat, weight: NSFont.Weight, rounded: Bool) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard rounded, let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}
