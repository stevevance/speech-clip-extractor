import AppKit
import SwiftUI

/*
 * Checking that this Mac has what each feature needs (Homebrew tools,
 * Python packages, tokens, permissions) and telling the user how to get
 * whatever is missing.
 */

// MARK: - Safari cookie permission

enum SafariCookies {
    static let path = NSHomeDirectory() + "/Library/Cookies/Cookies.binarycookies"

    /*
     * macOS shows no prompt for Safari's cookies: they're covered by Full
     * Disk Access, which only the user can grant in System Settings. Opening
     * the file is the only way to find out; without access it fails with
     * "Operation not permitted". yt-dlp runs as this app's child process,
     * so it gets the same answer.
     */
    static var canRead: Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        try? handle.close()
        return true
    }

    // System Settings > Privacy & Security > Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/*
 * A box explaining how to allow Safari cookies, with a button to the right
 * System Settings pane. It checks again whenever the app comes back to the
 * front (after the user flips the switch) and disappears once access works.
 */
struct SafariCookieNotice: View {
    @State private var allowed = SafariCookies.canRead

    var body: some View {
        Group {
            if !allowed {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Safari cookies aren't allowed yet", systemImage: "lock.fill")
                        .font(.callout.bold())
                    Text("macOS doesn't ask for this; you turn it on yourself. In System Settings, open Privacy & Security > Full Disk Access, switch on Speech Clip Extractor (click + to add it if it isn't listed), then come back here. Without it, downloads run without cookies, which most sites don't need but YouTube often does.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open System Settings") { SafariCookies.openFullDiskAccessSettings() }
                        Button("Check Again") { allowed = SafariCookies.canRead }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            allowed = SafariCookies.canRead
        }
    }
}

// MARK: - Setup check

struct SetupItem: Identifiable {
    let id = UUID()
    let name: String
    let neededFor: String
    let ok: Bool
    // Shown when missing: a Terminal command to copy, and/or a note or link.
    var command: String? = nil
    var note: String? = nil
    var link: URL? = nil
    // Missing an essential item opens the setup window at launch.
    var essential = false
}

enum SetupCheck {
    // Set once the first window has run the launch check, so new windows don't repeat it.
    static var checkedAtLaunch = false

    /*
     * Builds the checklist. The Python check imports mlx_whisper and pyannote,
     * which takes a few seconds, so this runs off the main thread.
     */
    static func run() async -> [SetupItem] {
        var items: [SetupItem] = []
        let brew = Tools.find("brew")
        let appleSilicon = isAppleSilicon()

        items.append(SetupItem(
            name: "Apple Silicon Mac", neededFor: "Transcribing (mlx-whisper runs only on M-series chips)",
            ok: appleSilicon,
            note: "This Mac has an Intel chip. Everything except transcribing still works; open an existing VTT instead."
        ))
        items.append(SetupItem(
            name: "Homebrew", neededFor: "Installing the tools below",
            ok: brew != nil,
            note: "Install Homebrew from brew.sh, then come back and check again.",
            link: URL(string: "https://brew.sh"), essential: true
        ))
        items.append(SetupItem(
            name: "ffmpeg", neededFor: "Cutting, cropping, captioning and denoising clips",
            ok: Tools.find("ffmpeg") != nil && Tools.find("ffprobe") != nil,
            command: "brew install ffmpeg", essential: true
        ))
        items.append(SetupItem(
            name: "yt-dlp", neededFor: "Downloading videos from a URL",
            ok: Tools.find("yt-dlp") != nil,
            command: "brew install yt-dlp"
        ))
        if appleSilicon {
            items.append(SetupItem(
                name: "mlx-whisper", neededFor: "Transcribing",
                ok: Tools.find("mlx_whisper") != nil,
                command: "brew install uv && uv tool install --python 3.12 mlx-whisper",
                note: "The first transcription downloads the Whisper model (about 1–3 GB)."
            ))
            items.append(SetupItem(
                name: "pyannote (Python)", neededFor: "Speaker labels when transcribing",
                ok: await diarizationPythonAvailable(),
                command: "brew install python@3.11 && /opt/homebrew/bin/pip3.11 install mlx-whisper pyannote.audio --break-system-packages"
            ))
            items.append(SetupItem(
                name: "HuggingFace token", neededFor: "Speaker labels when transcribing",
                ok: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.cache/huggingface/token"),
                command: "uvx hf auth login",
                note: "Make a free HuggingFace account and an access token, accept the terms on the pyannote/speaker-diarization-3.1 model page, then run the command and paste the token.",
                link: URL(string: "https://huggingface.co/pyannote/speaker-diarization-3.1")
            ))
        }
        // The key for whichever AI provider is chosen in Settings.
        let provider = Provider.current
        items.append(SetupItem(
            name: "\(provider.name) API key", neededFor: "Suggest Highlights",
            ok: Keychain.exists(provider.keychainAccount),
            note: "Get a key from \(provider.name), then paste it in Settings (⌘,). You can switch to Anthropic, OpenRouter or DeepInfra there.",
            link: provider.keyPage
        ))
        return items
    }

    private static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    // A Python that can import both mlx_whisper and pyannote (the same search the transcribe step uses).
    private static func diarizationPythonAvailable() async -> Bool {
        for name in ["python3.11", "python3.12", "python3.13", "python3"] {
            guard let path = Tools.find(name) else { continue }
            if let result = try? await ProcessRunner.run(path, ["-c", "import mlx_whisper, pyannote.audio"], onLine: { _, _ in }),
               result.status == 0 {
                return true
            }
        }
        return false
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [SetupItem] = []
    @State private var checking = true
    @AppStorage(Pref.cookieBrowser) private var cookieBrowser = "safari"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Setup check").font(.title2.bold())
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Check Again") { Task { await refresh() } }.disabled(checking)
            }
            Text("Each feature uses free tools installed on this Mac. Copy a command into Terminal to install anything missing.")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        SetupRow(item: item)
                        Divider()
                    }
                    if cookieBrowser == "safari" {
                        SafariCookieNotice()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        checking = true
        items = await SetupCheck.run()
        checking = false
    }
}

struct SetupRow: View {
    let item: SetupItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(item.ok ? .green : (item.essential ? .red : .orange))
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).bold()
                Text(item.neededFor).font(.caption).foregroundStyle(.secondary)
                if !item.ok {
                    if let note = item.note {
                        Text(note).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    if let command = item.command {
                        HStack {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(6)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                        }
                    }
                    if let link = item.link {
                        Link(link.host ?? link.absoluteString, destination: link).font(.caption)
                    }
                }
            }
        }
    }
}
