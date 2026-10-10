import AppKit
import ServiceManagement
import SnapmarkCore

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

    /// ⌘Q, logout and restarts: save what is open before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editors.forEach { $0.saveEdits() }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Finder "Open With › Snapmark" and dropping images on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.filter(\.isFileURL).forEach(open)
    }

    /// snapmark://capture, snapmark://capture/window, snapmark://capture/screen, snapmark://open?path=/x.png, snapmark://settings
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
            guard let s = Shortcut(keys) else { NSLog("Snapmark: bad shortcut %@", keys); continue }
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
        Capture.run(mode) { [weak self] doc in
            guard let self else { return }
            self.capturing = false
            guard let doc else { return }  // cancelled with Esc
            let url = self.settings.newCaptureURL()
            do { try Output.write(doc.image, to: url, dpi: doc.dpi) } catch {
                NSAlert(error: error).runModal()
                return
            }
            if self.settings.copyOnCapture { Output.copy(doc.image, fileURL: url, dpi: doc.dpi) }
            self.edit(doc, fileURL: url, ownsFile: true)
        }
    }

    func open(_ url: URL) {
        guard let doc = Renderer.loadDocument(at: url) else {
            NSSound.beep()
            return
        }
        edit(doc, fileURL: url, ownsFile: false)
    }

    /// A menu-bar-only app cannot reliably take keyboard focus on current macOS, so while an editor
    /// is open Snapmark becomes a regular app (Dock icon, menu bar, ⌘-Tab) and goes back afterwards.
    private func edit(_ doc: Document, fileURL: URL, ownsFile: Bool) {
        let editor = EditorWindowController(document: doc, fileURL: fileURL, ownsFile: ownsFile)
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
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapmark")
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
                  NSMenuItem(title: "Quit Snapmark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")] {
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
                NSLog("Snapmark: launch at login: %@", error.localizedDescription)
            }
        }
    }
}
