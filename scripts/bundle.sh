#!/bin/zsh
# Builds a release binary and wraps it in build/casting.app (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

app="build/casting.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Casting "$app/Contents/MacOS/casting"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>casting</string>
    <key>CFBundleDisplayName</key><string>casting</string>
    <key>CFBundleIdentifier</key><string>io.github.432meadow.casting</string>
    <key>CFBundleExecutable</key><string>casting</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally.
codesign --force --sign - "$app"
echo "Built $app"
