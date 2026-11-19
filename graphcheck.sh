#!/bin/sh
# Checks the graph's filter, depth, colour groups and off-main-thread layout, without a window.
set -e
BIN=$("$(dirname "$0")/Dev/build.sh" --product jet-graphcheck)
exec "$BIN/jet-graphcheck" "$@"
