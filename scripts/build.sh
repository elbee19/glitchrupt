#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Glitchrupt.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Sounds"
python3 -B "$ROOT/scripts/generate_sounds.py"
swift "$ROOT/scripts/generate_brand.swift" "$ROOT/assets/brand"
cp "$ROOT/assets/brand/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/assets/brand/MenuIcon.png" "$APP/Contents/Resources/MenuIcon.png"
for SOUND in classic fracture brownout arc stutter; do
  cp "$ROOT/assets/sounds/$SOUND.wav" "$APP/Contents/Resources/Sounds/$SOUND.wav"
done
cp "$ROOT/assets/sounds/manifest.json" "$APP/Contents/Resources/Sounds/manifest.json"
ARCH="$(uname -m)"
xcrun swiftc -target "$ARCH-apple-macos14.0" -swift-version 5 -parse-as-library -warnings-as-errors -O -framework AppKit -framework CoreImage -framework ScreenCaptureKit -framework QuartzCore -framework AVFoundation "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/Glitchrupt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.glitchrupt.app</string>
<key>CFBundleName</key><string>Glitchrupt</string>
<key>CFBundleDisplayName</key><string>Glitchrupt</string>
<key>CFBundleExecutable</key><string>Glitchrupt</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Show a brief local attention cue over an in-memory desktop snapshot. Images are never saved or sent anywhere.</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Glitchrupt local requests</string><key>CFBundleURLSchemes</key><array><string>glitchrupt</string></array></dict></array>
</dict></plist>
PLIST
find "$APP" -type f -name '._*' -delete
codesign --force --sign "${GLITCHRUPT_SIGN_IDENTITY:--}" --identifier local.glitchrupt.app "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
