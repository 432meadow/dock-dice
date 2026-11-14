import AppKit
import QuartzCore

/// The game's tiny score display, drawn above the SCNView inside the click-through overlay:
/// one quiet pill with the turn total, and small "+150" pills that drift up and fade.
/// Pure Core Animation, so it needs no SceneKit rendering. Coordinates are window-local AppKit.
final class HudView: NSView {
    private let pill = CALayer()
    private let pillText = CATextLayer()
    private var shownValue = 0
    private var targetValue = 0
    private var countTimer: Timer?
    private var bg = NSColor(srgbRed: 0.975, green: 0.962, blue: 0.925, alpha: 0.96)
    private var fg = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
    private var edge = NSColor(white: 0, alpha: 0.10)
    private(set) var pillVisible = false
    /// Left-centre anchor of the pill.
    private var anchor = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        pill.isHidden = true
        pill.opacity = 0
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.22
        pill.shadowRadius = 4
        pill.shadowOffset = CGSize(width: 0, height: -1)
        pill.borderWidth = 0.5
        pillText.alignmentMode = .center
        pill.addSublayer(pillText)
        layer?.addSublayer(pill)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never takes clicks

    private static func font(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Follow the die palette: ivory with dark numerals, dark with red on Friday the 13th, and
    /// for the styled looks the die's own body with its pip colour (aqua or white on dark).
    func applyPalette(_ p: DiePalette) {
        if p.name == "friday13" {
            bg = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.96)
            fg = NSColor(srgbRed: 0.95, green: 0.36, blue: 0.30, alpha: 1)
            edge = NSColor(white: 1, alpha: 0.14)
        } else if p.surface != .plain {
            bg = (NSColor(cgColor: p.surface == .void ? DieArt.grey(0.03) : p.body) ?? .black).withAlphaComponent(0.96)
            fg = NSColor(cgColor: p.glow ?? p.pipOuter) ?? .white
            edge = NSColor(cgColor: p.edge) ?? NSColor(white: 0, alpha: 0.10)
        } else {
            bg = NSColor(srgbRed: 0.975, green: 0.962, blue: 0.925, alpha: 0.96)
            fg = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
            edge = NSColor(white: 0, alpha: 0.10)
        }
        applyColors()
        render(shownValue)
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.backgroundColor = bg.cgColor
        pill.borderColor = edge.cgColor
        CATransaction.commit()
    }

    private func attributed(_ s: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Self.font(size), .foregroundColor: fg])
    }

    /// Lay the pill out for the widest number it will show, so it does not wobble while counting.
    private func layout(for value: Int) {
        let size: CGFloat = 13
        let widest = attributed("\(max(value, shownValue))", size: size).size()
        let h: CGFloat = 22
        let w = max(h + 6, ceil(widest.width) + 18)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = CGRect(x: anchor.x, y: anchor.y - h / 2, width: w, height: h)
        pill.cornerRadius = h / 2
        let lh = ceil(Self.font(size).ascender - Self.font(size).descender)
        pillText.frame = CGRect(x: 0, y: (h - lh) / 2, width: w, height: lh)
        pillText.contentsScale = scale
        CATransaction.commit()
    }

    private func render(_ v: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillText.string = attributed("\(v)", size: 13)
        CATransaction.commit()
    }

    func showPill(at p: CGPoint, value: Int) {
        anchor = p
        shownValue = value
        targetValue = value
        layout(for: value)
        render(value)
        if !pillVisible {
            pillVisible = true
            pill.isHidden = false
            fade(pill, to: 1, duration: 0.25)
        }
    }

    func movePill(to p: CGPoint) {
        anchor = p
        layout(for: targetValue)
    }

    /// Count up (or drain down) to `value` over `duration`.
    func setPillValue(_ value: Int, duration: TimeInterval = 0.45) {
        targetValue = value
        layout(for: value)
        countTimer?.invalidate()
        let from = shownValue
        let t0 = ProcessInfo.processInfo.systemUptime
        countTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let k = min(1, (ProcessInfo.processInfo.systemUptime - t0) / duration)
            let e = 1 - pow(1 - k, 2)
            self.shownValue = from + Int((Double(value - from) * e).rounded())
            self.render(self.shownValue)
            if k >= 1 { timer.invalidate() }
        }
    }

    func hidePill() {
        guard pillVisible else { return }
        pillVisible = false
        countTimer?.invalidate()
        fade(pill, to: 0, duration: 0.3) { [weak self] in
            guard let self, !self.pillVisible else { return }
            self.pill.isHidden = true
            self.shownValue = 0
        }
    }

    /// A small "+150" pill that drifts up 34 pt and fades over ~1.1 s.
    func floatText(_ s: String, at p: CGPoint) {
        let size: CGFloat = 12
        let text = attributed(s, size: size)
        let ts = text.size()
        let h: CGFloat = 19
        let w = ceil(ts.width) + 14
        let l = CALayer()
        l.frame = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        l.cornerRadius = h / 2
        l.backgroundColor = bg.cgColor
        l.borderColor = edge.cgColor
        l.borderWidth = 0.5
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.18
        l.shadowRadius = 3
        l.shadowOffset = CGSize(width: 0, height: -1)
        let t = CATextLayer()
        t.string = text
        t.alignmentMode = .center
        t.contentsScale = scale
        let lh = ceil(Self.font(size).ascender - Self.font(size).descender)
        t.frame = CGRect(x: 0, y: (h - lh) / 2, width: w, height: lh)
        l.addSublayer(t)
        layer?.addSublayer(l)

        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = l.position.y
        move.toValue = l.position.y + 34
        let fadeOut = CAKeyframeAnimation(keyPath: "opacity")
        fadeOut.values = [0, 1, 1, 0]
        fadeOut.keyTimes = [0, 0.12, 0.55, 1]
        let g = CAAnimationGroup()
        g.animations = [move, fadeOut]
        g.duration = 1.1
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        l.add(g, forKey: "float")
        l.opacity = 0
        CATransaction.commit()
    }

    private func fade(_ l: CALayer, to o: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setCompletionBlock(completion)
        l.opacity = o
        CATransaction.commit()
    }
}
