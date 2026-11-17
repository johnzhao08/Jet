#!/bin/sh
# UI gesture tests. Optional second argument is an xcodebuild destination.
set -eu
cd "$(dirname "$0")"
case "${1:-mac}" in
    mac) scheme=JetMac; destination='platform=macOS' ;;
    ipad) scheme=Jet; destination='platform=iOS Simulator,name=iPad Pro 11-inch (M5)' ;;
    *) echo 'Usage: ./ui-test.sh [mac|ipad] [destination]' >&2; exit 2 ;;
esac
xcodegen generate --quiet
mkdir -p build.noindex
exec xcodebuild -project Jet.xcodeproj -scheme "$scheme" -configuration Debug \
    -destination "${2:-$destination}" -derivedDataPath "build.noindex/UITests-$scheme" \
    -resultBundlePath "build.noindex/UIResults-$scheme-$(date +%Y%m%d-%H%M%S).xcresult" \
    -parallel-testing-enabled NO test
