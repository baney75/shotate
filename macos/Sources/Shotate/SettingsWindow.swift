import AppKit
import ShotateCore

/// Shotate Settings: a standard macOS settings window with a toolbar of panes. Every control
/// applies at once and writes ~/.config/shotate/config.json; edits to that file (by hand or by
/// an agent) show up here as soon as Shotate reloads it.
final class SettingsWindowController: NSWindowController {
    private weak var app: AppDelegate?
    private let panes: [SettingsPane]

    init(app: AppDelegate) {
        self.app = app
        panes = [GeneralPane(app: app), ShortcutsPane(app: app), CommandsPane(app: app), AdvancedPane(app: app)]
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for pane in panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Shotate Settings"
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)  // open on the Space the user is looking at
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Shows the app's current settings, e.g. after the config file changed on disk.
    func reload() { panes.forEach { $0.reload() } }
}

// MARK: - Building blocks

class SettingsPane: NSViewController {
    weak var app: AppDelegate?
    let symbol: String
    private let width: CGFloat = 540

    init(app: AppDelegate, title: String, symbol: String) {
        self.app = app
        self.symbol = symbol
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView(views: build())
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for v in stack.arrangedSubviews where v is NSBox || (v as? NSTextField)?.maximumNumberOfLines == 0 {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        }
        view = root
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        preferredContentSize = view.fittingSize
    }

    func build() -> [NSView] { [] }
    func reload() {}

    /// Applies a change and writes the config file.
    func apply(_ change: (inout Settings) -> Void) {
        guard let app else { return }
        change(&app.settings)
        app.applySettings()
    }

    // Small factories so every pane looks the same.
    func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
    func heading(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        return f
    }
    func note(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.textColor = .secondaryLabelColor
        f.font = .systemFont(ofSize: 11)
        f.maximumNumberOfLines = 0
        return f
    }
    func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
    func form(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [label($0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        return grid
    }
}

// MARK: - General

final class GeneralPane: SettingsPane {
    private let permissionIcon = NSImageView()
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "Set Up…", target: nil, action: nil)
    private let folderMenu = NSPopUpButton()
    private let copyBox = NSButton(checkboxWithTitle: "Copy every capture to the clipboard", target: nil, action: nil)
    private let menuBox = NSButton(checkboxWithTitle: "Show Shotate in the menu bar", target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: "Open Shotate when I log in", target: nil, action: nil)
    private let channelMenu = NSPopUpButton()
    private let autoUpdateBox = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let pasteBox = NSButton(checkboxWithTitle: "Ask which screenshot to paste with ⌘V", target: nil, action: nil)
    private let checkButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let installButton = NSButton(title: "Install Update", target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")

    /// The folders offered by name; anything else shows as its own item.
    private static let presets: [(String, URL)] = [
        ("Pictures › Screenshots", Settings.defaultFolder),
        ("Desktop", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)),
        ("Downloads", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)),
    ]

    init(app: AppDelegate) { super.init(app: app, title: "General", symbol: "gearshape") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() -> [NSView] {
        permissionIcon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        permissionButton.target = self
        permissionButton.action = #selector(setUp)
        let permission = NSStackView(views: [permissionIcon, permissionLabel, permissionButton])
        permission.spacing = 8

        folderMenu.target = self
        folderMenu.action = #selector(folderChosen)
        let show = NSButton(title: "Show", target: self, action: #selector(showFolder))
        let folderRow = NSStackView(views: [folderMenu, show])
        folderMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        for b in [copyBox, menuBox, loginBox, autoUpdateBox, pasteBox] { b.target = self; b.action = #selector(toggled(_:)) }
        pasteBox.toolTip = "Take two or more screenshots, then press ⌘V: a panel shows them so you pick one. "
            + "Shotate types the paste for you, which needs Accessibility."
        let options = NSStackView(views: [copyBox, pasteBox, menuBox, loginBox])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 8

        channelMenu.addItems(withTitles: ["Stable", "Nightly"])
        channelMenu.target = self
        channelMenu.action = #selector(channelChosen)
        checkButton.target = self
        checkButton.action = #selector(checkNow)
        installButton.target = self
        installButton.action = #selector(install)
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.preferredMaxLayoutWidth = 320
        let channelRow = NSStackView(views: [channelMenu, checkButton, installButton])
        let updates = NSStackView(views: [channelRow, autoUpdateBox, updateStatus])
        updates.orientation = .vertical
        updates.alignment = .leading
        updates.spacing = 8

        return [
            form([("Screen Recording:", permission), ("Save captures to:", folderRow), ("Options:", options),
                  ("Updates:", updates)]),
            separator(),
            note("Stable gets tested releases. Nightly is built every day from the newest code and may have "
                 + "rough edges; switch back any time. Checking asks GitHub for one small file and sends "
                 + "nothing about you. Captures are saved and copied the moment you take them, and opened "
                 + "images are never overwritten."),
            separator(),
            Credits.label(),
        ]
    }

    override func reload() {
        guard let s = app?.settings else { return }
        let granted = ScreenRecording.isGranted
        permissionIcon.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                       accessibilityDescription: nil)
        permissionIcon.contentTintColor = granted ? .systemGreen : .systemOrange
        permissionLabel.stringValue = granted ? "Allowed" : "Off: Shotate can't capture yet"
        permissionButton.isHidden = granted
        reloadFolderMenu(s.saveFolder)
        copyBox.state = s.copyOnCapture ? .on : .off
        pasteBox.state = s.choosePaste ? .on : .off
        menuBox.state = s.showMenuBarIcon ? .on : .off
        loginBox.state = (app?.launchAtLogin ?? false) ? .on : .off
        if let updater = app?.updater {
            channelMenu.selectItem(at: updater.channel == "nightly" ? 1 : 0)
            autoUpdateBox.state = s.checkForUpdates ? .on : .off
            updateStatus.stringValue = updater.statusText
            installButton.isHidden = updater.available == nil
            checkButton.isEnabled = updater.state != .checking && updater.state != .installing
        }
    }

    /// The presets, the current folder if it is none of them, and "Other Folder…".
    private func reloadFolderMenu(_ current: URL) {
        folderMenu.removeAllItems()
        func add(_ title: String, _ url: URL?) {
            folderMenu.addItem(withTitle: title)
            folderMenu.lastItem?.representedObject = url
            if let url {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                folderMenu.lastItem?.image = icon
            }
        }
        let currentPath = current.standardizedFileURL.path
        for (title, url) in Self.presets { add(title, url) }
        if !Self.presets.contains(where: { $0.1.standardizedFileURL.path == currentPath }) {
            folderMenu.menu?.addItem(.separator())
            add(FileManager.default.displayName(atPath: currentPath), current)
        }
        folderMenu.menu?.addItem(.separator())
        add("Other Folder…", nil)
        let index = folderMenu.itemArray.firstIndex {
            ($0.representedObject as? URL)?.standardizedFileURL.path == currentPath
        }
        folderMenu.selectItem(at: index ?? 0)
        folderMenu.toolTip = (currentPath as NSString).abbreviatingWithTildeInPath
    }

    @objc private func setUp() { app?.showWelcome() }

    @objc private func toggled(_ b: NSButton) {
        switch b {
        case loginBox: app?.launchAtLogin = b.state == .on
        case copyBox: apply { $0.copyOnCapture = b.state == .on }
        case autoUpdateBox: apply { $0.checkForUpdates = b.state == .on }
        case pasteBox: app?.setChoosePaste(b.state == .on)
        default: apply { $0.showMenuBarIcon = b.state == .on }
        }
        reload()
    }

    @objc private func folderChosen() {
        if let url = folderMenu.selectedItem?.representedObject as? URL { setFolder(url) } else { chooseFolder() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = app?.settings.saveFolder
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let url = panel.url { self?.setFolder(url) } else { self?.reload() }
        }
    }

    private func setFolder(_ url: URL) {
        apply { $0.saveFolder = URL(fileURLWithPath: url.path, isDirectory: true) }
        reload()
    }

    @objc private func showFolder() { app?.openFolder() }

    @objc private func channelChosen() {
        let channel = channelMenu.indexOfSelectedItem == 1 ? "nightly" : "stable"
        apply { $0.updateChannel = channel }
    }

    @objc private func checkNow() { app?.checkForUpdates() }
    @objc private func install() { app?.installUpdate() }
}

// MARK: - Shortcuts

final class ShortcutsPane: SettingsPane {
    private var recorders: [String: ShortcutRecorder] = [:]
    private var toolFields: [Tool: NSTextField] = [:]

    init(app: AppDelegate) { super.init(app: app, title: "Shortcuts", symbol: "command") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() -> [NSView] {
        let record = app?.canRecord == true
            ? [("recordArea", "Record area:"), ("recordScreen", "Record full screen:"), ("recordApp", "Record app and log:")]
            : []
        let global = form(([("captureArea", "Capture area:"), ("captureWindow", "Capture window:"),
                            ("captureScreen", "Capture full screen:")] + record).map { name, title in
            let r = ShortcutRecorder(value: app?.settings.shortcuts[name] ?? "")
            r.onChange = { [weak self] v in self?.apply { $0.shortcuts[name] = v } }
            recorders[name] = r
            return (title, r)
        })

        let tools = NSGridView(numberOfColumns: 6, rows: 0)
        tools.rowSpacing = 8
        tools.columnSpacing = 8
        tools.rowAlignment = .firstBaseline
        let all = Tool.allCases
        for row in stride(from: 0, to: all.count, by: 3) {
            var cells: [NSView] = []
            for t in all[row..<min(row + 3, all.count)] {
                let name = NSTextField(labelWithString: t.title)
                let image = NSImageView(image: NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)!)
                image.contentTintColor = .secondaryLabelColor
                // Symbols differ in width; a fixed column keeps the tool names lined up.
                image.widthAnchor.constraint(equalToConstant: 20).isActive = true
                let title = NSStackView(views: [image, name])
                title.spacing = 5
                title.alignment = .firstBaseline
                let field = NSTextField(string: "")
                field.alignment = .center
                field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                field.widthAnchor.constraint(equalToConstant: 30).isActive = true
                field.delegate = self
                field.toolTip = "The letter that picks \(t.title) in the editor"
                toolFields[t] = field
                title.widthAnchor.constraint(equalToConstant: 105).isActive = true
                cells += [title, field]
            }
            tools.addRow(with: cells)
        }

        return [
            heading("Global shortcuts"),
            global,
            note("Click a shortcut, then press the keys. Delete or the ✕ turns it off. These work from any app."
                 + (record.isEmpty ? "" : " Press any record shortcut again to stop and save. Recording an app "
                    + "copies what it logged while recording, ready to paste; the video and the log are saved together.")),
            separator(),
            heading("Editor tool keys"),
            tools,
            note("One letter per tool. A letter another tool already uses is ignored, so every tool stays reachable. "
                 + "Digits 1–6 always pick colors."),
        ]
    }

    override func reload() {
        guard let s = app?.settings else { return }
        for (name, r) in recorders { r.value = s.shortcuts[name] ?? "" }
        for (t, f) in toolFields where f.currentEditor() == nil { f.stringValue = s.key(for: t).uppercased() }
    }

    @objc private func toolKeyChanged(_ f: NSTextField) {
        guard let tool = toolFields.first(where: { $0.value === f })?.key else { return }
        let k = f.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        apply { $0.toolKeys[tool.title.lowercased()] = k.isEmpty ? tool.rawValue : k }
        if app?.settings.key(for: tool) != k, !k.isEmpty { NSSound.beep() }
        reload()
    }
}

extension ShortcutsPane: NSTextFieldDelegate {
    /// Keep tool-key fields to a single letter while typing.
    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField else { return }
        let letters = f.stringValue.filter { $0.isLetter && $0.isASCII }
        f.stringValue = String(letters.suffix(1)).uppercased()
    }
    func controlTextDidEndEditing(_ n: Notification) {
        if let f = n.object as? NSTextField { toolKeyChanged(f) }
    }
}

// MARK: - Commands

/// Global shortcuts that run a shell command, one row each.
final class CommandsPane: SettingsPane {
    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "No command shortcuts yet.")

    init(app: AppDelegate) { super.init(app: app, title: "Commands", symbol: "terminal") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() -> [NSView] {
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        empty.textColor = .tertiaryLabelColor
        let add = NSButton(title: "Add Command Shortcut", target: self, action: #selector(addRow))
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        return [
            note("Run any shell command from a global shortcut, such as opening a terminal or a notes script. "
                 + "Commands run in your login shell, so your PATH applies."),
            list, add,
        ]
    }

    override func reload() {
        guard let s = app?.settings, list.window?.firstResponder as? NSText == nil else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let sorted = s.commandHotkeys.sorted { $0.key < $1.key }
        if sorted.isEmpty { list.addArrangedSubview(empty) }
        for (keys, command) in sorted { list.addArrangedSubview(row(keys: keys, command: command)) }
    }

    private func row(keys: String, command: String) -> NSView {
        let recorder = ShortcutRecorder(value: keys, placeholder: "Set Shortcut")
        let field = NSTextField(string: command)
        field.placeholderString = "open -a Terminal"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")!,
                              target: nil, action: nil)
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        let row = CommandRow(views: [recorder, field, remove])
        row.recorder = recorder
        row.field = field
        recorder.onChange = { [weak self] _ in self?.save() }
        field.target = self
        field.action = #selector(save)
        remove.target = row
        remove.action = #selector(CommandRow.removeSelf)
        row.onRemove = { [weak self] in self?.save() }
        return row
    }

    @objc private func addRow() {
        empty.removeFromSuperview()
        let r = row(keys: "", command: "")
        list.addArrangedSubview(r)
        view.window?.makeFirstResponder((r as? CommandRow)?.field)
    }

    /// Rows with both a shortcut and a command are saved; incomplete rows wait on screen.
    @objc private func save() {
        var map: [String: String] = [:]
        for case let r as CommandRow in list.arrangedSubviews {
            let keys = r.recorder?.value ?? ""
            let command = r.field?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
            if !keys.isEmpty, !command.isEmpty { map[keys] = command }
        }
        apply { $0.commandHotkeys = map }
    }
}

private final class CommandRow: NSStackView {
    weak var recorder: ShortcutRecorder?
    weak var field: NSTextField?
    var onRemove: (() -> Void)?
    @objc func removeSelf() {
        removeFromSuperview()
        onRemove?()
    }
}

// MARK: - Advanced

final class AdvancedPane: SettingsPane {
    init(app: AppDelegate) { super.init(app: app, title: "Advanced", symbol: "slider.horizontal.3") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() -> [NSView] {
        let path = NSTextField(labelWithString: (Settings.configURL.path as NSString).abbreviatingWithTildeInPath)
        path.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        path.isSelectable = true
        let edit = NSButton(title: "Edit Config File…", target: self, action: #selector(editConfig))
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealConfig))
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadConfig))
        let buttons = NSStackView(views: [edit, reveal, reload])

        // Two even columns, so the list fits the pane and the window keeps one width for every pane.
        let names = ["shotate://capture", "shotate://capture/window", "shotate://capture/screen", "shotate://open?path=…",
                     "shotate://settings", "shotate://config", "shotate://reload", "shotate://relaunch"]
        let urls = NSGridView(views: stride(from: 0, to: names.count, by: 2).map { i in
            names[i..<i + 2].map { name -> NSView in
                let f = NSTextField(labelWithString: name)
                f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                f.textColor = .secondaryLabelColor
                f.isSelectable = true
                return f
            }
        })
        urls.rowSpacing = 4
        urls.columnSpacing = 24

        let permissions = NSButton(title: "Set Up Screen Recording…", target: self, action: #selector(welcome))
        let relaunch = NSButton(title: "Relaunch Shotate", target: self, action: #selector(relaunchApp))
        return [
            heading("Config file"),
            note("Every setting lives in one JSON file. Edit it yourself or let a script or AI agent change it; "
                 + "Shotate applies changes the moment the file is saved."),
            path, buttons,
            separator(),
            heading("Automation"),
            urls,
            separator(),
            heading("Troubleshooting"),
            NSStackView(views: [permissions, relaunch]),
        ]
    }

    @objc private func editConfig() { app?.openConfig() }
    @objc private func revealConfig() {
        if !FileManager.default.fileExists(atPath: Settings.configURL.path) { try? app?.settings.save() }
        NSWorkspace.shared.activateFileViewerSelecting([Settings.configURL])
    }
    @objc private func reloadConfig() { app?.reloadConfig() }
    @objc private func welcome() { app?.showWelcome() }
    @objc private func relaunchApp() { ScreenRecording.relaunch() }
}
