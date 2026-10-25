#!/bin/bash
set -euo pipefail
# Requirements: macOS, Xcode command-line tools, Python 3, FFmpeg (with libx264).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/glitchrupt-demo.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$ROOT/assets/demo"
xcrun swiftc -swift-version 5 -warnings-as-errors -O \
  "$ROOT/Sources/Renderer.swift" "$ROOT/scripts/render_demo.swift" \
  -framework AppKit -framework CoreImage -framework QuartzCore \
  -o "$WORK/render-demo"
"$WORK/render-demo" "$WORK/frames"
# Make a finite PCM timeline instead of padding an unbounded FFmpeg filter graph.
python3 - "$ROOT/assets/sounds/classic.wav" "$WORK/audio.wav" <<'PYTHON'
import array
import sys
import wave
with wave.open(sys.argv[1], "rb") as source:
    assert source.getnchannels() == 2 and source.getsampwidth() == 2
    rate = source.getframerate()
    samples = array.array("h", source.readframes(source.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
output = array.array("h", [0]) * (int(rate * 7.5) * 2)
for start_ms in (2000, 2800):
    offset = rate * start_ms // 1000 * 2
    for i, sample in enumerate(samples):
        output[offset + i] = round(sample * 0.28)
if sys.byteorder != "little":
    output.byteswap()
with wave.open(sys.argv[2], "wb") as target:
    target.setparams((2, 2, rate, 0, "NONE", "not compressed"))
    target.writeframes(output.tobytes())
PYTHON
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$WORK/frames/frame-%04d.png" \
  -i "$WORK/audio.wav" -t 7.5 -c:v libx264 -crf 24 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart "$ROOT/assets/demo/demo.mp4"
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$WORK/frames/frame-%04d.png" \
  -filter_complex '[0:v]split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle' \
  -loop 0 "$ROOT/assets/demo/demo.gif"
cp "$WORK/frames/frame-0067.png" "$ROOT/assets/demo/poster.png"
# Storyboard is a generated review aid, deliberately retained only in the temp output if requested.
if [[ -n "${GLITCHRUPT_DEMO_REVIEW_DIR:-}" ]]; then
  mkdir -p "$GLITCHRUPT_DEMO_REVIEW_DIR"
  for number in 0000 0067 0081 0093 0120 0180; do
    cp "$WORK/frames/frame-$number.png" "$GLITCHRUPT_DEMO_REVIEW_DIR/$number.png"
  done
fi
