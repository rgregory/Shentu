#!/bin/sh
# Builds build/Shentu.app from the Swift package (no Xcode needed). MenshenCore comes from
# ../menshen, or from MENSHEN_PATH (see Package.swift).
set -eu
cd "$(dirname "$0")/.."

if pgrep -f "$PWD/build/Shentu.app/Contents/MacOS/Shentu" >/dev/null; then
    echo "build-app.sh: Shentu is running from build/Shentu.app. Quit and reopen it after the build; until then it may keep running the old version." >&2
fi

swift build -c release --product Shentu
BIN=$(swift build -c release --show-bin-path)
VERSION=0.1.0

APP=build/Shentu.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Shentu" "$APP/Contents/MacOS/Shentu"

# App icon from assets/AppIcon.png (made from icon.jpg by scripts/make-icon.swift).
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Shentu</string>
    <key>CFBundleIdentifier</key><string>dev.shentu.app</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>Shentu</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Apps dropped on the Dock icon get the options pop-up. Rank None: Shentu never
         becomes the default for opening apps. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Application</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key>
            <array><string>com.apple.application-bundle</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign -s - --force "$APP"
codesign --verify --strict "$APP"
# Re-register so Finder and the Dock don't keep a stale (generic) icon for the rebuilt bundle.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP"
echo "built $APP ($VERSION)"
