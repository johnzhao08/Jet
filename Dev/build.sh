#!/bin/sh
# Builds the dev tools. With only the Command Line Tools installed, the newest macOS SDK cannot
# compile SwiftUI (its macro plugin ships with Xcode), so fall back to the macOS 26 SDK.
set -e
cd "$(dirname "$0")"
if xcode-select -p | grep -q CommandLineTools; then
    SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
    [ -n "$SDK" ] && set -- --sdk "$SDK" "$@"
fi
swift build "$@" >&2
swift build "$@" --show-bin-path
