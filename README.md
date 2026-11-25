# Speech Clip Extractor

A workflow for extracting highlight clips from speech videos using VTT subtitle files and ffmpeg. Includes horizontal (16:9) and vertical (9:16) crop versions for multi-platform publishing.

It comes two ways: a **Mac app** you can download, and a **Claude Code skill** (`SKILL.md`) that walks Claude through the same steps.

## Mac app

**[Download the latest version from Releases](https://github.com/stevevance/speech-clip-extractor/releases)** (`Speech-Clip-Extractor-x.x.zip`). Requires macOS 15 or later.

The app does the whole workflow in one window:

- Open a video, drop one on the window, or download one from a URL (YouTube, Vimeo, news sites and more, via yt-dlp)
- Transcribe it with Whisper on your Mac, optionally with speaker labels (diarization, explained below)
- Pick clips by selecting transcript lines, or have AI suggest highlights (Anthropic, OpenRouter or DeepInfra, with your own API key)
- Export horizontal and vertical clips, a subtitle file for each clip, and versions with burned-in captions

### What you'll need

- **A Mac with macOS 15 or later.** Transcribing needs an Apple Silicon (M-series) Mac.
- **Free command-line tools** (ffmpeg, yt-dlp, mlx-whisper). The app's Check Setup window lists them and gives the install command for each.
- **An AI API key, only for Suggest Highlights.** Get one from [Anthropic](https://console.anthropic.com/settings/keys) to use Claude, or use [OpenRouter](https://openrouter.ai/settings/keys) or [DeepInfra](https://deepinfra.com/dash/api_keys) instead. These services charge per use. You don't need a key to pick clips yourself from the transcript.
- **A free Hugging Face token, only for speaker labels.** See below.

### Speaker labels (diarization)

*Diarization* means working out **who spoke when**. Whisper turns speech into text but can't tell voices apart. With diarization turned on, the app also runs [pyannote](https://github.com/pyannote/pyannote-audio), which listens for changes in voice and labels each line of the transcript with a speaker, such as `[SPEAKER_00]` or `[SPEAKER_01]`. That helps with hearings, panels, interviews and anything else with more than one person talking, so you can tell whose quote you're clipping. For a single speaker, leave it off.

The labels are numbered, not named: compare them with the video to see who each one is. Two similar voices on the same microphone can end up sharing a label, so check before attributing a quote.

pyannote's models are free but gated: Hugging Face asks you to accept their terms first. To set it up once:

1. Make a free account at [huggingface.co](https://huggingface.co/join).
2. Accept the terms on both model pages: [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1) and [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0).
3. Create an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) (the "Read" type is enough).
4. Save it on your Mac by running this in Terminal and pasting the token when asked (it uses [uv](https://docs.astral.sh/uv/); install that first with `brew install uv` if needed):

   ```bash
   uvx --from huggingface_hub hf auth login
   ```

   The token is saved in `~/.cache/huggingface/token`, where the app finds it. Never share it or commit it to a repository.
5. Install pyannote with the command the app's **Check Setup…** window gives you.

### Installing it

1. Download the zip from [Releases](https://github.com/stevevance/speech-clip-extractor/releases), unzip it, and move **Speech Clip Extractor** to your Applications folder.
2. Open it. Because the app isn't signed with an Apple Developer ID yet, macOS shows **"Speech Clip Extractor.app" Not Opened: Apple could not verify "Speech Clip Extractor.app" is free of malware…** Click **Done** (not Move to Trash).
3. Open **System Settings > Privacy & Security** and scroll down to Security. Next to "Speech Clip Extractor.app was blocked to protect your Mac," click **Open Anyway**, then confirm with your password or Touch ID. The button appears for about an hour after you try to open the app. You only do this once.

   Prefer Terminal? This does the same thing:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Speech Clip Extractor.app"
   ```
4. Choose **Check Setup…** from the app menu. It lists the free tools the app uses (ffmpeg, yt-dlp, mlx-whisper and more) and gives the Homebrew command to install anything missing. Transcribing needs an Apple Silicon Mac.
5. To use Suggest Highlights, choose your AI provider in **Settings** (⌘,) and paste its API key. Keys are stored only in your Mac's Keychain.
6. For speaker labels, set up a Hugging Face token as described in [Speaker labels (diarization)](#speaker-labels-diarization).

## What the skill does

1. Reads an auto-generated VTT subtitle file from a video platform (e.g. Vimeo). You can also use OpenAI Whisper to transcribe audio, but I didn't use that because I already had the VTT subtitle file that Vimeo generated. 
2. Identifies the most interesting or quotable moments with timestamps
3. Extracts those moments as individual MP4 clips or combined segments
4. Produces both horizontal (1920×1080) and vertical center-cropped (608×1080, 9:16) versions of each clip
5. Generates adjusted VTT subtitle files for each clip, with timestamps re-zeroed to the clip start

## Example

This workflow was developed while processing Illinois Governor Pritzker's February 18, 2026 budget address housing segment. From a ~3:40 speech, we extracted:

- **Clip 1** (0:00–0:14) — "Illinoisans are paying too much to live"
- **Clip 2** (0:14–0:17) — "Everything is just too damned expensive"
- **Clips 3–9 combined** (0:32–2:17) — Housing diagnosis through policy announcement
- **Clip 10+** (2:05–end) — "Building Up Illinois" plan detail

Each clip was produced in horizontal and vertical formats. A matching `.vtt` subtitle file was generated for the combined clip (which can be uploaded to Bluesky which will show them as closed captions).

## Requirements

- `ffmpeg` — video extraction and encoding
- A VTT subtitle file from the source video (Vimeo auto-generated captions work well)
- Python 3 — for VTT timestamp adjustment script

## Usage

### 1. Extract a clip (horizontal)

Always include `-pix_fmt yuv420p -movflags +faststart` for macOS QuickTime/Photos compatibility.

```bash
ffmpeg -y -ss [START_SECONDS] -to [END_SECONDS] \
  -i input.mov \
  -c:v libx264 -preset fast -crf 23 \
  -pix_fmt yuv420p -movflags +faststart \
  -c:a aac \
  output_horizontal.mp4
```

### 2. Extract a clip (vertical 9:16 center crop from 1920×1080)

```bash
ffmpeg -y -ss [START_SECONDS] -to [END_SECONDS] \
  -i input.mov \
  -vf "crop=608:1080:656:0" \
  -c:v libx264 -preset fast -crf 23 \
  -pix_fmt yuv420p -movflags +faststart \
  -c:a aac \
  output_vertical.mp4
```

> Adjust the crop values if your source resolution differs. For 1920×1080:
> - Width: `608` (= 1080 × 9/16)
> - Height: `1080`
> - X offset: `656` (= (1920 − 608) / 2, centers the crop)
> - Y offset: `0`

### 3. Generate adjusted VTT subtitles for a clip

Use the included `adjust_vtt.py` script:

```bash
python3 adjust_vtt.py \
  --input captions.vtt \
  --start 32 \
  --end 137 \
  --output clip_subtitles.vtt
```

## Vertical Crop Math

For other source resolutions, calculate the crop as follows:

```
crop_width  = source_height × (9/16)
x_offset    = (source_width − crop_width) / 2
crop filter = crop=crop_width:source_height:x_offset:0
```

## Building the Mac app from source

The app's code is in `app/` (SwiftUI). It needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```bash
cd app
xcodegen generate
xcodebuild -project SpeechClipExtractor.xcodeproj -scheme SpeechClipExtractor -configuration Release -derivedDataPath build build
open "build/Build/Products/Release/Speech Clip Extractor.app"
```

To share a build, zip it with `ditto -c -k --keepParent "Speech Clip Extractor.app" Speech-Clip-Extractor.zip` and attach it to a GitHub release. Clip lists save next to each video as `<name>.clips.json`.

## Testing the Mac app

`app/tests/ui-test.sh` is an end-to-end test: it builds a separate copy of the app, makes a test video and transcript, and drives the app through macOS accessibility scripting (opening a file, adding a clip, export with vertical and burned-in captions, duplicate, undo and redo, the space bar, deleting a clip), then checks the saved clip list and exported files.

```bash
bash app/tests/ui-test.sh           # 27 checks, about 40 seconds once built
bash app/tests/ui-test.sh --quiet   # 21 checks, never brings the app forward
```

The test copy opens in the background and its buttons are pressed without moving the mouse, so you can keep working. Only the keyboard checks (duplicate, undo, redo and the space bar) need the app in front, for about 3 seconds near the end, and then the app you were using comes back. Don't type during those seconds. `--quiet` skips them. The test copy opens no Finder window and shows no notifications.

It needs Xcode, XcodeGen and ffmpeg, plus Accessibility permission for the app you run it from (System Settings > Privacy & Security > Accessibility). It doesn't touch a copy of the app you have open and makes no AI calls. The build is kept in your temporary folder between runs; everything else is deleted when it finishes.

## Secret checks for contributors

This repo has git hooks in `.githooks/` that use [gitleaks](https://github.com/gitleaks/gitleaks) to block a commit or push containing what looks like a secret (API keys, tokens, private keys). Turn them on once per clone:

```bash
brew install gitleaks
git config core.hooksPath .githooks
```

The commit check scans the staged changes; the push check scans every commit being pushed, so it also catches anything committed with `--no-verify`. Found values are hidden in the output. For a false alarm, add the finding's fingerprint to `.gitleaksignore`.
