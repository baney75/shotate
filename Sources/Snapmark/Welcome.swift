import AppKit
import CoreGraphics
import SnapmarkCore

/// Screen Recording permission. macOS shows its own prompt once; after that the only way to turn it
/// on is System Settings, and a running app may not see the change until it relaunches.
enum ScreenRecording {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    private static let askedKey = "askedScreenRecording"

    /// First time: the system prompt (which also adds Snapmark to the list in System Settings).
    /// After that: open the right System Settings pane.
    static func request() {
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            if CGRequestScreenCaptureAccess() { return }
        }
        openSettings()
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
final class WelcomeWindowController: NSWindowController {
    private weak var app: AppDelegate?
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let allowButton = NSButton(title: "Allow…", target: nil, action: nil)
    private let relaunchButton = NSButton(title: "Relaunch Snapmark", target: nil, action: nil)
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let loginBox = NSButton(checkboxWithTitle: "Open Snapmark when I log in", target: nil, action: nil)
    private let primary = NSButton(title: "Try a Capture", target: nil, action: nil)
    private var timer: Timer?
    private var openedSettings = false

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 440),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Snapmark"
        super.init(window: window)
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

        let card = NSStackView(views: [permission, separator(), shortcut, separator(), mark])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 14
        card.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor

        let stack = NSStackView(views: [header, card, footer])
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
        allowButton.title = UserDefaults.standard.bool(forKey: "askedScreenRecording") ? "Open Settings" : "Allow…"
        statusLabel.stringValue = granted ? "Allowed. Snapmark can capture your screen."
            : openedSettings ? "Turn on Snapmark in the list, then relaunch."
            : "Needed to capture your screen. Snapmark never sends it anywhere."
        let s = app?.settings
        let keys = Shortcut(s?.captureShortcut ?? Settings.defaultShortcut)?.displayString ?? "⇧⌘S"
        shortcutLabel.stringValue = s?.captureHotkeyEnabled == false
            ? "Use the menu bar icon (the shortcut is off in Settings)."
            : "Press \(keys) and drag. Space switches to a whole window."
        loginBox.state = (app?.launchAtLogin ?? false) ? .on : .off
        primary.isEnabled = granted
    }

    @objc private func allow() {
        let firstTime = !UserDefaults.standard.bool(forKey: "askedScreenRecording")
        ScreenRecording.request()
        // The system prompt only appears once. After that, the user has to flip the switch in Settings.
        openedSettings = !firstTime || !ScreenRecording.isGranted
        refresh()
    }

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

    override func close() {
        timer?.invalidate()
        UserDefaults.standard.set(true, forKey: "onboarded")
        super.close()
    }
}
