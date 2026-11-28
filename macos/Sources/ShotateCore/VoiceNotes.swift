import Foundation

/// How a voice note is recorded. The raw value is what the config file stores (`voiceQuality`).
public enum VoiceQuality: String, CaseIterable, Identifiable, Equatable {
    case aac, alac, wav
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .aac: return "AAC"
        case .alac: return "Lossless"
        case .wav: return "WAV"
        }
    }
    public var ext: String { self == .wav ? "wav" : "m4a" }
    public var detail: String {
        switch self {
        case .aac: return "AAC 48 kHz: small files, near-transparent quality"
        case .alac: return "Apple Lossless 24-bit / 48 kHz: full quality, about half the size of WAV"
        case .wav: return "WAV 24-bit / 48 kHz: uncompressed, opens anywhere"
        }
    }
}

/// A point someone marked while recording, in seconds from the start.
public struct VoiceMarker: Codable, Hashable {
    public var time: Double
    public var label: String
    public init(time: Double, label: String) { self.time = time; self.label = label }
}

/// What Yapshot knows about a voice note beyond the audio: kept in `.meta/<file>.json` beside it.
/// Older sidecars that still contain extra fields (such as a legacy `transcript`) decode cleanly
/// because unknown keys are ignored.
public struct VoiceMeta: Codable, Hashable {
    public var markers: [VoiceMarker] = []
    public var duration: Double?
    /// The script it was read from in the teleprompter, by name.
    public var script: String?
    public init(markers: [VoiceMarker] = [], duration: Double? = nil, script: String? = nil) {
        self.markers = markers
        self.duration = duration
        self.script = script
    }
}

public enum VoiceNotes {
    /// Audio files the library lists.
    public static let audioExtensions: Set<String> = ["m4a", "wav", "caf", "aif", "aiff", "mp3"]

    /// The sidecar for an audio file: `<folder>/.meta/<file name>.json`, so Finder shows only audio.
    public static func sidecarURL(for audio: URL) -> URL {
        audio.deletingLastPathComponent().appendingPathComponent(".meta", isDirectory: true)
            .appendingPathComponent(audio.lastPathComponent + ".json")
    }

    /// A file name typed in the library, made safe: no folder separators, no surrounding spaces.
    public static func safeName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Search over voice note names. An empty query matches everything.
    public static func matches(_ query: String, name: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(q)
    }

    /// "1:05", "1:02:03", or with tenths "01:05.3".
    public static func clock(_ t: Double, tenths: Bool = false) -> String {
        let t = max(0, t.isFinite ? t : 0)
        let m = Int(t) / 60, s = Int(t) % 60
        if tenths { return String(format: "%02d:%02d.%d", m, s, Int((t - floor(t)) * 10)) }
        if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// State machine for the quick voice note overlay (⇧⌘M): start recording, stop and copy the audio
/// file to the clipboard, or dismiss reliably via Esc, the close button, the shortcut, or external
/// stop. There is no transcription: stopping copies the recorded audio file URL to the clipboard.
public final class QuickVoiceController {
    public enum Phase: Equatable {
        case idle
        case starting
        case recording
        /// Stopped and copied the audio file URL to the clipboard; carries the display label (file name).
        case copied(String)
        case failed(String)

        public var isVisible: Bool {
            switch self {
            case .idle, .starting: return false
            case .recording, .copied, .failed: return true
            }
        }
    }

    public private(set) var phase: Phase = .idle
    private var startToken = 0
    private var hideToken = 0
    private var stoppingInternally = false

    private let isRecording: () -> Bool
    private let startRecording: (@escaping (Bool, String?) -> Void) -> Void
    private let stopRecording: () -> URL?
    private let copyAudioFile: (URL) -> Bool
    private let onPhaseChange: (Phase) -> Void
    private let scheduleHide: (TimeInterval, @escaping () -> Void) -> Void
    private let cancelScheduledHide: () -> Void

    public init(
        isRecording: @escaping () -> Bool,
        startRecording: @escaping (@escaping (Bool, String?) -> Void) -> Void,
        stopRecording: @escaping () -> URL?,
        copyAudioFile: @escaping (URL) -> Bool,
        onPhaseChange: @escaping (Phase) -> Void = { _ in },
        scheduleHide: @escaping (TimeInterval, @escaping () -> Void) -> Void = { _, _ in },
        cancelScheduledHide: @escaping () -> Void = {}
    ) {
        self.isRecording = isRecording
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.copyAudioFile = copyAudioFile
        self.onPhaseChange = onPhaseChange
        self.scheduleHide = scheduleHide
        self.cancelScheduledHide = cancelScheduledHide
    }

    /// Global voice-note shortcut (⇧⌘M): starts when idle, stops and copies the audio file when
    /// recording, or cancels if still waiting on the microphone prompt.
    public func toggle() {
        if isRecording() || phase == .recording {
            finish()
        } else if phase == .starting {
            dismiss()
        } else {
            cancelScheduledHide()
            hideToken += 1
            startToken += 1
            let token = startToken
            transition(to: .starting)
            startRecording { [weak self] ok, error in
                guard let self else { return }
                guard self.startToken == token, self.phase == .starting else {
                    // Dismissed while waiting on permission: stop if recording actually began.
                    if ok { _ = self.stopRecording() }
                    return
                }
                if ok {
                    self.transition(to: .recording)
                } else {
                    self.showTemporary(.failed(error ?? "Recording didn't start."), duration: 4)
                }
            }
        }
    }

    /// Stops recording, copies the audio file URL to the clipboard, shows a brief confirmation, and
    /// auto-hides. If nothing was recording, dismisses any visible badge immediately.
    @discardableResult
    public func finish() -> URL? {
        startToken += 1
        stoppingInternally = true
        let url = stopRecording()
        stoppingInternally = false
        guard let url else {
            dismiss()
            return nil
        }
        if copyAudioFile(url) {
            showTemporary(.copied(url.lastPathComponent), duration: 2.5)
        } else {
            showTemporary(.failed("Saved \(url.lastPathComponent), but couldn't copy the audio file."), duration: 4)
        }
        return url
    }

    /// Esc or the close (×) button: stops recording if active (saving and copying the audio file so
    /// nothing is lost) and hides the overlay immediately.
    public func dismiss() {
        startToken += 1
        hideToken += 1
        cancelScheduledHide()
        if isRecording() || phase == .recording {
            stoppingInternally = true
            let url = stopRecording()
            stoppingInternally = false
            if let url {
                _ = copyAudioFile(url)
            }
        }
        if phase != .idle {
            transition(to: .idle)
        }
    }

    /// Called when the underlying recorder stops from outside this overlay (Voice Notes window,
    /// Teleprompter, or a system audio interruption), so the badge is never stranded on screen.
    public func externalRecordingStopped() {
        guard !stoppingInternally, phase == .recording || phase == .starting else { return }
        startToken += 1
        hideToken += 1
        cancelScheduledHide()
        transition(to: .idle)
    }

    private func showTemporary(_ next: Phase, duration: TimeInterval) {
        cancelScheduledHide()
        hideToken += 1
        let token = hideToken
        transition(to: next)
        scheduleHide(duration) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.transition(to: .idle)
        }
    }

    private func transition(to next: Phase) {
        phase = next
        onPhaseChange(next)
    }
}
