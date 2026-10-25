# Preparing a Glitchrupt release

This project prepares shareable artifacts locally. Packaging does not create a repository, upload files, register an MCP server, or enable a chat monitor.

## Reproduce the local build

Use a Mac with macOS 14 or later, Xcode Command Line Tools/Swift, Python 3.11 or later, and uv. From the source checkout:

```sh
uv sync --locked
uv run --locked pytest -q
./scripts/build.sh
./scripts/package.sh
```

The Swift app is built for the current Mac's architecture. The build script regenerates the five original 600 ms sounds using the checked-in standard-library Python generator, verifies their format and levels, bundles resources, and signs the app. The Python CLI/MCP dependencies are pinned in `uv.lock`; no Python environment is bundled inside the app.

Outputs in `dist/`:

- `Glitchrupt-<version>-source.zip`: editable source, generated audio, documentation, tests, and dependency lockfile.
- `Glitchrupt-<version>-macos-<architecture>.zip`: the built `Glitchrupt.app` only.
- `SHA256SUMS`: SHA-256 checksums for those archives.

`./scripts/package.sh --source-only` prepares just the source archive and its checksum when an app build is unavailable. Extract the source ZIP, enter its top-level directory, then run the commands above to rebuild it. Source ZIP entry ordering and timestamps are deterministic; compiled app bytes can vary with the compiler and signature.

The package script uses an explicit root allowlist and rejects symlinks, known local-machine paths, development state, capture/reference directories, and unexpected sound assets. It excludes Git metadata, virtual environments, caches, logs, AppleDouble sidecars, and build outputs from the source ZIP. Its app archive strips Finder metadata and resource forks. Review archive listings as an additional release check; the script cannot establish the provenance of arbitrary future source additions.

## Verify the candidate

```sh
shasum -a 256 -c dist/SHA256SUMS
unzip -l dist/Glitchrupt-0.3.0-source.zip
codesign --verify --deep --strict build/Glitchrupt.app
uv run --locked glitchrupt doctor
```

Run the checksum command from the project root; `SHA256SUMS` records paths relative to that root. Adjust the sample version if it has changed. Manually compare all five sounds, check the preview, then check one desktop cue with Screen Recording permission enabled. Confirm pause, cooldown, Reduce Motion, multi-display cleanup, and a CLI/MCP completion response on the candidate. User reports about desktop operation and automated tests cover different things; keep both in release notes.

A rebuild, changed bundle identifier, different path, or changed signing identity can cause macOS to require Screen Recording authorization again. Keep a stable bundle identifier and signing identity for distributed updates. Do not claim permission approval based only on build success.

## Publishing the source repository

Start from the audited source ZIP when local history or handoffs contain private setup details. Extract it into a separate checkout and use a GitHub noreply commit identity. Preserve the development checkout and its history locally. The source archive includes only the named synthetic demo GIF, MP4, and poster; its renderer inputs and regeneration steps are documented in [demo provenance](demo.md). Do not add real desktop recordings or screenshots.

Check the exported files, commit metadata, media, and README links before pushing. Publish source separately from compiled app releases; publishing the source does not make the development app a notarized download.

## Public downloadable apps

The default build is **ad-hoc signed**. This verifies local bundle integrity but does not identify a trusted publisher to Gatekeeper. It is suitable for development on the build Mac; it is not a notarized public release.

Before offering compiled downloads:

1. Establish an Apple Developer ID Application identity and choose a stable release signing process. Review hardened-runtime, entitlements, and minimum OS support against the actual app.
2. Sign the app and nested executable code with that identity, submit the distribution artifact to Apple's notarization service, and staple the accepted ticket to the app. Developer ID credentials and notarization secrets stay outside the repository.
3. Verify with `codesign --verify --deep --strict` and `spctl --assess --type execute --verbose` on the final app, then package and verify the final downloadable artifact. Check a clean Mac's first-launch and Screen Recording experience.
4. Publish a platform/architecture statement, checksums, MIT notice, dependency notices where required, and release notes that describe the snapshot overlay and permissions plainly.

The initial package does not promise a universal binary, Intel coverage, or notarization. Do not instruct users to bypass Gatekeeper as a substitute for a release signing process. No signing credentials or public publication are configured by this proof of concept.

When an actual test-channel distribution or review submission is confirmed, tag its exact verified source commit with an immutable annotated tag according to the repository's shared instructions. Preparing ZIPs locally is not distribution and does not justify a distribution tag.
