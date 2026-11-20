#!/bin/sh
# Builds the next TestFlight release: bumps the build number, archives the iPad app, and uploads it
# to App Store Connect (the build then shows up in TestFlight after Apple's processing, ~10-30 min).
#
#   ./release.sh              bump, commit, archive, upload
#   ./release.sh --no-upload  same, but only export the signed .ipa to build.noindex/export
set -e
cd "$(dirname "$0")"

TEAM=BJ2UZLM855
DESTINATION=upload
[ "$1" = "--no-upload" ] && DESTINATION=export

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first; a release should match a commit." >&2
    exit 1
fi

# Bump the build number of the iPad app and its extensions (the share sheet and widgets must match the
# app's version); the Mac app has its own, under JetMac.
read OLD NEW VERSION <<EOF2
$(python3 - <<'PY'
import re
text = open("project.yml").read()
old = version = None
for name in ("Jet", "JetShare", "JetWidgets"):
    start = text.index("\n  %s:\n" % name)
    end = text.find("\n  Jet", start + 1)
    end = len(text) if end == -1 else end
    block = text[start:end]
    this = int(re.search(r'CURRENT_PROJECT_VERSION: "(\d+)"', block).group(1))
    assert old in (None, this), "build numbers of Jet and its extensions differ"
    old = this
    version = re.search(r'MARKETING_VERSION: "([^"]+)"', block).group(1)
    block = block.replace(f'CURRENT_PROJECT_VERSION: "{old}"', f'CURRENT_PROJECT_VERSION: "{old + 1}"', 1)
    text = text[:start] + block + text[end:]
open("project.yml", "w").write(text)
print(old, old + 1, version)
PY
)
EOF2
xcodegen generate --quiet
echo "Building Jet $VERSION ($NEW)"

rm -rf build.noindex/Jet.xcarchive build.noindex/export
mkdir -p build.noindex
# Provision the shared App Group for the app, share extension and widgets when archiving.
xcodebuild -project Jet.xcodeproj -scheme Jet -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build.noindex/DerivedData \
    -archivePath build.noindex/Jet.xcarchive -allowProvisioningUpdates CODE_SIGN_IDENTITY= archive > build.noindex/archive.log 2>&1 \
    || { tail -20 build.noindex/archive.log; echo "Archive failed; full log in build.noindex/archive.log" >&2; git checkout project.yml Jet.xcodeproj; exit 1; }

cat > build.noindex/ExportOptions.plist <<EOF
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
xcodebuild -exportArchive -archivePath build.noindex/Jet.xcarchive -exportOptionsPlist build.noindex/ExportOptions.plist \
    -exportPath build.noindex/export -allowProvisioningUpdates > build.noindex/export.log 2>&1 \
    || { tail -20 build.noindex/export.log; echo "Export failed; full log in build.noindex/export.log" >&2; git checkout project.yml Jet.xcodeproj; exit 1; }

git commit -q -m "Release $VERSION ($NEW)" project.yml Jet.xcodeproj
git tag "v$VERSION-$NEW"
if [ "$DESTINATION" = upload ]; then
    echo "Uploaded Jet $VERSION ($NEW). It appears in TestFlight once Apple finishes processing."
else
    echo "Exported build.noindex/export/Jet.ipa for $VERSION ($NEW)."
fi
