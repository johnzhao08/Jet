#!/bin/sh
# Builds the Mac app (Debug) and opens it.
set -e
cd "$(dirname "$0")"
xcodegen generate --quiet
xcodebuild -project Jet.xcodeproj -scheme JetMac -configuration Debug -derivedDataPath build/DerivedData \
    build > build/mac-debug.log 2>&1 || { tail -20 build/mac-debug.log; exit 1; }
open build/DerivedData/Build/Products/Debug/Jet.app
