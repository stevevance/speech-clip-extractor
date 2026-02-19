# Speech Clip Extractor

A workflow for extracting highlight clips from speech videos using VTT subtitle files and ffmpeg. Includes horizontal (16:9) and vertical (9:16) crop versions for multi-platform publishing.

## What It Does

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
