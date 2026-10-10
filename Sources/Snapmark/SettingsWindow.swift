import AppKit
import SnapmarkCore

final class SettingsWindowController: NSWindowController {
    private weak var app: AppDelegate?
    private let folderLabel = NSTextField(labelWithString: "")
    private let copyBox = NSButton(checkboxWithTitle: "Copy every capture to the clipboard", target: nil, action: nil)
    private let hotkeyBox = NSButton(checkboxWithTitle: "Capture an area with", target: nil, action: nil)
    private let shortcutField = NSTextField(string: "")
    private let permissionLabel = NSTextField(labelWithString: "")
    private let menuBox = NSButton(checkboxWithTitle: "Show Snapmark in the menu bar", target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: "Open Snapmark at login", target: nil, action: nil)
    private let commands = NSTextView()

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Snapmark Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        load()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        load()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let folderRow = NSStackView(views: [folderLabel, choose])

        for b in [copyBox, hotkeyBox, menuBox, loginBox] { b.target = self; b.action = #selector(changed) }
        shortcutField.placeholderString = Settings.defaultShortcut
        shortcutField.target = self
        shortcutField.action = #selector(changed)
        shortcutField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        shortcutField.toolTip = "For example cmd+shift+s or ctrl+option+2. Press Return to apply."
        let shortcutRow = NSStackView(views: [hotkeyBox, shortcutField])

        let fix = NSButton(title: "Set Up…", target: self, action: #selector(showWelcome))
        let permissionRow = NSStackView(views: [permissionLabel, fix])

        let help = NSTextField(wrappingLabelWithString:
            "Extra shortcuts, one per line: shortcut = command. The command runs in your login shell.\n"
            + "Example:  cmd+shift+a = open -a Ghostty")
        help.textColor = .secondaryLabelColor
        commands.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commands.isAutomaticQuoteSubstitutionEnabled = false
        commands.isAutomaticDashSubstitutionEnabled = false
        let scroll = NSScrollView()
        scroll.documentView = commands
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        commands.autoresizingMask = [.width]
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        let save = NSButton(title: "Save Shortcuts", target: self, action: #selector(changed))

        let stack = NSStackView(views: [
            permissionRow,
            NSTextField(labelWithString: "Save screenshots to:"), folderRow,
            copyBox, shortcutRow, menuBox, loginBox, help, scroll, save,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            folderRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window?.contentView = root
    }

    private func load() {
        guard let s = app?.settings else { return }
        folderLabel.stringValue = (s.saveFolder.path as NSString).abbreviatingWithTildeInPath
        copyBox.state = s.copyOnCapture ? .on : .off
        hotkeyBox.state = s.captureHotkeyEnabled ? .on : .off
        shortcutField.stringValue = s.captureShortcut
        shortcutField.isEnabled = s.captureHotkeyEnabled
        permissionLabel.stringValue = ScreenRecording.isGranted ? "✓ Screen Recording is allowed"
            : "⚠︎ Screen Recording is off, so Snapmark can't capture"
        menuBox.state = s.showMenuBarIcon ? .on : .off
        loginBox.state = (app?.launchAtLogin ?? false) ? .on : .off
        commands.string = s.commandHotkeys.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n")
    }

    @objc private func changed() {
        guard let app else { return }
        var s = app.settings
        s.copyOnCapture = copyBox.state == .on
        s.captureHotkeyEnabled = hotkeyBox.state == .on
        let typed = shortcutField.stringValue.trimmingCharacters(in: .whitespaces)
        if Shortcut(typed) != nil { s.captureShortcut = typed.lowercased() } else if !typed.isEmpty {
            NSSound.beep()
        }
        s.showMenuBarIcon = menuBox.state == .on
        var map: [String: String] = [:]
        for line in commands.string.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, Shortcut(parts[0]) != nil, !parts[1].isEmpty { map[parts[0]] = parts[1] }
        }
        s.commandHotkeys = map
        app.settings = s
        if (loginBox.state == .on) != app.launchAtLogin { app.launchAtLogin = loginBox.state == .on }
        app.applySettings()
        load()
    }

    @objc private func showWelcome() { app?.showWelcome() }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard let window, panel.runModal() == .OK, let url = panel.url else { return }
        app?.settings.saveFolder = url
        app?.applySettings()
        load()
        _ = window
    }
}
