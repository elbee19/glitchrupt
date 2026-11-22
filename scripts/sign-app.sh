#!/bin/bash
# Use a consistent local signer without committing a developer's certificate identity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -eq 1 && -d "$1/Contents" ]] || { echo 'Usage: sign-app.sh /path/to/Glitchrupt.app' >&2; exit 2; }
APP="$(cd "$1" && pwd)"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == 'local.glitchrupt.app' ]] || { echo 'Refusing to sign a different app identifier.' >&2; exit 2; }
SIGNER="${GLITCHRUPT_SIGN_IDENTITY:-}"
if [[ -z "$SIGNER" && ( -e "$ROOT/.signing-identity" || -L "$ROOT/.signing-identity" ) ]]; then
  [[ -f "$ROOT/.signing-identity" && ! -L "$ROOT/.signing-identity" ]] || { echo 'Invalid local signing configuration.' >&2; exit 2; }
  IFS= read -r SIGNER < "$ROOT/.signing-identity"
  [[ "$SIGNER" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo 'Local signing identity must be a certificate SHA-1 fingerprint.' >&2; exit 2; }
fi
SIGNER="${SIGNER:--}"
# Ad-hoc signing remains the portable fallback, but is unsuitable for stable permission across builds.
# Missing/locked/expired configured certificates fail rather than silently changing identity.
find "$APP" -type f -name '._*' -delete
codesign --force --sign "$SIGNER" --identifier local.glitchrupt.app "$APP"
codesign --verify --deep --strict "$APP"
