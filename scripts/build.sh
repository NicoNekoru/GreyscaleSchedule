#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIRECTORY:h}"
PROJECT="$PROJECT_ROOT/GreyscaleSchedule.xcodeproj"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData-release"
APP="$DERIVED_DATA/Build/Products/Release/Greyscale Schedule.app"
EXTENSION="$APP/Contents/PlugIns/GreyscaleControl.appex"
APP_INTENTS="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
EXTENSION_INTENTS="$EXTENSION/Contents/Resources/Metadata.appintents/extract.actionsdata"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"$SCRIPT_DIRECTORY/test.sh"

SIGN_IDENTITY="${GREYSCALE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F'"' '/Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    print -u2 "No valid Apple Development signing identity was found."
    exit 1
fi

/usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "Greyscale Schedule" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet clean build

/bin/mkdir -p "$APP/Contents/Resources"
/usr/bin/iconutil \
    -c icns \
    "$PROJECT_ROOT/Resources/AppIcon.iconset" \
    -o "$APP/Contents/Resources/AppIcon.icns"

/usr/bin/codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$PROJECT_ROOT/Configuration/GreyscaleControl.entitlements" \
    "$EXTENSION"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

if ! /usr/bin/nm -m "$EXTENSION/Contents/MacOS/GreyscaleControl" \
    | rg '_NSExtensionMain' >/dev/null; then
    print -u2 "The Control Centre extension has the wrong entry point."
    exit 1
fi

for metadata in "$APP_INTENTS" "$EXTENSION_INTENTS"; do
    if [[ "$(/usr/bin/plutil -extract actions.SetGreyscaleFromControlIntent.supportedModes raw "$metadata")" != "8" ]] \
        || ! rg -q 'com.apple.link.systemProtocol.SetValue' "$metadata" \
        || ! rg -q 'com.apple.link.systemProtocol.ForegroundContinuable' "$metadata" \
        || rg -q 'OpenURLIntent' "$metadata"; then
        print -u2 "The Control Centre intent metadata is invalid: $metadata"
        exit 1
    fi
done

"$APP/Contents/MacOS/Greyscale Schedule" --self-test

# xcodebuild registers local products with Launch Services. Release artifacts
# are build inputs, not installed apps, so remove that transient registration.
/usr/bin/pluginkit -r "$EXTENSION" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$APP" >/dev/null 2>&1 || true
# App Intents indexes by bundle identifier, not just registration path. Removing
# a build product can also remove the installed app's action bindings. Restore
# the canonical installed copy, without registering a second gallery provider.
for installed_app in "/Applications/Greyscale Schedule.app" "$HOME/Applications/Greyscale Schedule.app"; do
    if [[ -d "$installed_app" ]]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -f "$installed_app"
        /usr/bin/pluginkit -a "$installed_app/Contents/PlugIns/GreyscaleControl.appex"
        break
    fi
done
print -r -- "$APP"
