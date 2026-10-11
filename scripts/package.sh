#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIRECTORY:h}"
APP="$PROJECT_ROOT/.build/DerivedData-release/Build/Products/Release/Greyscale Schedule.app"
OUTPUT_DIRECTORY="$PROJECT_ROOT/outputs"
STAGING_DIRECTORY="$(/usr/bin/mktemp -d /tmp/greyscale-schedule-release.XXXXXX)"

cleanup() {
    /bin/rm -rf "$STAGING_DIRECTORY"
}
trap cleanup EXIT

"$SCRIPT_DIRECTORY/build.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="$OUTPUT_DIRECTORY/GreyscaleSchedule-v$VERSION-macos-arm64.dmg"
/bin/mkdir -p "$OUTPUT_DIRECTORY"
/usr/bin/ditto "$APP" "$STAGING_DIRECTORY/Greyscale Schedule.app"
/bin/cp "$PROJECT_ROOT/docs/README.txt" "$STAGING_DIRECTORY/Read Me.txt"

/usr/bin/hdiutil create \
    -volname "Greyscale Schedule" \
    -srcfolder "$STAGING_DIRECTORY" \
    -format UDZO \
    -ov \
    "$OUTPUT"
/usr/bin/hdiutil verify "$OUTPUT"
print -r -- "$OUTPUT"
