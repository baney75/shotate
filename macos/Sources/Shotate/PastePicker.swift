import AppKit
import Carbon.HIToolbox
import ImageIO
import ShotateCore
import SwiftUI

/// With "Choose which screenshot to paste" on, ⌘V asks which one when several were copied lately:
/// a panel in the middle of the screen shows them newest first, numbered 1–9. Shotate claims ⌘V
/// only while the clipboard still holds its own screenshot, so anything copied since pastes as usual.
final class PastePicker {
    private let hotkeys: Hotkeys
    private let enabled: () -> Bool
    private var choices = PasteChoices()
    /// Pixel size and a thumbnail per screenshot, made once when it's copied. The image itself is
    /// read from its file only when chosen.
    private var sizes: [URL: CGSize] = [:]
    private var thumbnails: [URL: NSImage] = [:]
    /// The pasteboard's change count right after Shotate last wrote it.
    private var ourChangeCount = -1
    /// ⌘V stays unclaimed until then: while the chosen screenshot is being pasted, or, without
    /// Accessibility, so the next ⌘V pastes it.
    private var holdOffUntil = Date.distantPast
    /// The copy the picker makes itself, which shouldn't reorder the list.
    private var choosing = false
    private var timer: Timer?
    private var chooser: PasteChooser?
    /// The app ⌘V was pressed in, which gets the paste whatever is in front by then.
    private var target: NSRunningApplication?
    /// Turns the option off (or on) from the chooser's switch.
    var setEnabled: (Bool) -> Void = { _ in }

    init(hotkeys: Hotkeys, enabled: @escaping () -> Bool) {
        self.hotkeys = hotkeys
        self.enabled = enabled
        hotkeys.onPaste = { [weak self] in self?.ask() }
        Output.onCopied = { [weak self] file, png, count in self?.copied(file, png: png, changeCount: count) }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Switching apps changes who ⌘V belongs to; don't wait for the timer.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.update() }
        }
    }

    private func copied(_ file: URL, png: Data, changeCount: Int) {
        ourChangeCount = changeCount
        // Kept whether or not the option is on (a name, a size and a thumbnail each), so turning
        // it on works for screenshots already taken.
        guard !choosing else { return update() }
        choices.copied(file)
        let source = CGImageSourceCreateWithData(png as CFData, nil)
        if let source, let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            sizes[file] = CGSize(width: w, height: h)
        }
        // Decoding a big screenshot takes a moment; the thumbnail is made off the main thread.
        if let source {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let t = Self.thumbnail(source)
                DispatchQueue.main.async { if self?.sizes[file] != nil { self?.thumbnails[file] = t } }
            }
        }
        update()
    }

    /// Claims ⌘V exactly while a paste should ask.
    func update() {
        // Off: release ⌘V and do nothing else; the list is pruned when it's next used.
        guard enabled() else {
            if hotkeys.pasteClaimed { hotkeys.claimPaste(false) }
            return
        }
        choices.prune()
        let kept = Set(choices.entries.map(\.file))
        sizes = sizes.filter { kept.contains($0.key) }
        thumbnails = thumbnails.filter { kept.contains($0.key) }
        let ours = NSPasteboard.general.changeCount == ourChangeCount
        // In Shotate's own windows ⌘V is theirs; while the chooser is up, ⌘V pastes its choice.
        // Without Accessibility a pick could only copy, and a claimed ⌘V can't be passed on, so
        // ⌘V stays the app's own until Shotate is allowed (setup and the menu say so).
        let ask = choices.shouldAsk(enabled: true, clipboardIsOurs: ours) && Date() >= holdOffUntil && AXIsProcessTrusted()
            && (!NSApp.isActive || chooser != nil)
        if ask != hotkeys.pasteClaimed { hotkeys.claimPaste(ask) }
    }

    private func ask() {
        // ⌘V again while choosing pastes the highlighted one.
        if let chooser { return chooser.chooseSelected() }
        update()
        guard hotkeys.pasteClaimed else {
            // Something changed since ⌘V was claimed (text copied, another app in front): this ⌘V
            // was meant for the app in front, so pass it on.
            if AXIsProcessTrusted() { Self.pressCommandV() }
            return
        }
        let now = Date()
        let items = choices.entries.enumerated().map { i, e in
            PasteChooser.Item(id: e.file, number: i + 1, image: thumbnails[e.file], age: Self.age(e.copiedAt, now: now),
                              size: sizes[e.file].map { "\(Int($0.width)) × \(Int($0.height))" } ?? "", pasted: e.pasted)
        }
        target = NSWorkspace.shared.frontmostApplication
        // Without Accessibility the panel says so and offers Allow; a system prompt here would take
        // focus and close the panel the moment it opened.
        let c = PasteChooser(items: items, typesPaste: AXIsProcessTrusted())
        c.onToggle = { [weak self] on in self?.setEnabled(on) }
        c.onChoose = { [weak self] file in self?.chooser = nil; self?.paste(file) }
        c.onCancel = { [weak self] in self?.chooser = nil; self?.update() }
        chooser = c
        c.show()
    }

    private func paste(_ file: URL) {
        // A capture is a PNG; an opened JPEG or HEIC that was copied is converted, never mislabeled.
        guard let data = try? Data(contentsOf: file), let png = Self.asPNG(data) else { return NSSound.beep() }
        choosing = true
        Output.copy(png: png, fileURL: file)
        choosing = false
        choices.markPasted(file)
        hotkeys.claimPaste(false)
        guard AXIsProcessTrusted() else {
            // Without permission to type ⌘V, the next ⌘V is the user's own and pastes this one.
            holdOffUntil = Date().addingTimeInterval(10)
            return
        }
        holdOffUntil = Date().addingTimeInterval(0.6)
        // The chooser has closed; the field you were typing in gets its keys back, then the paste.
        let app = target
        target = nil
        if let app, !app.isActive { app.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Self.pressCommandV(to: app) }
    }

    /// ⌘V into `app` (its focused field), or into whatever is in front.
    private static func pressCommandV(to app: NSRunningApplication? = nil) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(Hotkeys.keyCode(typing: "v")), keyDown: down)
            e?.flags = .maskCommand
            if let app, app.processIdentifier > 0 { e?.postToPid(app.processIdentifier) } else { e?.post(tap: .cghidEventTap) }
        }
    }

    private static func asPNG(_ data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// "Just now", "4 min ago".
    private static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? "Just now" : "\(minutes) min ago"
    }

    /// The screenshot shrunk to at most 480 pixels on its long side, sharp in a 200-point card.
    private static func thumbnail(_ source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 480,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }
}

/// The panel that asks which screenshot to paste. It takes the keyboard without activating
/// Shotate, so the app being pasted into stays in front and gets the paste.
final class PasteChooser {
    struct Item: Identifiable {
        let id: URL
        let number: Int
        let image: NSImage?
        let age: String
        let size: String
        let pasted: Bool
    }

    final class Model: ObservableObject {
        let items: [Item]
        let typesPaste: Bool
        /// Cards per row: five, or fewer on a narrow screen.
        let columns: Int
        @Published var selected = 0
        /// The switch in the panel: on means ⌘V keeps asking.
        @Published var asking = true { didSet { toggle(asking) } }
        var choose: (Int) -> Void = { _ in }
        var toggle: (Bool) -> Void = { _ in }
        /// Where the pointer was when the panel opened. It usually opens under the pointer, so
        /// hover selects only once the mouse has really moved; a twitch never changes what pastes.
        private let mouseAtOpen = NSEvent.mouseLocation
        init(items: [Item], typesPaste: Bool, columns: Int) {
            self.items = items
            self.typesPaste = typesPaste
            self.columns = columns
        }
        func hovered(_ i: Int) {
            let m = NSEvent.mouseLocation
            if hypot(m.x - mouseAtOpen.x, m.y - mouseAtOpen.y) > 6 { selected = i }
        }
    }

    var onChoose: (URL) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onToggle: (Bool) -> Void = { _ in }
    private let model: Model
    private let panel: ChooserPanel
    /// For `--render-ui`, which captures the panel without showing it the usual way.
    var window: NSWindow { panel }
    private var resignObserver: NSObjectProtocol?
    private var done = false

    init(items: [Item], typesPaste: Bool) {
        let mouse = NSEvent.mouseLocation
        let width = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame.width ?? 1440
        // A card is 192 points plus 12 between; the panel adds 36 and keeps 40 clear of the edges.
        let fit = max(1, Int((width - 76 + 12) / 204))
        model = Model(items: items, typesPaste: typesPaste, columns: min(items.count, 5, fit))
        panel = ChooserPanel()
        model.choose = { [weak self] i in self?.choose(i) }
        model.toggle = { [weak self] on in self?.onToggle(on) }
        panel.onKey = { [weak self] e in self?.key(e) ?? false }
        let host = FirstClickHostingView(rootView: ChooserView(model: model))
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let size = panel.frame.size
            // Centered, a little above the middle, like ⌘Tab.
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.08))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        // A click in another window closes it, like a menu.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in self?.cancel() }
    }

    func chooseSelected() { choose(model.selected) }

    private func choose(_ i: Int) {
        guard model.items.indices.contains(i), close() else { return }
        onChoose(model.items[i].id)
    }

    private func cancel() {
        guard close() else { return }
        onCancel()
    }

    /// Hides the panel once; false if it was already closed.
    private func close() -> Bool {
        guard !done else { return false }
        done = true
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        panel.orderOut(nil)
        return true
    }

    /// ← → (and Tab) move, 1–9 pick, Return pastes, Esc cancels.
    private func key(_ e: NSEvent) -> Bool {
        let n = model.items.count
        // ⌘V pastes the highlighted one, also after the switch below released Shotate's claim on it.
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "v" {
            chooseSelected()
            return true
        }
        switch Int(e.keyCode) {
        case kVK_LeftArrow: model.selected = (model.selected + n - 1) % n
        case kVK_RightArrow: model.selected = (model.selected + 1) % n
        case kVK_UpArrow: model.selected = max(model.selected - model.columns, 0)
        case kVK_DownArrow: model.selected = min(model.selected + model.columns, n - 1)
        case kVK_Tab: model.selected = (model.selected + (e.modifierFlags.contains(.shift) ? n - 1 : 1)) % n
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: chooseSelected()
        case kVK_Escape: cancel()
        default:
            guard let c = e.charactersIgnoringModifiers, let d = Int(c), (1...n).contains(d) else { return false }
            choose(d - 1)
        }
        return true
    }
}

/// A click on a card picks it at once. Shotate isn't the active app, and without this the first
/// click would only bring the panel forward.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless and nonactivating, but able to take keys, as the capture overlay does.
private final class ChooserPanel: NSPanel {
    var onKey: (NSEvent) -> Bool = { _ in false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, onKey(e) { return }
        super.sendEvent(e)
    }

    /// Shotate's menu shortcuts (⌘Q, ⌘,) would reach the app ahead of `sendEvent`; while choosing,
    /// the panel's keys are the only ones that act.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        _ = onKey(e)
        return true
    }
}

private struct ChooserView: View {
    @ObservedObject var model: PasteChooser.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Paste a Screenshot").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 24)
                Text(model.typesPaste ? "← → to choose   Return to paste   Esc to cancel"
                                      : "Return copies it, then press ⌘V   Esc to cancel")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !model.typesPaste {
                // Without Accessibility a pick can only copy. Say so plainly, with the fix one click away.
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("Shotate needs Accessibility to paste into the field for you.")
                        .font(.system(size: 12))
                    Spacer(minLength: 12)
                    Button("Allow Pasting…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.yellow.opacity(0.12)))
            }
            // Five to a row, so nine still fit a laptop screen.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(192), spacing: 12), count: model.columns),
                      alignment: .leading, spacing: 12) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                    Card(item: item, selected: i == model.selected)
                        .onHover { if $0 { model.hovered(i) } }
                        .onTapGesture { model.choose(i) }
                        .accessibilityAction { model.choose(i) }
                        .accessibilityAddTraits(i == model.selected ? .isSelected : [])
                }
            }
            Divider().opacity(0.5)
            // The easy way out: turn it off here, and ⌘V goes back to pasting the latest.
            HStack(spacing: 8) {
                Toggle(isOn: $model.asking) {
                    Text("Ask which screenshot to paste").font(.system(size: 12))
                }
                .toggleStyle(AccentSwitch())
                Spacer(minLength: 12)
                Text(model.asking ? "Only for screenshots taken within 3 seconds of each other"
                                  : "Off. ⌘V pastes the latest. Turn it back on in Settings or the menu bar.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .fixedSize()
    }

    private struct Card: View {
        let item: PasteChooser.Item
        let selected: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.18))
                    if let image = item.image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(6)
                    }
                }
                .frame(width: 176, height: 112)
                .overlay(alignment: .topLeading) {
                    Text("\(item.number)")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(selected ? Color.accentColor : Color(nsColor: .windowBackgroundColor).opacity(0.9)))
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if item.pasted {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, Color.green)
                            .padding(6).help("Pasted already")
                    }
                }
                HStack(spacing: 6) {
                    Text(item.age).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 4)
                    Text(item.size).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
            .padding(8)
            .frame(width: 192)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Screenshot \(item.number), \(item.age), \(item.size)\(item.pasted ? ", pasted" : "")")
            .accessibilityAddTraits(.isButton)
        }
    }

    /// A switch that reads as on even though Shotate isn't the active app (the system one turns
    /// gray then): the accent color when on, gray when off.
    private struct AccentSwitch: ToggleStyle {
        func makeBody(configuration c: Configuration) -> some View {
            HStack(spacing: 8) {
                c.label
                ZStack(alignment: c.isOn ? .trailing : .leading) {
                    Capsule().fill(c.isOn ? Color.accentColor : Color.secondary.opacity(0.35))
                    Circle().fill(Color.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(2)
                }
                .frame(width: 32, height: 18)
                .animation(.easeOut(duration: 0.15), value: c.isOn)
            }
            .contentShape(Rectangle())
            .onTapGesture { c.isOn.toggle() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(c.isOn ? "On" : "Off")
            .accessibilityAction { c.isOn.toggle() }
        }
    }

    private struct VisualEffect: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            return v
        }
        func updateNSView(_ v: NSVisualEffectView, context: Context) {}
    }
}
