import AppKit
import ShotateCore
import SwiftUI

private func clock(_ t: Double, tenths: Bool = false) -> String { VoiceNotes.clock(t, tenths: tenths) }

/// The voice notes library, opened from the menu bar. Closing it stops playback; recording and
/// the shortcut keep working.
final class VoiceNotesWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Voice Notes"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentView = NSHostingView(rootView: VoiceNotesView().frame(minWidth: 860, minHeight: 560))
        if !window.setFrameUsingName("VoiceNotes") { window.center() }
        window.setFrameAutosaveName("VoiceNotes")
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        VoiceStore.shared.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        VoicePlayer.shared.unload()
        onClose?()
    }
}

/// The dark band behind the recorder, the same ink as the app icon.
struct StageBackground: View {
    var body: some View {
        LinearGradient(colors: [.brandInkTop, .brandInk], startPoint: .top, endPoint: .bottom)
    }
}

struct PlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.brandRed))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.5 : 0.8))
            .frame(width: 34, height: 34)
            .contentShape(Circle())
    }
}

struct MarkerChip: View {
    var label: String
    var time: Double
    var onStage = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bookmark.fill").font(.system(size: 9))
            Text(label)
            Text(clock(time)).monospacedDigit().opacity(0.7)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(onStage ? Color.white : Color.primary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.brandRed.opacity(onStage ? 0.3 : 0.16), in: Capsule())
    }
}

/// ContentUnavailableView needs macOS 14; this is the same layout for 13.
struct EmptyState: View {
    var title: String
    var symbol: String
    var detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LevelWave: View {
    var levels: [Float]
    var active: Bool
    var body: some View {
        Canvas { ctx, size in
            let n = levels.count
            let bw = size.width / CGFloat(n)
            let mid = size.height / 2
            // Center line keeps the stage from looking empty when idle.
            ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(.white.opacity(0.10)))
            for (i, l) in levels.enumerated() {
                let h = max(2, CGFloat(l) * size.height)
                let rect = CGRect(x: CGFloat(i) * bw + bw * 0.22, y: mid - h / 2, width: bw * 0.56, height: h)
                let age = Double(i) / Double(n)
                let color: Color = active
                    ? (i >= n - 3 ? .white : Color.brandRed.opacity(0.25 + 0.75 * age))
                    : Color.white.opacity(0.12 * age + 0.04)
                ctx.fill(Path(roundedRect: rect, cornerRadius: bw * 0.28), with: .color(color))
            }
        }
        .accessibilityLabel("Input level")
    }
}

/// A white ring around a red light that squares off while recording.
struct RecordGlyph: View {
    var recording: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 4).frame(width: 64, height: 64)
            RoundedRectangle(cornerRadius: recording ? 6 : 24)
                .fill(Color.brandRed)
                .frame(width: recording ? 26 : 48, height: recording ? 26 : 48)
                .shadow(color: .brandRed.opacity(recording ? 0.6 : 0.3), radius: recording ? 10 : 4)
        }
        // `.spring(duration:)` is macOS 14; this is its macOS 13 equivalent.
        .animation(.spring(response: 0.25, dampingFraction: 0.825), value: recording)
        .contentShape(Circle())
    }
}

struct RecorderPanel: View {
    @ObservedObject var rec = VoiceRecorder.shared
    var status: String { !rec.isRecording ? "Ready" : rec.isPaused ? "Paused" : "Recording" }
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                HStack(spacing: 7) {
                    Circle().fill(rec.isRecording && !rec.isPaused ? Color.brandRed : Color.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(status.uppercased()).font(.caption.weight(.semibold)).tracking(1.2)
                }
                .foregroundStyle(.white.opacity(0.85))
                Label(rec.inputName, systemImage: "mic").font(.callout).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Spacer()
                SwiftUI.Picker("Quality", selection: $rec.quality) {
                    ForEach(VoiceQuality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                .disabled(rec.isRecording).help(rec.quality.detail)
                Toggle("Stereo", isOn: $rec.stereo).disabled(rec.isRecording)
                    .help("Record two channels. Leave off for the built-in mic.")
            }
            LevelWave(levels: rec.history, active: rec.isRecording && !rec.isPaused).frame(height: 76)
            HStack(spacing: 16) {
                Text(clock(rec.elapsed, tenths: true))
                    .font(.system(size: 40, weight: .light, design: .monospaced))
                    .foregroundStyle(rec.isRecording ? Color.white : Color.white.opacity(0.45))
                Spacer()
                Button { rec.addMarker() } label: { Label("Marker", systemImage: "bookmark") }
                    .disabled(!rec.isRecording).keyboardShortcut("b").help("Drop a marker here (Command-B)")
                Button { rec.togglePause() } label: {
                    Label(rec.isPaused ? "Resume" : "Pause", systemImage: rec.isPaused ? "record.circle" : "pause.fill")
                }
                .disabled(!rec.isRecording).keyboardShortcut("r", modifiers: [.command, .option])
                .help("Pause or resume (Option-Command-R)")
                Button {
                    // A note started with the shortcut finishes the same way: transcribe, copy, close its badge.
                    if QuickVoiceNote.shared.phase == .recording { QuickVoiceNote.shared.finish() } else { rec.toggle() }
                } label: { RecordGlyph(recording: rec.isRecording) }
                    .buttonStyle(.plain).keyboardShortcut("r")
                    .help(rec.isRecording ? "Stop (Command-R)" : "Record (Command-R)")
            }
            if !rec.markers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(rec.markers, id: \.self) { MarkerChip(label: $0.label, time: $0.time, onStage: true) } }
                }
            }
            if let e = rec.error {
                Text(e).font(.callout).foregroundStyle(Color(red: 1, green: 0.6, blue: 0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .background(StageBackground())
        .environment(\.colorScheme, .dark)
        .tint(.brandRed)
    }
}

struct Scrubber: View {
    var time: Double
    var duration: Double
    var markers: [VoiceMarker]
    var onSeek: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let frac = duration > 0 ? min(1, max(0, time / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 5)
                Capsule().fill(Color.brandRed).frame(width: max(5, w * frac), height: 5)
                ForEach(markers, id: \.self) { m in
                    Capsule().fill(Color.brandRed).frame(width: 3, height: 16)
                        .offset(x: duration > 0 ? w * min(1, m.time / duration) - 1.5 : 0)
                }
                Circle().fill(Color.white).overlay(Circle().strokeBorder(Color.brandRed, lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: 15, height: 15).offset(x: w * frac - 7.5)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard w > 0 else { return }
                onSeek(max(0, min(duration, v.location.x / w * duration)))
            })
        }
        .frame(height: 22)
    }
}

struct PlayerPanel: View {
    let r: VoiceNote
    @ObservedObject var player = VoicePlayer.shared
    @ObservedObject var store = VoiceStore.shared
    @State private var title = ""
    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $title)
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .semibold))
                    .onSubmit { store.rename(r, to: title) }
                    .help("Edit and press Return to rename the file")
                Text("\(r.date.formatted(date: .long, time: .shortened))  ·  \(clock(r.duration))  ·  \(ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file))  ·  \(r.url.pathExtension.uppercased())")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                Scrubber(time: player.time, duration: player.duration > 0 ? player.duration : r.duration,
                         markers: r.meta.markers) { player.seek($0) }
                HStack {
                    Text(clock(player.time))
                    Spacer()
                    Text("-" + clock(max(0, player.duration - player.time)))
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                SwiftUI.Picker("Speed", selection: $player.rate) {
                    ForEach(speeds, id: \.self) { Text(String(format: "%gx", $0)).tag($0) }
                }
                .labelsHidden().frame(width: 72).help("Playback speed")
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    .buttonStyle(TransportButtonStyle())
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).help("Back 15 seconds (Option-Command-Left)")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").offset(x: player.isPlaying ? 0 : 1.5)
                }
                .buttonStyle(PlayButtonStyle()).keyboardShortcut("p").help("Play or pause (Command-P)")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    .buttonStyle(TransportButtonStyle())
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).help("Forward 15 seconds (Option-Command-Right)")
                Spacer()
                Color.clear.frame(width: 72, height: 1)
            }
            if !r.meta.markers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(r.meta.markers, id: \.self) { m in
                            Button { player.seek(m.time) } label: { MarkerChip(label: m.label, time: m.time) }
                                .buttonStyle(.plain).help("Jump to \(clock(m.time))")
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                if store.transcribing.contains(r.url) {
                    ProgressView().controlSize(.small)
                    Text(VoiceStore.transcribesOnDevice ? "Transcribing on this Mac" : "Transcribing")
                        .foregroundStyle(.secondary)
                } else {
                    Button { store.transcribe(r.url) } label: {
                        Label(r.meta.transcript == nil ? "Transcribe" : "Transcribe Again", systemImage: "text.quote")
                    }
                }
                if let t = r.meta.transcript {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(t, forType: .string)
                    } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                }
                Spacer()
                Button { store.reveal(r) } label: { Label("Show in Finder", systemImage: "folder") }
                Button(role: .destructive) { store.delete(r) } label: { Label("Move to Trash", systemImage: "trash") }
            }
            .controlSize(.regular)
            if let t = r.meta.transcript {
                ScrollView {
                    Text(t).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(24)
        .onAppear { title = r.name; player.load(r.url) }
    }
}

struct VoiceNoteRow: View {
    let r: VoiceNote
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(r.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            HStack(spacing: 6) {
                Text(r.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                if r.meta.transcript != nil {
                    Image(systemName: "text.quote").foregroundStyle(Color.brandRed).help("Has a transcript")
                }
                if !r.meta.markers.isEmpty {
                    Image(systemName: "bookmark.fill").foregroundStyle(Color.brandRed).help("Has markers")
                }
                Spacer()
                Text(clock(r.duration)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct VoiceNotesView: View {
    @ObservedObject var store = VoiceStore.shared
    @State private var query = ""

    var filtered: [VoiceNote] {
        store.notes.filter { VoiceNotes.matches(query, name: $0.name, transcript: $0.meta.transcript) }
    }

    var body: some View {
        NavigationSplitView {
            // A search field and folder button in the sidebar itself: a hosted view has no window
            // toolbar for `.searchable` and toolbar items on macOS 13.
            VStack(spacing: 0) {
                TextField("Search names and transcripts", text: $query)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.vertical, 8)
                List(filtered, selection: $store.selection) { r in
                    VoiceNoteRow(r: r)
                        .onDrag { NSItemProvider(contentsOf: r.url) ?? NSItemProvider() }
                        .contextMenu {
                            Button("Transcribe") { store.transcribe(r.url) }
                            Button("Show in Finder") { store.reveal(r) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { store.delete(r) }
                        }
                }
                .overlay {
                    if store.notes.isEmpty {
                        EmptyState(title: "No voice notes yet", symbol: "waveform", detail: "Press Command-R to start.")
                    }
                }
                Divider()
                HStack {
                    Button { NSWorkspace.shared.open(store.dir) } label: { Label("Open Folder", systemImage: "folder") }
                        .buttonStyle(.borderless)
                        .help("Open \((store.dir.path as NSString).abbreviatingWithTildeInPath) in Finder")
                    Spacer()
                    Menu {
                        let scripts = Scripts.list(in: store.dir)
                        ForEach(scripts, id: \.url) { s in Button(s.name) { Teleprompter.shared.show(s.url) } }
                        if scripts.isEmpty { Text("No scripts yet") }
                        Divider()
                        Button("Show Scripts Folder") {
                            let dir = Scripts.folder(in: store.dir)
                            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(dir)
                        }
                    } label: { Label("Scripts", systemImage: "text.alignleft") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Read a script in the teleprompter while you record")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                RecorderPanel()
                if let r = store.note(store.selection) {
                    PlayerPanel(r: r).id(r.url)
                } else {
                    EmptyState(title: "Select a voice note", symbol: "play.circle",
                               detail: "Or press Command-R to record a new one.")
                }
                Spacer(minLength: 0)
            }
        }
        .tint(.brandRed)
        .alert(store.message ?? "", isPresented: Binding(get: { store.message != nil },
                                                          set: { if !$0 { store.message = nil } })) {
            Button("OK") {}
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
        }
    }
}
