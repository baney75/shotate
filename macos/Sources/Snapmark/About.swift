import AppKit

/// Who made Snapmark and where to find them. One place, used by the About panel, Settings and Welcome.
enum Credits {
    static let author = "Donovan Baney"
    static let handle = "@baney75"
    static let links: [(String, String)] = [
        ("dbaney.com", "https://dbaney.com"),
        ("GitHub", "https://github.com/baney75/snapmark"),
        ("X \(handle)", "https://x.com/baney75"),
    ]

    /// "Made by Donovan Baney · dbaney.com · GitHub · X @baney75", with working links.
    static func line(size: CGFloat = 11, centered: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = centered ? .center : .left
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size),
                                                   .foregroundColor: NSColor.secondaryLabelColor,
                                                   .paragraphStyle: style]
        let s = NSMutableAttributedString(string: "Made by \(author)", attributes: base)
        for (title, url) in links {
            s.append(NSAttributedString(string: "  ·  ", attributes: base))
            var a = base
            a[.link] = URL(string: url)
            a[.foregroundColor] = NSColor.linkColor
            s.append(NSAttributedString(string: title, attributes: a))
        }
        return s
    }

    /// A label whose links open in the browser.
    static func label(size: CGFloat = 11, centered: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithAttributedString: line(size: size, centered: centered))
        f.isSelectable = true
        f.allowsEditingTextAttributes = true
        return f
    }

    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: line(size: 11, centered: true),
            .init(rawValue: "Copyright"): "© 2026 \(author) (\(handle)). Free and open source under the MIT License.",
        ])
    }
}
