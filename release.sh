#!/bin/sh
# Builds the next TestFlight release: bumps the build number, archives the iPad app, and uploads it
# to App Store Connect (the build then shows up in TestFlight after Apple's processing, ~10-30 min).
#
#   ./release.sh              bump, commit, archive, upload
#   ./release.sh --no-upload  same, but only export the signed .ipa to build/export
set -e
cd "$(dirname "$0")"

TEAM=BJ2UZLM855
DESTINATION=upload
[ "$1" = "--no-upload" ] && DESTINATION=export

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first; a release should match a commit." >&2
    exit 1
fi

OLD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' project.yml)
NEW=$((OLD + 1))
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$OLD\"/CURRENT_PROJECT_VERSION: \"$NEW\"/" project.yml
xcodegen generate --quiet
echo "Building Jet $VERSION ($NEW)"

rm -rf build/Jet.xcarchive build/export
mkdir -p build
# Archive unsigned; the export step signs it for App Store distribution (no registered devices needed).
xcodebuild -project Jet.xcodeproj -scheme Jet -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
    -archivePath build/Jet.xcarchive CODE_SIGNING_ALLOWED=NO archive > build/archive.log 2>&1 \
    || { tail -20 build/archive.log; echo "Archive failed; full log in build/archive.log" >&2; git checkout project.yml Jet.xcodeproj; exit 1; }

cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath build/Jet.xcarchive -exportOptionsPlist build/ExportOptions.plist \
    -exportPath build/export -allowProvisioningUpdates > build/export.log 2>&1 \
    || { tail -20 build/export.log; echo "Export failed; full log in build/export.log" >&2; git checkout project.yml Jet.xcodeproj; exit 1; }

git commit -q -m "Release $VERSION ($NEW)" project.yml Jet.xcodeproj
git tag "v$VERSION-$NEW"
if [ "$DESTINATION" = upload ]; then
    echo "Uploaded Jet $VERSION ($NEW). It appears in TestFlight once Apple finishes processing."
else
    echo "Exported build/export/Jet.ipa for $VERSION ($NEW)."
fi
