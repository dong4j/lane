#!/bin/sh
# Assemble the SwiftPM executable into a locally launchable macOS application.
set -eu

cd "$(dirname "$0")/.."
configuration=${1:-debug}
swift build -c "$configuration" --product Lane
binary_directory=$(swift build -c "$configuration" --show-bin-path)
app="$PWD/.build/Lane.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/Lane" "$app/Contents/MacOS/.Lane.new"
mv "$app/Contents/MacOS/.Lane.new" "$app/Contents/MacOS/Lane"
cp "scripts/Info.plist" "$app/Contents/Info.plist"
cp "scripts/Lane.icns" "$app/Contents/Resources/Lane.icns"
cp "LICENSE" "$app/Contents/Resources/LICENSE.txt"
cp "docs/Porthole-MIT.txt" "$app/Contents/Resources/"
/usr/bin/codesign --force --sign - "$app"
printf '\n%s\n' "$app"
