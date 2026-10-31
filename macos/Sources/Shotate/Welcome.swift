import AppKit
import CoreGraphics
import ShotateCore

/// Screen Recording permission. A running app may not see a change until it relaunches.
///
/// macOS stores a grant together with the code signature of the build that asked. If that signature
/// changes (older builds, as Snapmark, were signed ad hoc, so every build had a new one), the switch in
/// System Settings can show "on" while macOS still refuses this build, and flipping it doesn't help.
/// `request()` therefore clears Shotate's own entry before asking, so macOS records this build.
enum ScreenRecording {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    static let askedKey = "askedScreenRecording"
    static var hasAsked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    /// Shows the system prompt, which also adds Shotate to the list in System Settings.
    ///
    /// The stale-entry reset runs at most once per installed build. A second click must never wipe a
    /// grant the user just made in System Settings, which this process can't see until it relaunches.
    static func request(completion: @escaping () -> Void = {}) {
        let build = buildStamp
        let needsReset = hasAsked && UserDefaults.standard.string(forKey: "resetForBuild") != build
        UserDefaults.standard.set(true, forKey: askedKey)
        DispatchQueue.global(qos: .userInitiated).async {
            if needsReset {
                resetOwnEntry()
                UserDefaults.standard.set(build, forKey: "resetForBuild")
            }
            DispatchQueue.main.async {
                _ = CGRequestScreenCaptureAccess()
                completion()
            }
        }
    }

    /// Identifies this installed build: the executable changes on every build and install.
    private static var buildStamp: String {
        let path = Bundle.main.executablePath ?? ""
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return "\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "")-\(date?.timeIntervalSince1970 ?? 0)"
    }

    /// Removes only Shotate's Screen Recording entry (never another app's), so macOS asks again.
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

    /// Quits and reopens Shotate so it picks up a permission granted in System Settings.
    /// macOS ends an app's helper processes with it, so a helper can't do the reopening. Instead
    /// LaunchServices starts a second copy, which waits for this one to exit (see main.swift) and
    /// then opens the welcome window so the user sees the result.
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        config.arguments = ["--wait-for", String(ProcessInfo.processInfo.processIdentifier), "--welcome"]
        // The new copy reports in only after this one exits, so don't wait for the completion to quit;
        // just give a launch error a moment to arrive.
        var failed = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                failed = true
                Alerts.show("Shotate couldn't relaunch itself", "Quit it from the menu bar and open it again.\n\n"
                            + error.localizedDescription)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if !failed { NSApp.terminate(nil) } }
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

/// First launch and missing permission: one window that gets Shotate ready to use.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private weak var app: AppDelegate?
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let allowButton = NSButton(title: "Allow…", target: nil, action: nil)
    private let relaunchButton = NSButton(title: "Relaunch", target: nil, action: nil)
    private let settingsLink = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let loginBox = NSButton(checkboxWithTitle: "Open Shotate when I log in", target: nil, action: nil)
    private let pasteBox = NSButton(checkboxWithTitle: "Ask which screenshot to paste with ⌘V", target: nil, action: nil)
    private let axLabel = NSTextField(wrappingLabelWithString: "")
    private let axStatusIcon = NSImageView()
    private let axAllowButton = NSButton(title: "Allow…", target: nil, action: nil)
    /// The capture shortcut, changeable right here: click, then press the keys you want.
    private lazy var shortcutRecorder: ShortcutRecorder = {
        let r = ShortcutRecorder(value: app?.settings.shortcuts["captureArea"] ?? "")
        r.onChange = { [weak self] v in
            guard let app = self?.app else { return }
            app.settings.shortcuts["captureArea"] = v
            app.applySettings()
            self?.refresh()
        }
        r.toolTip = "Click, then press the keys you want for capturing an area. The × turns the shortcut off."
        return r
    }()
    private let primary = NSButton(title: "Try a Capture", target: nil, action: nil)
    private var timer: Timer?
    private var openedSettings = false
    /// Wide enough that the permission notes wrap in a few lines and the window fits a laptop screen.
    private static let width: CGFloat = 600

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)  // open on the Space the user is looking at
        window.title = "Welcome to Shotate"
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
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: "Welcome to Shotate")
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
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = 390
        let permissionsTitle = NSTextField(labelWithString: "Permissions")
        permissionsTitle.font = .systemFont(ofSize: 13, weight: .bold)
        let permissionsIntro = NSTextField(wrappingLabelWithString:
            "macOS asks you to approve anything that can see your screen or press keys. Here is exactly "
            + "what Shotate uses each permission for, and what it never does. Change them anytime in "
            + "System Settings › Privacy & Security.")
        permissionsIntro.font = .systemFont(ofSize: 12)
        permissionsIntro.textColor = .secondaryLabelColor
        permissionsIntro.preferredMaxLayoutWidth = 500
        let permission = row(symbol: "rectangle.dashed.badge.record", title: "Screen Recording · Required",
                             detail: statusLabel, trailing: [statusIcon, allowButton, relaunchButton])

        axLabel.maximumNumberOfLines = 0
        axLabel.preferredMaxLayoutWidth = 390
        axStatusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Allowed")
        axStatusIcon.contentTintColor = .systemGreen
        axStatusIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        axAllowButton.target = self
        axAllowButton.action = #selector(allowAccessibility)
        axAllowButton.bezelStyle = .rounded
        let accessibility = row(symbol: "keyboard.badge.ellipsis", title: "Accessibility · Optional",
                                detail: axLabel, trailing: [axStatusIcon, axAllowButton])

        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.maximumNumberOfLines = 0
        shortcutLabel.lineBreakMode = .byWordWrapping
        shortcutLabel.cell?.wraps = true
        shortcutLabel.cell?.usesSingleLineMode = false
        shortcutLabel.preferredMaxLayoutWidth = 290
        let shortcut = row(symbol: "keyboard", title: "Capture from anywhere", detail: shortcutLabel, trailing: [shortcutRecorder])
        let mark = row(symbol: "pencil.tip.crop.circle", title: "Mark it up, press Return",
                       detail: NSTextField(labelWithString: "Return (or Esc) copies it and closes. It is saved too."),
                       trailing: [])

        loginBox.target = self
        loginBox.action = #selector(toggleLogin)
        pasteBox.target = self
        pasteBox.action = #selector(togglePaste)
        pasteBox.toolTip = "Take screenshots within 3 seconds of each other and ⌘V lets you choose which one to paste. "
            + "Off by default; turn it off anytime in the panel, Settings or the menu bar."

        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        primary.target = self
        primary.action = #selector(tryCapture)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        let footer = NSStackView(views: [loginBox, NSView(), done, primary])
        footer.spacing = 10

        // The paste option belongs to Accessibility: indented to line up with its text.
        let pasteRow = NSStackView(views: [pasteBox])
        pasteRow.edgeInsets = NSEdgeInsets(top: 0, left: 40, bottom: 0, right: 0)
        let card = NSStackView(views: [permissionsTitle, permissionsIntro, permission, settingsLink, separator(),
                                       accessibility, pasteRow, separator(), shortcut, separator(), mark])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 14
        card.setCustomSpacing(4, after: permissionsTitle)
        card.setCustomSpacing(8, after: accessibility)
        card.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor

        let privacy = NSTextField(wrappingLabelWithString:
            "Your screenshots never leave your Mac. Shotate has no analytics and no account. On its own it goes "
            + "online only to check for updates, when it starts and once a day. You can turn that off in Settings.")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .secondaryLabelColor
        privacy.alignment = .center
        privacy.preferredMaxLayoutWidth = 480
        let stack = NSStackView(views: [header, card, privacy, footer, Credits.label(centered: true)])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 28, bottom: 20, right: 28)
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
        refresh()
    }

    /// As tall as the text needs once it's filled in, and again whenever it changes length.
    private func fitHeight() {
        guard let window, let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let height = max(480, root.fittingSize.height)
        guard abs(window.contentLayoutRect.height - height) > 1 else { return }
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: height)))
        frame.origin.y += frame.height - newFrame.height  // keep the top edge where it is
        frame.size = newFrame.size
        window.setFrame(frame, display: true)
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
        let row = NSStackView(views: [image, text] + trailing)
        row.spacing = 12
        // The note takes the spare width, so a check mark or button sits at the card's right edge.
        row.distribution = .fill
        text.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        for v in [image] + trailing { v.setContentHuggingPriority(.required, for: .horizontal) }
        // The symbol sits beside the title, not halfway down a long note.
        row.alignment = .top
        return row
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// " ⇧⌘R records an area, ⌃⇧⌘R the whole screen, ⇧⌘D an app and its log; press it again to stop."
    private static func recordHint(_ s: Settings?) -> String {
        let parts = [("recordArea", "records an area"), ("recordScreen", "the whole screen"), ("recordApp", "an app and its log")]
            .compactMap { name, what in s?.shortcut(name).map { "\($0.displayString) \(what)" } }
        return parts.isEmpty ? "" : " " + parts.joined(separator: ", ") + "; press it again to stop."
    }

    private func refresh() {
        let granted = ScreenRecording.isGranted
        statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Allowed")
        statusIcon.contentTintColor = .systemGreen
        statusIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        statusIcon.isHidden = !granted
        // Before asking: Allow. After: Relaunch is the next step, System Settings the fallback.
        allowButton.isHidden = granted || openedSettings
        relaunchButton.isHidden = granted || !openedSettings
        relaunchButton.bezelColor = .controlAccentColor
        settingsLink.isHidden = granted || !openedSettings
        let records = app?.canRecord == true
        let agents = app?.settings.agentControl == true
            ? " Agent control is on: programs you run on this Mac (the shotate command, coding agents) can "
                + "take captures" + (records ? " and start and stop recordings (yours only when asked to)" : "") + " without a click."
                + (records ? " The recording bar still shows." : "")
                + " The switch guards against accidents, not against a harmful program running as you."
            : ""
        let what = (records
            ? "Lets Shotate see your screen only at the moment you take a capture, or while a recording you "
                + "started is running. It doesn't watch in the background, and captures and recordings stay on your "
                + "Mac. Recording an app (⇧⌘D) also saves what that app writes meanwhile to the system log and to "
                + "its own log files, and any crash report it leaves; Shotate reads no other logs. While any "
                + "recording runs, Shotate notes where you click (time and position, never keys) beside the video."
            : "Lets Shotate see your screen only at the moment you take a capture. It doesn't record video or "
                + "watch in the background, and captures stay on your Mac.") + agents
        statusLabel.stringValue = granted ? what + "\nAllowed."
            : openedSettings ? what + "\nTurn Shotate on when macOS asks (or in System Settings), then click Relaunch."
            : what + "\nNot allowed yet. Click Allow."
        let s = app?.settings
        if let keys = s?.captureShortcut?.displayString {
            shortcutLabel.stringValue = "Press \(keys) and drag. Space switches to a whole window. Click the shortcut to change it."
                + (records ? Self.recordHint(s) : "")
        } else {
            shortcutLabel.stringValue = "No shortcut set. Record one here, or use the menu bar icon."
        }
        let current = s?.shortcuts["captureArea"] ?? ""
        if shortcutRecorder.value != current { shortcutRecorder.value = current }
        loginBox.state = (app?.launchAtLogin ?? false) ? .on : .off
        let ax = AXIsProcessTrusted()
        let pasteOn = app?.settings.choosePaste == true
        pasteBox.state = pasteOn ? .on : .off
        axStatusIcon.isHidden = !ax
        axAllowButton.isHidden = ax
        let axWhat = "Only for the option below. After you pick a screenshot, Shotate presses ⌘V for you in "
            + "the app you were using, so it pastes into your field. It doesn't read what you type or "
            + "what's in other apps."
        axLabel.stringValue = axWhat + (ax ? "\nAllowed."
            : pasteOn ? "\nNeeded for the option below. Click Allow, then turn Shotate on in System Settings."
            : "\nNot allowed, and not needed unless you turn the option on.")
        statusLabel.preferredMaxLayoutWidth = Self.noteWidth(beside: [allowButton, relaunchButton], check: statusIcon)
        axLabel.preferredMaxLayoutWidth = Self.noteWidth(beside: [axAllowButton], check: axStatusIcon)
        fitHeight()
        primary.isEnabled = granted
    }

    /// A permission note's width: 390 pt beside a check mark, less whatever button shows in its place,
    /// so Allow or Relaunch keeps its room at the card's right edge.
    private static func noteWidth(beside buttons: [NSView], check: NSView) -> CGFloat {
        let freed = check.isHidden ? check.fittingSize.width + 12 : 0
        let taken = buttons.filter { !$0.isHidden }.reduce(0) { $0 + $1.fittingSize.width + 12 }
        return 390 + freed - taken
    }

    @objc private func allow() {
        allowButton.isEnabled = false
        ScreenRecording.request { [weak self] in
            self?.allowButton.isEnabled = true
            self?.openedSettings = true
            self?.refresh()
        }
    }

    @objc private func openSystemSettings() { ScreenRecording.openSettings() }

    @objc private func doneClicked() { close() }

    @objc private func relaunch() { ScreenRecording.relaunch() }

    @objc private func togglePaste() {
        app?.setChoosePaste(pasteBox.state == .on)
        refresh()
    }

    /// Shows macOS's prompt (which also adds Shotate to the list), then the pane to turn it on.
    @objc private func allowAccessibility() {
        // An entry left by an earlier build can show "on" while macOS refuses this one; clear only
        // Shotate's own, so the switch in System Settings means what it says.
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.baney.snapmark"]
        reset.standardOutput = FileHandle.nullDevice
        reset.standardError = FileHandle.nullDevice
        if (try? reset.run()) != nil { reset.waitUntilExit() }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

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
