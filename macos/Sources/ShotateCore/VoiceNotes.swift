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

/// What Shotate knows about a voice note beyond the audio: kept in `.meta/<file>.json` beside it.
public struct VoiceMeta: Codable, Hashable {
    public var markers: [VoiceMarker] = []
    public var transcript: String?
    public var duration: Double?
    /// The script it was read from in the teleprompter, by name.
    public var script: String?
    public init(markers: [VoiceMarker] = [], transcript: String? = nil, duration: Double? = nil, script: String? = nil) {
        self.markers = markers
        self.transcript = transcript
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

    /// Search over names and transcripts. An empty query matches everything.
    public static func matches(_ query: String, name: String, transcript: String?) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(q) || (transcript?.localizedCaseInsensitiveContains(q) ?? false)
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
