# Glitchrupt architecture

Glitchrupt is a local macOS attention cue with an optional desktop tester, a command line client, and an MCP stdio adapter. It includes a local approval registry and a Codex advisory hook adapter. Explicit waits use the app timer; reliable automatic state tracking depends on a supported host event connection.

## One native cue engine

The native AppKit app owns all rendering and audio. Swift reuses the prototype's full normalized visual timeline and AVAudioEngine playback. A 600 ms cue traverses the entire sequence, with a 60 Hz target timer, then restores the image and removes every overlay. Desktop captures remain in memory, one image per display, capped at 1920 px width for performance. The scene looks frozen during the short snapshot effect. No screen audio or microphone is recorded.

The five original generated stereo sounds are Classic (the chosen digital crackle), Fracture, Brownout, Arc, and Stutter. Every sound is 600 ms/44.1kHz/PCM16 with zero endpoints and matched sample RMS. The generator and manifest are under scripts/ and assets/sounds/.

## Local request bridge

The Python adapter never captures the display directly. It launches/contacts the same signed app through Launch Services, preserving native permission identity and allowing one process to coordinate all agents. No HTTP listener or network service is exposed.

1. Create a UUID and atomically write 0600 JSON to `~/Library/Application Support/Glitchrupt/requests/<UUID>.request.json` inside a 0700 directory.
2. Run `open -g -a <Glitchrupt.app> glitchrupt://request/<UUID> --args --agent-mode` without a shell. New agent-mode launches stay headless; previews are explicit. Existing app instances receive the URL.
3. Native code validates the URL UUID, matching body ID, private directory ownership, regular file ownership/permissions/size/age without following symlinks, action and bounded settings.
4. Native code atomically writes 0600 `<UUID>.response.json`; Python validates the request ID and removes both files after reading. It times out after 15 seconds without retrying an effect. Requests older than 30 seconds are expired. Owned bridge files older than 60 seconds are cleaned on subsequent requests. The five-second cooldown uses a monotonic clock.

Request: `id`, `action:status|signal`. Signal fields: `variant:classic|fracture|brownout|arc|stutter`, `duration_ms:300..1000` (default 600), `volume:0..0.5` (default 0.28), `sound:boolean` (default true), `preview:boolean` (default false). No shell command, file path, network address, or chat content is accepted from a tool call.

Status response: `status:ready`, `request_id`, `permission`, `reduce_motion`, `agents_enabled`, `busy`, `cooldown_remaining_ms`, `app_version`, `variants`.

Signal response: `status:completed|muted|cooldown|busy|permission_required|reduce_motion|error`, `request_id`, and applicable `variant`, `duration_ms`, `mode:desktop|preview`, `sound`. Completed is emitted only after animation finishes and overlays are removed. Input/transport errors do not claim an effect ran.

## Human controls and concurrency

The menu-bar item opens the tester, toggles agent cues, and quits. Manual previews remain available when agent cues are paused. Agent requests share one native busy state and a five-second cooldown; they are suppressed rather than queued. Reduce Motion suppresses desktop animation. Screen Recording is requested only from the user's app setup action, not silently by an agent tool.

Agent requests use the current macOS user's private filesystem and local process access. This is not an authentication boundary against malicious processes already running as that same user. The native bridge rejects path traversal and oversized/stale requests. It does not accept arbitrary URLs, paths, scripts, or source text.

## Distribution

The source package contains original code/audio and editable generators. Prototype reference excerpts, screenshots, local verification logs, development virtual environments, private machine paths, and Git metadata are excluded. The initial build is ad-hoc signed for local development; a public downloadable app should receive Developer ID signing/notarization before general release. No publication or global MCP configuration installation is part of this iteration.

## Glitchrupt rebrand (0.2.0)

The app, Python package, command, MCP tools, URL scheme, request directory, and source folder use Glitchrupt. The new native identifier is `local.glitchrupt.app`; macOS Screen Recording access is specific to this app identity. This is an explicit rename rather than an alias layer because no public integration or global agent configuration had been installed. The five cue IDs and effect behavior stay the same.

The logo is original polygon geometry with a standalone lightning jolt, an exclamation dot, and print registration offsets. SVG, PNG, app icon, and menu template share `scripts/generate_brand.swift` as their editable source. The build regenerates assets using macOS AppKit; no image or font dependency is added. Public packaging allowlists only the generated brand images and still rejects unrelated capture/reference media. See `docs/brand.md`.

## Approval attention policy (0.3.0)

An explicit approval wait has a stable key and one complete double cue: 600 ms animation, a target 200 ms restored-screen gap, then another complete 600 ms animation. Audio preparation occurs inside the gap deadline. The app owns a monotonic 900-second reminder timer while the key remains pending; an MCP process does not need to stay alive. Duplicate registration preserves settings and deadlines. Registrations within an active pair or its five-second cooldown coalesce into that episode. Resolve, prefix cleanup, the menu's clear control, and app quit remove pending work. The in-memory registry intentionally does not restore stale waits after restart.

Automatic Codex hooks use one-shot `repeat:false` waits. This is a deliberate resolution-safety boundary: `PermissionRequest` precedes approval but `PostToolUse` follows tool completion, potentially much later than the answer. The documented app-server resolution API is suitable only when connected to the actual session host. Without that connection, an automatic repeat could interrupt already-approved work. The explicit wait/resolve MCP workflow remains recurring under the user's policy; the source includes the optional global-rule proposal separately from host configuration.

The hook adapter hashes identifiers and tool inputs in memory for correlation, forwards no raw question/command/transcript, returns benign JSON, and never decides approvals. See `docs/approval-alerts.md` for contracts and coverage.
