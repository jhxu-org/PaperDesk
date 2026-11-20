#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
extension_version="$(/usr/bin/plutil -extract version raw -o - BrowserExtension/manifest.json)"
release_directory="$PWD/dist/Releases/$version"
mkdir -p "$release_directory"
stage_directory="$(mktemp -d "$PWD/.build/distribution.XXXXXX")"
trap 'rm -rf "$stage_directory"' EXIT

# Build each slice independently so Command Line Tools alone can create a universal app.
bash scripts/build-app.sh release arm64
swift build -c release --arch x86_64 --product PaperDesk
swift build -c release --arch x86_64 --product PaperDeskBridge
arm_directory="$(swift build -c release --arch arm64 --show-bin-path)"
intel_directory="$(swift build -c release --arch x86_64 --show-bin-path)"
app_directory="$stage_directory/PaperDesk.app"
ditto dist/PaperDesk.app "$app_directory"
for executable in PaperDesk PaperDeskBridge; do
    xcrun lipo -create "$arm_directory/$executable" "$intel_directory/$executable" -output "$app_directory/Contents/MacOS/$executable"
    xcrun lipo "$app_directory/Contents/MacOS/$executable" -verify_arch arm64 x86_64
    # Remove debug symbol entries containing local object and source paths.
    xcrun strip -S "$app_directory/Contents/MacOS/$executable"
done
codesign --force --sign - "$app_directory/Contents/MacOS/PaperDeskBridge"
codesign --force --sign - "$app_directory"
codesign --verify --deep --strict "$app_directory"

# Only explicit product files enter the packages; no workspace, defaults, library or credentials.
mkdir -p "$stage_directory/dmg" "$stage_directory/mac-zip" "$stage_directory/chrome/PaperDesk-Chrome"
ditto "$app_directory" "$stage_directory/dmg/PaperDesk.app"
ln -s /Applications "$stage_directory/dmg/Applications"
cp Distribution/安装指南.html "$stage_directory/dmg/Installation.html"
ditto BrowserExtension "$stage_directory/chrome/PaperDesk-Chrome"
cp LICENSE "$stage_directory/chrome/LICENSE.txt"
cp Distribution/安装指南.html "$stage_directory/chrome/Installation.html"
cp Distribution/安装指南.html "$release_directory/Installation.html"
ditto "$app_directory" "$stage_directory/mac-zip/PaperDesk.app"
cp Distribution/安装指南.html "$stage_directory/mac-zip/Installation.html"

hdiutil create -volname "PaperDesk $version" -srcfolder "$stage_directory/dmg" -format UDZO \
    -ov "$release_directory/PaperDesk-$version-macOS-universal.dmg"
ditto -c -k --sequesterRsrc "$stage_directory/mac-zip" "$release_directory/PaperDesk-$version-macOS-universal.zip"
python3 - "$stage_directory/chrome" "$release_directory/PaperDesk-Chrome-$extension_version.zip" <<'PY'
from pathlib import Path
import sys, zipfile
source = Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(source.rglob('*')):
        if path.is_file():
            archive.write(path, path.relative_to(source).as_posix())
PY

(cd "$release_directory" && shasum -a 256 "PaperDesk-$version-macOS-universal.dmg" \
    "PaperDesk-$version-macOS-universal.zip" "PaperDesk-Chrome-$extension_version.zip" Installation.html > SHA256SUMS.txt)
printf '%s\n' "$release_directory"
