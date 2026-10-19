import AppKit
import OSLog
import ServiceManagement
import ShotateCore

private let log = Logger(subsystem: "com.baney.snapmark", category: "config")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var editors: [EditorWindowController] = []
    /// The last other app you were in, to get focus back when the last editor closes.
    private var returnTo: NSRunningApplication?
    private var statusItem: NSStatusItem?
    private var hotkeys = Hotkeys()
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private var capturing = false
    /// Quitting waits for the recording to be saved.
    private var quitAfterRecording = false
    private var configSource: DispatchSourceFileSystemObject?
    /// True while the config file has a JSON error. Shotate then never writes it, so a typo
    /// can't cost someone their settings.
    private(set) var configBroken = false
    /// Shortcuts that registered (or failed) last time, so a conflict is reported once, not on every change.
    private var lastShortcuts: [String: String] = [:]
    private var lastCommands: [String: String] = [:]
    static let actionTitles = ["captureArea": "Capture Area", "captureWindow": "Capture Window",
                               "captureScreen": "Capture Full Screen", "recordArea": "Record Area",
                               "recordScreen": "Record Full Screen", "recordApp": "Record App"]
    var settings = Settings()
    private(set) lazy var updater = Updater { [weak self] in self?.settings ?? Settings() }
    private lazy var pastePicker: PastePicker = {
        let p = PastePicker(hotkeys: hotkeys) { [weak self] in self?.settings.choosePaste ?? false }
        p.setEnabled = { [weak self] on in self?.setChoosePaste(on, prompt: false) }
        return p
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        returnTo = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { self?.returnTo = app }
        }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        NSApp.mainMenu = MainMenu.build(target: self)
        // While a shortcut is being recorded, global shortcuts step aside so the keys reach the recorder.
        ShortcutRecorder.onRecordingChange = { [weak self] recording in
            if recording { self?.hotkeys.removeAll() } else { self?.applySettings(save: false) }
        }
        Settings.adoptLegacyConfig()
        moveLoginItem()
        settings = loadConfig() ?? settings
        settings.normalize()
        applySettings(save: !FileManager.default.fileExists(atPath: Settings.configURL.path))
        watchConfig()
        updater.onChange = { [weak self] in self?.settingsWindow?.reload() }
        pastePicker.update()
        updater.start()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count { open(URL(fileURLWithPath: args[i + 1])) }
        if args.contains("--capture") { capture(.area) }
        if args.contains("--welcome") { showWelcome() }
        // Only the first launch opens the welcome window. After that a missing permission shows in the
        // menu bar menu, and the welcome window opens when a capture needs it.
        if !UserDefaults.standard.bool(forKey: "onboarded") { showWelcome() }
    }

    /// ⌘Q, logout and restarts: save what is open before quitting. A recording is stopped and its
    /// file finished first; cut off, the video wouldn't play.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editors.forEach { $0.saveEdits() }
        guard isRecording else { return .terminateNow }
        quitAfterRecording = true
        stopRecording()
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Finder "Open With › Shotate" and dropping images on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.filter(\.isFileURL).forEach(open)
    }

    /// shotate://capture, shotate://capture/window, shotate://capture/screen, shotate://record (pick an
    /// area and record it, or stop the recording), shotate://record/screen, shotate://record/app,
    /// shotate://record/stop, shotate://open?path=/x.png,
    /// shotate://settings, shotate://config (open the config file), shotate://reload, shotate://welcome,
    /// shotate://update (check for updates now)
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLComponents(string: s) else { return }
        switch (url.host ?? "") + url.path {
        case "capture", "capture/area": capture(.area)
        case "capture/window": capture(.window)
        case "capture/screen": capture(.screen)
        case "record", "record/area": toggleRecording(.area)
        case "record/screen":
            // Any web page can open these links, and this one would start recording with no picker:
            // ask first. (Area and app recording wait for a drag or a click.)
            if isRecording || !canRecord || confirmLinkRecording() { toggleRecording(.screen) }
        case "record/app": toggleRecording(.app)
        case "record/stop": stopRecording()
        case "open":
            if let p = url.queryItems?.first(where: { $0.name == "path" })?.value {
                open(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
            }
        case "settings": showSettings()
        case "welcome", "permissions": showWelcome()
        case "config": openConfig()
        case "reload": reloadConfig()
        case "relaunch": ScreenRecording.relaunch()
        case "update", "check-for-updates":
            // Any web page can open these links, so they never install anything, and with update
            // checks off they only open Settings.
            settings.checkForUpdates ? checkForUpdates() : showSettings()
        case "update-failed":
            let token = url.queryItems?.first { $0.name == "token" }?.value
            guard updater.state == .installing else { break }
            updater.installFailed(token: token)
            if case .failed = updater.state { showUpdateResult() }
        default: break
        }
    }

    // MARK: Config file

    /// The config file, or settings migrated from before it existed. A broken file is reported and
    /// left alone, never overwritten, so a typo can't wipe someone's settings.
    private func loadConfig() -> Settings? {
        let url = Settings.configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            configBroken = false
            return Settings.migrated(from: .standard)
        }
        do {
            let s = try Settings.load(from: url)
            configBroken = false
            return s
        } catch {
            configBroken = true
            Alerts.show("Shotate couldn't read its config file",
                        "\((url.path as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)\n\n"
                        + "Shotate keeps its current settings and won't change the file until it is fixed.")
            return nil
        }
    }

    /// Reloads when the file changes, whoever changed it: a text editor, an agent, `shotate://reload`.
    /// A kernel file event wakes Shotate even while macOS naps it (a timer would stall). Editors that
    /// save by replacing the file end the watch, so it re-arms on the new file.
    private func watchConfig() {
        configSource?.cancel()
        configSource = nil
        let fd = Darwin.open(Settings.configURL.path, O_EVTONLY)
        guard fd >= 0 else {
            // No file yet (or it was deleted): look again shortly, and load it once it's back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let back = FileManager.default.fileExists(atPath: Settings.configURL.path)
                self.watchConfig()
                if back { self.reloadConfig() }
            }
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
        guard FileManager.default.fileExists(atPath: Settings.configURL.path) else {
            // Deleted (for example to get past a broken file): write the current settings back out.
            configBroken = false
            applySettings()
            return
        }
        guard var fresh = loadConfig() else { return }
        fresh.normalize()
        guard fresh != settings else { return }
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

    /// "Choose which screenshot to paste", from Settings or setup. Pasting the chosen one types ⌘V
    /// for you, which needs Accessibility, so turning it on asks for that.
    /// `prompt` is false from the chooser's own switch: a system prompt would take focus and close it.
    func setChoosePaste(_ on: Bool, prompt: Bool = true) {
        settings.choosePaste = on
        applySettings()
        pastePicker.update()
        if on, prompt, !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
    }

    /// Applies settings to the running app; with `save`, also writes the config file.
    func applySettings(save: Bool = true) {
        defer {
            updater.settingsChanged()
            for e in editors { e.settings = settings }
        }
        if save, configBroken {
            Alerts.show("Fix the config file first",
                        "\((Settings.configURL.path as NSString).abbreviatingWithTildeInPath) has an error, so Shotate "
                        + "won't overwrite it. Fix or delete the file; your change applies to this session only.")
        } else if save {
            settings.normalize()
            do { try settings.save() } catch {
                Alerts.show("Shotate couldn't save its settings", error: error)
            }
        }
        hotkeys.removeAll()
        let actions: [String: () -> Void] = [
            "captureArea": { [weak self] in self?.capture(.area) },
            "captureWindow": { [weak self] in self?.capture(.window) },
            "captureScreen": { [weak self] in self?.capture(.screen) },
            "recordArea": { [weak self] in self?.toggleRecording(.area) },
            "recordScreen": { [weak self] in self?.toggleRecording(.screen) },
            "recordApp": { [weak self] in self?.toggleRecording(.app) },
        ]
        var taken: [String] = [], clashes: [String] = []
        // Another app's shortcut is reported once, not at every launch: the person may never have
        // chosen those keys (a new default), and the alert would only nag.
        var reported = Set(UserDefaults.standard.stringArray(forKey: "reportedTakenShortcuts") ?? [])
        func report(_ id: String, _ s: Shortcut) {
            if reported.insert(id).inserted { taken.append(s.displayString) }
        }
        // Which Shotate action or command already has each shortcut, to name it when two share one.
        var mine: [Shortcut: String] = [:]
        for name in Settings.actions {
            guard let keys = settings.shortcuts[name], let s = Shortcut(keys), let action = actions[name] else { continue }
            // Recording shortcuts stay free for other apps where Shotate can't record.
            if Settings.recordActions.contains(name), !canRecord { continue }
            let changed = lastShortcuts[name] != keys
            if let other = mine[s] {
                if changed { clashes.append("\(s.displayString) is set for both \(other) and \(Self.actionTitles[name] ?? name)") }
            } else if hotkeys.register(s, action) {
                mine[s] = Self.actionTitles[name] ?? name
            } else if changed {
                report("\(name)=\(keys)", s)
            }
        }
        lastShortcuts = settings.shortcuts
        for (keys, command) in settings.commandHotkeys.sorted(by: { $0.key < $1.key }) {
            guard let s = Shortcut(keys) else { NSLog("Shotate: bad shortcut %@", keys); continue }
            let changed = lastCommands[keys] != command
            if let other = mine[s] {
                if changed { clashes.append("\(s.displayString) is set for both \(other) and the command “\(command)”") }
            } else if hotkeys.register(s, { Self.run(command) }) {
                mine[s] = "the command “\(command)”"
            } else if changed {
                report("command:\(keys)=\(command)", s)
            }
        }
        lastCommands = settings.commandHotkeys
        UserDefaults.standard.set(reported.sorted(), forKey: "reportedTakenShortcuts")
        if !taken.isEmpty {
            Alerts.show("\(taken.joined(separator: ", ")) \(taken.count == 1 ? "is" : "are") already in use",
                        "Another app owns that shortcut. Pick a different one in Shotate Settings.")
        }
        if !clashes.isEmpty {
            Alerts.show("Two Shotate shortcuts use the same keys",
                        clashes.joined(separator: ".\n") + ". Only the first works. Change one in Shotate Settings.")
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
        // The picker would cover the screen being recorded, and be in the video.
        if isRecording, mode != .screen { return NSSound.beep() }
        guard ScreenRecording.isGranted else { showWelcome(); return }
        capturing = true
        Capture.run(mode) { [weak self] shot in
            guard let self else { return }
            self.capturing = false
            guard let shot else { return }  // cancelled with Esc
            defer { try? FileManager.default.removeItem(at: shot.file) }  // gone already once moved
            let url = self.settings.newCaptureURL()
            do { try Output.place(shot.file, at: url) } catch {
                Alerts.show("Shotate couldn't save the capture to \(url.deletingLastPathComponent().path)",
                            error: error)
                return
            }
            if self.settings.copyOnCapture, !Output.copy(png: shot.png, fileURL: url) {
                Alerts.show("Shotate couldn't copy the capture", "It is saved at \(url.path).")
            }
            self.edit(shot.doc, fileURL: url, ownsFile: true, capturePNG: shot.png)
        }
    }

    // MARK: Record

    enum RecordKind { case area, screen, app }

    var isRecording: Bool { Recording.isActive }

    /// macOS 15 and a build with recording in it.
    var canRecord: Bool {
        if #available(macOS 14.0, *) { return Recording.isSupported }
        return false
    }

    /// A record shortcut: start recording; pressed again (any record shortcut), stop and save.
    /// Area: drag over part of the screen. Full screen: the screen with the pointer. App: click one of
    /// its windows; its log is saved too, and copied instead of the video.
    func toggleRecording(_ kind: RecordKind) {
        if isRecording { return stopRecording() }
        guard !capturing else { return }
        guard #available(macOS 14.0, *), canRecord else {
            return Alerts.show("Recording needs macOS 15 or later", "Screenshots work as before on this Mac. "
                               + "On macOS 15, updating Shotate with Xcode 16 or later installed turns recording on.")
        }
        guard ScreenRecording.isGranted else { showWelcome(); return }
        if kind == .screen {
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            else { return }
            return startRecording(.screen(screen))
        }
        capturing = true
        NativeCapture.pickToRecord(app: kind == .app) { [weak self] pick in
            guard let self else { return }
            self.capturing = false
            switch pick {
            case .cancelled: break
            case .failed: Alerts.show("Shotate couldn't start recording", "macOS didn't let it see the screen. Try again.")
            case let .chosen(target): self.startRecording(target)
            }
        }
    }

    private func confirmLinkRecording() -> Bool {
        let a = NSAlert()
        a.messageText = "Record your whole screen?"
        a.informativeText = "A link asked Shotate to start recording the screen. Only allow it if you opened that link."
        a.addButton(withTitle: "Record")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    private func startRecording(_ target: RecordTarget) {
        Recording.start(target, to: settings.newRecordingURL()) { [weak self] saved, error in
            self?.recordingFinished(saved, error: error)
        }
        updateStatusIcon()
    }

    @objc func stopRecording() { Recording.stop() }

    /// Saved: copy it like a capture, and nothing more (no Finder window; Donovan asked for none). A
    /// recorded app's log is what's copied (it pastes as text into a chat, an issue or a coding
    /// agent); otherwise the video, as a file.
    private func recordingFinished(_ saved: SavedRecording?, error: Error?) {
        updateStatusIcon()
        if settings.copyOnCapture, let saved {
            NSPasteboard.general.clearContents()
            if saved.logError == nil, let text = saved.logText {
                NSPasteboard.general.setString(text, forType: .string)
            } else {
                NSPasteboard.general.writeObjects([saved.video as NSURL])
            }
        }
        if quitAfterRecording { return NSApp.reply(toApplicationShouldTerminate: true) }
        if let error {
            Alerts.show("Shotate couldn't save the recording", error: error)
        } else if let why = saved?.logError {
            Alerts.show("Shotate couldn't read the app's log",
                        "The video is saved\(settings.copyOnCapture ? " and copied" : ""). macOS said: \(why)")
        }
    }

    func open(_ url: URL) {
        guard let doc = Renderer.loadDocument(at: url) else {
            Alerts.show("Shotate can't open \(url.lastPathComponent)", "It isn't an image Shotate can read.")
            return
        }
        edit(doc, fileURL: url, ownsFile: false)
    }

    /// Shotate lives in the menu bar only: no Dock icon, even while an editor is open. The editor
    /// window activates the app to take keyboard focus, and the hidden main menu still routes ⌘V,
    /// ⌘A and friends to text labels.
    private func edit(_ doc: Document, fileURL: URL, ownsFile: Bool, capturePNG: Data? = nil) {
        let editor = EditorWindowController(document: doc, fileURL: fileURL, ownsFile: ownsFile, capturePNG: capturePNG,
                                            settings: settings)
        editor.onClose = { [weak self] e in
            self?.editors.removeAll { $0 === e }
            // Let the window finish closing before checking what else is still open.
            DispatchQueue.main.async { self?.returnFocusIfDone() }
        }
        editors.append(editor)
        editor.present()
    }

    /// Shotate has no Dock icon, so once the last editor closes nothing of it is left to use, yet
    /// it stays the active app and keys go nowhere. Hand focus back to the app you came from.
    private func returnFocusIfDone() {
        guard editors.isEmpty else { return }
        let app = returnTo
        guard NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) })
        else { return }
        if let app, !app.isTerminated { app.activate() } else { NSApp.hide(nil) }
    }

    @objc func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = settings.saveFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    // MARK: Menu bar

    /// The app icon's mark, crop corners around a marker loop, as a template image so macOS tints it
    /// for light and dark menu bars.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let box = r.insetBy(dx: 1.5, dy: 2.5), arm: CGFloat = 4.5
            ctx.setStrokeColor(.black)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(1.6)
            for (x, y, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0),
                                   (box.minX, box.maxY, 1.0, -1.0), (box.maxX, box.maxY, -1.0, -1.0)] {
                ctx.move(to: CGPoint(x: x + dx * arm, y: y)); ctx.addLine(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x, y: y + dy * arm))
            }
            ctx.strokePath()
            // A little more than one turn, growing, like the icon's loop.
            ctx.setLineWidth(1.9)
            let c = CGPoint(x: r.midX, y: r.midY), start = CGFloat.pi * 0.7, sweep = CGFloat.pi * 2.18
            for i in 0...60 {
                let t = CGFloat(i) / 60, a = start - sweep * t, grow = 0.86 + 0.24 * t
                let x = cos(a) * 4.6 * grow, y = sin(a) * 3.1 * grow
                let p = CGPoint(x: c.x + x * cos(0.28) - y * sin(0.28), y: c.y + x * sin(0.28) + y * cos(0.28))
                i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
            }
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Shotate"
        return image
    }()

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    /// A stop button while recording, so the menu bar says how to end it.
    private func updateStatusIcon() {
        statusItem?.button?.image = isRecording
            ? NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Shotate is recording")
            : Self.menuBarIcon
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
        if isRecording {
            let stop = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            stop.target = self
            stop.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            stop.toolTip = "Or press any record shortcut again"
            menu.addItem(stop)
            menu.addItem(.separator())
        }
        if let offer = updater.available {
            let update = NSMenuItem(title: Updater.menuTitle(offer), action: #selector(installUpdate), keyEquivalent: "")
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
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
        // While recording, Stop Recording at the top replaces the record items.
        let record = canRecord && !isRecording
            ? [.separator(), item("Record Area", #selector(recordArea), shortcut: "recordArea"),
               item("Record Full Screen", #selector(recordScreen), shortcut: "recordScreen"),
               item("Record App and Its Log…", #selector(recordApp), shortcut: "recordApp")]
            : [NSMenuItem]()
        for i in [item("Capture Area", #selector(captureArea), shortcut: "captureArea"),
                  item("Capture Window", #selector(captureWindow), shortcut: "captureWindow"),
                  item("Capture Full Screen", #selector(captureScreen), shortcut: "captureScreen")]
                  + record + [
                  .separator(),
                  NSMenuItem(title: "Open Image…", action: #selector(openImagePanel), keyEquivalent: ""),
                  NSMenuItem(title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: ""),
                  .separator(),
                  choosePasteItem(),
                  NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","),
                  NSMenuItem(title: "Edit Config File…", action: #selector(openConfig), keyEquivalent: ""),
                  NSMenuItem(title: "About Shotate", action: #selector(showAbout), keyEquivalent: ""),
                  NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""),
                  NSMenuItem(title: "Quit Shotate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")] {
            if i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
            menu.addItem(i)
        }
    }

    /// A checkmark to turn "⌘V asks which screenshot" on and off without opening Settings.
    private func choosePasteItem() -> NSMenuItem {
        let i = NSMenuItem(title: "Ask Which Screenshot to Paste", action: #selector(toggleChoosePaste), keyEquivalent: "")
        i.state = settings.choosePaste ? .on : .off
        i.toolTip = "When you take screenshots within 3 seconds of each other, ⌘V lets you choose which one to paste."
        return i
    }

    @objc private func toggleChoosePaste() { setChoosePaste(!settings.choosePaste) }

    @objc func captureArea() { capture(.area) }
    @objc func captureWindow() { capture(.window) }
    @objc func captureScreen() { capture(.screen) }
    @objc func recordArea() { toggleRecording(.area) }
    @objc func recordScreen() { toggleRecording(.screen) }
    @objc func recordApp() { toggleRecording(.app) }
    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.saveFolder)
    }

    @objc func showAbout() { Credits.showAbout() }

    // MARK: Updates

    /// Checks now and says what it found, with the choice to install.
    @objc func checkForUpdates() {
        updater.check(manual: true) { [weak self] _ in self?.showUpdateResult() }
    }

    @objc func installUpdate() {
        guard let offer = updater.available else { return checkForUpdates() }
        confirmInstall(offer)
    }

    func showUpdateResult() {
        NSApp.activate(ignoringOtherApps: true)
        switch updater.state {
        case let .available(offer):
            confirmInstall(offer)
        case let .failed(why):
            Alerts.show("Shotate couldn't update", why)
        case .installing:
            Alerts.show("Shotate is updating", "The update is building and Shotate restarts by itself when it's done.")
        case .idle, .checking:
            break
        case .upToDate:
            let a = NSAlert()
            a.messageText = "Shotate is up to date"
            a.informativeText = "You have Shotate \(updater.build.version) on the \(updater.channel) channel. "
                + "Change channels in Settings."
            a.runModal()
        }
    }

    private func confirmInstall(_ offer: Updates.Offer) {
        let m = offer.manifest
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        switch offer {
        case .update:
            a.messageText = "\(Updater.name(of: m)) is available"
            a.informativeText = "You have \(updater.build.version). Shotate builds the update on this Mac, "
                + "which takes a minute or two, then restarts. Your settings and permission stay as they are."
        case .switchToStable:
            a.messageText = "Switch to \(Updater.name(of: m))?"
            a.informativeText = "You're on a nightly build. This installs the newest stable release, "
                + "which may be a little older. Your settings and permission stay as they are."
        }
        a.addButton(withTitle: "Install Update")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "What's New")
        switch a.runModal() {
        case .alertFirstButtonReturn: updater.install(offer)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(m.notes)
        default: break
        }
    }

    @objc func showWelcome() {
        if welcomeWindow == nil { welcomeWindow = WelcomeWindowController(app: self) }
        welcomeWindow?.present()
    }

    @objc func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.present()
    }

    // MARK: Launch at login

    /// Open at login was registered for Snapmark.app. Registering again once points it at Shotate.app;
    /// macOS keeps the old path otherwise, and the item stops working once that app is gone.
    private func moveLoginItem() {
        let key = "loginItemMovedToShotate"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard launchAtLogin else { return UserDefaults.standard.set(true, forKey: key) }
        do {
            try? SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("Shotate: moving the login item: %@", error.localizedDescription)
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Shotate: launch at login: %@", error.localizedDescription)
            }
        }
    }
}
