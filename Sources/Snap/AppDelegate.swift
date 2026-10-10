import AppKit
import ServiceManagement
import SnapCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var editors: [EditorWindowController] = []
    private var statusItem: NSStatusItem?
    private var hotkeys = Hotkeys()
    private var settingsWindow: SettingsWindowController?
    private var capturing = false
    var settings = Settings.load()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        applySettings()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count { open(URL(fileURLWithPath: args[i + 1])) }
        if args.contains("--capture") { capture(.area) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Finder "Open With › Snap" and dropping images on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.filter(\.isFileURL).forEach(open)
    }

    /// snap://capture, snap://capture/window, snap://capture/screen, snap://open?path=/x.png, snap://settings
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLComponents(string: s) else { return }
        switch (url.host ?? "") + url.path {
        case "capture", "capture/area": capture(.area)
        case "capture/window": capture(.window)
        case "capture/screen": capture(.screen)
        case "open":
            if let p = url.queryItems?.first(where: { $0.name == "path" })?.value {
                open(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
            }
        case "settings": showSettings()
        default: break
        }
    }

    func applySettings() {
        settings.save()
        hotkeys.removeAll()
        if settings.captureHotkeyEnabled, let s = Shortcut("cmd+shift+s") {
            hotkeys.register(s) { [weak self] in self?.capture(.area) }
        }
        for (keys, command) in settings.commandHotkeys {
            guard let s = Shortcut(keys) else { NSLog("Snap: bad shortcut %@", keys); continue }
            hotkeys.register(s) { Self.run(command) }
        }
        if settings.showMenuBarIcon { installStatusItem() } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Runs a user-configured command through the login shell, so PATH matches a terminal.
    static func run(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", command]
        try? p.run()
    }

    // MARK: Capture and open

    func capture(_ mode: CaptureMode) {
        guard !capturing, Capture.ensurePermission() else { return }
        capturing = true
        Capture.run(mode) { [weak self] image in
            guard let self else { return }
            self.capturing = false
            guard let image else { return }  // cancelled with Esc
            let url = self.settings.newCaptureURL()
            Output.write(image, to: url)
            if self.settings.copyOnCapture { Output.copy(image, fileURL: url) }
            self.edit(Document(image: image), fileURL: url)
        }
    }

    func open(_ url: URL) {
        guard let image = Renderer.loadImage(at: url) else {
            NSSound.beep()
            return
        }
        edit(Document(image: image), fileURL: url)
    }

    /// A menu-bar-only app cannot reliably take keyboard focus on current macOS, so while an editor
    /// is open Snap becomes a regular app (Dock icon, menu bar, ⌘-Tab) and goes back afterwards.
    private func edit(_ doc: Document, fileURL: URL) {
        let editor = EditorWindowController(document: doc, fileURL: fileURL)
        editor.onClose = { [weak self] e in
            guard let self else { return }
            self.editors.removeAll { $0 === e }
            if self.editors.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
        editors.append(editor)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = MainMenu.build(target: self)
        }
        editor.present()
    }

    @objc func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = settings.saveFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    // MARK: Menu bar

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snap")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let area = NSMenuItem(title: "Capture Area", action: #selector(captureArea), keyEquivalent: "")
        if settings.captureHotkeyEnabled { area.title = "Capture Area      ⇧⌘S" }
        for i in [area,
                  NSMenuItem(title: "Capture Window", action: #selector(captureWindow), keyEquivalent: ""),
                  NSMenuItem(title: "Capture Full Screen", action: #selector(captureScreen), keyEquivalent: ""),
                  .separator(),
                  NSMenuItem(title: "Open Image…", action: #selector(openImagePanel), keyEquivalent: ""),
                  NSMenuItem(title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: ""),
                  .separator(),
                  NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","),
                  NSMenuItem(title: "Quit Snap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")] {
            if i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
            menu.addItem(i)
        }
    }

    @objc func captureArea() { capture(.area) }
    @objc func captureWindow() { capture(.window) }
    @objc func captureScreen() { capture(.screen) }
    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.saveFolder)
    }

    @objc func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.present()
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Snap: launch at login: %@", error.localizedDescription)
            }
        }
    }
}
