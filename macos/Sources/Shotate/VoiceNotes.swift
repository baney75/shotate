import AppKit
import AVFoundation
import Combine
import ShotateCore
import SwiftUI

/// One audio file in the voice notes folder.
struct VoiceNote: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var date: Date
    var duration: Double
    var size: Int64
    var meta: VoiceMeta
}

extension VoiceQuality {
    func recorderSettings(channels: Int) -> [String: Any] {
        switch self {
        case .aac:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 192_000 : 256_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue]
        case .alac:
            return [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 24]
        case .wav:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        }
    }
}

/// The voice notes folder: plain audio files, with markers in `.meta/<file>.json`.
@MainActor final class VoiceStore: ObservableObject {
    static let shared = VoiceStore()
    private(set) var dir = Settings.defaultVoiceFolder
    @Published var notes: [VoiceNote] = []
    @Published var selection: URL?
    @Published var message: String?
    /// The library has been looked at, so a folder change should list the new one.
    private var listed = false

    func setFolder(_ url: URL) {
        guard url.standardizedFileURL != dir.standardizedFileURL else { return }
        dir = url
        selection = nil
        if listed { reload() }
    }

    func reload() {
        listed = true
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        notes = urls.filter { VoiceNotes.audioExtensions.contains($0.pathExtension.lowercased()) }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            var meta = loadMeta(u)
            if meta.duration == nil, let d = try? AVAudioPlayer(contentsOf: u).duration, d > 0 {
                meta.duration = d
                saveMeta(meta, for: u)
            }
            return VoiceNote(url: u, date: v?.creationDate ?? .distantPast, duration: meta.duration ?? 0,
                             size: Int64(v?.fileSize ?? 0), meta: meta)
        }.sorted { $0.date > $1.date }
        if let s = selection, !notes.contains(where: { $0.url == s }) { selection = nil }
    }

    func loadMeta(_ u: URL) -> VoiceMeta {
        (try? JSONDecoder().decode(VoiceMeta.self, from: Data(contentsOf: VoiceNotes.sidecarURL(for: u)))) ?? VoiceMeta()
    }

    func saveMeta(_ m: VoiceMeta, for u: URL) {
        let url = VoiceNotes.sidecarURL(for: u)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: url, options: .atomic) }
    }

    func note(_ u: URL?) -> VoiceNote? { notes.first { $0.url == u } }

    func rename(_ r: VoiceNote, to raw: String) {
        let name = VoiceNotes.safeName(raw)
        guard !name.isEmpty, name != r.name else { return }
        let dest = r.url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(r.url.pathExtension)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            message = "A voice note named \u{201C}\(name)\u{201D} already exists."
            return
        }
        if VoicePlayer.shared.url == r.url { VoicePlayer.shared.unload() }
        do {
            try FileManager.default.moveItem(at: r.url, to: dest)
            try? FileManager.default.moveItem(at: VoiceNotes.sidecarURL(for: r.url), to: VoiceNotes.sidecarURL(for: dest))
            let wasSelected = selection == r.url
            reload()
            if wasSelected { selection = dest }
        } catch {
            message = "Couldn't rename: \(error.localizedDescription)"
        }
    }

    func delete(_ r: VoiceNote) {
        if VoicePlayer.shared.url == r.url { VoicePlayer.shared.unload() }
        do {
            try FileManager.default.trashItem(at: r.url, resultingItemURL: nil)
            reload()
        } catch {
            message = "Couldn't move to Trash: \(error.localizedDescription)"
        }
    }

    func reveal(_ r: VoiceNote) { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }

    @discardableResult
    static func copyAudioFile(_ url: URL) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([url as NSURL])
    }
}

/// The microphone: one voice note at a time, with live levels, pause and markers.
@MainActor final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = VoiceRecorder()
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var history: [Float] = Array(repeating: 0, count: 160)
    @Published private(set) var markers: [VoiceMarker] = []
    @Published var error: String?
    /// Kept in Yapshot's config; `onSettingsChange` writes a change made here back to it.
    @Published var quality: VoiceQuality = .aac { didSet { if quality != oldValue, !adopting { onSettingsChange?() } } }
    @Published var stereo = false { didSet { if stereo != oldValue, !adopting { onSettingsChange?() } } }
    var onSettingsChange: (() -> Void)?
    /// Where the next voice note in this quality goes.
    var newFileURL: (VoiceQuality) -> URL = { q in
        var s = Settings()
        s.voiceQuality = q
        return s.newVoiceNoteURL()
    }
    private var adopting = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?
    /// Posted with the file's URL when a voice note is saved.
    static let saved = Notification.Name("YapshotVoiceNoteSaved")
    static let deniedText = "Yapshot can't use the microphone. Allow it in System Settings > Privacy & Security > Microphone."

    var inputName: String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "No microphone found" }

    /// Takes quality and stereo from the config without writing them back.
    func adopt(quality q: VoiceQuality, stereo s: Bool) {
        adopting = true
        if quality != q { quality = q }
        if stereo != s { stereo = s }
        adopting = false
    }

    func toggle() { if isRecording { stop() } else { start() } }

    /// Starts recording, asking for the microphone the first time. `started` says whether it did.
    func start(started: ((Bool) -> Void)? = nil) {
        guard !isRecording else { started?(true); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: started?(begin())
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in
                    let rec = VoiceRecorder.shared
                    if ok { started?(rec.begin()) } else { rec.error = Self.deniedText; started?(false) }
                }
            }
        default:
            error = Self.deniedText
            started?(false)
        }
    }

    private func begin() -> Bool {
        let u = newFileURL(quality)
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            let r = try AVAudioRecorder(url: u, settings: quality.recorderSettings(channels: stereo ? 2 : 1))
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.record() else {
                error = "Recording didn't start. Check that a microphone is connected."
                return false
            }
            recorder = r; url = u; markers = []; elapsed = 0
            isRecording = true; isPaused = false; error = nil
            history = Array(repeating: 0, count: history.count)
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                Task { @MainActor in VoiceRecorder.shared.tick() }
            }
            return true
        } catch {
            self.error = "Recording failed: \(error.localizedDescription)"
            return false
        }
    }

    private func tick() {
        guard let r = recorder, !isPaused else { return }
        r.updateMeters()
        let level = max(0, min(1, (r.averagePower(forChannel: 0) + 55) / 55))
        history.removeFirst()
        history.append(level)
        elapsed = r.currentTime
    }

    func togglePause() {
        guard let r = recorder else { return }
        if isPaused { r.record(); isPaused = false } else { r.pause(); isPaused = true }
    }

    func addMarker() {
        guard isRecording else { return }
        markers.append(VoiceMarker(time: elapsed, label: "Marker \(markers.count + 1)"))
    }

    /// Stops and saves. Returns the new file, or nil when nothing was recording.
    @discardableResult
    func stop() -> URL? {
        guard let r = recorder, let u = url else { return nil }
        r.delegate = nil
        r.stop()
        timer?.invalidate(); timer = nil; recorder = nil; url = nil
        isRecording = false; isPaused = false
        let store = VoiceStore.shared
        var m = store.loadMeta(u)
        m.markers = markers
        m.duration = nil
        store.saveMeta(m, for: u)
        store.reload()
        store.selection = u
        NotificationCenter.default.post(name: Self.saved, object: u)
        return u
    }

    /// System interruption or encode error: clean up so neither the recorder nor the badge sticks.
    private func handleUnexpectedStop(errorMessage: String?) {
        guard let r = recorder else { return }
        let u = url
        r.delegate = nil
        timer?.invalidate(); timer = nil; recorder = nil; url = nil
        isRecording = false; isPaused = false
        if let errorMessage { error = errorMessage }
        if let u, FileManager.default.fileExists(atPath: u.path) {
            VoiceStore.shared.reload()
        }
        QuickVoiceNote.shared.externalRecordingStopped()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            VoiceRecorder.shared.handleUnexpectedStop(errorMessage: flag ? nil : "The microphone recording stopped unexpectedly.")
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            VoiceRecorder.shared.handleUnexpectedStop(errorMessage: message.map { "Recording failed: \($0)" } ?? "Recording failed.")
        }
    }
}

@MainActor final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    @Published private(set) var url: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ u: URL) {
        guard url != u else { return }
        unload()
        guard let p = try? AVAudioPlayer(contentsOf: u) else { return }
        p.enableRate = true
        p.delegate = self
        p.prepareToPlay()
        p.rate = rate
        player = p; url = u; duration = p.duration; time = 0
    }

    func unload() {
        player?.stop(); player = nil; url = nil
        isPlaying = false; time = 0; duration = 0
        timer?.invalidate(); timer = nil
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause(); isPlaying = false
            timer?.invalidate(); timer = nil
        } else {
            if p.currentTime >= p.duration - 0.05 { p.currentTime = 0 }
            p.rate = rate
            p.play(); isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                Task { @MainActor in
                    let me = VoicePlayer.shared
                    if let p = me.player { me.time = p.currentTime }
                }
            }
        }
    }

    func seek(_ t: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(duration, t))
        time = p.currentTime
    }

    func skip(_ d: Double) { seek(time + d) }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let me = VoicePlayer.shared
            me.isPlaying = false
            me.timer?.invalidate(); me.timer = nil
            me.time = me.duration
        }
    }
}

/// The voice note shortcut from any app (⇧⌘M): the first press starts recording the microphone,
/// the second stops and puts the audio file on the clipboard. A floating badge that never takes
/// focus shows what is happening, with clickable Stop and Close buttons and Esc dismiss.
@MainActor final class QuickVoiceNote: ObservableObject {
    static let shared = QuickVoiceNote()

    typealias Phase = QuickVoiceController.Phase

    @Published private(set) var phase: Phase = .idle
    /// The configured shortcut as macOS shows it ("⇧⌘M"), or nil when it is off.
    @Published var shortcut: String?
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var localEscMonitor: Any?
    private var globalEscMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []
    private lazy var controller: QuickVoiceController = QuickVoiceController(
        isRecording: { MainActor.assumeIsolated { VoiceRecorder.shared.isRecording } },
        startRecording: { done in
            MainActor.assumeIsolated {
                VoiceRecorder.shared.start { ok in
                    done(ok, VoiceRecorder.shared.error)
                }
            }
        },
        stopRecording: { MainActor.assumeIsolated { VoiceRecorder.shared.stop() } },
        copyAudioFile: { url in MainActor.assumeIsolated { VoiceStore.copyAudioFile(url) } },
        onPhaseChange: { [weak self] next in MainActor.assumeIsolated { self?.apply(phase: next) } },
        scheduleHide: { [weak self] delay, work in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork?.cancel()
                let item = DispatchWorkItem(block: work)
                self.hideWork = item
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
        },
        cancelScheduledHide: { [weak self] in
            MainActor.assumeIsolated {
                self?.hideWork?.cancel()
                self?.hideWork = nil
            }
        }
    )

    private init() {
        VoiceRecorder.shared.$isRecording.removeDuplicates().sink { [weak self] recording in
            guard !recording else { return }
            Task { @MainActor [weak self] in self?.controller.externalRecordingStopped() }
        }.store(in: &subscriptions)
    }

    var isVisible: Bool { phase.isVisible }

    func toggle() { controller.toggle() }

    func finish() { _ = controller.finish() }

    func dismiss() { controller.dismiss() }

    func externalRecordingStopped() { controller.externalRecordingStopped() }

    private func apply(phase next: Phase) {
        phase = next
        if next.isVisible {
            let panel = self.panel ?? makePanel()
            self.panel = panel
            if let host = panel.contentView {
                host.layoutSubtreeIfNeeded()
                panel.setContentSize(host.fittingSize)
            }
            position(panel)
            panel.orderFrontRegardless()
            installEscMonitors()
        } else {
            removeEscMonitors()
            panel?.orderOut(nil)
        }
    }

    private func installEscMonitors() {
        if localEscMonitor == nil {
            localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                return MainActor.assumeIsolated {
                    guard let self, self.phase.isVisible else { return event }
                    self.dismiss()
                    return nil
                }
            }
        }
        if globalEscMonitor == nil {
            globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.phase.isVisible else { return }
                    self.dismiss()
                }
            }
        }
    }

    private func removeEscMonitors() {
        if let m = localEscMonitor { NSEvent.removeMonitor(m); localEscMonitor = nil }
        if let m = globalEscMonitor { NSEvent.removeMonitor(m); globalEscMonitor = nil }
    }

    /// The badge's window, which captures and recordings leave out.
    /// The panel is made on first use and kept, so a screen recording started before the first voice
    /// note can still leave it out.
    var badgeWindowID: CGWindowID? {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        return panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
    }

    private func makePanel() -> NSPanel {
        let p = BadgePanel(contentRect: NSRect(origin: .zero, size: QuickVoiceBadge.size),
                           styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        // Clickable so Stop and Close (×) always work on the first click without activating Yapshot.
        p.ignoresMouseEvents = false
        // Keep the badge out of screenshots and screen recordings.
        p.sharingType = .none
        let host = BadgeHostingView(rootView: QuickVoiceBadge())
        host.frame = p.contentRect(forFrameRect: p.frame)
        p.contentView = host
        return p
    }

    /// Top center of the screen with the pointer, just under the menu bar.
    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: vf.midX - p.frame.width / 2, y: vf.maxY - p.frame.height - 12))
    }
}

/// Never key or main, so the badge can't take keys from the app you are typing in.
private final class BadgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accepts the first click while Yapshot is in the background, so Stop and Close work immediately.
private final class BadgeHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// The voice notes colors are the app's own (Brand): ink surfaces, mark red for anything live.
extension Color {
    static let brandRed = Color(nsColor: Brand.red)
    static let brandInk = Color(nsColor: Brand.ink)
    static let brandInkTop = Color(nsColor: Brand.inkTop)
    static let brandEdge = Color(nsColor: Brand.edge)
}

/// The floating badge for a quick voice note, drawn like the screen recording bar: an ink pill
/// with a hairline edge, a pulsing red light, white text, and clickable Stop and Close buttons.
struct QuickVoiceBadge: View {
    /// The width, and the height of a one-line badge. A failure wraps and the badge grows to fit.
    static let size = CGSize(width: 440, height: 56)
    @ObservedObject var quick = QuickVoiceNote.shared
    @ObservedObject var rec = VoiceRecorder.shared
    /// A fixed state to draw instead of the live one, for `--render-ui`.
    var sample: (phase: QuickVoiceNote.Phase, elapsed: Double, levels: [Float])?
    private var phase: QuickVoiceNote.Phase { sample?.phase ?? quick.phase }
    private var isFailure: Bool { if case .failed = phase { return true } else { return false } }

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(isFailure ? 3 : 1).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if phase == .recording {
                MiniLevels(levels: sample?.levels ?? Array(rec.history.suffix(18))).frame(width: 44, height: 20)
                Button { quick.finish() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                        Text("Stop").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(Color.brandRed))
                }
                .buttonStyle(.plain)
                .help("Stop recording and copy the audio file")
            }
            Button { quick.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .help("Close (Esc)")
        }
        .padding(.leading, 18).padding(.trailing, 14).padding(.vertical, 10)
        .frame(width: Self.size.width).frame(minHeight: Self.size.height)
        // Half the one-line height: a pill like the recording bar, still round when a failure wraps.
        .background(RoundedRectangle(cornerRadius: Self.size.height / 2, style: .continuous).fill(Color.brandInk.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: Self.size.height / 2, style: .continuous).strokeBorder(Color.brandEdge, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .recording:
            LiveDot()
        case .starting:
            ProgressView().controlSize(.small).tint(.white)
        case .copied:
            Image(systemName: "doc.on.clipboard.fill").font(.system(size: 16)).foregroundStyle(.white)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).foregroundStyle(Color.brandRed)
        case .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch phase {
        case .recording: return "Recording  \(VoiceNotes.clock(sample?.elapsed ?? rec.elapsed))"
        case .copied: return "Audio copied to clipboard"
        case .failed: return "Couldn't record voice note"
        case .idle, .starting: return ""
        }
    }

    private var detail: String {
        switch phase {
        case .recording:
            return quick.shortcut.map { "Press \($0) or click Stop to copy audio" }
                ?? "Click Stop or press Esc to close"
        case .copied(let name): return name
        case .failed(let why): return why
        case .idle, .starting: return ""
        }
    }
}

/// The recording bar's live light: a red dot with a ring that grows out of it and fades. Still when
/// Reduce Motion is on.
struct LiveDot: View {
    @State private var pulse = false
    var body: some View {
        Circle().fill(Color.brandRed).frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.brandRed.opacity(0.7), lineWidth: 2)
                .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            .onAppear {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityLabel("Recording")
    }
}

struct MiniLevels: View {
    var levels: [Float]
    var body: some View {
        Canvas { ctx, size in
            let bw = size.width / CGFloat(max(levels.count, 1))
            for (i, l) in levels.enumerated() {
                let h = max(2, CGFloat(l) * size.height)
                let r = CGRect(x: CGFloat(i) * bw + bw * 0.2, y: (size.height - h) / 2, width: bw * 0.6, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: bw * 0.3), with: .color(.brandRed))
            }
        }
    }
}
