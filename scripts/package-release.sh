#!/bin/sh
# Package the built application and checksum using the bundle's version and CPU architecture.
set -eu

cd "$(dirname "$0")/.."
app="$PWD/.build/Lane.app"
/usr/bin/codesign --verify --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if ! printf '%s\n' "$version" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf 'Invalid bundle version: %s\n' "$version" >&2
    exit 1
fi
if [ "$#" -gt 0 ] && [ "$1" != "v$version" ]; then
    printf 'Tag %s does not match bundle version %s.\n' "$1" "$version" >&2
    exit 1
fi
architecture=$(/usr/bin/lipo -archs "$app/Contents/MacOS/Lane")
case "$architecture" in
    arm64|x86_64) ;;
    "x86_64 arm64"|"arm64 x86_64") architecture=universal ;;
    *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac

mkdir -p .build/dist
cd .build/dist
archive="Lane-$version-macOS-$architecture.zip"
temporary=$(mktemp -d .lane-package.XXXXXX)
trap 'rm -rf "$temporary"' EXIT
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary/$archive"
(
    cd "$temporary"
    /usr/bin/shasum -a 256 "$archive" > SHA256SUMS.txt
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt >&2
)
mv -f "$temporary/$archive" "$temporary/SHA256SUMS.txt" .
printf '%s\n' "$PWD/$archive"
