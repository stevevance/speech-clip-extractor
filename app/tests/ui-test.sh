#!/bin/bash
#
# End-to-end UI test for Speech Clip Extractor.
#
# Builds a separate copy of the app into a temporary folder, makes a test
# video and transcript, then drives the app through macOS accessibility
# scripting (System Events): opening a file, the Clip menu, undo and redo,
# the space bar, and export with vertical and burned-in captions. It checks
# the saved clip list and the exported files.
#
# Run from anywhere:  bash app/tests/ui-test.sh
# Needs: Xcode, xcodegen, ffmpeg, and Accessibility permission for the app
# you run it from (System Settings > Privacy & Security > Accessibility).
# It targets its own copy by process ID, so a copy you have open (same name
# and bundle ID) is never touched. No AI calls or Keychain access are made.
#
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The real path (no trailing-slash doubling, /var resolved to /private/var), because
# macOS reports running apps by their real path and the script finds its copy by path.
T="$(mktemp -d "${TMPDIR%/}/sce-ui-test.XXXXXX")" && T="$(cd "$T" && pwd -P)"
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT

echo "Building a test copy in ${T} ..."
(cd "$APP_DIR" && xcodegen generate --quiet && xcodebuild -project SpeechClipExtractor.xcodeproj -scheme SpeechClipExtractor \
    -configuration Release -derivedDataPath "$T/build" build >"$T/build.log" 2>&1) \
    || { echo "Build failed; see $T/build.log"; trap - EXIT; exit 1; }

# A 20-second 1280x720 test video with a tone, and a 4-line transcript next to it.
mkdir -p "$T/fixtures"
ffmpeg -nostdin -y -loglevel error -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=20" \
    -f lavfi -i "sine=frequency=440:duration=20" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$T/fixtures/test talk.mp4"
printf 'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\n[SPEAKER_00]: We need more housing near transit.\n\n00:00:04.500 --> 00:00:08.000\n[SPEAKER_01]: Parking minimums make that harder.\n\n00:00:09.000 --> 00:00:13.000\n[SPEAKER_00]: This ordinance removes them citywide.\n\n00:00:14.000 --> 00:00:18.000\n[SPEAKER_01]: That is a big change.\n' > "$T/fixtures/test talk.vtt"

APP="$T/build/Build/Products/Release/Speech Clip Extractor.app"
VIDEO="$T/fixtures/test talk.mp4"
CLIPS="$T/fixtures/test talk.clips.json"
OUT="$T/fixtures/test talk clips"
pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', expected '$3'"; fi; }

# AppleScript against the test process only.
as() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID)" -e "$1" -e "end tell" 2>&1; }
front() { as "set frontmost to true" >/dev/null; sleep 0.4; }
menu() { front; as "click menu item \"$2\" of menu \"$1\" of menu bar item \"$1\" of menu bar 1" >/dev/null; sleep "${3:-0.8}"; }
clipcount() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$CLIPS" 2>/dev/null || echo 0; }
# Every static text in the window, one per line (heredoc AppleScript, by accessibility role).
texts() { osascript 2>&1 <<EOS
tell application "System Events" to tell (first process whose unix id is $PID)
  set out to ""
  set els to entire contents of window 1
  repeat with i from 1 to count of els
    try
      set e to item i of els
      if role of e is "AXStaticText" then set out to out & ((value of e) as text) & linefeed
    end try
  end repeat
  return out
end tell
EOS
}
# Tick a checkbox found by the start of its tooltip (the export checkboxes have no accessible name).
checkbox() { osascript 2>&1 <<EOS
tell application "System Events" to tell (first process whose unix id is $PID)
  set els to entire contents of window 1
  repeat with i from 1 to count of els
    try
      set e to item i of els
      if role of e is "AXCheckBox" and ((value of attribute "AXHelp" of e) as text) starts with "$1" then
        if value of e is 0 then click e
        return "on"
      end if
    end try
  end repeat
  return "missing"
end tell
EOS
}

rm -rf "$OUT" "$CLIPS"

# 1. Opening a file with the app (Finder's Open With path) before any window exists.
# Wait for any earlier test copy to finish quitting, so the new one is the only match.
for i in $(seq 1 20); do pgrep -f "$APP/Contents/MacOS/" >/dev/null || break; sleep 0.5; done
open -n -a "$APP" "$VIDEO"
for i in $(seq 1 30); do PID=$(pgrep -n -f "$APP/Contents/MacOS/"); [ -n "$PID" ] && break; sleep 0.5; done
[ -n "$PID" ] && ok "test copy launched (pid $PID)" || { bad "test copy didn't launch"; exit 1; }
sleep 4
title=$(as "name of window 1")
check "file sent at launch opens in the window (title)" "$title" "test talk.mp4"

# 2. The transcript next to the video loads automatically.
t=$(texts)
echo "$t" | grep -q "We need more housing near transit." && ok "sidecar transcript loaded" || bad "sidecar transcript not shown"
echo "$t" | grep -q "1,280×720" && ok "video size read (1,280×720)" || bad "video size not shown: $(echo "$t" | grep -m1 '×' )"

# 3. Menus: the Clip menu exists and Remove Noise is gone.
items=$(as "name of menu items of menu \"Clip\" of menu bar item \"Clip\" of menu bar 1")
echo "$items" | grep -q "Transcribe" && ok "Clip menu present" || bad "Clip menu missing: $items"
echo "$items" | grep -qi "noise" && bad "Remove Noise still in the Clip menu" || ok "Remove Noise is gone from the menu"

# 4. Clip editing through the menus, checked against the saved clip list.
menu Clip "New Clip at Playhead"
check "New Clip at Playhead saves 1 clip" "$(clipcount)" "1"
menu Clip "Duplicate Selected Clips"
check "Duplicate makes 2 clips" "$(clipcount)" "2"
menu Clip "Delete Selected Clips"
check "Delete removes the duplicate" "$(clipcount)" "1"
undo=$(as 'enabled of menu item 1 of menu "Edit" of menu bar item "Edit" of menu bar 1')
check "Edit > Undo is enabled after Delete" "$undo" "true"
front; as 'keystroke "z" using command down' >/dev/null; sleep 0.8
check "Undo (⌘Z) brings the duplicate back" "$(clipcount)" "2"
front; as 'keystroke "z" using {command down, shift down}' >/dev/null; sleep 0.8
check "Redo (⇧⌘Z) removes it again" "$(clipcount)" "1"

# 5. Space bar plays and pauses: the playhead time should move only while playing.
# The player's "0:01.3 / 0:20.0" label; retried, since a read can come back empty mid-update.
timeof() { local v=""; for _ in 1 2 3 4 5; do v=$(texts | grep -E "^[0-9]+:[0-9]{2}\.[0-9] / " | head -1 | cut -d' ' -f1); [ -n "$v" ] && break; sleep 0.3; done; echo "$v"; }
# Play for about 1.5 s, pause, then read: the time should have moved a little and then hold still.
t0=$(timeof); front; as "key code 49" >/dev/null; sleep 1.5; as "key code 49" >/dev/null; sleep 0.5
t1=$(timeof); sleep 1.5; t2=$(timeof)
secs() { echo "$1" | awk -F: '{print $1*60+$2}'; }
moved=$(awk -v a="$(secs "$t0")" -v b="$(secs "$t1")" 'BEGIN{print (b-a>0.5 && b-a<5) ? "yes" : "no"}')
[ -n "$t1" ] && [ "$moved" = "yes" ] && ok "space bar plays, then pauses ($t0 -> $t1)" || bad "space bar play/pause: '$t0' -> '$t1'"
[ -n "$t2" ] && [ "$t1" = "$t2" ] && ok "stays paused ($t1 stays $t2)" || bad "didn't stay paused ('$t1' -> '$t2')"

# 6. Export with Vertical and Burn captions ticked.
check "tick Vertical 9:16" "$(checkbox 'Also make a center-cropped vertical')" "on"
check "tick Burn captions" "$(checkbox 'Also make a -captioned.mp4')" "on"
menu Clip "Export Clips" 1
for i in $(seq 1 60); do [ -f "$OUT/01-clip-at-0-00-0-vertical-captioned.mp4" ] && break; sleep 1; done
sleep 2
for f in 01-clip-at-0-00-0.mp4 01-clip-at-0-00-0.vtt 01-clip-at-0-00-0-vertical.mp4 01-clip-at-0-00-0-captioned.mp4 01-clip-at-0-00-0-vertical-captioned.mp4; do
  [ -s "$OUT/$f" ] && ok "exported $f" || bad "missing $f"
done
dims() { ffprobe -v error -select_streams V:0 -show_entries stream=width,height -of csv=p=0 "$1" 2>/dev/null; }
check "horizontal clip size" "$(dims "$OUT/01-clip-at-0-00-0.mp4")" "1280,720"
check "vertical clip size (9:16 crop)" "$(dims "$OUT/01-clip-at-0-00-0-vertical.mp4")" "404,720"
check "vertical captioned size" "$(dims "$OUT/01-clip-at-0-00-0-vertical-captioned.mp4")" "404,720"
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/01-clip-at-0-00-0-captioned.mp4" | cut -c1-4)
check "captioned clip length (15 s clip)" "$dur" "15.0"
first=$(grep -m1 -- "-->" "$OUT/01-clip-at-0-00-0.vtt")
check "subtitle file re-zeroed to the clip start" "$first" "00:00:01.000 --> 00:00:04.000"
grep -q "SPEAKER" "$OUT/01-clip-at-0-00-0.vtt" && bad "speaker labels left in subtitles" || ok "speaker labels removed from subtitles (default)"


# Clean up: quit only the test copy, and close the Finder window the export opened.
kill "$PID" 2>/dev/null
for i in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
osascript -e "tell application \"Finder\" to close (every window whose name is \"test talk clips\")" >/dev/null 2>&1
PID=""
echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
