import AVKit
import SwiftUI
import UserNotifications

/*
 * Receives files sent from Finder (Open With, or dropped on the Dock icon)
 * and hands them to the most recently opened window, like a drop on it.
 */
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var onOpen: (([URL]) -> Void)?
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    // Show the banner even when the app is in front (macOS hides it by default).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpen { onOpen(urls) } else { pending += urls }
    }

    // Files that arrived before any window existed.
    func attach(_ handler: @escaping ([URL]) -> Void) {
        onOpen = handler
        if !pending.isEmpty { handler(pending); pending = [] }
    }
}

@main
struct SpeechClipExtractorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Each window is its own project (⌘N opens another).
        WindowGroup("Speech Clip Extractor") {
            ProjectWindow(delegate: delegate)
        }
        .commands {
            ProjectCommands()
        }
        Settings {
            SettingsView()
        }
    }
}

/*
 * One window and its project. The state is created per window and
 * published as the "focused scene object", so the menu commands act on
 * whichever window is in front.
 */
struct ProjectWindow: View {
    let delegate: AppDelegate
    @StateObject private var app = AppState()
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ContentView()
            .environmentObject(app)
            .focusedSceneObject(app)
            .frame(minWidth: 1000, minHeight: 660)
            .onAppear {
                let state = app
                delegate.attach { [weak state] urls in state?.handleDrop(urls) }
                app.undoManager = undoManager
            }
            .onChange(of: undoManager) { _, manager in app.undoManager = manager }
    }
}

// MARK: - Menus

/*
 * Every toolbar and window action has a menu item and a keyboard shortcut.
 * Items are disabled when they don't apply, and when no window is open.
 */
struct ProjectCommands: Commands {
    @FocusedObject private var app: AppState?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Video…") { app?.chooseVideo() }
                .keyboardShortcut("o")
                .disabled(app == nil || app!.busy)
            Button("Open Transcript…") { app?.chooseTranscript() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(app?.videoURL == nil || app!.busy)
            Button("Download from URL…") { app?.sheet = .download }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(app == nil || app!.busy)
        }
        CommandGroup(after: .appSettings) {
            Button("Check Setup…") { app?.showSetup = true }
                .disabled(app == nil)
        }
        CommandMenu("Clip") {
            Button("Transcribe…") { app?.sheet = .transcribe }
                .keyboardShortcut("t")
                .disabled(app?.videoURL == nil || app!.busy)
            Button("Suggest Highlights…") { app?.sheet = .suggest }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(app?.cues.isEmpty ?? true || app!.busy)
            Button("Remove Noise…") { app?.sheet = .denoise }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(app?.videoURL == nil || app!.busy)
            Divider()
            Button("Add Clip from Selection") { app?.addClipFromSelection() }
                .keyboardShortcut("k")
                .disabled(app?.cueSelection.isEmpty ?? true)
            Button("New Clip at Playhead") { app?.addClipAtPlayhead() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(app?.player == nil)
            Button("Preview Selected Clip") { app?.previewSelected() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(app?.selectedClips.count != 1)
            Button("Duplicate Selected Clips") { app?.duplicateSelected() }
                .keyboardShortcut("d")
                .disabled(app?.selectedClips.isEmpty ?? true)
            Button("Delete Selected Clips") { app?.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(app?.selectedClips.isEmpty ?? true)
            Divider()
            Button("Export Clips") { app?.exportClips() }
                .keyboardShortcut("e")
                .disabled(app?.clips.contains(where: \.include) != true || app!.busy)
            Button("Show Exported Clips in Finder") { app?.revealOutput() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app?.outputExists != true)
        }
        CommandGroup(after: .toolbar) {
            Button(app?.showLog == false ? "Show Log" : "Hide Log") { app?.showLog.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(app == nil)
            Button("Cancel Running Job") { app?.cancelJob() }
                .keyboardShortcut(".")
                .disabled(app?.busy != true)
        }
    }
}

// MARK: - Main window

enum SheetKind: String, Identifiable {
    case download, transcribe, suggest, denoise
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if app.videoURL == nil {
                EmptyStateView(sheet: $app.sheet)
            } else {
                NextStepBar(sheet: $app.sheet)
                Divider()
                HSplitView {
                    TranscriptView()
                        .frame(minWidth: 320, idealWidth: 420)
                    VSplitView {
                        PlayerPane().frame(minHeight: 240, idealHeight: 360)
                        ClipsView().frame(minHeight: 220)
                    }
                    .frame(minWidth: 520)
                }
                .disabled(app.busy)
            }
            Divider()
            LogView()
        }
        /*
         * A customizable toolbar (right-click it > Customize Toolbar…). Every
         * button is off while a job runs; Cancel lives in the log bar and the
         * View menu.
         */
        .toolbar(id: "main") {
            ToolbarItem(id: "open", placement: .automatic) {
                Button { app.chooseVideo() } label: { Label("Open Video", systemImage: "film") }
                    .help("Open a video or audio file (⌘O)")
                    .disabled(app.busy)
            }
            ToolbarItem(id: "download", placement: .automatic) {
                Button { app.sheet = .download } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .help("Download a video from a URL with yt-dlp (⌥⌘O)")
                    .disabled(app.busy)
            }
            ToolbarItem(id: "transcript", placement: .automatic) {
                Button { app.chooseTranscript() } label: { Label("Open Transcript", systemImage: "captions.bubble") }
                    .help("Load an existing VTT or SRT file (⇧⌘O)")
                    .disabled(app.busy || app.videoURL == nil)
            }
            ToolbarItem(id: "transcribe", placement: .automatic) {
                Button { app.sheet = .transcribe } label: { Label("Transcribe", systemImage: "waveform") }
                    .help("Make a VTT with mlx-whisper (⌘T)")
                    .disabled(app.busy || app.videoURL == nil)
            }
            ToolbarItem(id: "suggest", placement: .automatic) {
                Button { app.sheet = .suggest } label: { Label("Suggest Highlights", systemImage: "sparkles") }
                    .help("Ask AI to pick quotable moments (⇧⌘L)")
                    .disabled(app.busy || app.cues.isEmpty)
            }
            ToolbarItem(id: "denoise", placement: .automatic) {
                Button { app.sheet = .denoise } label: { Label("Remove Noise", systemImage: "speaker.wave.2") }
                    .help("Clean up buzzing or background noise with ffmpeg afftdn (⌥⌘N)")
                    .disabled(app.busy || app.videoURL == nil)
            }
            ToolbarItem(id: "export", placement: .automatic, showsByDefault: false) {
                Button { app.exportClips() } label: { Label("Export Clips", systemImage: "square.and.arrow.up") }
                    .help("Export the ticked clips (⌘E)")
                    .disabled(app.busy || !app.clips.contains(where: \.include))
            }
        }
        .sheet(item: $app.sheet) { kind in
            switch kind {
            case .download: DownloadSheet()
            case .transcribe: TranscribeSheet()
            case .suggest: SuggestSheet()
            case .denoise: DenoiseSheet()
            }
        }
        .sheet(isPresented: $app.showSetup) { SetupView() }
        .task {
            /*
             * At launch (first window only), open the setup window if a core
             * tool is missing, so a new user learns what to install before a
             * button fails.
             */
            guard !SetupCheck.checkedAtLaunch else { return }
            SetupCheck.checkedAtLaunch = true
            let items = await SetupCheck.run()
            let core = ["ffmpeg", "yt-dlp", "mlx-whisper"]
            if items.contains(where: { !$0.ok && ($0.essential || core.contains($0.name)) }) {
                app.showSetup = true
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("OK") { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            app.handleDrop(urls)
            return true
        }
        .navigationTitle(app.videoURL?.lastPathComponent ?? "Speech Clip Extractor")
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var app: AppState
    @Binding var sheet: SheetKind?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Drop a video here").font(.title2)
            Text("A VTT with the same name next to it will load automatically.").foregroundStyle(.secondary)
            HStack {
                Button("Open Video…") { app.chooseVideo() }
                Button("Download from URL…") { sheet = .download }
            }
            .controlSize(.large)
            Button("Check Setup…") { app.showSetup = true }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Next step

/*
 * A bar across the top that says which of the three steps you're on
 * (transcript, pick clips, export) and offers the button for it, plus a
 * green notice when a step has just finished.
 */
struct NextStepBar: View {
    @EnvironmentObject var app: AppState
    @Binding var sheet: SheetKind?

    private var step: Int {
        if app.cues.isEmpty { return 1 }
        if app.clips.isEmpty { return 2 }
        return 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = app.notice {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice)
                    Spacer()
                    Button { app.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss notice")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.green.opacity(0.12))
            }
            HStack(spacing: 12) {
                // The three steps, with the current one highlighted.
                ForEach(1...3, id: \.self) { n in
                    Label(["Transcript", "Pick clips", "Export"][n - 1],
                          systemImage: n < step ? "checkmark.circle.fill" : "\(n).circle\(n == step ? ".fill" : "")")
                        .foregroundStyle(n == step ? Color.accentColor : Color.secondary)
                        .fontWeight(n == step ? .semibold : .regular)
                }
                Divider().frame(height: 18)
                if app.busy {
                    Text("Working: \(app.jobTitle)…").foregroundStyle(.secondary)
                } else {
                    switch step {
                    case 1:
                        Text("Make a transcript so you can find quotes.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Existing Transcript…") { app.chooseTranscript() }
                        Button("Transcribe…") { sheet = .transcribe }.buttonStyle(.borderedProminent)
                    case 2:
                        Text("Select transcript lines and click Add Clip, or let AI suggest some.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Suggest Highlights…") { sheet = .suggest }.buttonStyle(.borderedProminent)
                    default:
                        Text("Tick the clips you want, choose options below, then export.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Export Clips") { app.exportClips() }
                            .buttonStyle(.borderedProminent)
                            .disabled(app.clips.filter(\.include).isEmpty)
                    }
                }
                if app.busy { Spacer() }
            }
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""

    private var shown: [Cue] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? app.cues : app.cues.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript").font(.headline)
                if let vtt = app.vttURL {
                    Text(vtt.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
            }
            .padding(8)

            if app.cues.isEmpty {
                VStack(spacing: 8) {
                    Text("No transcript yet").foregroundStyle(.secondary)
                    Text("Use Transcribe, or Open Transcript for an existing VTT.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(shown, selection: $app.cueSelection) { cue in
                        CueRow(cue: cue, isCurrent: cue.start <= app.currentTime && app.currentTime < cue.end)
                            .id(cue.id)
                            .contextMenu {
                                Button("Play from here") { app.seek(to: cue.start, play: true) }
                                Button("Add clip from selection") { app.addClipFromSelection() }
                            }
                    }
                    .onChange(of: app.cueSelection) { _, selection in
                        // Clicking one line jumps the player there.
                        if selection.count == 1, let cue = app.cues.first(where: { selection.contains($0.id) }) {
                            app.seek(to: cue.start)
                        }
                    }
                    .onChange(of: search) { _, _ in
                        if let first = shown.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }

            Divider()
            HStack {
                Text("⇧/⌘-click to select lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Clip from Selection (\(app.cueSelection.count))") { app.addClipFromSelection() }
                    .disabled(app.cueSelection.isEmpty)
            }
            .padding(8)
        }
    }
}

struct CueRow: View {
    let cue: Cue
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Timecode.format(cue.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = cue.speaker {
                    Text(speaker).font(.caption2.bold()).foregroundStyle(.tint)
                }
                Text(cue.text)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

// MARK: - Player

/*
 * AppKit's AVPlayerView wrapped for SwiftUI. SwiftUI's own VideoPlayer
 * crashed the app (an abort inside _AVKit_SwiftUI) as soon as a video
 * loaded, so it isn't used.
 */
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct PlayerPane: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let player = app.player {
                PlayerView(player: player)
            } else {
                Color.black
            }
            HStack {
                Text("\(Timecode.format(app.currentTime)) / \(Timecode.format(app.duration))")
                    .font(.system(.body, design: .monospaced))
                if let size = app.videoSize {
                    Text("\(Int(size.width))×\(Int(size.height))").foregroundStyle(.secondary)
                } else {
                    Text("audio only").foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Clip at Playhead") { app.addClipAtPlayhead() }
            }
            .padding(8)
        }
    }
}

// MARK: - Clips and export

struct ClipsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clips").font(.headline)
                Text("\(app.clips.filter(\.include).count) of \(app.clips.count) ticked").foregroundStyle(.secondary)
                Spacer()
                if !app.clips.isEmpty {
                    // Undoable with ⌘Z, so it doesn't ask first.
                    Button("Clear All", role: .destructive) { app.clearClips() }
                        .help("Remove every clip (Edit > Undo brings them back)")
                }
            }
            .padding(8)

            if app.clips.isEmpty {
                Text("Select transcript lines and Add Clip, use New Clip at Playhead, or Suggest Highlights.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Click to select, ⇧/⌘-click for several; Delete removes the selection.
                List(selection: $app.clipSelection) {
                    ForEach($app.clips) { $clip in
                        ClipRow(clip: $clip)
                            .tag(clip.id)
                            .contextMenu { ClipMenu(clip: clip) }
                    }
                }
                .onDeleteCommand { app.deleteSelected() }
            }

            Divider()
            ExportBar()
        }
    }
}

struct ClipRow: View {
    @EnvironmentObject var app: AppState
    @Binding var clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("Include in export", isOn: $clip.include).labelsHidden()
                    .help("Include this clip when exporting")
                TextField("Title", text: $clip.title).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Clip title")
                // Times go through the app so a changed time can be undone with ⌘Z.
                TimecodeField(value: Binding(get: { clip.start }, set: { app.setStart(of: clip, to: $0) }))
                    .accessibilityLabel("Start time")
                Button { app.setStart(of: clip, to: app.currentTime) } label: { Image(systemName: "arrow.right.to.line") }
                    .help("Set start to the playhead")
                    .accessibilityLabel("Set start to the playhead")
                Text("–").accessibilityHidden(true)
                TimecodeField(value: Binding(get: { clip.end }, set: { app.setEnd(of: clip, to: $0) }))
                    .accessibilityLabel("End time")
                Button { app.setEnd(of: clip, to: app.currentTime) } label: { Image(systemName: "arrow.left.to.line") }
                    .help("Set end to the playhead")
                    .accessibilityLabel("Set end to the playhead")
                Text(String(format: "%.1fs", clip.duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(clip.duration > 0 ? Color.secondary : Color.red)
                    .frame(width: 52, alignment: .trailing)
                    .accessibilityLabel(String(format: "Duration %.1f seconds", clip.duration))
                Button { app.preview(clip) } label: { Image(systemName: "play.fill") }
                    .help("Preview this clip")
                    .accessibilityLabel("Preview clip")
                Button { app.delete(clip) } label: { Image(systemName: "trash") }
                    .help("Remove this clip")
                    .accessibilityLabel("Delete clip")
            }
            if !clip.quote.isEmpty || !clip.why.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !clip.quote.isEmpty { Text("“\(clip.quote)”").italic().lineLimit(3) }
                    if !clip.why.isEmpty { Text(clip.why).foregroundStyle(.secondary) }
                }
                .font(.caption)
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 3)
    }
}

// The right-click menu on a clip. It acts on the whole selection when the clicked clip is part of it.
struct ClipMenu: View {
    @EnvironmentObject var app: AppState
    let clip: Clip

    // The selection when the clicked clip is part of it, otherwise just the clicked clip.
    private var targets: [Clip] {
        app.clipSelection.contains(clip.id) ? app.selectedClips : [clip]
    }

    var body: some View {
        Button("Preview") { app.preview(clip) }
        Button("Set Start to Playhead") { app.setStart(of: clip, to: app.currentTime) }
        Button("Set End to Playhead") { app.setEnd(of: clip, to: app.currentTime) }
        Button("Jump to Start") { app.seek(to: clip.start) }
        Divider()
        Divider()
        // Export just this clip (or the selection it's part of), with or without open captions.
        Button(targets.count > 1 ? "Export \(targets.count) Selected Clips" : "Export Clip") {
            app.exportClips(only: targets)
        }
        .disabled(app.busy)
        Button(targets.count > 1 ? "Export \(targets.count) Selected Clips with Open Captions" : "Export Clip with Open Captions") {
            app.exportClips(only: targets, openCaptions: true)
        }
        .disabled(app.busy || app.cues.isEmpty)
        Divider()
        Button("Duplicate") {
            if !app.clipSelection.contains(clip.id) { app.clipSelection = [clip.id] }
            app.duplicateSelected()
        }
        Button("Delete", role: .destructive) {
            if app.clipSelection.contains(clip.id) { app.deleteSelected() } else { app.delete(clip) }
        }
    }
}

// A time text field that accepts "1:15.5" or seconds, committed on Return or when focus leaves.
struct TimecodeField: View {
    @Binding var value: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0:00.0", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(width: 84)
            .focused($focused)
            .onAppear { text = Timecode.format(value) }
            .onChange(of: value) { _, newValue in
                if !focused { text = Timecode.format(newValue) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit(commit)
    }

    private func commit() {
        if let parsed = Timecode.parse(text) { value = parsed }
        text = Timecode.format(value)
    }
}

struct ExportBar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Toggle("Vertical 9:16", isOn: $app.exportVertical)
                    .disabled(app.videoSize == nil)
                    .help("Also make a center-cropped vertical copy (re-encoded)")
                Toggle("Subtitle file", isOn: $app.exportVTT)
                    .help("A .vtt per clip, re-zeroed to the clip start (upload to Bluesky for closed captions)")
                Toggle("Burn captions", isOn: $app.burnCaptions)
                    .help("Also make a -captioned.mp4 with open captions")
                Toggle("Frame-accurate", isOn: $app.reencode)
                    .help("Re-encode the horizontal clip instead of stream copy, so it cuts exactly (stream copy cuts on keyframes)")
                Toggle("Speaker labels", isOn: $app.keepSpeakerLabels)
                    .help("Keep [SPEAKER_00]: prefixes in subtitle files and captions")
            }
            .toggleStyle(.checkbox)
            HStack {
                Image(systemName: "folder")
                Text(app.outputDir?.path ?? "No output folder")
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") { app.chooseOutputDir() }
                if let dir = app.outputDir, FileManager.default.fileExists(atPath: dir.path) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                }
                Spacer()
                Button("Export Clips") { app.exportClips() }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.clips.filter(\.include).isEmpty)
            }
        }
        .padding(8)
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if app.busy { ProgressView().controlSize(.small) }
                Text(app.status).lineLimit(1).truncationMode(.middle)
                    .font(.system(.callout, design: app.busy ? .monospaced : .default))
                Spacer()
                if app.busy {
                    Button("Cancel") { app.cancelJob() }
                }
                Button { app.showLog.toggle() } label: {
                    Image(systemName: app.showLog ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .help(app.showLog ? "Hide the log (⌥⌘L)" : "Show the log (⌥⌘L)")
                .accessibilityLabel(app.showLog ? "Hide the log" : "Show the log")
            }
            .padding(.horizontal, 8)
            .frame(height: 32)

            if app.showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(app.log.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix("ERROR") ? Color.red : line.hasPrefix("$") ? Color.accentColor : Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(height: 150)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: app.log.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }
}
