#!/bin/sh
# Builds the Mac app (Debug) and opens it.
set -e
cd "$(dirname "$0")"
xcodegen generate --quiet
mkdir -p build.noindex
xcodebuild -project Jet.xcodeproj -scheme JetMac -configuration Debug -derivedDataPath build.noindex/DerivedData \
    build > build.noindex/mac-debug.log 2>&1 || { tail -20 build.noindex/mac-debug.log; exit 1; }
open build.noindex/DerivedData/Build/Products/Debug/Jet.app
