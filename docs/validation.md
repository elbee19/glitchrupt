# Validation

## Engine baseline (0.1.0)

Verified locally on 2026-10-25, Apple silicon, macOS 26.4.1, two displays.
The binary targets macOS 14.0; macOS 14 and Intel runtime behavior have not been tested.

- Native build passes Swift warnings-as-errors and strict ad-hoc signature verification.
- All five WAV resources decode in the built app: exactly 26,460 stereo frames at 44.1 kHz (600 ms), PCM16, zero endpoints, deterministic generation. Classic is byte-identical to the selected prototype crackle. Sample RMS is matched; this is not perceptual loudness normalization.
- All five native comparison previews completed. Observed elapsed animation times were approximately 601–605 ms. Render cadence varies with display load; the normalized timeline always traverses the full sequence.
- A synthetic midpoint differs from the original, and the final rendered image matches the original byte-for-byte.
- Python CLI/MCP suite: 29 tests passed (`uv run --locked pytest -q`). This includes actual SDK stdio transport with an isolated native test client.
- Real MCP stdio → Launch Services → native app: three tools discovered; first status launched headless with `tester_visible:false`; a Fracture preview completed with sound; an immediate repeat returned `cooldown`.
- Native pause control returned `muted` to an agent cue, while a manual Brownout preview completed. Agent cues were re-enabled afterward.
- The native bridge rejected unknown variants, expired files, nonprivate files, and oversized files without running effects.
- After the user enabled the final app's Screen Recording access, two real MCP desktop calls (Classic and Fracture) completed with sound across both displays. Each recorded approximately 601 ms; both reported `overlays=0` after cleanup and final status reported `busy:false`.
- Clean source extraction/rebuild, bundled resource verification, app archive extraction/signature, source archive reproducibility, package exclusions, and checksum verification passed.

No chat monitor or host MCP configuration is installed. No source or app is published. The app remains ad-hoc signed for local testing; Developer ID signing and notarization are release work. Changing the development build can require Screen Recording access to be refreshed because its signature changes.

## Reproduce core checks

```sh
./scripts/build.sh
build/Glitchrupt.app/Contents/MacOS/Glitchrupt --verify-sounds
uv run --locked pytest -q
./scripts/package.sh
shasum -a 256 -c dist/SHA256SUMS
```

For human-approved integration checks, run `uv run --locked glitchrupt status`, then `uv run --locked glitchrupt preview --variant fracture`. An immediate repeat should report `cooldown`. A desktop check uses `signal` instead of `preview` and needs native Screen Recording access. These effectful checks are intentionally separate from the automated suite.

## Rebrand (0.2.0)

The Glitchrupt native build passes warnings-as-errors and strict signature verification. The renamed Python package passes the same 29 CLI/MCP tests. A real SDK stdio session discovered `glitchrupt_status`, `glitchrupt_variants`, and `glitchrupt_signal`; the new app returned version 0.2.0 while headless, then completed a silent 600 ms windowed preview. Native window title and preview artwork were visually checked. All five bundled audio resources decode. Desktop tests were not repeated under the new identifier because its Screen Recording permission needs separate setup.

The original SVG logo, PNG previews, app icon and template menu image were visually inspected. They regenerate from shared Swift geometry. The source/app package includes only allowlisted generated brand images; reference/capture media remains excluded. Final source and app archives and checksums were verified. The package includes a Codex configuration example and does not install host configuration or hooks. The documented Codex CLI setup was checked in isolation; actual host registration is a separate setup step.

## Approval reminders (0.3.0)

Verified on 2026-10-25:

- Python CLI/MCP/hook suite: 63 tests passed with `uv run --locked python -m pytest -q`.
- Pure native scheduler: 48 deterministic assertions passed, including the exact 900-second boundary, duplicates, cancellation, coalescing, no catch-up, and one-shot cleanup. This verifies scheduling with a simulated monotonic clock; it is not a fifteen-minute wall-clock playback test.
- Final native sources compile with warnings-as-errors and strict app signature verification passes. `uv pip check` reports installed dependencies compatible.
- A real stdio SDK connection discovered all six tools, registered a recurring silent windowed approval wait, ignored a duplicate, completed the pair, reported about 898 seconds remaining, and resolved to zero pending approvals.
- Measured pair timing was 601 ms + 214 ms gap + 602 ms (1417 ms total) against targets of 600/200/600. macOS scheduling can add frame-sized timing slip; the gap uses an absolute deadline and audio setup occurs inside it.
- Codex's current desktop-bundled CLI accepted MCP registration without changing an unrelated setting rejected by the older standalone CLI. Hook discovery via the documented `hooks/list` API parsed six new advisory handlers with no warnings/errors, while the pre-existing hook remained trusted. New handlers require human trust; no trust records were changed by setup.
- The documented precise approval-resolution API is suitable for a client connected to the actual session host. A shared-server connection to current desktop sessions was not available during setup, so automatic hooks request one-shot pairs only. Recurring explicit waits remain available; automatic “repeat only while blocked” across every desktop chat is not established.

Desktop playback under this final build depends on its Screen Recording permission. Codex hook review/trust and connection refresh are human setup steps. No automatic review or approval decision is delegated to Glitchrupt.

## Final desktop setup check

On 2026-10-25 the user enabled capture for the final0.3.0 build and approved exactly one desktop test pair. Readiness reported permissiontrue. One pair completed across two displays with sound; measured gap210ms and total1411ms against targets200ms and1400ms. The one-shot registration removed itself and pending_count returned0. The global approval-attention rule was then applied with the clarified stopping condition: user response OR task unblocked, whichever happens first.

## 0.4.0 attribution checks

-99 Python tests pass, including metadata bounds/controls/UUID validation, backward compatibility and CLI/SDK forwarding.
-48 existing reminder state assertions and31 attribution/handover assertions pass. Final app compiles with warnings-as-errors and strict signature verification.
-Real MCP SDK to the installed app verified attributed registration, duplicate context enrichment without replay/deadline reset, native rejection of malformed context, and exact test-key resolution preserving a peer request.
-An actual0.3→0.4 upgrade preserved a registered peer’s key and remaining deadline through the explicit private handover, without an initial replay.
-The installed0.4 app reports screen access unavailable after its signing identity changed. Static banner delivery was exercised; an end-to-end desktop pair followed by its banner remains dependent on the user's permission refresh. No private desktop screenshots were saved for documentation.

## Stable signing verification

The local ad-hoc app and source build had the same exact-code designated requirement, yet the actual running app reported capturepermissionfalse after the user's toggle/reopen attempts. An existing Apple Development certificate signed two temporary copies with different bundle build numbers: fingerprints differed, while certificate-based designated requirements matched and strict signature verification passed. This proves identity stability, not granted Screen Recording authorization.

The shared sign-app helper reads explicit environment configuration or an ignored local certificate fingerprint, failing closed for malformed configuration or signer failure. A malformed configuration test stopped before signing. The installed app is certificate-signed, and source archive audit excluded the local fingerprint file and contents. A fresh permission entry for the new signer remains a human OS action; capture success must be verified separately.

### Certificate-signed desktop verification

After the user removed/re-added the installed app and enabled its fresh permission entry, native status reported permissiontrue. One authorized test registration completed across two displays with metadata and the banner presentation path. The measured pair was1423ms total with221ms gap (nominal1400/200); overlays were cleaned up and busy returnedfalse. The test key was then resolved after the banner display interval. No desktop images were saved. Two independent peer waits appeared during verification and were preserved. Pixel-level banner appearance was not independently inspected.
