#!/bin/sh
# Syncs two simulated devices through a local bare repository. Pass --https to also test the network transport.
set -e
BIN=$("$(dirname "$0")/Dev/build.sh")
exec "$BIN/jet-selftest" "$@"
