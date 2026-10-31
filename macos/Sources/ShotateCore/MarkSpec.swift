import Foundation

/// Marks written as JSON, for `shotate annotate`: agents annotate screenshots for docs the way a
/// person would in the editor. Coordinates are image pixels from the top left, as image viewers and
/// `shotate windows` show them:
///
///     [{"tool": "box", "rect": [40, 60, 300, 120], "color": "red"},
///      {"tool": "arrow", "from": [500, 400], "to": [340, 140], "text": "Click Deploy"},
///      {"tool": "step", "at": [360, 90]},
///      {"tool": "text", "at": [40, 220], "text": "Then wait for the build", "width": 260},
///      {"tool": "redact", "rect": [600, 20, 180, 30]}]
///
/// Tools: arrow, box, ellipse, highlight, redact, text, step, pen ("points"). Colors: red, amber,
/// blue, green, purple, white. Sizes: thin, medium, thick.
public enum MarkSpec {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    static let colors = ["red": 0, "amber": 1, "yellow": 1, "blue": 2, "green": 3, "purple": 4, "white": 5]

    public static func marks(from data: Data, imageHeight: Int) throws -> [Mark] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure(message: "Marks must be a JSON array of objects.")
        }
        let h = CGFloat(imageHeight)
        func point(_ v: Any?, _ key: String, _ i: Int) throws -> CGPoint {
            guard let n = numbers(v), n.count == 2 else { throw Failure(message: "Mark \(i + 1): \(key) must be [x, y].") }
            return CGPoint(x: n[0], y: h - n[1])
        }
        return try list.enumerated().map { i, o in
            guard let name = o["tool"] as? String,
                  let tool = Tool.allCases.first(where: { $0.title.lowercased() == name.lowercased() }),
                  tool != .select, tool != .crop else {
                throw Failure(message: "Mark \(i + 1): tool must be arrow, box, ellipse, highlight, redact, text, step or pen.")
            }
            let colorName = (o["color"] as? String)?.lowercased() ?? (tool == .highlight ? "amber" : "red")
            guard let c = colors[colorName] else { throw Failure(message: "Mark \(i + 1): unknown color \(colorName).") }
            let color = RGBA.palette[c]
            let size = ["thin": StrokeSize.thin, "medium": .medium, "thick": .thick][(o["size"] as? String)?.lowercased() ?? "medium"] ?? .medium
            let text = o["text"] as? String ?? ""
            switch tool {
            case .arrow:
                return Mark(tool: .arrow, color: color, size: size, start: try point(o["from"], "from", i),
                            end: try point(o["to"], "to", i), text: text, bend: CGFloat(numbers(o["bend"])?.first ?? 0))
            case .box, .ellipse, .highlight, .redact:
                guard let r = numbers(o["rect"]), r.count == 4 else { throw Failure(message: "Mark \(i + 1): rect must be [x, y, w, h].") }
                return Mark(tool: tool, color: color, size: size, start: CGPoint(x: r[0], y: h - r[1]),
                            end: CGPoint(x: r[0] + r[2], y: h - r[1] - r[3]))
            case .text:
                guard !text.isEmpty else { throw Failure(message: "Mark \(i + 1): text needs \"text\".") }
                let width = numbers(o["width"])?.first.map { CGFloat($0) }
                let font = numbers(o["fontSize"])?.first.map { CGFloat($0) }
                return Mark(tool: .text, color: color, size: size, start: try point(o["at"], "at", i), end: .zero,
                            text: text, fontSize: font, textWidth: width)
            case .step:
                return Mark(tool: .step, color: color, size: size, start: try point(o["at"], "at", i), end: .zero)
            case .pen:
                guard let pts = o["points"] as? [Any], pts.count >= 2 else {
                    throw Failure(message: "Mark \(i + 1): pen needs points [[x, y], ...].")
                }
                let points = try pts.map { try point($0, "points", i) }
                return Mark.stroke(points, pressures: [], color: color, size: size)
            case .select, .crop:
                throw Failure(message: "Mark \(i + 1): \(name) isn't a mark.")
            }
        }
    }

    static func numbers(_ v: Any?) -> [Double]? {
        if let n = v as? NSNumber { return [n.doubleValue] }
        guard let a = v as? [Any] else { return nil }
        let n = a.compactMap { ($0 as? NSNumber)?.doubleValue }
        return n.count == a.count ? n : nil
    }
}
