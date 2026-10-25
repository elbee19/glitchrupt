# README demo

The demo is an entirely code-drawn fictional desktop. It contains no screenshot,
user account, private filename, personal chat, or reference-film material.
It uses the production `GlitchRenderer` from `Sources/Renderer.swift`; it does not
launch Glitchrupt, request Screen Recording, or trigger a live desktop effect.

Regenerate on macOS with Xcode command-line tools, Python 3, and FFmpeg installed:

```sh
./scripts/generate_demo.sh
```

`render_demo.swift` creates 225 PNG frames in a disposable temporary directory.
FFmpeg makes a 960 × 680, 30 fps, 7.5-second looping GIF and an H.264/AAC MP4.
The poster is frame 67, during the first glitch. Outputs live in `assets/demo/`.
The script removes temporary frames on exit. Set `GLITCHRUPT_DEMO_REVIEW_DIR` to
retain six representative frames for visual review.

Timing is real time: first glitch 2.000–2.600 seconds, gap 2.600–2.800,
second glitch 2.800–3.400. Both complete normalized animations are rendered;
neither is cut short. The GIF samples at 30 fps and is silent. The MP4 adds the
original `classic.wav` twice, at 2.000 and 2.800 seconds, at the app's default
0.28 gain. Its soundtrack is synthesized source audio, not a recording.

At 5.300 seconds the fictional user replies and the cue clears. The caption
explains that waiting reminders repeat every 15 minutes; the demo does not
pretend that a second reminder interval elapses within its 7.5-second runtime.
The final pause makes the loop boundary clear. The actual app can affect all
displays and uses a transient in-memory desktop image when authorized.
