import SwiftUI

// MARK: - Download

struct DownloadSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @AppStorage(Pref.cookieBrowser) private var cookieBrowser = "safari"

    var body: some View {
        Form {
            Text("Download a video").font(.headline)
            TextField("Video URL", text: $url, prompt: Text("https://…"))
            Text("Any page or file yt-dlp can read: YouTube, Vimeo, news sites, a direct .mp4 link and more. Uses your browser's cookies (choose which in Settings), so sites you're logged into work. Saves to ~/Downloads, re-encoded to H.264 if needed so QuickTime can play it.")
                .font(.caption).foregroundStyle(.secondary)
            if cookieBrowser == "safari" {
                SafariCookieNotice()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    app.download(url.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!url.lowercased().hasPrefix("http"))
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Transcribe

struct TranscribeSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.whisperModel) private var model = "mlx-community/whisper-large-v3-mlx"
    @AppStorage(Pref.niceLevel) private var niceLevel = 10
    @State private var diarize = false
    @State private var language = "en"

    private var speedHelp: String {
        switch niceLevel {
        case 0: return "Finishes soonest, but other apps may feel sluggish while it runs."
        case 19: return "Keeps the Mac responsive for other work; takes longer if the Mac is busy."
        default: return "A balance: the Mac stays usable and the transcript doesn't take much longer."
        }
    }

    var body: some View {
        Form {
            Text("Transcribe with mlx-whisper").font(.headline)
            Picker("Model", selection: $model) {
                Text("large-v3 (2.9 GB, most accurate)").tag("mlx-community/whisper-large-v3-mlx")
                Text("large-v3-turbo (~1 GB, faster)").tag("mlx-community/whisper-large-v3-turbo")
            }
            TextField("Language", text: $language).frame(width: 160)
            Toggle("Speaker diarization ([SPEAKER_00]: labels)", isOn: $diarize)
            if diarize {
                Text("Runs pyannote after Whisper, using your HuggingFace token. Labels are per video, and similar voices on one mic can be merged into one label, so check speakers against the video before attributing a quote.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Each choice is a nice level: 0 runs at normal priority, 19 at the lowest.
            Picker("Speed", selection: $niceLevel) {
                Text("Faster").tag(0)
                Text("Medium").tag(10)
                Text("Slower").tag(19)
            }
            .pickerStyle(.segmented)
            Text(speedHelp).font(.caption).foregroundStyle(.secondary)
            if !app.cues.isEmpty {
                Text("A transcript is already loaded; the new one will replace it in the window.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Transcribe") {
                    app.transcribe(model: model, diarize: diarize, niceLevel: niceLevel, language: language)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// MARK: - Suggest highlights

struct SuggestSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var guidance = ""
    @State private var count = 1
    @State private var replace = false

    // Seconds of speech: from the first transcript line to the last.
    private var speechSeconds: Double {
        guard let first = app.cues.map(\.start).min(), let last = app.cues.map(\.end).max() else { return 0 }
        return max(0, last - first)
    }

    /*
     * About one clip per 30 seconds of speech, from 1 to 30. Asking a short
     * transcript for many clips made a model return a blank placeholder clip.
     */
    private var suggestedCount: Int {
        min(30, max(1, Int((speechSeconds / 30).rounded(.up))))
    }

    // "16-second", "4-minute" or "1-hour 20-minute", for the caption.
    private var lengthDescription: String {
        let total = Int(speechSeconds.rounded())
        if total < 60 { return "\(total)-second" }
        let minutes = Int((speechSeconds / 60).rounded())
        if minutes < 60 { return "\(minutes)-minute" }
        return "\(minutes / 60)-hour \(minutes % 60)-minute"
    }

    var body: some View {
        Form {
            Text("Suggest highlights with AI").font(.headline)
            Text("Sends the whole transcript (\(app.cues.count) cues) to \(Provider.current.currentModel) on \(Provider.current.name). This uses your API key and costs money. Change the provider or model in Settings (⌘,).")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Up to \(count) clip\(count == 1 ? "" : "s")", value: $count, in: 1...30)
            Text("Suggested for a \(lengthDescription) transcript. The AI may return fewer if it finds fewer good moments.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Guidance (optional)", text: $guidance, prompt: Text("e.g. focus on housing; skip the thank-yous"), axis: .vertical)
                .lineLimit(2...4)
            Toggle("Replace the current clips", isOn: $replace)
                .disabled(app.clips.isEmpty)
            SpendingLimitTip(provider: Provider.current)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Suggest") {
                    app.suggestHighlights(guidance: guidance, count: count, replace: replace)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { count = suggestedCount }
    }
}

// A short spending-limit tip with a link to the provider's page for it.
struct SpendingLimitTip: View {
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Gray tip text that wraps instead of running off the window's edge.
            Text(provider.spendingLimitTip)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The link keeps the accent color, with an arrow so it reads as a link.
            Link(destination: provider.spendingLimitPage) {
                Label("Set a limit with \(provider.name)", systemImage: "arrow.up.right.square")
            }
            .help(provider.spendingLimitPage.absoluteString)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .font(.caption)
    }
}

// MARK: - Denoise

struct DenoiseSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var noiseFloor = -25.0

    var body: some View {
        Form {
            Text("Remove background noise").font(.headline)
            Text("Runs ffmpeg's afftdn denoiser on the whole source and switches to the cleaned copy (\"…clean.mp4\"). Your transcript and clips carry over.")
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: $noiseFloor, in: -40 ... -15, step: 1) {
                Text("Noise floor: \(Int(noiseFloor)) dB")
            }
            Text("Lower values remove more noise but can make speech sound watery. -25 is a good start.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove Noise") {
                    app.denoise(noiseFloor: Int(noiseFloor))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Pref.provider) private var providerRaw = "anthropic"
    @AppStorage(Pref.claudeEffort) private var effort = "medium"
    @AppStorage(Pref.captionFont) private var font = "Proxima Nova"
    @AppStorage(Pref.captionSize) private var fontSize = 22
    @AppStorage(Pref.cookieBrowser) private var cookieBrowser = "safari"

    private let tools = ["ffmpeg", "ffprobe", "yt-dlp", "mlx_whisper", "python3.11"]

    private var provider: Provider { Provider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        Form {
            Section("AI for Suggest Highlights") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(Provider.allCases) { Text($0.name).tag($0.rawValue) }
                }
                // Rebuilt for each provider, so its key and model fields start fresh.
                ProviderSettings(provider: provider).id(provider)
                Picker("Effort", selection: $effort) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .pickerStyle(.segmented)
                Text("Higher effort thinks longer: better picks, slower and pricier. Not every OpenRouter model uses it, and DeepInfra ignores it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Picker("Cookies from", selection: $cookieBrowser) {
                    Text("Safari").tag("safari")
                    Text("Chrome").tag("chrome")
                    Text("Firefox").tag("firefox")
                    Text("Edge").tag("edge")
                    Text("Brave").tag("brave")
                    Text("None").tag("none")
                }
                Text("YouTube needs cookies to get past its bot check; be logged into YouTube in that browser. Chrome asks for your Keychain password the first time (click Always Allow). Firefox needs nothing.")
                    .font(.caption).foregroundStyle(.secondary)
                if cookieBrowser == "safari" {
                    SafariCookieNotice()
                }
            }
            Section("Burned-in captions") {
                TextField("Font name", text: $font)
                Stepper("Font size: \(fontSize)", value: $fontSize, in: 10...60)
                Text("libass units; about 22 looks right on most videos.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Tools found") {
                ForEach(tools, id: \.self) { name in
                    HStack {
                        Image(systemName: Tools.find(name) == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(Tools.find(name) == nil ? .red : .green)
                        Text(name)
                        Spacer()
                        Text(Tools.find(name) ?? "not found").foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .onAppear {
            if !["low", "medium", "high"].contains(effort) { effort = "high" }
        }
    }
}

/*
 * One provider's key and model. The key field is never filled from the
 * Keychain: a saved key only shows as "saved", with Replace and Remove.
 * The model is a text field (type any model ID) with a menu of the
 * provider's current models, fetched live.
 */
struct ProviderSettings: View {
    let provider: Provider
    @State private var newKey = ""
    @State private var hasKey = false
    @State private var replacing = false
    // Shown under the key after saving, when the key was also cleared from the clipboard.
    @State private var clearedClipboard = false
    @State private var model = ""
    @State private var models: [ModelInfo] = []
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if hasKey && !replacing {
                HStack {
                    Label(clearedClipboard
                          ? "\(provider.name) API key saved in your Keychain, and cleared from the clipboard."
                          : "\(provider.name) API key saved in your Keychain.", systemImage: "key.fill")
                    Spacer()
                    Button("Replace…") { replacing = true }
                    Button("Remove", role: .destructive) {
                        Keychain.delete(provider.keychainAccount)
                        hasKey = false
                    }
                }
                SpendingLimitTip(provider: provider)
            } else {
                HStack {
                    SecureField("\(provider.name) API key", text: $newKey)
                    Button("Save") {
                        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        Keychain.save(key, account: provider.keychainAccount)
                        /*
                         * If the key was pasted, it's still on the clipboard. Clear the
                         * clipboard only when it holds this exact key, so nothing else the
                         * user copied is lost. (A clipboard-history app keeps its own copy.)
                         */
                        let pasteboard = NSPasteboard.general
                        if pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == key {
                            pasteboard.clearContents()
                            clearedClipboard = true
                        }
                        // Drop the typed copy as soon as it's in the Keychain.
                        newKey = ""
                        hasKey = Keychain.exists(provider.keychainAccount)
                        replacing = false
                        if provider == .anthropic { Task { await loadModels() } }
                    }
                    .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if replacing {
                        Button("Cancel") { newKey = ""; replacing = false }
                    }
                }
                Link("Get a \(provider.name) key", destination: provider.keyPage).font(.caption)
            }

            HStack {
                TextField("Model", text: $model, prompt: Text(provider.defaultModel))
                    .onSubmit(saveModel)
                    .onChange(of: model) { _, _ in saveModel() }
                Menu {
                    if models.isEmpty {
                        Text(loading ? "Loading…" : (loadError ?? "No models loaded"))
                    }
                    ForEach(models) { info in
                        Button(info.label == info.id ? info.id : "\(info.label)  (\(info.id))") { model = info.id }
                    }
                    Divider()
                    Button("Refresh List") { Task { await loadModels() } }
                    Button("Use Default (\(provider.defaultModel))") { model = provider.defaultModel }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose from \(provider.name)'s current models")
                .accessibilityLabel("Choose a model")
            }
            Text(models.isEmpty
                 ? "Type any model ID, or pick one from the list button."
                 : "\(models.count) models available. Pick one from the list button, or type any model ID.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            hasKey = Keychain.exists(provider.keychainAccount)
            model = Pref.string(provider.modelPref, provider.defaultModel)
        }
        .task { await loadModels() }
    }

    private func saveModel() {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: provider.modelPref)
    }

    private func loadModels() async {
        loading = true
        defer { loading = false }
        do {
            models = try await ModelCatalog.fetch(provider)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
