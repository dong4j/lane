#!/bin/sh
# Assemble the SwiftPM executable into a locally launchable macOS application.
set -eu

cd "$(dirname "$0")/.."
configuration=${1:-debug}
swift build -c "$configuration" --product Portlane
binary_directory=$(swift build -c "$configuration" --show-bin-path)
app="$PWD/.build/Portlane.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/Portlane" "$app/Contents/MacOS/.Portlane.new"
mv "$app/Contents/MacOS/.Portlane.new" "$app/Contents/MacOS/Portlane"
cp "scripts/Info.plist" "$app/Contents/Info.plist"
cp "scripts/Portlane.icns" "docs/Porthole-MIT.txt" "$app/Contents/Resources/"
/usr/bin/codesign --force --sign - "$app"
printf '\n%s\n' "$app"
