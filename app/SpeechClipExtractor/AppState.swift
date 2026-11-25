import AVFoundation
import AppKit
import Foundation
import SwiftUI
import UserNotifications

// Settings keys shared by AppState and SettingsView (@AppStorage).
enum Pref {
    static let claudeModel = "claudeModel"
    static let claudeEffort = "claudeEffort"
    static let captionFont = "captionFont"
    static let captionSize = "captionSize"
    static let whisperModel = "whisperModel"
    static let niceLevel = "transcribeNiceLevel"
    static let cookieBrowser = "cookieBrowser"
    static let provider = "aiProvider"

    static func string(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    /*
     * Set only by the UI test, as a launch argument (-SCEUITesting YES), which
     * lasts for that launch and isn't saved. It keeps the test off the user's
     * screen: no Finder window after an export and no notification banners.
     */
    static var uiTesting: Bool { UserDefaults.standard.bool(forKey: "SCEUITesting") }
}

/*
 * Everything the window shows: the source video, its transcript, the clip
 * list, export options, and the running job with its log. Pipeline.swift
 * adds the steps that call ffmpeg, yt-dlp, mlx_whisper and Claude.
 */
@MainActor
final class AppState: ObservableObject {
    // Source
    @Published var videoURL: URL?
    @Published var player: AVPlayer?
    @Published var videoSize: CGSize?
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0

    // Transcript
    @Published var cues: [Cue] = []
    @Published var vttURL: URL?
    @Published var cueSelection: Set<Cue.ID> = []

    // Clips, saved next to the video as "<name>.clips.json" whenever they change
    @Published var clips: [Clip] = [] {
        didSet { saveClips() }
    }

    // Export options
    @Published var exportVertical = false
    @Published var exportVTT = true
    @Published var burnCaptions = false
    @Published var reencode = false
    @Published var keepSpeakerLabels = false
    @Published var outputDir: URL?

    // Running job
    @Published var busy = false
    @Published var jobTitle = ""
    @Published var status = "Open a video, drop one on the window, or download one from a URL."
    @Published var log: [String] = []
    @Published var showLog = true
    @Published var errorMessage: String?
    // A finished-step message shown in a green bar at the top of the window.
    @Published var notice: String?
    @Published var showSetup = false
    // The sheet open on this window (download, transcribe, suggest).
    @Published var sheet: SheetKind?
    // Clips selected in the clip list (for Delete, Duplicate, Preview and the right-click menu).
    @Published var clipSelection: Set<Clip.ID> = []
    /*
     * The undo manager for clip changes: the window's own, which is the one
     * the Edit menu's Undo and ⌘Z use. SwiftUI's environment undo manager is
     * only a fallback, because it can still be nil when the window appears,
     * which left Undo greyed out (found by the automated UI test).
     */
    weak var environmentUndoManager: UndoManager?
    var undoManager: UndoManager? { window?.undoManager ?? environmentUndoManager }
    // This project's window, so the space bar only controls the video in the window in front.
    weak var window: NSWindow?

    private var job: Task<Void, Never>?
    // True while the status line shows a tool's progress bar rather than a step message.
    private var statusIsProgress = false
    private var timeObserver: Any?
    private var previewObserver: Any?
    private var loadingClips = false

    // MARK: - Jobs

    /*
     * Runs one long step (download, transcribe, export...) at a time. The
     * toolbar is disabled while it runs, and Cancel stops it, which
     * terminates whatever tool it's waiting on.
     */
    func startJob(_ title: String, _ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        jobTitle = title
        status = title + "…"
        appendLog("── \(title) ──")
        job = Task {
            do {
                try await work()
                self.status = "\(title): done."
            } catch is CancellationError {
                self.status = "\(title): cancelled."
                self.appendLog("Cancelled.")
            } catch {
                self.status = "\(title) failed."
                self.appendLog("ERROR: \(error.localizedDescription)")
                self.errorMessage = error.localizedDescription
            }
            self.busy = false
            self.job = nil
        }
    }

    func cancelJob() {
        job?.cancel()
    }

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    /*
     * Runs a tool for the current job: logs the command, streams its
     * output into the log (progress redraws go to the status line), and
     * throws if it exits non-zero. Returns its output lines.
     */
    @discardableResult
    func exec(_ executable: String, _ args: [String], cwd: URL? = nil, private isPrivate: Bool = false) async throws -> [String] {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        // A private run (downloads) never shows the URL or video ID in the log, the status line or an error.
        let clean: (String) -> String = { isPrivate ? AppState.redact($0) : $0 }
        appendLog(clean("$ \(name) " + args.map(shellQuote).joined(separator: " ")))
        let (status, output) = try await ProcessRunner.run(executable, args, cwd: cwd) { line, endedInReturn in
            let shown = clean(line)
            // A redraw (ends in "\r") or anything shaped like a progress update goes to the status line, not the log.
            let isProgress = endedInReturn || AppState.looksLikeProgress(line)
            // Hop to the main thread in order (DispatchQueue.main is FIFO).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if isProgress {
                        self.status = shown
                        self.statusIsProgress = true
                    } else {
                        self.appendLog(shown)
                        // A finished progress bar (like "Fetching 4 files") mustn't linger once newer output arrives.
                        if self.statusIsProgress {
                            self.status = self.jobTitle + "…"
                            self.statusIsProgress = false
                        }
                    }
                }
            }
        }
        guard status == 0 else { throw ToolError.failed(name, status, clean(output.tail)) }
        return output.lines
    }

    /*
     * Removes what would identify a download: every http(s) address, and the
     * video ID yt-dlp prints after its site tag ("[youtube] dQw4w9WgXcQ: ..."
     * becomes "[youtube] …: ..."). Words like "Unsupported URL" stay, so the
     * download step can still recognize those errors.
     */
    nonisolated static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"https?://\S+"#, with: "[URL]", options: .regularExpression)
            .replacingOccurrences(of: #"(\[[^\]]+\] )[^\s:]+:"#, with: "$1…:", options: .regularExpression)
    }

    /*
     * yt-dlp's "[download]  12.3% of 40MiB at …" and ffmpeg's "frame= … time= …"
     * lines are progress updates even when they end in a newline, and would
     * otherwise fill the log with thousands of lines.
     */
    nonisolated static func looksLikeProgress(_ line: String) -> Bool {
        line.range(of: #"^\[download\]\s+[0-9.]+%"#, options: .regularExpression) != nil
            || line.range(of: #"^frame=\s*\d+.*time="#, options: .regularExpression) != nil
    }

    private func shellQuote(_ s: String) -> String {
        s.rangeOfCharacter(from: CharacterSet(charactersIn: " '\"$&()[];*?")) == nil ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Telling the user a long step finished

    /*
     * Shows the message in the window's green bar and, when notifications
     * are allowed, as a macOS notification too (useful when a long
     * transcription finishes while you're in another app).
     */
    func announce(_ title: String, _ body: String) {
        notice = "\(title). \(body)"
        guard !Pref.uiTesting else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - Opening files

    /*
     * Opens a video (or audio file). A VTT with the same base name next to
     * it is loaded as the transcript, and a saved clip list is restored.
     */
    func openVideo(_ url: URL) {
        /*
         * Both observers belong to the old player and must come off it before
         * it's replaced: removing one from a different player later throws an
         * exception and crashes the app (a preview still running when another
         * video opens).
         */
        if let player {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            if let previewObserver { player.removeTimeObserver(previewObserver) }
            player.pause()
        }
        timeObserver = nil
        previewObserver = nil

        videoURL = url
        videoSize = nil
        duration = 0
        currentTime = 0
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }

        let base = url.deletingPathExtension()
        outputDir = url.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + " clips", isDirectory: true)

        undoManager?.removeAllActions()
        clipSelection = []
        loadingClips = true
        cues = []
        vttURL = nil
        clips = []
        cueSelection = []
        if let transcript = newestTranscript(for: url) {
            loadTranscript(transcript)
        }
        loadClips()
        loadingClips = false

        notice = nil
        appendLog("Opened \(url.path)")
        Task { await probe() }
    }

    /*
     * The transcript to load with a video: the newest of "<name>.vtt" and any
     * "<name>-whisper….vtt" the app made when "<name>.vtt" was already taken.
     */
    private func newestTranscript(for video: URL) -> URL? {
        let folder = video.deletingLastPathComponent()
        let name = video.deletingPathExtension().lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = files.filter { file in
            file.pathExtension.lowercased() == "vtt" && {
                let stem = file.deletingPathExtension().lastPathComponent
                return stem == name || stem.hasPrefix(name + "-whisper")
            }()
        }
        func modified(_ file: URL) -> Date {
            (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return candidates.max { modified($0) < modified($1) }
    }

    func loadTranscript(_ url: URL) {
        do {
            cues = try VTT.load(url)
            vttURL = url
            cueSelection = []
            appendLog("Loaded \(cues.count) cues from \(url.lastPathComponent)")
        } catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /*
     * Reads the video's displayed width and height and its duration with
     * ffprobe. Phone video is often stored sideways with a rotation tag; ffmpeg
     * turns it upright when encoding, so for a 90° or 270° rotation the stored
     * width and height are swapped to match what ffmpeg (and the viewer) sees.
     */
    func probe() async {
        guard let url = videoURL, let ffprobe = Tools.find("ffprobe") else { return }
        do {
            // "V:0" (capital V) skips attached pictures, so an audio file's cover art isn't taken for video.
            let (status, output) = try await ProcessRunner.run(ffprobe, [
                "-v", "error", "-select_streams", "V:0",
                "-show_entries", "stream=width,height:stream_side_data=rotation:stream_tags=rotate:format=duration",
                "-of", "json", url.path,
            ]) { _, _ in }
            guard status == 0 else { return }
            // A slower probe of a video that's since been replaced mustn't overwrite the new one's values.
            guard videoURL == url else { return }
            let data = Data(output.lines.joined(separator: "\n").utf8)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let stream = (json["streams"] as? [[String: Any]])?.first,
               let w = stream["width"] as? Int, let h = stream["height"] as? Int {
                let sideRotation = (stream["side_data_list"] as? [[String: Any]])?
                    .compactMap { ($0["rotation"] as? NSNumber)?.intValue }.first
                let tagRotation = ((stream["tags"] as? [String: Any])?["rotate"] as? String).flatMap { Int($0) }
                let quarterTurns = abs(sideRotation ?? tagRotation ?? 0) % 180 == 90
                videoSize = quarterTurns ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            }
            if let format = json["format"] as? [String: Any],
               let d = format["duration"] as? String, let seconds = Double(d) {
                duration = seconds
            }
            let size = videoSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "audio only"
            appendLog("Source: \(size), \(Timecode.format(duration))")
        } catch {
            appendLog("ffprobe failed: \(error.localizedDescription)")
        }
    }

    /*
     * Files dropped on the window or sent from Finder. Refused while a job
     * runs, because the job would put its results (a transcript, suggested
     * clips) into the newly opened video. Videos open first and subtitle files
     * load after, so a subtitle file dropped with its video isn't cleared when
     * the video opens.
     */
    func handleDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if busy {
            errorMessage = "Wait for the current job to finish, or cancel it, before opening another file."
            return
        }
        let isSubtitle: (URL) -> Bool = { ["vtt", "srt"].contains($0.pathExtension.lowercased()) }
        for url in urls where !isSubtitle(url) { openVideo(url) }
        for url in urls where isSubtitle(url) { loadTranscript(url) }
    }

    // MARK: - Open panels

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose a video or audio file"
        if panel.runModal() == .OK, let url = panel.url { openVideo(url) }
    }

    func chooseTranscript() {
        let panel = NSOpenPanel()
        panel.message = "Choose a VTT or SRT subtitle file"
        panel.directoryURL = videoURL?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { loadTranscript(url) }
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outputDir?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { outputDir = url }
    }

    // MARK: - Playback

    // Play if paused, pause if playing (the space bar).
    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }

    func seek(to seconds: Double, play: Bool = false) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play { player.play() }
    }

    // Plays one clip from start to end, then pauses.
    func preview(_ clip: Clip) {
        guard let player else { return }
        if let previewObserver { player.removeTimeObserver(previewObserver) }
        seek(to: clip.start, play: true)
        previewObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: clip.end, preferredTimescale: 600))], queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                player.pause()
                if let observer = self.previewObserver { player.removeTimeObserver(observer) }
                self.previewObserver = nil
            }
        }
    }

    // MARK: - Clip editing

    // A new clip covering the selected transcript lines.
    /*
     * Replaces the clip list as one undoable step named actionName ("Delete
     * Clip", "Add Clip"...), so ⌘Z puts the old list back and ⇧⌘Z redoes it.
     * Typing in a clip's title or time fields uses the text field's own undo.
     */
    func setClips(_ newValue: [Clip], actionName: String) {
        let old = clips
        clips = newValue
        clipSelection = clipSelection.filter { id in newValue.contains { $0.id == id } }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setClips(old, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
    }

    // Applies one change to the clip list, kept in time order, as an undoable step.
    func changeClips(_ actionName: String, _ change: (inout [Clip]) -> Void) {
        var updated = clips
        change(&updated)
        setClips(updated.sorted { $0.start < $1.start }, actionName: actionName)
    }

    // A new clip covering the selected transcript lines.
    func addClipFromSelection() {
        let picked = cues.filter { cueSelection.contains($0.id) }
        guard let first = picked.min(by: { $0.start < $1.start }),
              let last = picked.max(by: { $0.end < $1.end }) else { return }
        let text = picked.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        let title = text.split(separator: " ").prefix(6).joined(separator: " ")
        let clip = Clip(title: title, start: first.start, end: last.end, quote: text)
        changeClips("Add Clip") { $0.append(clip) }
        clipSelection = [clip.id]
    }

    // A new 15-second clip starting at the playhead.
    func addClipAtPlayhead() {
        let end = duration > 0 ? min(duration, currentTime + 15) : currentTime + 15
        let clip = Clip(title: "Clip at \(Timecode.format(currentTime))", start: currentTime, end: end)
        changeClips("Add Clip") { $0.append(clip) }
        clipSelection = [clip.id]
    }

    func delete(_ clip: Clip) {
        changeClips("Delete Clip") { $0.removeAll { $0.id == clip.id } }
    }

    func clearClips() {
        setClips([], actionName: "Clear Clips")
    }

    func setStart(of clip: Clip, to seconds: Double) {
        changeClips("Set Clip Start") { list in
            if let i = list.firstIndex(where: { $0.id == clip.id }) { list[i].start = seconds }
        }
    }

    func setEnd(of clip: Clip, to seconds: Double) {
        changeClips("Set Clip End") { list in
            if let i = list.firstIndex(where: { $0.id == clip.id }) { list[i].end = seconds }
        }
    }

    // MARK: - Selected clips (menu commands and the Delete key)

    var selectedClips: [Clip] {
        clips.filter { clipSelection.contains($0.id) }
    }

    func deleteSelected() {
        let ids = clipSelection
        guard !ids.isEmpty else { return }
        changeClips(ids.count == 1 ? "Delete Clip" : "Delete Clips") { $0.removeAll { ids.contains($0.id) } }
    }

    // Copies of the selected clips, each with a new id, selected afterward.
    func duplicateSelected() {
        let copies = selectedClips.map { clip -> Clip in
            var copy = clip
            copy.id = UUID()
            copy.title = clip.title + " copy"
            return copy
        }
        guard !copies.isEmpty else { return }
        changeClips(copies.count == 1 ? "Duplicate Clip" : "Duplicate Clips") { $0 += copies }
        clipSelection = Set(copies.map(\.id))
    }

    func previewSelected() {
        if let clip = selectedClips.first { preview(clip) }
    }

    // MARK: - Output folder

    var outputExists: Bool {
        outputDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func revealOutput() {
        if let outputDir, outputExists { NSWorkspace.shared.activateFileViewerSelecting([outputDir]) }
    }

    // MARK: - Clip list persistence

    private var clipsFile: URL? {
        videoURL?.deletingPathExtension().appendingPathExtension("clips.json")
    }

    private func saveClips() {
        guard !loadingClips, let file = clipsFile else { return }
        if clips.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(clips).write(to: file, options: .atomic)
    }

    private func loadClips() {
        guard let file = clipsFile, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Clip].self, from: data) else { return }
        clips = saved
        appendLog("Restored \(saved.count) clips from \(file.lastPathComponent)")
    }
}
