import AppKit
import Foundation

/*
 * The skill's steps, each run as a job: download from any URL (yt-dlp), transcribe
 * (mlx_whisper, optionally with pyannote diarization), suggest highlights
 * (Claude), denoise (ffmpeg afftdn) and export clips (ffmpeg).
 */
extension AppState {
    // MARK: - Step 0a: download a video from a URL

    func download(_ urlString: String) {
        startJob("Download") {
            let ytdlp = try Tools.require("yt-dlp")
            let ffmpeg = try Tools.require("ffmpeg")
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            /*
             * yt-dlp reads YouTube, Vimeo, most news sites and direct file links.
             * Safari cookies get past YouTube's bot check and into sites you're
             * logged into in Safari. The format string prefers H.264 (YouTube's
             * default AV1/VP9 won't play in QuickTime), then falls back to the
             * best a site offers. --print after_move:filepath prints the finished
             * file's path; --progress and --newline keep the progress lines that
             * --print would otherwise hide.
             */
            let browser = Pref.string(Pref.cookieBrowser, "safari")
            let downloadArgs = [
                "-f", "bestvideo[vcodec^=avc][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4][vcodec!=av1][vcodec!=vp9]+bestaudio[ext=m4a]/best[ext=mp4]/bestvideo+bestaudio/best",
                "--merge-output-format", "mp4",
                // Keep no yt-dlp cache on disk, and never a download archive (yt-dlp keeps none unless asked).
                "--no-cache-dir",
                "--ffmpeg-location", ffmpeg,
                "--concurrent-fragments", "5",
                "--print", "after_move:filepath",
                "--progress", "--newline",
                "-o", downloads.path + "/%(title)s.%(ext)s",
                urlString,
            ]
            var lines: [String]
            do {
            if browser == "none" {
                lines = try await self.exec(ytdlp, downloadArgs, private: true)
            } else {
                do {
                    lines = try await self.exec(ytdlp, ["--cookies-from-browser", browser] + downloadArgs, private: true)
                } catch ToolError.failed(_, _, let tail) where tail.contains("Operation not permitted") && tail.contains("Cookies") {
                    /*
                     * macOS keeps Safari's cookie file private to apps with Full
                     * Disk Access. Most sites don't need cookies, so try again
                     * without them before giving up.
                     */
                    self.appendLog("macOS blocked reading \(browser) cookies; retrying without cookies.")
                    do {
                        lines = try await self.exec(ytdlp, downloadArgs, private: true)
                    } catch {
                        throw ToolError.message("""
                        The download needs browser cookies, but macOS won't let this app read Safari's.
                        Either choose Chrome or Firefox under "Cookies from" in Settings (⌘,), or give Speech Clip Extractor Full Disk Access in System Settings > Privacy & Security > Full Disk Access.

                        \(error.localizedDescription)
                        """)
                    }
                }
            }
            } catch ToolError.failed(_, _, let tail) where tail.contains("Unsupported URL") {
                // yt-dlp has no extractor for the site and found no video file on the page.
                throw ToolError.message("""
                This site isn't supported by yt-dlp, so the app can't download from it.

                If you have the video file itself, open it or drop it on the window instead. Updating yt-dlp (brew upgrade yt-dlp) sometimes adds support for new sites.
                """)
            }
            guard let path = lines.last(where: { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }) else {
                throw ToolError.message("yt-dlp finished but didn't report where it saved the file.")
            }
            var file = URL(fileURLWithPath: path)

            // Sites that only offer AV1, VP9 or the like get re-encoded to H.264, as the skill does.
            let codec = try await self.videoCodec(file)
            if let codec, !["h264", "hevc"].contains(codec) {
                self.appendLog("Video is \(codec), which QuickTime can't play; re-encoding to H.264.")
                let h264 = file.deletingPathExtension().appendingPathExtension("h264.mp4")
                try await self.exec(ffmpeg, [
                    "-nostdin", "-y", "-i", file.path,
                    "-c:v", "libx264", "-preset", "fast", "-crf", "23",
                    "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                    "-c:a", "aac", "-b:a", "128k", h264.path,
                ])
                file = h264
            }
            self.openVideo(file)
        }
    }

    // The first video stream's codec name ("h264", "vp9"...), or nil for audio-only files.
    private func videoCodec(_ file: URL) async throws -> String? {
        let ffprobe = try Tools.require("ffprobe")
        let (status, output) = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name", "-of", "csv=p=0", file.path,
        ]) { _, _ in }
        guard status == 0 else { return nil }
        return output.lines.first?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Step 0b: transcribe

    func transcribe(model: String, diarize: Bool, niceLevel: Int, language: String) {
        guard let video = videoURL else { return }
        startJob(diarize ? "Transcribe + diarize" : "Transcribe") {
            let dir = video.deletingLastPathComponent()
            // "<video>.vtt", or "<video>-whisper.vtt" if that name is taken by an existing transcript.
            var name = video.deletingPathExtension().lastPathComponent
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name + ".vtt").path) {
                name += "-whisper"
            }
            let vtt = dir.appendingPathComponent(name + ".vtt")
            let lang = language.trimmingCharacters(in: .whitespaces).isEmpty ? "en" : language

            if diarize {
                try await self.runDiarization(video: video, vtt: vtt, model: model, niceLevel: niceLevel, language: lang)
            } else {
                /*
                 * --condition-on-previous-text False stops the hallucination loops
                 * where Whisper repeats a phrase over quiet or noisy stretches.
                 */
                let whisper = try Tools.require("mlx_whisper")
                try await self.exec("/usr/bin/env", self.offlineIfCached(model) + [
                    "/usr/bin/nice", "-n", String(niceLevel), whisper, video.path,
                    "--model", model,
                    "--output-format", "vtt",
                    "--output-dir", dir.path,
                    "--output-name", name,
                    "--language", lang,
                    "--condition-on-previous-text", "False",
                    // A progress bar (shown in the status line) instead of every transcribed line and a settings dump.
                    "--verbose", "False",
                ])
            }
            self.loadTranscript(vtt)
            self.announce("Transcript ready", "\(self.cues.count) lines from \(video.lastPathComponent). Next, pick the clips you want.")
        }
    }

    /*
     * Two separate Python processes, as in the skill: Whisper's model memory is
     * freed when the first exits, so diarization doesn't stack on top of it.
     * The transcript JSON from stage 1 is kept, so a diarization failure never
     * costs the Whisper run.
     */
    private func runDiarization(video: URL, vtt: URL, model: String, niceLevel: Int, language: String) async throws {
        let tokenPath = NSHomeDirectory() + "/.cache/huggingface/token"
        guard FileManager.default.fileExists(atPath: tokenPath) else {
            throw ToolError.message("Diarization needs a HuggingFace token at ~/.cache/huggingface/token.")
        }
        let python = try await findDiarizationPython()
        let script = try writeDiarizationScript()
        let transcriptJSON = vtt.deletingPathExtension().appendingPathExtension("transcript.json")

        // Stage 1 can be skipped when an earlier run already saved the Whisper transcript.
        if FileManager.default.fileExists(atPath: transcriptJSON.path) {
            appendLog("Reusing \(transcriptJSON.lastPathComponent) from an earlier run (delete it to re-transcribe).")
        } else {
            try await exec("/usr/bin/env", offlineIfCached(model) + [
                "/usr/bin/nice", "-n", String(niceLevel), python, script.path, "transcribe", video.path, transcriptJSON.path, model, language,
            ])
        }
        appendLog("Diarizing. There's no progress bar for this stage; silence after \"Using device\" is normal.")
        try await exec("/usr/bin/nice", [
            "-n", String(niceLevel), python, script.path, "diarize", video.path, transcriptJSON.path, vtt.path,
        ])
    }

    /*
     * Whisper models load through huggingface_hub, which checks HuggingFace
     * online on every run even when the model is already downloaded (the
     * "Fetching 4 files" line). When the model is in the local cache,
     * HF_HUB_OFFLINE=1 makes it load straight from disk with no network
     * call. A model that isn't cached yet still downloads normally.
     */
    func offlineIfCached(_ model: String) -> [String] {
        let folder = "models--" + model.replacingOccurrences(of: "/", with: "--")
        let snapshots = NSHomeDirectory() + "/.cache/huggingface/hub/\(folder)/snapshots"
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: snapshots))?.isEmpty == false
        return cached ? ["HF_HUB_OFFLINE=1"] : []
    }

    /*
     * The Homebrew Python that has both mlx_whisper and pyannote installed.
     * The skill notes python3.13 doesn't exist on this Mac; 3.11 is the one.
     */
    private func findDiarizationPython() async throws -> String {
        for name in ["python3.11", "python3.12", "python3.13", "python3"] {
            guard let path = Tools.find(name) else { continue }
            appendLog("Checking \(path) for mlx_whisper and pyannote…")
            let (status, _) = try await ProcessRunner.run(path, ["-c", "import mlx_whisper, pyannote.audio"]) { _, _ in }
            if status == 0 { return path }
        }
        throw ToolError.message("No Python found with both mlx_whisper and pyannote.audio. Install them with: /opt/homebrew/bin/pip3.11 install mlx-whisper pyannote.audio --break-system-packages")
    }

    private func writeDiarizationScript() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeechClipExtractor", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let url = support.appendingPathComponent("transcribe-with-diarization.py")
        try diarizationScript.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Step 2: suggest highlights with the chosen AI provider

    func suggestHighlights(guidance: String, count: Int, replace: Bool) {
        guard !cues.isEmpty else { return }
        let provider = Provider.current
        guard Keychain.exists(provider.keychainAccount) else {
            errorMessage = "Add your \(provider.name) API key in Settings (⌘,) first."
            return
        }
        let cues = self.cues
        startJob("Suggest highlights") {
            self.appendLog("Sending \(cues.count) cues to \(provider.currentModel) on \(provider.name) (effort \(Provider.currentEffort))…")
            let result = try await HighlightService.suggest(cues: cues, guidance: guidance, count: count)
            self.appendLog("\(result.model) used \(result.inputTokens) input and \(result.outputTokens) output tokens.")
            let suggested = result.highlights.map {
                Clip(title: $0.title, start: $0.start_seconds, end: $0.end_seconds, quote: $0.quote, why: $0.why)
            }
            self.setClips(((replace ? [] : self.clips) + suggested).sorted { $0.start < $1.start }, actionName: "Suggest Highlights")
            self.appendLog("Added \(suggested.count) suggested clips.")
        }
    }

    // MARK: - Audio noise removal

    /*
     * FFT denoiser on the whole source, video stream copied. nf is the noise
     * floor in dB: lower (e.g. -35) removes more but can hurt speech. The
     * cleaned file becomes the source; the transcript and clips carry over.
     */
    func denoise(noiseFloor: Int) {
        guard let video = videoURL else { return }
        startJob("Remove noise") {
            let ffmpeg = try Tools.require("ffmpeg")
            let out = video.deletingPathExtension()
                .appendingPathExtension("clean")
                .appendingPathExtension(video.pathExtension.isEmpty ? "mp4" : video.pathExtension)
            try await self.exec(ffmpeg, [
                "-nostdin", "-y", "-i", video.path,
                "-af", "afftdn=nf=\(noiseFloor)",
                "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                out.path,
            ])
            self.openVideo(out, keepWork: true)
        }
    }

    // MARK: - Steps 4-5: export clips

    func exportClips() {
        guard let video = videoURL, let outDir = outputDir else { return }
        let chosen = clips.filter { $0.include && $0.duration > 0 }
        guard !chosen.isEmpty else {
            errorMessage = "Tick at least one clip with an end time after its start."
            return
        }
        let vertical = exportVertical, writeVTT = exportVTT, burn = burnCaptions
        let reencode = self.reencode, keepSpeakers = keepSpeakerLabels
        let cues = self.cues, size = videoSize
        let font = Pref.string(Pref.captionFont, "Proxima Nova")
        let fontSize = UserDefaults.standard.object(forKey: Pref.captionSize) as? Int ?? 22

        if vertical && size == nil {
            errorMessage = "This source has no video stream, so there's nothing to crop vertically."
            return
        }
        if burn && cues.isEmpty {
            errorMessage = "Burning captions needs a transcript."
            return
        }

        startJob("Export \(chosen.count) clip\(chosen.count == 1 ? "" : "s")") {
            let ffmpeg = try Tools.require("ffmpeg")
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            for (index, clip) in chosen.enumerated() {
                try Task.checkCancellation()
                let base = String(format: "%02d-", index + 1) + slugify(clip.title)
                self.status = "Clip \(index + 1) of \(chosen.count): \(clip.title)"
                self.appendLog("Clip \(index + 1): \(clip.title) (\(Timecode.format(clip.start))–\(Timecode.format(clip.end)))")
                var made: [URL] = []

                /*
                 * Horizontal, always. Stream copy keeps the original quality but
                 * cuts on keyframes; re-encode when the cut must be frame-accurate.
                 * -map_chapters -1 stops source chapters from inflating the
                 * duration QuickTime shows.
                 */
                let horizontal = outDir.appendingPathComponent(base + ".mp4")
                var args = ["-nostdin", "-y", "-ss", String(clip.start), "-to", String(clip.end),
                            "-i", video.path, "-map_chapters", "-1"]
                args += reencode ? self.h264Args() : ["-c", "copy"]
                try await self.exec(ffmpeg, args + [horizontal.path])
                made.append(horizontal)

                // Vertical 9:16 center crop: width = height × 9/16 (kept even), centered.
                if vertical, let size {
                    let h = Int(size.height), w = Int(size.width)
                    var cropW = Int((Double(h) * 9 / 16).rounded())
                    cropW -= cropW % 2
                    let x = max(0, (w - cropW) / 2)
                    let verticalURL = outDir.appendingPathComponent(base + "-vertical.mp4")
                    try await self.exec(ffmpeg, [
                        "-nostdin", "-y", "-ss", String(clip.start), "-to", String(clip.end),
                        "-i", video.path, "-vf", "crop=\(cropW):\(h):\(x):0", "-map_chapters", "-1",
                    ] + self.h264Args() + [verticalURL.path])
                    made.append(verticalURL)
                }

                // Re-zeroed subtitles for this clip (also needed for burning).
                let vttName = base + ".vtt"
                if (writeVTT || burn) && !cues.isEmpty {
                    let clipCues = VTT.clipCues(cues, start: clip.start, end: clip.end)
                    try VTT.write(clipCues, to: outDir.appendingPathComponent(vttName), keepSpeakers: keepSpeakers)
                    self.appendLog("Wrote \(vttName) (\(clipCues.count) cues)")
                }

                /*
                 * Open captions with ffmpeg's subtitles filter (Homebrew ffmpeg 9
                 * has libass). The filter's path is parsed by ffmpeg's filter
                 * syntax, so ffmpeg runs from the output folder with the bare,
                 * slugified filename. FontSize is in libass units, which scale
                 * with the video's height.
                 */
                if burn {
                    let style = "FontName=\(font),Bold=1,FontSize=\(fontSize),PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,BorderStyle=1,Outline=2,Shadow=0,MarginV=30"
                    for source in made {
                        let captioned = source.deletingPathExtension().lastPathComponent + "-captioned.mp4"
                        try await self.exec(ffmpeg, [
                            "-nostdin", "-y", "-i", source.lastPathComponent,
                            "-vf", "subtitles=\(vttName):fontsdir=/Library/Fonts:force_style='\(style)'",
                            "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                            "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                            "-c:a", "aac", "-b:a", "160k", captioned,
                        ], cwd: outDir)
                    }
                    // The VTT was only a means to the burn unless the user asked for it.
                    if !writeVTT { try? FileManager.default.removeItem(at: outDir.appendingPathComponent(vttName)) }
                }
            }
            self.appendLog("Saved to \(outDir.path)")
            self.notice = "Exported \(chosen.count) clip\(chosen.count == 1 ? "" : "s") to \(outDir.lastPathComponent)."
            NSWorkspace.shared.open(outDir)
        }
    }

    // H.264 settings that QuickTime and Photos play: yuv420p plus faststart.
    private func h264Args() -> [String] {
        ["-c:v", "libx264", "-preset", "fast", "-crf", "23", "-pix_fmt", "yuv420p",
         "-movflags", "+faststart", "-c:a", "aac", "-b:a", "160k"]
    }
}

/*
 * The skill's diarization script, with the Whisper model and language passed
 * as arguments. Written to Application Support before each run.
 *   transcribe <audio> <transcript.json> <model> <language>
 *   diarize    <audio> <transcript.json> <output.vtt>
 */
private let diarizationScript = #"""
#!/usr/bin/env python3
"""
Transcribe with mlx-whisper + pyannote diarization -> VTT with [SPEAKER_XX]: labels.
Two separate processes, so Whisper's model memory is freed when the first exits.
Uses Apple MPS (Metal GPU) for diarization when available.
"""
import sys, os, json

def seconds_to_vtt_ts(s):
    h = int(s // 3600); m = int((s % 3600) // 60); sec = s % 60
    return f"{h:02d}:{m:02d}:{sec:06.3f}"

def assign_speaker(seg_start, seg_end, diarization_segments):
    overlap_by_speaker = {}
    for (ts, te, speaker) in diarization_segments:
        overlap = max(0.0, min(seg_end, te) - max(seg_start, ts))
        if overlap > 0:
            overlap_by_speaker[speaker] = overlap_by_speaker.get(speaker, 0.0) + overlap
    return max(overlap_by_speaker, key=overlap_by_speaker.get) if overlap_by_speaker else "SPEAKER_UNK"

stage, audio_path, transcript_json = sys.argv[1], sys.argv[2], sys.argv[3]

if stage == "transcribe":
    model = sys.argv[4] if len(sys.argv) > 4 else "mlx-community/whisper-large-v3-mlx"
    language = sys.argv[5] if len(sys.argv) > 5 else "en"
    print(f"Step 1: Transcribing with {model}...", flush=True)
    import mlx_whisper
    # condition_on_previous_text=False prevents hallucination loops on silent or unclear audio.
    result = mlx_whisper.transcribe(audio_path, path_or_hf_repo=model, language=language, condition_on_previous_text=False, verbose=False)
    segments = [{"start": seg["start"], "end": seg["end"], "text": seg["text"].strip()} for seg in result["segments"]]
    json.dump(segments, open(transcript_json, "w"))
    print(f"Whisper segments: {len(segments)}", flush=True)
    sys.exit(0)

output_vtt = sys.argv[4]
segments = json.load(open(transcript_json))
hf_token = open(os.path.expanduser("~/.cache/huggingface/token")).read().strip()

print("Step 2: Running pyannote diarization...", flush=True)
import torch
from pyannote.audio import Pipeline
import torchaudio

device = torch.device("mps") if torch.backends.mps.is_available() else torch.device("cpu")
print(f"Using device: {device}", flush=True)

pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", token=hf_token)
pipeline.to(device)

waveform, sample_rate = torchaudio.load(audio_path)
diarization = pipeline({"waveform": waveform, "sample_rate": sample_rate})

# pyannote 3.x returns an Annotation; 4.x a DiarizeOutput dataclass.
annotation = diarization.speaker_diarization if hasattr(diarization, "speaker_diarization") else diarization
diar_segs = [(t.start, t.end, spk) for t, _, spk in annotation.itertracks(yield_label=True)]

print("Step 3: Writing VTT...", flush=True)
lines = ["WEBVTT", ""]
for seg in segments:
    if not seg["text"]: continue
    spk = assign_speaker(seg["start"], seg["end"], diar_segs)
    lines += [f"{seconds_to_vtt_ts(seg['start'])} --> {seconds_to_vtt_ts(seg['end'])}", f"[{spk}]: {seg['text']}", ""]
open(output_vtt, "w").write("\n".join(lines))
print(f"Done: {output_vtt}", flush=True)
"""#
