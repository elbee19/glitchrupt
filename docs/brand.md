# Glitchrupt brand

An original standalone electrical jolt with an exclamation dot: a quick poke for attention. A displaced horizontal slice crosses both the glyph and the custom geometric wordmark. Cyan and magenta registration offsets, warm paper, and near-black evoke misprinted punk posters and digital disruption.

The design uses original editable polygon geometry. It contains no character artwork, costume insignia, mask eyes, film typography, or reference-film assets. It is not affiliated with Marvel or Sony. Original construction does not establish trademark clearance; check the name and mark before a public launch.

## Files and regeneration

- `assets/brand/logo.svg` / `logo.png`: horizontal lockup with custom outlined wordmark.
- `assets/brand/icon.svg` / `icon.png`: standalone full-color glyph on paper.
- `assets/brand/AppIcon.icns`: rounded native app tile with transparent outer padding.
- `assets/brand/MenuIcon.png`: transparent monochrome template at 36 × 36 pixels, displayed at 18 points.
- `scripts/generate_brand.swift`: source of all shapes and exported assets. Uses only macOS AppKit and `iconutil`; no fonts or external dependencies.

From the repository root:

```sh
swift scripts/generate_brand.swift assets/brand
```

SVGs are resolution independent. All raster outputs are rendered from the same geometry. Keep the jolt, exclamation dot, and interrupted slice readable; do not stretch the mark or replace the wordmark with a film-associated font. Treat the menu image as an AppKit template so it follows the menu bar's light/dark appearance.

Colors: paper `#F5F0E7`, ink `#181817`, cyan `#00C9DB`, magenta `#F23879`. Brand source and generated assets use the repository's MIT license.
