#!/bin/sh
# Launches the Mac app without Xcode.
set -e
BIN=$("$(dirname "$0")/Dev/build.sh")
exec "$BIN/JetDev"
