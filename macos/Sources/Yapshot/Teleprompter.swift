import AppKit
import Combine
import YapshotCore
import SwiftUI

/// A script on screen to read aloud while recording a voice note. It floats over every app and
/// never becomes key, so the app you were typing in keeps the keyboard. The text scrolls on its own
/// while a voice note records (and stops when it pauses or ends); the scroll wheel moves it by hand
/// at any time. A voice note started while it is open notes the script's name in its sidecar.
@MainActor final class Teleprompter: ObservableObject {
    static let shared = Teleprompter()
    static let speeds = 10.0...160.0
    static let sizes = 20.0...72.0

    @Published private(set) var name = ""
    @Published private(set) var text = ""
    /// Points per second.
    @Published var speed = 40.0
    @Published var fontSize = 36.0 { didSet { textView?.applyStyle(size: fontSize) } }
    /// The scroll is held by the user while the voice note keeps recording.
    @Published var held = false { didSet { updateTimer() } }
    @Published var status: String?
    private(set) var url: URL?
    fileprivate weak var scrollView: NSScrollView?
    fileprivate weak var textView: PrompterTextView?
    private var panel: NSPanel?
    private var timer: Timer?
    /// The voice note recording now began while a script was open.
    private var fromScript = false
    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        let rec = VoiceRecorder.shared
        rec.$isRecording.removeDuplicates().sink { [weak self] on in
            Task { @MainActor in self?.recordingChanged(on) }
        }.store(in: &subscriptions)
        rec.$isPaused.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.updateTimer() }
        }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(forName: VoiceRecorder.saved, object: nil, queue: .main) { n in
            guard let u = n.object as? URL else { return }
            MainActor.assumeIsolated { Teleprompter.shared.saved(u) }
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Opens a script file, from the top.
    func show(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSSound.beep()
            return
        }
        self.url = url
        load(name: url.deletingPathExtension().lastPathComponent, text: text)
        let panel = self.panel ?? makePanel()
        if self.panel == nil { panel.center() }
        self.panel = panel
        panel.orderFrontRegardless()
        updateTimer()
    }

    /// Sets the text without a file (also used by `--render-ui`).
    func load(name: String, text: String) {
        self.name = name
        self.text = text
        status = nil
        held = false
        textView?.setScript(text, size: fontSize)
        scrollToTop()
    }

    func close() {
        panel?.orderOut(nil)
        timer?.invalidate(); timer = nil
    }

    /// Record starts a voice note from the top of the script; Stop saves and transcribes it.
    func toggleRecord() {
        let rec = VoiceRecorder.shared
        if QuickVoiceNote.shared.phase == .recording {
            // A note started with the shortcut finishes the same way: transcribe, copy, close its badge.
            QuickVoiceNote.shared.finish()
        } else if rec.isRecording {
            rec.stop()
        } else {
            scrollToTop()
            held = false
            rec.start { ok in
                if !ok { Teleprompter.shared.status = VoiceRecorder.shared.error ?? "Recording didn't start." }
            }
        }
    }

    /// For `--render-ui`: a recording part way down the script.
    func scrollForSample(to y: CGFloat) {
        guard let sv = scrollView else { return }
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    func scrollToTop() {
        guard let sv = scrollView else { return }
        sv.contentView.scroll(to: .zero)
        sv.reflectScrolledClipView(sv.contentView)
    }

    private func recordingChanged(_ on: Bool) {
        if on, isVisible, !text.isEmpty {
            fromScript = true
            status = nil
        }
        updateTimer()
    }

    /// A voice note recorded from the script: note the script and transcribe it as usual.
    private func saved(_ u: URL) {
        guard fromScript else { return }
        fromScript = false
        let store = VoiceStore.shared
        var m = store.loadMeta(u)
        m.script = name
        store.saveMeta(m, for: u)
        status = "Saved \(u.deletingPathExtension().lastPathComponent). Transcribing\u{2026}"
        store.transcribe(u) { text, failure in
            let me = Teleprompter.shared
            me.status = text != nil ? "Saved and transcribed." : (failure ?? "Couldn't transcribe.")
            VoiceStore.shared.reload()
        }
    }

    private func updateTimer() {
        let rec = VoiceRecorder.shared
        let run = rec.isRecording && !rec.isPaused && !held && isVisible
        guard run != (timer != nil) else { return }
        timer?.invalidate(); timer = nil
        guard run else { return objectWillChange.send() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { Teleprompter.shared.step(1.0 / 60) }
        }
        objectWillChange.send()
    }

    private func step(_ dt: Double) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        let y = min(maxY, sv.contentView.bounds.origin.y + speed * dt)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    func makePanel(sampleElapsed: Double? = nil) -> NSPanel {
        let p = PrompterPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.title = "Teleprompter"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        // Never key, so the close light would only ever show gray: the X in the bar closes it.
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = Brand.ink
        p.appearance = NSAppearance(named: .darkAqua)
        p.minSize = NSSize(width: 560, height: 300)
        p.contentView = FirstClickHosting(rootView: TeleprompterView(sampleElapsed: sampleElapsed))
        p.onClose = { Teleprompter.shared.close() }
        return p
    }
}

/// Never key or main: clicks work, keys stay with the app in front.
private final class PrompterPanel: NSPanel {
    var onClose: () -> Void = {}
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func close() { onClose(); orderOut(nil) }
}

/// Yapshot is never the active app, so the first click has to work.
private final class FirstClickHosting<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The script itself: a read-only text view in a scroll view, so the wheel and trackpad scroll it.
final class PrompterTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    func setScript(_ text: String, size: Double) {
        textStorage?.setAttributedString(NSAttributedString(string: text))
        applyStyle(size: size)
    }

    func applyStyle(size: Double) {
        guard let storage = textStorage else { return }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = size * 0.35
        para.paragraphSpacing = size * 0.25
        storage.setAttributes([.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white,
                               .paragraphStyle: para], range: NSRange(location: 0, length: storage.length))
    }
}

/// Keeps the text exactly as wide as what shows, so lines wrap instead of running off the edge.
private final class PrompterScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let doc = documentView, doc.frame.width != contentSize.width else { return }
        doc.setFrameSize(NSSize(width: contentSize.width, height: doc.frame.height))
    }
}

private struct PrompterText: NSViewRepresentable {
    let text: String
    let size: Double

    func makeNSView(context: Context) -> NSScrollView {
        let sv = PrompterScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.scrollerStyle = .overlay
        sv.autohidesScrollers = true
        let tv = PrompterTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 40, height: 24)
        sv.documentView = tv
        tv.setScript(text, size: size)
        let t = Teleprompter.shared
        t.scrollView = sv
        t.textView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? PrompterTextView, tv.string != text else { return }
        tv.setScript(text, size: size)
    }
}

struct TeleprompterView: View {
    @ObservedObject var t = Teleprompter.shared
    @ObservedObject var rec = VoiceRecorder.shared
    /// A recording to draw instead of the live one, for `--render-ui`.
    var sampleElapsed: Double?
    private var recording: Bool { sampleElapsed != nil || rec.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(t.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer()
                if let s = t.status {
                    Text(s).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
                }
            }
            // In the title bar, where it drags the panel.
            .padding(.leading, 16).padding(.trailing, 16).frame(height: 28)
            ZStack(alignment: .topLeading) {
                PrompterText(text: t.text, size: t.fontSize)
                // The reading line: a red mark where the eye should be.
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 14)).foregroundStyle(Color.brandRed)
                    .padding(.leading, 14).padding(.top, 24 + t.fontSize * 0.35)
                    .allowsHitTesting(false)
            }
            Divider().overlay(Color.brandEdge)
            controls.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color.brandInk)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .tint(.brandRed)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { t.toggleRecord() } label: {
                HStack(spacing: 7) {
                    if recording { LiveDot() } else { Circle().fill(Color.brandRed).frame(width: 10, height: 10) }
                    Text(recording ? "Stop" : "Record").font(.system(size: 13, weight: .semibold))
                    if recording {
                        Text(VoiceNotes.clock(sampleElapsed ?? rec.elapsed)).font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(recording ? Color.brandRed.opacity(0.25) : Color.white.opacity(0.1)))
                .overlay(Capsule().strokeBorder(recording ? Color.brandRed : Color.brandEdge, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(recording ? "Stop and save the voice note" : "Record a voice note; the script scrolls while you read")

            Button { t.held.toggle() } label: {
                Image(systemName: t.held ? "play.fill" : "pause.fill").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless).foregroundStyle(.white).disabled(!recording)
            .help(t.held ? "Resume scrolling" : "Hold the scroll (the recording keeps going). The scroll wheel moves it by hand.")

            HStack(spacing: 6) {
                Image(systemName: "tortoise.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                Slider(value: $t.speed, in: Teleprompter.speeds).frame(width: 120).help("Scroll speed")
                Image(systemName: "hare.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Button { t.fontSize = max(Teleprompter.sizes.lowerBound, t.fontSize - 4) } label: {
                    Image(systemName: "textformat.size.smaller").frame(width: 26, height: 22)
                }
                .help("Smaller text")
                Button { t.fontSize = min(Teleprompter.sizes.upperBound, t.fontSize + 4) } label: {
                    Image(systemName: "textformat.size.larger").frame(width: 26, height: 22)
                }
                .help("Larger text")
            }
            .buttonStyle(.borderless).foregroundStyle(.white)
            Button { t.close() } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                .buttonStyle(.borderless).foregroundStyle(.white.opacity(0.8)).help("Close the teleprompter")
        }
    }
}
