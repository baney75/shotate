import AppKit
import OSLog
import ServiceManagement
import SnapmarkCore

private let log = Logger(subsystem: "com.baney.snapmark", category: "config")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var editors: [EditorWindowController] = []
    private var statusItem: NSStatusItem?
    private var hotkeys = Hotkeys()
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private var capturing = false
    private var configSource: DispatchSourceFileSystemObject?
    /// Shortcuts that registered (or failed) last time, so a conflict is reported once, not on every change.
    private var lastShortcuts: [String: String] = [:]
    var settings = Settings()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        NSApp.mainMenu = MainMenu.build(target: self)
        settings = loadConfig() ?? settings
        applySettings(save: !FileManager.default.fileExists(atPath: Settings.configURL.path))
        watchConfig()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count { open(URL(fileURLWithPath: args[i + 1])) }
        if args.contains("--capture") { capture(.area) }
        // Only the first launch opens the welcome window. After that a missing permission shows in the
        // menu bar menu, and the welcome window opens when a capture needs it.
        if !UserDefaults.standard.bool(forKey: "onboarded") { showWelcome() }
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

    /// snapmark://capture, snapmark://capture/window, snapmark://capture/screen, snapmark://open?path=/x.png,
    /// snapmark://settings, snapmark://config (open the config file), snapmark://reload, snapmark://welcome
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
        case "welcome", "permissions": showWelcome()
        case "config": openConfig()
        case "reload": reloadConfig()
        default: break
        }
    }

    // MARK: Config file

    /// The config file, or settings migrated from before it existed. A broken file is reported and
    /// left alone, never overwritten, so a typo can't wipe someone's settings.
    private func loadConfig() -> Settings? {
        let url = Settings.configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Settings.migrated(from: .standard)
        }
        do { return try Settings.load(from: url) } catch {
            Alerts.show("Snapmark couldn't read its config file",
                        "\((url.path as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)\n\n"
                        + "Snapmark keeps its current settings until the file is fixed.")
            return nil
        }
    }

    /// Reloads when the file changes, whoever changed it: a text editor, an agent, `snapmark://reload`.
    /// A kernel file event wakes Snapmark even while macOS naps it (a timer would stall). Editors that
    /// save by replacing the file end the watch, so it re-arms on the new file.
    private func watchConfig() {
        configSource?.cancel()
        configSource = nil
        let fd = Darwin.open(Settings.configURL.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.watchConfig() }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let replaced = !(source?.data ?? []).isDisjoint(with: [.delete, .rename])
            // Let the writer finish before reading.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.reloadConfig()
                if replaced { self?.watchConfig() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configSource = source
    }

    @objc func reloadConfig() {
        guard FileManager.default.fileExists(atPath: Settings.configURL.path),
              let fresh = loadConfig(), fresh != settings else { return }
        settings = fresh
        log.notice("Reloaded \(Settings.configURL.path, privacy: .public)")
        applySettings(save: false)
        settingsWindow?.reload()
    }

    @objc func openConfig() {
        if !FileManager.default.fileExists(atPath: Settings.configURL.path) { try? settings.save() }
        // TextEdit, so it opens as text even where .json belongs to an app that can't edit it.
        NSWorkspace.shared.open([Settings.configURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Applies settings to the running app; with `save`, also writes the config file.
    func applySettings(save: Bool = true) {
        if save {
            do { try settings.save() } catch {
                Alerts.show("Snapmark couldn't save its settings", error: error)
            }
        }
        hotkeys.removeAll()
        let actions: [String: () -> Void] = [
            "captureArea": { [weak self] in self?.capture(.area) },
            "captureWindow": { [weak self] in self?.capture(.window) },
            "captureScreen": { [weak self] in self?.capture(.screen) },
        ]
        var taken: [String] = []
        for name in Settings.actions {
            guard let keys = settings.shortcuts[name], let s = Shortcut(keys), let action = actions[name] else { continue }
            if !hotkeys.register(s, action), lastShortcuts[name] != keys { taken.append(s.displayString) }
        }
        lastShortcuts = settings.shortcuts
        if !taken.isEmpty {
            Alerts.show("\(taken.joined(separator: ", ")) \(taken.count == 1 ? "is" : "are") already in use",
                        "Another app owns that shortcut. Pick a different one in Snapmark Settings.")
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
        guard !capturing else { return }
        guard ScreenRecording.isGranted else { showWelcome(); return }
        capturing = true
        Capture.run(mode) { [weak self] doc in
            guard let self else { return }
            self.capturing = false
            guard let doc else { return }  // cancelled with Esc
            let url = self.settings.newCaptureURL()
            do { try Output.write(doc.image, to: url, dpi: doc.dpi) } catch {
                Alerts.show("Snapmark couldn't save the capture to \(url.deletingLastPathComponent().path)",
                            error: error)
                return
            }
            if self.settings.copyOnCapture, !Output.copy(doc.image, fileURL: url, dpi: doc.dpi) {
                Alerts.show("Snapmark couldn't copy the capture", "It is saved at \(url.path).")
            }
            self.edit(doc, fileURL: url, ownsFile: true)
        }
    }

    func open(_ url: URL) {
        guard let doc = Renderer.loadDocument(at: url) else {
            Alerts.show("Snapmark can't open \(url.lastPathComponent)", "It isn't an image Snapmark can read.")
            return
        }
        edit(doc, fileURL: url, ownsFile: false)
    }

    /// Snapmark lives in the menu bar only: no Dock icon, even while an editor is open. The editor
    /// window activates the app to take keyboard focus, and the hidden main menu still routes ⌘V,
    /// ⌘A and friends to text labels.
    private func edit(_ doc: Document, fileURL: URL, ownsFile: Bool) {
        let editor = EditorWindowController(document: doc, fileURL: fileURL, ownsFile: ownsFile, settings: settings)
        editor.onClose = { [weak self] e in self?.editors.removeAll { $0 === e } }
        editors.append(editor)
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
        if !ScreenRecording.isGranted {
            let fix = NSMenuItem(title: "Allow Screen Recording…", action: #selector(showWelcome), keyEquivalent: "")
            fix.target = self
            fix.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(fix)
            menu.addItem(.separator())
        }
        func item(_ title: String, _ action: Selector, shortcut name: String) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if let s = settings.shortcuts[name].flatMap(Shortcut.init), s.key.count == 1 {
                // Shown, not bound: the global hotkey does the work.
                i.keyEquivalent = s.key
                i.keyEquivalentModifierMask = s.modifierFlags
            }
            return i
        }
        for i in [item("Capture Area", #selector(captureArea), shortcut: "captureArea"),
                  item("Capture Window", #selector(captureWindow), shortcut: "captureWindow"),
                  item("Capture Full Screen", #selector(captureScreen), shortcut: "captureScreen"),
                  .separator(),
                  NSMenuItem(title: "Open Image…", action: #selector(openImagePanel), keyEquivalent: ""),
                  NSMenuItem(title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: ""),
                  .separator(),
                  NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","),
                  NSMenuItem(title: "Edit Config File…", action: #selector(openConfig), keyEquivalent: ""),
                  NSMenuItem(title: "About Snapmark", action: #selector(showAbout), keyEquivalent: ""),
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

    @objc func showAbout() { Credits.showAbout() }

    @objc func showWelcome() {
        if welcomeWindow == nil { welcomeWindow = WelcomeWindowController(app: self) }
        welcomeWindow?.present()
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
