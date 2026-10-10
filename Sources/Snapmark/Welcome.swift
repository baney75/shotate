import AppKit
import CoreGraphics
import SnapmarkCore

/// Screen Recording permission. A running app may not see a change until it relaunches.
///
/// macOS stores a grant together with the code signature of the build that asked. If that signature
/// changes (older Snapmark builds were signed ad hoc, so every build had a new one), the switch in
/// System Settings can show "on" while macOS still refuses this build, and flipping it doesn't help.
/// `request()` therefore clears Snapmark's own entry before asking, so macOS records this build.
enum ScreenRecording {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    static let askedKey = "askedScreenRecording"
    static var hasAsked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    /// Shows the system prompt, which also adds Snapmark to the list in System Settings.
    static func request() {
        if hasAsked { resetOwnEntry() }
        UserDefaults.standard.set(true, forKey: askedKey)
        _ = CGRequestScreenCaptureAccess()
    }

    /// Removes only Snapmark's Screen Recording entry (never another app's), so macOS asks again.
    @discardableResult
    static func resetOwnEntry() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "com.baney.snapmark"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Quits and reopens Snapmark so it picks up a permission granted in System Settings.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"", "sh",
                       String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Errors the user must see. A menu bar app has no window of its own, so bring it forward first.
enum Alerts {
    static func show(_ title: String, _ detail: String, in window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    static func show(_ title: String, error: Error, in window: NSWindow? = nil) {
        show(title, (error as NSError).localizedDescription, in: window)
    }
}

/// First launch and missing permission: one window that gets Snapmark ready to use.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private weak var app: AppDelegate?
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let allowButton = NSButton(title: "Allow…", target: nil, action: nil)
    private let relaunchButton = NSButton(title: "Relaunch", target: nil, action: nil)
    private let settingsLink = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let loginBox = NSButton(checkboxWithTitle: "Open Snapmark when I log in", target: nil, action: nil)
    private let primary = NSButton(title: "Try a Capture", target: nil, action: nil)
    private var timer: Timer?
    private var openedSettings = false

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Snapmark"
        super.init(window: window)
        window.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { self?.timer?.invalidate(); return }
            self.refresh()
        }
    }

    private func build() {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let title = NSTextField(labelWithString: "Welcome to Snapmark")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Capture, mark up, and paste in a few seconds.")
        subtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [icon, title, subtitle])
        header.orientation = .vertical
        header.spacing = 6
        header.setCustomSpacing(12, after: icon)

        allowButton.target = self
        allowButton.action = #selector(allow)
        allowButton.bezelStyle = .rounded
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunch)
        relaunchButton.bezelStyle = .rounded
        settingsLink.target = self
        settingsLink.action = #selector(openSystemSettings)
        settingsLink.isBordered = false
        settingsLink.contentTintColor = .linkColor
        settingsLink.font = .systemFont(ofSize: 11)
        settingsLink.alignment = .right
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.preferredMaxLayoutWidth = 250
        let permission = row(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                             detail: statusLabel, trailing: [statusIcon, allowButton, relaunchButton])

        shortcutLabel.textColor = .secondaryLabelColor
        let shortcut = row(symbol: "keyboard", title: "Capture from anywhere", detail: shortcutLabel, trailing: [])
        let mark = row(symbol: "pencil.tip.crop.circle", title: "Mark it up, press Return",
                       detail: NSTextField(labelWithString: "The image is copied and saved. Esc closes."),
                       trailing: [])

        loginBox.target = self
        loginBox.action = #selector(toggleLogin)

        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        primary.target = self
        primary.action = #selector(tryCapture)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        let footer = NSStackView(views: [loginBox, NSView(), done, primary])
        footer.spacing = 10

        let card = NSStackView(views: [permission, settingsLink, separator(), shortcut, separator(), mark])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 14
        card.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor

        let stack = NSStackView(views: [header, card, footer, Credits.label(centered: true)])
        stack.orientation = .vertical
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSVisualEffectView()
        root.material = .windowBackground
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56),
            footer.widthAnchor.constraint(equalTo: card.widthAnchor),
        ])
        for v in card.arrangedSubviews { v.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -32).isActive = true }
        window?.contentView = root
    }

    private func row(symbol: String, title: String, detail: NSTextField, trailing: [NSView]) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        image.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        image.contentTintColor = .controlAccentColor
        image.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, text] + trailing)
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func refresh() {
        let granted = ScreenRecording.isGranted
        statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Allowed")
        statusIcon.contentTintColor = .systemGreen
        statusIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        statusIcon.isHidden = !granted
        allowButton.isHidden = granted
        relaunchButton.isHidden = granted || !openedSettings
        settingsLink.isHidden = granted || !openedSettings
        allowButton.title = openedSettings ? "Ask Again" : "Allow…"
        statusLabel.stringValue = granted ? "Allowed. Snapmark can capture your screen."
            : openedSettings ? "Turn Snapmark on in the macOS prompt or in System Settings, then click Relaunch."
            : "Needed to capture your screen. Snapmark never sends it anywhere."
        let s = app?.settings
        if let keys = s?.captureShortcut?.displayString {
            shortcutLabel.stringValue = "Press \(keys) and drag. Space switches to a whole window."
        } else {
            shortcutLabel.stringValue = "Use the menu bar icon, or set a shortcut in Settings."
        }
        loginBox.state = (app?.launchAtLogin ?? false) ? .on : .off
        primary.isEnabled = granted
    }

    @objc private func allow() {
        ScreenRecording.request()
        openedSettings = true
        refresh()
    }

    @objc private func openSystemSettings() { ScreenRecording.openSettings() }

    @objc private func doneClicked() { close() }

    @objc private func relaunch() { ScreenRecording.relaunch() }

    @objc private func toggleLogin() {
        app?.launchAtLogin = loginBox.state == .on
        refresh()
    }

    @objc private func tryCapture() {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak app] in app?.capture(.area) }
    }

    /// Every way of closing (Done, Esc, the red button) counts as finishing the welcome.
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        UserDefaults.standard.set(true, forKey: "onboarded")
    }
}
