import SwiftUI
import AppKit
import MonitorCore

/// A line through fixed-width values. Index 0 sits one step off the left edge so a glide enters smoothly.
/// Used for screenshots (SwiftUI drawing); the live window uses the Core Animation version below.
struct SparkShape: Shape {
    var values: [Double?]
    var lo: Double
    var hi: Double
    var closed = false

    func path(in rect: CGRect) -> Path { Path(SparkPath.make(values: values, lo: lo, hi: hi, rect: rect, closed: closed)) }
}

enum SparkPath {
    static func make(values: [Double?], lo: Double, hi: Double, rect: CGRect, closed: Bool) -> CGPath {
        let p = CGMutablePath()
        guard values.count > 2, hi > lo, rect.width > 0 else { return p }
        let step = rect.width / CGFloat(values.count - 2)
        func y(_ v: Double) -> CGFloat {
            let f = (v - lo) / (hi - lo)
            // y grows downward (SwiftUI and flipped NSView).
            return rect.maxY - CGFloat(min(1, max(0, f))) * (rect.height - 2) - 1
        }
        var runStart: CGPoint?
        var last: CGPoint?
        func closeRun() {
            if closed, let s = runStart, let l = last {
                p.addLine(to: CGPoint(x: l.x, y: rect.maxY)); p.addLine(to: CGPoint(x: s.x, y: rect.maxY)); p.closeSubpath()
            }
        }
        for (i, v) in values.enumerated() {
            let x = CGFloat(i - 1) * step
            guard let v, v.isFinite else { closeRun(); runStart = nil; last = nil; continue }
            let pt = CGPoint(x: x, y: y(v))
            if runStart == nil { p.move(to: pt); runStart = pt } else { p.addLine(to: pt) }
            last = pt
        }
        closeRun()
        return p
    }

    static func bounds(_ values: [Double?], _ range: ClosedRange<Double>?) -> (Double, Double) {
        if let range { return (range.lowerBound, range.upperBound) }
        let v = values.compactMap { $0 }
        guard let mn = v.min(), let mx = v.max() else { return (0, 1) }
        let pad = max(1e-6, (mx - mn) * 0.15)
        return (mn - pad, mx + pad)
    }
}

/// Live sparkline with a soft fill. It glides one step per sample.
/// The glide runs as a Core Animation translation in the render server, so it costs the app almost no CPU.
struct Sparkline: View {
    var values: [Double?]
    var range: ClosedRange<Double>?
    var color: Color
    var tick: Int
    var lineWidth: CGFloat = 1.6
    var interval: Double = 1

    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let (lo, hi) = SparkPath.bounds(values, range)
        if renderMode {
            ZStack {
                SparkShape(values: values, lo: lo, hi: hi, closed: true)
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                SparkShape(values: values, lo: lo, hi: hi)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
            .clipped()
        } else {
            LayerSparkline(values: values, lo: lo, hi: hi, color: NSColor(color), lineWidth: lineWidth, tick: tick, interval: interval)
        }
    }
}

private struct LayerSparkline: NSViewRepresentable {
    var values: [Double?]
    var lo: Double
    var hi: Double
    var color: NSColor
    var lineWidth: CGFloat
    var tick: Int
    var interval: Double

    func makeNSView(context: Context) -> SparkView { SparkView() }

    func updateNSView(_ v: SparkView, context: Context) {
        v.update(values: values, lo: lo, hi: hi, color: color, lineWidth: lineWidth, tick: tick, interval: interval)
    }
}

final class SparkView: NSView {
    private let glide = CALayer()
    private let line = CAShapeLayer()
    private let fillMask = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private var values: [Double?] = []
    private var lo = 0.0, hi = 1.0
    private var lastTick: Int?
    private var interval = 1.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        gradient.mask = fillMask
        glide.addSublayer(gradient)
        glide.addSublayer(line)
        line.fillColor = nil
        line.lineCap = .round
        line.lineJoin = .round
        layer?.addSublayer(glide)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(values: [Double?], lo: Double, hi: Double, color: NSColor, lineWidth: CGFloat, tick: Int, interval: Double) {
        self.values = values; self.lo = lo; self.hi = hi; self.interval = interval
        line.strokeColor = color.cgColor
        line.lineWidth = lineWidth
        gradient.colors = [color.withAlphaComponent(0.32).cgColor, color.withAlphaComponent(0).cgColor]
        // The view is flipped, so layer y grows downward: opaque at the top, clear at the bottom.
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        redraw()
        if let lastTick, lastTick != tick, values.count > 2, window != nil {
            let step = bounds.width / CGFloat(values.count - 2)
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = step
            a.toValue = 0
            a.duration = interval
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            glide.add(a, forKey: "glide")
        }
        lastTick = tick
    }

    override func layout() {
        super.layout()
        redraw()
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        glide.frame = b
        gradient.frame = b
        line.frame = b
        fillMask.frame = b
        // Paths are built y-down, which matches this flipped view.
        let r = CGRect(x: 0, y: 0, width: b.width, height: b.height)
        line.path = SparkPath.make(values: values, lo: lo, hi: hi, rect: r, closed: false)
        fillMask.path = SparkPath.make(values: values, lo: lo, hi: hi, rect: r, closed: true)
        CATransaction.commit()
    }
}

/// Spins at a speed tied to the real fan RPM (scaled down so the eye can follow it).
/// The spin is a Core Animation rotation; changing speed keeps the current angle.
struct FanIcon: View {
    var rpm: Double?
    var size: CGFloat = 14
    var color: Color = Theme.fan

    @Environment(\.renderMode) private var renderMode

    var body: some View {
        if renderMode {
            Image(systemName: "fanblades.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .rotationEffect(.degrees(20))
        } else {
            SpinningFan(turnsPerSecond: FanSpin.turnsPerSecond(rpm: rpm), size: size, color: NSColor(color))
                .frame(width: size * 1.25, height: size * 1.25)
        }
    }
}

private struct SpinningFan: NSViewRepresentable {
    var turnsPerSecond: Double
    var size: CGFloat
    var color: NSColor
    func makeNSView(context: Context) -> FanView { FanView() }
    func updateNSView(_ v: FanView, context: Context) { v.update(tps: turnsPerSecond, size: size, color: color) }
}

final class FanView: NSView {
    private let icon = CALayer()
    private var tps = -1.0
    private var size: CGFloat = 0
    private var color: NSColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.contentsGravity = .resizeAspect
        layer?.addSublayer(icon)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        icon.add(spin, forKey: "spin")
        icon.speed = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tps: Double, size: CGFloat, color: NSColor) {
        if size != self.size || color != self.color {
            self.size = size; self.color = color
            let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
            let img = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: "fan")?.withSymbolConfiguration(cfg)
            icon.contents = img
            icon.contentsScale = window?.backingScaleFactor ?? 2
            needsLayout = true
        }
        // Only re-time the spin on a real speed change (a 5% band), so small RPM wobble costs nothing.
        guard abs(tps - self.tps) > max(0.02, self.tps * 0.05) else { return }
        self.tps = tps
        let now = CACurrentMediaTime()
        let t = icon.convertTime(now, from: nil)
        icon.timeOffset = t
        icon.beginTime = now
        icon.speed = Float(tps)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.bounds = bounds
        icon.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

/// A number that rolls to its new value. Live: Core Animation (TickerText). Screenshots: plain SwiftUI text.
struct AnimatedNumber: View {
    var text: String
    var value: Double
    var size: CGFloat = 24
    var weight: Font.Weight = .semibold
    var rounded = true
    var color: Color?

    @Environment(\.renderMode) private var renderMode
    @Environment(\.theme) private var theme

    var body: some View {
        let c = color ?? theme.fg
        if renderMode {
            Text(text)
                .font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
                .monospacedDigit()
                .foregroundStyle(c)
        } else {
            TickerText(text: text, value: value, font: .numbers(size: size, weight: Self.nsWeight(weight), rounded: rounded), color: NSColor(c))
        }
    }

    static func nsWeight(_ w: Font.Weight) -> NSFont.Weight {
        switch w {
        case .bold: return .bold
        case .semibold: return .semibold
        case .medium: return .medium
        case .heavy: return .heavy
        default: return .regular
        }
    }
}

/// A rounded bar that slides to its new length. Live: Core Animation (LayerBar). Screenshots: SwiftUI shapes.
struct LevelBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6
    var vertical = false
    var track: Color?
    var radius: CGFloat?
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let f = max(0, min(1, fraction.isFinite ? fraction : 0))
        let r = radius ?? (vertical ? 4 : height / 2)
        let t = track ?? theme.line
        Group {
            if renderMode {
                GeometryReader { g in
                    ZStack(alignment: vertical ? .bottom : .leading) {
                        RoundedRectangle(cornerRadius: r).fill(t)
                        RoundedRectangle(cornerRadius: r)
                            .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: vertical ? .bottom : .leading,
                                                 endPoint: vertical ? .top : .trailing))
                            .frame(width: vertical ? nil : g.size.width * f, height: vertical ? g.size.height * f : nil)
                    }
                }
            } else {
                LayerBar(fraction: f, color: NSColor(color), track: NSColor(t), vertical: vertical, radius: r)
            }
        }
        .frame(height: vertical ? nil : height)
    }
}
