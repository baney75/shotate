import AppKit
import ShotateCore

/// Click, then press a key combination: the standard macOS way to set a shortcut. Delete clears it,
/// Esc cancels. The value is Shotate's text form ("cmd+shift+s"), so it round-trips through the
/// config file unchanged.
final class ShortcutRecorder: NSView {
    var value: String { didSet { update() } }
    /// Called with the new value ("" when cleared).
    var onChange: ((String) -> Void)?
    /// Global shortcuts must pause while recording, or pressing the current one would fire it.
    static var onRecordingChange: ((Bool) -> Void)?

    private let button = NSButton(title: "", target: nil, action: nil)
    private let clear = NSButton()
    private var monitors: [Any] = []
    private var recording = false { didSet { update(); Self.onRecordingChange?(recording) } }

    private static let keyNames: [Int: String] = Dictionary(Hotkeys.keyCodes.map { ($0.value, $0.key) },
                                                             uniquingKeysWith: { a, _ in a })

    init(value: String, placeholder: String = "Record Shortcut") {
        self.value = value
        self.placeholder = placeholder
        super.init(frame: .zero)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(toggle)
        button.setAccessibilityLabel("Shortcut")
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")
        clear.isBordered = false
        clear.contentTintColor = .tertiaryLabelColor
        clear.target = self
        clear.action = #selector(clearValue)
        clear.toolTip = "Turn this shortcut off"
        let stack = NSStackView(views: [button, clear])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.widthAnchor.constraint(equalToConstant: 150),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    private let placeholder: String

    private func update() {
        if recording {
            button.title = "Type shortcut…"
            button.bezelColor = .controlAccentColor
        } else {
            button.title = Shortcut(value)?.displayString ?? placeholder
            button.bezelColor = nil
        }
        clear.isHidden = recording || value.isEmpty
        button.toolTip = recording ? "Press the keys. Esc cancels, Delete turns it off."
            : "Click to record a new shortcut"
    }

    @objc private func toggle() { recording ? stop() : start() }

    @objc private func clearValue() {
        value = ""
        onChange?("")
    }

    private func start() {
        recording = true
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handle(e)
            return nil
        } as Any)
        // A click anywhere else ends recording without a change.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self else { return e }
            if e.window !== self.window || !self.button.frame.contains(self.button.superview!.convert(e.locationInWindow, from: nil)) {
                self.stop()
            }
            return e
        } as Any)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        if recording { recording = false }
    }

    @objc private func windowResigned() { stop() }

    private func handle(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, e.keyCode == 53 { stop(); return }                         // Esc
        if flags.isEmpty, e.keyCode == 51 || e.keyCode == 117 { stop(); clearValue(); return }  // Delete
        guard let key = Self.keyNames[Int(e.keyCode)] else { NSSound.beep(); return }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        let text = (parts + [key]).joined(separator: "+")
        // A shortcut needs a modifier, or it would swallow normal typing everywhere.
        guard Shortcut(text) != nil else { NSSound.beep(); return }
        stop()
        value = text
        onChange?(text)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
}
