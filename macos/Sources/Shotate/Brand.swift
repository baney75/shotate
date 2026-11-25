import AppKit

/// The app's colors, the same as the icon: deep ink, mark red, and white crop corners.
enum Brand {
    static let ink = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.137, alpha: 1)      // #131523
    static let inkTop = NSColor(srgbRed: 0.161, green: 0.176, blue: 0.290, alpha: 1)   // #292D4A
    static let red = NSColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 1)        // #E8434A
    /// Hairline that lets an ink surface read on a dark desktop.
    static let edge = NSColor(white: 1, alpha: 0.12)
}

/// A soft ring that grows out of a dot and fades, like a live light. Off when Reduce Motion is on.
enum Pulse {
    static func add(to layer: CALayer, color: NSColor) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let ring = CALayer()
        ring.frame = layer.bounds
        ring.cornerRadius = layer.bounds.width / 2
        ring.borderColor = color.withAlphaComponent(0.7).cgColor
        ring.borderWidth = 2
        layer.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.4
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
    }
}
