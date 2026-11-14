#!/bin/sh
# Builds the Mac app (Release) and installs it as /Applications/Jet.app, replacing an older copy.
#   ./install-mac.sh            build and install
#   ./install-mac.sh --no-copy  build only (build/Release/Jet.app)
set -e
cd "$(dirname "$0")"
xcodegen generate --quiet
mkdir -p build
xcodebuild -project Jet.xcodeproj -scheme JetMac -configuration Release -derivedDataPath build/DerivedData \
    build > build/mac-release.log 2>&1 || { tail -20 build/mac-release.log; exit 1; }
APP=build/DerivedData/Build/Products/Release/Jet.app
if [ "$1" = "--no-copy" ]; then
    echo "Built $APP"
    exit 0
fi
if pgrep -xq Jet && [ -d /Applications/Jet.app ]; then
    osascript -e 'quit app "Jet"' >/dev/null 2>&1 || true
    sleep 1
fi
rm -rf /Applications/Jet.app
ditto "$APP" /Applications/Jet.app
echo "Installed /Applications/Jet.app"
