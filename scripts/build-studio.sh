#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-$ROOT/.build/studio}"
APP="$DESTINATION/Lumen Studio.app"

cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/ModuleCache}"
BUILD_OPTIONS=(--disable-sandbox --cache-path "$ROOT/.build/cache" --config-path "$ROOT/.build/configuration" --security-path "$ROOT/.build/security")
swift build "${BUILD_OPTIONS[@]}" --configuration release --product LumenStudio
BIN="$(swift build "${BUILD_OPTIONS[@]}" --configuration release --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LumenStudio" "$APP/Contents/MacOS/LumenStudio"
chmod 755 "$APP/Contents/MacOS/LumenStudio"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>LumenStudio</string>
    <key>CFBundleIdentifier</key><string>dev.lumen.studio</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Lumen Studio</string>
    <key>CFBundleDisplayName</key><string>Lumen Studio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>LumenStudio</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

swift "$ROOT/scripts/make-studio-icon.swift" "$APP/Contents/Resources/LumenStudio.icns"
plutil -lint "$APP/Contents/Info.plist"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
