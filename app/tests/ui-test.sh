#!/bin/bash
#
# End-to-end UI test for Speech Clip Extractor.
#
# Builds a separate copy of the app, makes a test video and transcript, then
# drives the app through macOS accessibility scripting (System Events):
# opening a file, adding a clip, export with vertical and burned-in captions,
# duplicate, undo and redo, the space bar, and deleting a clip. It checks the
# saved clip list and the exported files.
#
# It stays out of your way: the test copy opens in the background, and its
# buttons and checkboxes are pressed through accessibility, which doesn't
# move the mouse or bring the app forward. Only ⌘D, ⌘Z, ⇧⌘Z and the space bar
# need the app in front; they run in one burst of about 3 seconds near the end,
# then the app you were using comes back to the front. --quiet skips them.
# The test copy runs in test mode (-SCEUITesting), so exporting opens no Finder
# window and finishing a job shows no notification.
#
# Run from anywhere:  bash app/tests/ui-test.sh [--quiet]
# Needs: Xcode, xcodegen, ffmpeg, and Accessibility permission for the app
# you run it from (System Settings > Privacy & Security > Accessibility).
# It targets its own copy by process ID, so a copy you have open (same name
# and bundle ID) is never touched. No AI calls or Keychain access are made.
#
QUIET=""; [ "$1" = "--quiet" ] && QUIET=1
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The real path (no trailing-slash doubling, /var resolved to /private/var), because
# macOS reports running apps by their real path and the script finds its copy by path.
T="$(mktemp -d "${TMPDIR%/}/sce-ui-test.XXXXXX")" && T="$(cd "$T" && pwd -P)"
# The build is kept between runs, so a run with no code changes rebuilds in seconds.
BUILD="$(cd "${TMPDIR%/}" && pwd -P)/sce-ui-test-build"
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT

echo "Building a test copy in ${BUILD} ..."
(cd "$APP_DIR" && xcodegen generate --quiet && xcodebuild -project SpeechClipExtractor.xcodeproj -scheme SpeechClipExtractor \
    -configuration Release -derivedDataPath "$BUILD" build >"$T/build.log" 2>&1) \
    || { cp "$T/build.log" "$BUILD.log"; echo "Build failed; see $BUILD.log"; exit 1; }

# A 20-second 1280x720 test video with a tone, and a 4-line transcript next to it.
mkdir -p "$T/fixtures"
ffmpeg -nostdin -y -loglevel error -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=20" \
    -f lavfi -i "sine=frequency=440:duration=20" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$T/fixtures/test talk.mp4"
printf 'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\n[SPEAKER_00]: We need more housing near transit.\n\n00:00:04.500 --> 00:00:08.000\n[SPEAKER_01]: Parking minimums make that harder.\n\n00:00:09.000 --> 00:00:13.000\n[SPEAKER_00]: This ordinance removes them citywide.\n\n00:00:14.000 --> 00:00:18.000\n[SPEAKER_01]: That is a big change.\n' > "$T/fixtures/test talk.vtt"

APP="$BUILD/Build/Products/Release/Speech Clip Extractor.app"
VIDEO="$T/fixtures/test talk.mp4"
CLIPS="$T/fixtures/test talk.clips.json"
OUT="$T/fixtures/test talk clips"
pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', expected '$3'"; fi; }
# Polls until a command prints the expected value (up to about 5 s), then prints what it last got.
waitfor() { local want="$1" got=""; shift; for _ in $(seq 1 25); do got=$("$@"); [ "$got" = "$want" ] && break; sleep 0.2; done; echo "$got"; }

# Finding controls. "entire contents" comes back empty for a window in the
# background, so this walks the tree itself. Controls are found by their
# accessibility identifier (set in the app's views).
#   press <id>   presses a button or checkbox (no mouse movement, no focus change)
#   value <id>   prints its value (a checkbox is 0 or 1)
#   texts        prints every static text in the window, one per line
cat > "$T/ax.applescript" <<'EOS'
on findId(el, ident)
  tell application "System Events"
    try
      if (value of attribute "AXIdentifier" of el) is ident then return el
    end try
    try
      set kids to UI elements of el
    on error
      return missing value
    end try
    repeat with k in kids
      set r to my findId(k, ident)
      if r is not missing value then return r
    end repeat
  end tell
  return missing value
end findId

on texts(el)
  set out to ""
  tell application "System Events"
    try
      if role of el is "AXStaticText" then set out to ((value of el) as text) & linefeed
    end try
    try
      repeat with k in (UI elements of el)
        set out to out & my texts(k)
      end repeat
    end try
  end tell
  return out
end texts

on run argv
  tell application "System Events" to set w to window 1 of (first process whose unix id is ((item 1 of argv) as integer))
  set act to item 2 of argv
  if act is "texts" then return my texts(w)
  set e to my findId(w, item 3 of argv)
  if e is missing value then return "missing"
  tell application "System Events"
    if act is "press" then
      perform action "AXPress" of e
      return "pressed"
    end if
    return (value of e) as text
  end tell
end run
EOS
ax() { osascript "$T/ax.applescript" "$PID" "$@" 2>&1; }
as() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID)" -e "$1" -e "end tell" 2>&1; }
clipcount() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$CLIPS" 2>/dev/null || echo 0; }
# The player's "0:01.3 / 0:20.0" label: field 1 is the playhead, field 3 the length.
playhead() { ax value playheadTime | cut -d' ' -f1; }
length() { ax value playheadTime | cut -d' ' -f3; }
secs() { echo "$1" | awk -F: '{print $1*60+$2}'; }

# 1. Opening a file with the app (Finder's Open With path) before any window exists, in the background.
FRONT=$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null)
for i in $(seq 1 20); do pgrep -f "$APP/Contents/MacOS/" >/dev/null || break; sleep 0.5; done
open -g -n -a "$APP" "$VIDEO" --args -SCEUITesting YES
for i in $(seq 1 30); do PID=$(pgrep -n -f "$APP/Contents/MacOS/"); [ -n "$PID" ] && break; sleep 0.5; done
[ -n "$PID" ] && ok "test copy launched (pid $PID)" || { bad "test copy didn't launch"; exit 1; }
check "file sent at launch opens in the window (title)" "$(waitfor "test talk.mp4" as "name of window 1")" "test talk.mp4"

# 2. The video's length and size are read, and the transcript next to it loads automatically.
check "video length read" "$(waitfor "0:20.0" length)" "0:20.0"
t=$(ax texts)
echo "$t" | grep -q "We need more housing near transit." && ok "sidecar transcript loaded" || bad "sidecar transcript not shown"
echo "$t" | grep -q "1,280×720" && ok "video size read (1,280×720)" || bad "video size not shown: $(echo "$t" | grep -m1 '×')"

# 3. The Clip menu exists (its items can be read, though not used, in the background).
as "name of menu items of menu \"Clip\" of menu bar item \"Clip\" of menu bar 1" | grep -q "Transcribe" \
    && ok "Clip menu present" || bad "Clip menu missing"

# 4. A clip from the player's button, saved next to the video.
ax press newClipAtPlayhead >/dev/null
check "New Clip at Playhead saves 1 clip" "$(waitfor 1 clipcount)" "1"

# 5. Export with Vertical and Burn captions ticked.
[ "$(ax value exportVertical)" = "1" ] || ax press exportVertical >/dev/null
[ "$(ax value burnCaptions)" = "1" ] || ax press burnCaptions >/dev/null
check "tick Vertical 9:16" "$(ax value exportVertical)" "1"
check "tick Burn captions" "$(ax value burnCaptions)" "1"
ax press exportClips >/dev/null
for i in $(seq 1 120); do [ -f "$OUT/01-clip-at-0-00-0-vertical-captioned.mp4" ] && break; sleep 0.5; done
sleep 1
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

# 6. The burst that needs the app in front: duplicate, undo, redo, and the space bar.
if [ -z "$QUIET" ]; then
  as "set frontmost to true" >/dev/null; sleep 0.3
  as 'keystroke "d" using command down' >/dev/null
  check "Duplicate (⌘D) makes 2 clips" "$(waitfor 2 clipcount)" "2"
  check "Edit > Undo is enabled" "$(as 'enabled of menu item 1 of menu "Edit" of menu bar item "Edit" of menu bar 1')" "true"
  as 'keystroke "z" using command down' >/dev/null
  check "Undo (⌘Z) removes the duplicate" "$(waitfor 1 clipcount)" "1"
  as 'keystroke "z" using {command down, shift down}' >/dev/null
  check "Redo (⇧⌘Z) brings it back" "$(waitfor 2 clipcount)" "2"
  # Play for about a second, then pause.
  t0=$(playhead); as "key code 49" >/dev/null; sleep 1; as "key code 49" >/dev/null
  # Back to the app you were using, then read the result: the time should have moved, then hold still.
  [ -n "$FRONT" ] && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $FRONT) to true" >/dev/null 2>&1
  sleep 0.3; t1=$(playhead); sleep 1; t2=$(playhead)
  moved=$(awk -v a="$(secs "$t0")" -v b="$(secs "$t1")" 'BEGIN{print (b-a>0.4 && b-a<4) ? "yes" : "no"}')
  [ -n "$t1" ] && [ "$moved" = "yes" ] && ok "space bar plays, then pauses ($t0 -> $t1)" || bad "space bar play/pause: '$t0' -> '$t1'"
  [ -n "$t2" ] && [ "$t1" = "$t2" ] && ok "stays paused ($t1 stays $t2)" || bad "didn't stay paused ('$t1' -> '$t2')"
  expected=1
else
  echo "SKIP  duplicate, undo, redo and the space bar (--quiet)"
  expected=0
fi

# 7. A clip's trash button, back in the background.
ax press deleteClip >/dev/null
check "Delete clip button removes one" "$(waitfor $expected clipcount)" "$expected"

kill "$PID" 2>/dev/null
for i in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
PID=""
echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
