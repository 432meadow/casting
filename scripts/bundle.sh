#!/bin/zsh
# Builds a release binary and wraps it in build/susurrus.app (no Xcode needed).
# The version comes from the latest `vX.Y.Z` git tag (override with VERSION=…); the build number
# is the commit count, so every release is newer than the last as far as Sparkle is concerned.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.1.0)}"
version="${version#v}"
build="$(git rev-list --count HEAD)"

# Where Sparkle looks for updates, and the public half of the key that signs them (see README).
feed_url="https://github.com/432meadow/susurrus/releases/latest/download/appcast.xml"
public_ed_key="LW4cEXSYoL44dUKbqu2XN4NB86CGdjVlyJlWoz+8OWE="

swift build -c release

app="build/susurrus.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp .build/release/Susurrus "$app/Contents/MacOS/susurrus"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
ditto .build/release/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>susurrus</string>
    <key>CFBundleDisplayName</key><string>susurrus</string>
    <key>CFBundleIdentifier</key><string>io.github.432meadow.susurrus</string>
    <key>CFBundleExecutable</key><string>susurrus</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>$feed_url</string>
    <key>SUPublicEDKey</key><string>$public_ed_key</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signatures so macOS will launch it locally. Sparkle's helpers are signed inside out,
# then the app itself; updates are trusted through their EdDSA signature, not the code signature.
codesign --force --deep --sign - "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$app"
echo "Built $app $version ($build)"
