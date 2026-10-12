import CoreGraphics

public enum CaptureGeometry {
    /// The pixels of a screen's image that show `rect`. `rect` and `screenFrame` are in AppKit global
    /// coordinates (bottom-left origin); image pixels count from the top-left.
    public static func pixelRect(of rect: CGRect, screenFrame: CGRect, scale: CGFloat) -> CGRect {
        let local = rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        return CGRect(x: local.minX * scale, y: (screenFrame.height - local.maxY) * scale,
                      width: local.width * scale, height: local.height * scale).integral
    }
}
