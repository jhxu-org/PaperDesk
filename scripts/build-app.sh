#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
architecture="${2:-$(uname -m)}"
swift build -c "$configuration" --arch "$architecture" --product PaperDesk
swift build -c "$configuration" --arch "$architecture" --product PaperDeskBridge
binary_directory="$(swift build -c "$configuration" --arch "$architecture" --show-bin-path)"
app_directory="$PWD/dist/PaperDesk.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/PaperDesk" "$app_directory/Contents/MacOS/PaperDesk.next"
mv -f "$app_directory/Contents/MacOS/PaperDesk.next" "$app_directory/Contents/MacOS/PaperDesk"
cp "$binary_directory/PaperDeskBridge" "$app_directory/Contents/MacOS/PaperDeskBridge.next"
mv -f "$app_directory/Contents/MacOS/PaperDeskBridge.next" "$app_directory/Contents/MacOS/PaperDeskBridge"
swift scripts/make-icon.swift "$PWD/Assets/Brand/PaperDesk-logo-v1.png" "$PWD/dist" "$PWD/BrowserExtension/icons"
ditto BrowserExtension "$app_directory/Contents/Resources/BrowserExtension"
ditto "$binary_directory/PaperDesk_PaperDesk.bundle" "$app_directory/Contents/Resources/PaperDesk_PaperDesk.bundle"
cp scripts/Info.plist "$app_directory/Contents/Info.plist"
cp LICENSE "$app_directory/Contents/Resources/LICENSE.txt"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$app_directory/Contents/Resources/PaperDeskLogo.icns"
codesign --force --sign - "$app_directory/Contents/MacOS/PaperDeskBridge"
codesign --force --sign - "$app_directory"
printf '%s\n' "$app_directory"
