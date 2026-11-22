#!/bin/sh
# Build, notarize, and publish a Sparkle update for the public Mac release feed.
set -eu
cd "$(dirname "$0")"

REPO=johnzhao08/Jet-Mac-Releases
TEAM=BJ2UZLM855
NOTARY_PROFILE=${NOTARY_PROFILE:-Jet}
IDENTITY='Developer ID Application'
DERIVED=build.noindex/DerivedData
ARCHIVE=build.noindex/JetMac.xcarchive
OUTPUT=build.noindex/mac-release

if ! security find-identity -v -p codesigning | grep -F 'Developer ID Application:' | grep -Fq "($TEAM)"; then
    echo "Missing $IDENTITY certificate for Apple team $TEAM. Install it in Keychain Access first." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Missing notarization profile '$NOTARY_PROFILE'. Add it with xcrun notarytool store-credentials." >&2
    exit 1
fi
if ! gh repo view "$REPO" >/dev/null 2>&1; then
    echo "Public release repository $REPO is unavailable. Create it before publishing." >&2
    exit 1
fi

xcodegen generate --quiet
xcodebuild -resolvePackageDependencies -project Jet.xcodeproj -scheme JetMac -derivedDataPath "$DERIVED" >/dev/null
mkdir -p "$OUTPUT"
rm -rf "$ARCHIVE" "$OUTPUT/Jet.app" "$OUTPUT/Jet.zip"
xcodebuild -project Jet.xcodeproj -scheme JetMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    ENABLE_HARDENED_RUNTIME=YES JET_UPDATER_ENABLED=YES archive \
    > build.noindex/mac-archive.log 2>&1 || { tail -30 build.noindex/mac-archive.log; exit 1; }

APP="$ARCHIVE/Products/Applications/Jet.app"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/Jet.zip"
xcrun notarytool submit "$OUTPUT/Jet.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$OUTPUT/Jet.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/Jet.zip"
cp release-notes-mac.md "$OUTPUT/Jet.md"

SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_BIN/generate_appcast" -o "$OUTPUT/appcast.xml" \
    --download-url-prefix "https://github.com/$REPO/releases/latest/download/" "$OUTPUT"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
TAG="mac-v$VERSION-$BUILD"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists in $REPO." >&2
    exit 1
fi
gh release create "$TAG" "$OUTPUT/Jet.zip" "$OUTPUT/appcast.xml" "$OUTPUT/Jet.md" --repo "$REPO" \
    --title "Jet $VERSION ($BUILD) for Mac" --notes-file "$OUTPUT/Jet.md"
echo "Published Jet $VERSION ($BUILD). Sparkle will discover it from $REPO."
