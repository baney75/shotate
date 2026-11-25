import CoreGraphics

public enum CaptureGeometry {
    /// The pixels of a screen's image that show `rect`. `rect` and `screenFrame` are in AppKit global
    /// coordinates (bottom-left origin); image pixels count from the top-left.
    public static func pixelRect(of rect: CGRect, screenFrame: CGRect, scale: CGFloat) -> CGRect {
        let local = rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        return CGRect(x: local.minX * scale, y: (screenFrame.height - local.maxY) * scale,
                      width: local.width * scale, height: local.height * scale).integral
    }

    /// `rect` in the display's own points, counted from its top-left: what a recording's
    /// `sourceRect` takes.
    public static func displayRect(of rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A video's pixel size for an area of `size` points: even on both sides, since H.264 encodes
    /// colour for 2×2 blocks of pixels, and within what Apple's H.264 encoder takes (4096×2304, either
    /// way round), shrunk evenly when a 5K or 6K screen is bigger.
    public static func videoSize(of size: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let w = size.width * scale, h = size.height * scale
        let (maxW, maxH): (CGFloat, CGFloat) = w >= h ? (4096, 2304) : (2304, 4096)
        let fit = min(1, maxW / max(w, 1), maxH / max(h, 1))
        func even(_ v: CGFloat) -> Int { max(2, Int((v * fit).rounded(.down)) / 2 * 2) }
        return (even(w), even(h))
    }
}
