import AppKit
import SnapmarkCore

/// A front end for ~/.config/snapmark/config.json. Changes here write the file; edits to the file
/// (by hand or by an agent) show up here as soon as Snapmark reloads it.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private weak var app: AppDelegate?
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "Set Up…", target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: "")
    private let copyBox = NSButton(checkboxWithTitle: "Copy every capture to the clipboard", target: nil, action: nil)
    private let menuBox = NSButton(checkboxWithTitle: "Show Snapmark in the menu bar", target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: "Open Snapmark at login", target: nil, action: nil)
    private var shortcutFields: [String: NSTextField] = [:]
    private let commands = NSTextView()

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Snapmark Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func build() {
        permissionButton.target = self
        permissionButton.action = #selector(showWelcome)
        let permissionRow = NSStackView(views: [permissionLabel, permissionButton])

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let folderRow = NSStackView(views: [NSTextField(labelWithString: "Save screenshots to"), folderLabel, choose])

        for b in [copyBox, menuBox, loginBox] { b.target = self; b.action = #selector(changed) }

        let grid = NSGridView(views: [("captureArea", "Capture area"), ("captureWindow", "Capture window"),
                                      ("captureScreen", "Capture full screen")].map { name, title in
            let field = NSTextField(string: "")
            field.placeholderString = "off"
            field.delegate = self
            field.target = self
            field.action = #selector(changed)
            field.widthAnchor.constraint(equalToConstant: 180).isActive = true
            shortcutFields[name] = field
            return [NSTextField(labelWithString: title), field]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let shortcutHelp = hint("Type a shortcut such as cmd+shift+s or ctrl+option+2, then Return. Leave it empty to turn it off.")

        commands.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commands.isAutomaticQuoteSubstitutionEnabled = false
        commands.isAutomaticDashSubstitutionEnabled = false
        commands.isRichText = false
        let scroll = NSScrollView()
        scroll.documentView = commands
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        commands.autoresizingMask = [.width]
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        let commandHelp = hint("One per line: shortcut = command. The command runs in your login shell.\n"
                               + "Example:  cmd+shift+a = open -a Terminal")

        let path = (Settings.configURL.path as NSString).abbreviatingWithTildeInPath
        let configHelp = hint("All of this lives in \(path), including the editor's tool keys. "
                              + "Edit it there or here; changes apply right away.")
        let editConfig = NSButton(title: "Edit Config File…", target: self, action: #selector(openConfig))
        let apply = NSButton(title: "Apply", target: self, action: #selector(changed))
        apply.keyEquivalent = "\r"
        let footer = NSStackView(views: [editConfig, NSView(), apply])

        let stack = NSStackView(views: [
            permissionRow, separator(),
            folderRow, copyBox, menuBox, loginBox, separator(),
            heading("Shortcuts"), grid, shortcutHelp, separator(),
            heading("Command shortcuts"), scroll, commandHelp, separator(),
            configHelp, footer, separator(), Credits.label(),
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
        ])
        for v in [folderRow, scroll, footer, configHelp, shortcutHelp, commandHelp] + stack.arrangedSubviews.filter({ $0 is NSBox }) {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window?.contentView = root
    }

    private func heading(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        return f
    }

    private func hint(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.textColor = .secondaryLabelColor
        f.font = .systemFont(ofSize: 11)
        return f
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // MARK: State

    /// Shows the app's current settings, e.g. after the config file changed on disk.
    func reload() {
        guard let s = app?.settings else { return }
        let granted = ScreenRecording.isGranted
        permissionLabel.stringValue = granted ? "✓ Screen Recording is allowed"
            : "⚠︎ Screen Recording is off, so Snapmark can't capture yet"
        permissionButton.isHidden = granted
        folderLabel.stringValue = (s.saveFolder.path as NSString).abbreviatingWithTildeInPath
        copyBox.state = s.copyOnCapture ? .on : .off
        menuBox.state = s.showMenuBarIcon ? .on : .off
        loginBox.state = (app?.launchAtLogin ?? false) ? .on : .off
        for (name, field) in shortcutFields { field.stringValue = s.shortcuts[name] ?? "" }
        commands.string = s.commandHotkeys.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n")
    }

    @objc private func changed() {
        guard let app else { return }
        var s = app.settings
        s.copyOnCapture = copyBox.state == .on
        s.showMenuBarIcon = menuBox.state == .on
        var rejected: [String] = []
        for (name, field) in shortcutFields {
            let typed = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            if typed.isEmpty || Shortcut(typed) != nil { s.shortcuts[name] = typed } else { rejected.append(typed) }
        }
        var map: [String: String] = [:]
        for line in commands.string.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, Shortcut(parts[0]) != nil, !parts[1].isEmpty { map[parts[0].lowercased()] = parts[1] }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty { rejected.append(String(line)) }
        }
        s.commandHotkeys = map
        app.settings = s
        if (loginBox.state == .on) != app.launchAtLogin { app.launchAtLogin = loginBox.state == .on }
        app.applySettings()
        reload()
        if !rejected.isEmpty {
            Alerts.show("Some shortcuts weren't understood", rejected.joined(separator: "\n")
                        + "\n\nUse modifiers plus one key, such as cmd+shift+s.", in: window)
        }
    }

    @objc private func showWelcome() { app?.showWelcome() }
    @objc private func openConfig() { app?.openConfig() }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app?.settings.saveFolder = url
        app?.applySettings()
        reload()
    }
}
