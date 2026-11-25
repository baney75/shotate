import AppKit
import AVFoundation
import Combine
import Speech
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

/// The voice notes folder: plain audio files, with markers and transcripts in `.meta/<file>.json`.
@MainActor final class VoiceStore: ObservableObject {
    static let shared = VoiceStore()
    private(set) var dir = Settings.defaultVoiceFolder
    @Published var notes: [VoiceNote] = []
    @Published var selection: URL?
    @Published var transcribing: Set<URL> = []
    @Published var message: String?
    /// The library has been looked at, so a folder change should list the new one.
    private var listed = false
    private var speechTasks: [URL: SFSpeechRecognitionTask] = [:]
    private var recognizers: [URL: SFSpeechRecognizer] = [:]
    /// Callers waiting on a transcript. They get the text, or nil with the reason.
    private var waiters: [URL: [(String?, String?) -> Void]] = [:]

    /// True when transcription runs on this Mac. Otherwise macOS may send the audio to Apple.
    static var transcribesOnDevice: Bool { SFSpeechRecognizer()?.supportsOnDeviceRecognition ?? false }

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

    /// Transcribes with macOS speech recognition: on this Mac when it supports that. With a
    /// completion, errors go to it instead of an alert.
    func transcribe(_ u: URL, completion: ((_ text: String?, _ failure: String?) -> Void)? = nil) {
        if let completion { waiters[u, default: []].append(completion) }
        guard !transcribing.contains(u) else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in VoiceStore.shared.startTranscription(u, status: status) }
        }
    }

    private func startTranscription(_ u: URL, status: SFSpeechRecognizerAuthorizationStatus) {
        guard status == .authorized else {
            fail(u, "Speech recognition is off for Shotate. Turn it on in System Settings > Privacy & Security > Speech Recognition.")
            return
        }
        guard let rec = SFSpeechRecognizer(), rec.isAvailable else {
            fail(u, "Speech recognition isn't available right now.")
            return
        }
        let req = SFSpeechURLRecognitionRequest(url: u)
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        transcribing.insert(u)
        recognizers[u] = rec
        speechTasks[u] = rec.recognitionTask(with: req) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let err = error?.localizedDescription
            Task { @MainActor in VoiceStore.shared.finishTranscription(u, text: text, isFinal: isFinal, error: err) }
        }
        // A stalled speech service must not leave the note "Transcribing" forever: give up after a
        // minute plus twice the note's length, which hands the audio file to whoever is waiting.
        let task = speechTasks[u]
        let length = (try? AVAudioPlayer(contentsOf: u))?.duration ?? 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 60 + 2 * length) {
            MainActor.assumeIsolated {
                let store = VoiceStore.shared
                guard store.transcribing.contains(u), let task, store.speechTasks[u] === task else { return }
                task.cancel()
                store.endTranscription(u)
                store.fail(u, "Transcription took too long.")
            }
        }
    }

    private func finishTranscription(_ u: URL, text: String?, isFinal: Bool, error: String?) {
        guard transcribing.contains(u) else { return }
        if isFinal, let text {
            var m = loadMeta(u)
            m.transcript = text.isEmpty ? "(No speech found.)" : text
            saveMeta(m, for: u)
            endTranscription(u)
            reload()
            for w in waiters.removeValue(forKey: u) ?? [] { w(text, nil) }
        } else if let error {
            endTranscription(u)
            fail(u, "Transcription failed: \(error)")
        }
    }

    private func endTranscription(_ u: URL) {
        transcribing.remove(u)
        speechTasks[u] = nil
        recognizers[u] = nil
    }

    /// Reports a failure to waiting callers, or as an alert when nobody is waiting.
    private func fail(_ u: URL, _ reason: String) {
        let ws = waiters.removeValue(forKey: u) ?? []
        if ws.isEmpty { message = reason }
        for w in ws { w(nil, reason) }
    }
}

/// The microphone: one voice note at a time, with live levels, pause and markers.
@MainActor final class VoiceRecorder: NSObject, ObservableObject {
    static let shared = VoiceRecorder()
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var history: [Float] = Array(repeating: 0, count: 160)
    @Published private(set) var markers: [VoiceMarker] = []
    @Published var error: String?
    /// Kept in Shotate's config; `onSettingsChange` writes a change made here back to it.
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
    static let deniedText = "Shotate can't use the microphone. Allow it in System Settings > Privacy & Security > Microphone."

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
        return u
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

/// The voice note shortcut from any app: the first press starts recording in the background, the
/// second stops, transcribes and puts the text on the clipboard. A floating badge that never takes
/// focus shows what is happening.
@MainActor final class QuickVoiceNote: ObservableObject {
    static let shared = QuickVoiceNote()

    enum Phase: Equatable {
        case idle, starting, recording, transcribing
        case copied(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The configured shortcut as macOS shows it ("⇧⌘R"), or nil when it is off.
    @Published var shortcut: String?
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func toggle() {
        let rec = VoiceRecorder.shared
        if rec.isRecording {
            finish()
        } else if phase != .transcribing, phase != .starting {
            phase = .starting
            // start() may wait on the microphone prompt; the badge shows once recording begins.
            rec.start { ok in
                let me = QuickVoiceNote.shared
                me.show(ok ? .recording : .failed(VoiceRecorder.shared.error ?? "Recording didn't start."))
            }
        }
    }

    func finish() {
        guard let url = VoiceRecorder.shared.stop() else { return }
        show(.transcribing)
        VoiceStore.shared.transcribe(url) { text, failure in
            let pb = NSPasteboard.general
            pb.clearContents()
            if let text, !text.isEmpty {
                pb.setString(text, forType: .string)
                QuickVoiceNote.shared.show(.copied(text))
            } else {
                // No text: put the audio file on the clipboard so the note is still one paste away.
                pb.writeObjects([url as NSURL])
                QuickVoiceNote.shared.show(.failed((failure ?? "No speech found.") + " The audio file is on the clipboard."))
            }
        }
    }

    private func show(_ p: Phase) {
        phase = p
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let host = panel.contentView { panel.setContentSize(host.fittingSize) }
        position(panel)
        panel.orderFrontRegardless()
        switch p {
        case .copied, .failed:
            let work = DispatchWorkItem {
                let me = QuickVoiceNote.shared
                me.panel?.orderOut(nil)
                me.phase = .idle
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        default: break
        }
    }

    /// The badge's window while it is on screen, which captures and recordings leave out.
    var badgeWindowID: CGWindowID? {
        guard let panel, panel.isVisible else { return nil }
        return CGWindowID(panel.windowNumber)
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
        p.ignoresMouseEvents = true
        // Keep the badge (and the transcript it shows) out of screenshots and screen recordings.
        p.sharingType = .none
        let host = NSHostingView(rootView: QuickVoiceBadge())
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

// The voice notes colors are the app's own (Brand): ink surfaces, mark red for anything live.
extension Color {
    static let brandRed = Color(nsColor: Brand.red)
    static let brandInk = Color(nsColor: Brand.ink)
    static let brandInkTop = Color(nsColor: Brand.inkTop)
    static let brandEdge = Color(nsColor: Brand.edge)
}

/// The floating badge for a quick voice note, drawn like the screen recording bar: an ink pill
/// with a hairline edge, a pulsing red light and white text.
struct QuickVoiceBadge: View {
    /// The width, and the height of a one-line badge. A failure wraps and the badge grows to fit.
    static let size = CGSize(width: 400, height: 56)
    @ObservedObject var quick = QuickVoiceNote.shared
    @ObservedObject var rec = VoiceRecorder.shared
    /// A fixed state to draw instead of the live one, for `--render-ui`.
    var sample: (phase: QuickVoiceNote.Phase, elapsed: Double, levels: [Float])?
    private var phase: QuickVoiceNote.Phase { sample?.phase ?? quick.phase }
    private var isFailure: Bool { if case .failed = phase { return true } else { return false } }

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(isFailure ? 3 : 1).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if phase == .recording {
                MiniLevels(levels: sample?.levels ?? Array(rec.history.suffix(18))).frame(width: 54, height: 20)
            }
        }
        .padding(.leading, 18).padding(.trailing, 20).padding(.vertical, 10)
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
        case .transcribing, .starting:
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
        case .transcribing: return "Transcribing"
        case .copied: return "Copied to clipboard"
        case .failed: return "Couldn't transcribe"
        case .idle, .starting: return ""
        }
    }

    private var detail: String {
        switch phase {
        case .recording:
            return quick.shortcut.map { "Press \($0) to stop and copy the text" }
                ?? "Stop it from the menu bar"
        case .transcribing: return VoiceStore.transcribesOnDevice ? "On this Mac" : "With Apple's speech recognition"
        case .copied(let text): return text
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
